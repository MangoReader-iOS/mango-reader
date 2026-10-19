import CoreGraphics
import Foundation
import ImageIO
import MankoDomain
import UniformTypeIdentifiers

public enum CustomCoverStoreError: Error, Equatable, Sendable, LocalizedError {
    case emptyImage
    case inputTooLarge(maximumBytes: Int)
    case unsupportedImage
    case invalidDimensions
    case imageTooLarge(maximumPixels: Int)
    case encodingFailed
    case invalidManagedPath

    public var errorDescription: String? {
        switch self {
        case .emptyImage:
            "The selected image is empty."
        case let .inputTooLarge(maximumBytes):
            "The selected image is larger than the \(ByteCountFormatter.string(fromByteCount: Int64(maximumBytes), countStyle: .file)) limit."
        case .unsupportedImage:
            "Choose a valid JPEG, PNG, HEIC, GIF, TIFF, or WebP image."
        case .invalidDimensions:
            "Manko could not read the selected image dimensions."
        case let .imageTooLarge(maximumPixels):
            "The selected image exceeds the \(maximumPixels / 1_000_000)-megapixel safety limit."
        case .encodingFailed:
            "Manko could not create the custom cover."
        case .invalidManagedPath:
            "The stored custom-cover path is invalid."
        }
    }
}

/// Owns user-selected, app-managed cover thumbnails. The actor keeps image
/// parsing, downsampling, encoding, and file I/O away from MainActor.
public actor CustomCoverStore {
    public struct Configuration: Hashable, Sendable {
        public var maximumInputBytes: Int
        public var maximumPixelCount: Int
        public var maximumDimension: Int
        public var jpegQuality: Double

        public init(
            maximumInputBytes: Int = 50 * 1_024 * 1_024,
            maximumPixelCount: Int = 100_000_000,
            maximumDimension: Int = 1_600,
            jpegQuality: Double = 0.88
        ) {
            self.maximumInputBytes = maximumInputBytes
            self.maximumPixelCount = maximumPixelCount
            self.maximumDimension = maximumDimension
            self.jpegQuality = min(1, max(0, jpegQuality))
        }
    }

    public nonisolated let directory: URL
    private let storagePaths: StoragePaths
    private let configuration: Configuration
    private let fileManager: FileManager

    public init(
        storagePaths: StoragePaths,
        configuration: Configuration = Configuration(),
        fileManager: FileManager = .default
    ) {
        self.storagePaths = storagePaths
        directory = storagePaths.customCoversDirectory
        self.configuration = configuration
        self.fileManager = fileManager
    }

    /// Returns a relative managed filename suitable for `Work.customCoverPath`.
    /// A unique name lets the database switch to the new cover before the old
    /// file is removed, avoiding a broken persisted path if saving fails.
    public func store(_ data: Data, for workID: WorkID) throws -> String {
        guard !data.isEmpty else { throw CustomCoverStoreError.emptyImage }
        guard data.count <= configuration.maximumInputBytes else {
            throw CustomCoverStoreError.inputTooLarge(maximumBytes: configuration.maximumInputBytes)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw CustomCoverStoreError.unsupportedImage
        }
        guard
            let typeIdentifier = CGImageSourceGetType(source) as String?,
            let imageType = UTType(typeIdentifier),
            imageType.conforms(to: .image),
            CGImageSourceGetCount(source) > 0
        else {
            throw CustomCoverStoreError.unsupportedImage
        }
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ) as? [CFString: Any],
            let width = Self.integer(properties[kCGImagePropertyPixelWidth]),
            let height = Self.integer(properties[kCGImagePropertyPixelHeight]),
            width > 0,
            height > 0
        else {
            throw CustomCoverStoreError.invalidDimensions
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= configuration.maximumPixelCount else {
            throw CustomCoverStoreError.imageTooLarge(maximumPixels: configuration.maximumPixelCount)
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: configuration.maximumDimension,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            throw CustomCoverStoreError.unsupportedImage
        }

        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        else {
            throw CustomCoverStoreError.encodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            thumbnail,
            [kCGImageDestinationLossyCompressionQuality: configuration.jpegQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw CustomCoverStoreError.encodingFailed
        }

        let filename = "\(workID.rawValue.uuidString.lowercased())-\(UUID().uuidString.lowercased()).jpg"
        let destinationURL = directory.appending(path: filename, directoryHint: .notDirectory)
        try (output as Data).write(to: destinationURL, options: .atomic)
        try storagePaths.applyProtection(to: destinationURL)
        return filename
    }

    public func remove(path: String) throws {
        let url = try managedURL(for: path)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    public func contains(path: String) throws -> Bool {
        fileManager.fileExists(atPath: try managedURL(for: path).path)
    }

    public nonisolated func managedURL(for path: String) throws -> URL {
        guard
            !path.isEmpty,
            path == URL(fileURLWithPath: path).lastPathComponent,
            !path.contains("/"),
            !path.contains("\\")
        else {
            throw CustomCoverStoreError.invalidManagedPath
        }
        return directory.appending(path: path, directoryHint: .notDirectory)
    }

    /// Resolves a persisted file URL back to its managed relative filename.
    /// This keeps deletion and cloud-sanitization paths from accepting an
    /// arbitrary file outside the cover directory.
    public nonisolated func managedPath(for url: URL) throws -> String {
        let standardizedURL = url.standardizedFileURL
        let standardizedDirectory = directory.standardizedFileURL
        guard
            standardizedURL.isFileURL,
            standardizedURL.deletingLastPathComponent() == standardizedDirectory
        else {
            throw CustomCoverStoreError.invalidManagedPath
        }
        return try managedURL(for: standardizedURL.lastPathComponent).lastPathComponent
    }

    private nonisolated static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        return value as? Int
    }
}
