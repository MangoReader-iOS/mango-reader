import CryptoKit
import Foundation
import MankoDomain
import ReadiumZIPFoundation

public struct ImportLimits: Equatable, Sendable {
    public var maximumFileBytes: Int64
    public var maximumArchiveEntries: Int
    public var maximumUncompressedBytes: UInt64
    public var maximumCompressionRatio: Double

    public init(
        maximumFileBytes: Int64 = 8 * 1_024 * 1_024 * 1_024,
        maximumArchiveEntries: Int = 100_000,
        maximumUncompressedBytes: UInt64 = 20 * 1_024 * 1_024 * 1_024,
        maximumCompressionRatio: Double = 200
    ) {
        self.maximumFileBytes = maximumFileBytes
        self.maximumArchiveEntries = maximumArchiveEntries
        self.maximumUncompressedBytes = maximumUncompressedBytes
        self.maximumCompressionRatio = maximumCompressionRatio
    }
}

public struct ImportedPublication: Codable, Hashable, Sendable {
    public let format: PublicationFormat
    public let originalFileName: String
    public let relativePath: String
    public let sha256Hex: String
    public let fileSize: Int64
    public let wasDuplicate: Bool

    public init(
        format: PublicationFormat,
        originalFileName: String,
        relativePath: String,
        sha256Hex: String,
        fileSize: Int64,
        wasDuplicate: Bool
    ) {
        self.format = format
        self.originalFileName = originalFileName
        self.relativePath = relativePath
        self.sha256Hex = sha256Hex
        self.fileSize = fileSize
        self.wasDuplicate = wasDuplicate
    }
}

public enum LocalImportError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedExtension(String)
    case unexpectedFormat(expected: PublicationFormat, actual: PublicationFormat)
    case sourceIsNotRegularFile
    case fileTooLarge(Int64)
    case invalidMagicBytes
    case invalidArchive
    case unsafeArchivePath(String)
    case symbolicLink(String)
    case tooManyEntries(Int)
    case decompressionLimitExceeded
    case invalidEPUB
    case imageArchiveContainsNoImages
    case unableToReadSource

    public var errorDescription: String? {
        switch self {
        case let .unsupportedExtension(fileExtension):
            "The .\(fileExtension) file type is not supported."
        case let .unexpectedFormat(expected, actual):
            "Choose a \(expected.rawValue.uppercased()) file. The selected file is \(actual.rawValue.uppercased())."
        case .sourceIsNotRegularFile:
            "Only regular publication files can be imported."
        case let .fileTooLarge(bytes):
            "The selected file is too large (\(bytes) bytes)."
        case .invalidMagicBytes:
            "The file contents do not match its extension."
        case .invalidArchive:
            "The publication archive is malformed or unreadable."
        case let .unsafeArchivePath(path):
            "The archive contains an unsafe path: \(path)"
        case let .symbolicLink(path):
            "The archive contains a symbolic link: \(path)"
        case let .tooManyEntries(count):
            "The archive contains too many entries (\(count))."
        case .decompressionLimitExceeded:
            "The archive expands beyond Manko's safety limit."
        case .invalidEPUB:
            "The EPUB container is missing required metadata."
        case .imageArchiveContainsNoImages:
            "The image archive does not contain a supported image."
        case .unableToReadSource:
            "Manko could not read the selected file."
        }
    }
}

/// Serializes imports so two simultaneous selections cannot race on the same digest path.
public actor LocalPublicationImporter {
    private let isPrivate: Bool
    private let destinationDirectory: URL
    private let limits: ImportLimits

    public init(storagePaths: StoragePaths, limits: ImportLimits = ImportLimits()) {
        isPrivate = storagePaths.isPrivate
        destinationDirectory = storagePaths.libraryFilesDirectory
        self.limits = limits
    }

    public init(destinationDirectory: URL, limits: ImportLimits = ImportLimits()) {
        isPrivate = false
        self.destinationDirectory = destinationDirectory
        self.limits = limits
    }

    public func importPublication(
        from sourceURL: URL,
        expectedFormat: PublicationFormat? = nil
    ) async throws -> ImportedPublication {
        let didAccessSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        let resourceValues: URLResourceValues
        do {
            resourceValues = try sourceURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
        } catch {
            throw LocalImportError.unableToReadSource
        }
        guard resourceValues.isRegularFile == true, resourceValues.isSymbolicLink != true else {
            throw LocalImportError.sourceIsNotRegularFile
        }

        let fileSize = Int64(resourceValues.fileSize ?? 0)
        guard fileSize >= 0 else {
            throw LocalImportError.unableToReadSource
        }
        guard fileSize <= limits.maximumFileBytes else {
            throw LocalImportError.fileTooLarge(fileSize)
        }

        let fileExtension = sourceURL.pathExtension.lowercased()
        let format: PublicationFormat
        switch fileExtension {
        case "epub":
            format = .epub
        case "pdf":
            format = .pdf
        case "cbz", "zip":
            format = .cbz
        default:
            throw LocalImportError.unsupportedExtension(fileExtension)
        }
        if let expectedFormat, format != expectedFormat {
            throw LocalImportError.unexpectedFormat(expected: expectedFormat, actual: format)
        }

        try validateMagicBytes(at: sourceURL, format: format)
        if format == .epub || format == .cbz {
            try await validateArchive(at: sourceURL, format: format)
        }

        let digest = try Self.sha256Hex(of: sourceURL)
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        try StoragePaths.applyStandardProtection(to: destinationDirectory)

        let storedExtension = format == .cbz ? "cbz" : fileExtension
        let relativePath = "\(digest).\(storedExtension)"
        let destinationURL = destinationDirectory.appending(
            path: relativePath,
            directoryHint: .notDirectory
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            return ImportedPublication(
                format: format,
                originalFileName: sourceURL.lastPathComponent,
                relativePath: relativePath,
                sha256Hex: digest,
                fileSize: fileSize,
                wasDuplicate: true
            )
        }

        let stagingURL = destinationDirectory.appending(
            path: ".\(UUID().uuidString).importing",
            directoryHint: .notDirectory
        )
        defer { try? fileManager.removeItem(at: stagingURL) }
        do {
            try fileManager.copyItem(at: sourceURL, to: stagingURL)
            try FileManager.default.setAttributes([.protectionKey: isPrivate ? FileProtectionType.complete : .completeUntilFirstUserAuthentication], ofItemAtPath: stagingURL.path)
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        } catch {
            throw LocalImportError.unableToReadSource
        }

        return ImportedPublication(
            format: format,
            originalFileName: sourceURL.lastPathComponent,
            relativePath: relativePath,
            sha256Hex: digest,
            fileSize: fileSize,
            wasDuplicate: false
        )
    }

    private func validateMagicBytes(at url: URL, format: PublicationFormat) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw LocalImportError.unableToReadSource
        }
        defer { try? handle.close() }

        let header: Data
        do {
            header = try handle.read(upToCount: 8) ?? Data()
        } catch {
            throw LocalImportError.unableToReadSource
        }

        switch format {
        case .pdf:
            guard header.starts(with: Data("%PDF-".utf8)) else {
                throw LocalImportError.invalidMagicBytes
            }
        case .epub, .cbz:
            let signatures: [Data] = [
                Data([0x50, 0x4B, 0x03, 0x04]),
                Data([0x50, 0x4B, 0x05, 0x06]),
                Data([0x50, 0x4B, 0x07, 0x08]),
            ]
            guard signatures.contains(where: header.starts(with:)) else {
                throw LocalImportError.invalidMagicBytes
            }
        case .remoteImageSequence:
            throw LocalImportError.invalidMagicBytes
        }
    }

    private func validateArchive(at url: URL, format: PublicationFormat) async throws {
        let archive: Archive
        do {
            archive = try await Archive(url: url, accessMode: .read)
        } catch {
            throw LocalImportError.invalidArchive
        }

        var count = 0
        var totalUncompressed: UInt64 = 0
        var containsImage = false
        var hasEPUBMimetype = false
        var hasEPUBContainer = false

        do {
            for entry in try await archive.entries() {
                count += 1
                guard count <= limits.maximumArchiveEntries else {
                    throw LocalImportError.tooManyEntries(count)
                }
                try Self.validateArchivePath(entry.path)
                guard entry.type != .symlink else {
                    throw LocalImportError.symbolicLink(entry.path)
                }

                let (sum, overflow) = totalUncompressed.addingReportingOverflow(entry.uncompressedSize)
                guard !overflow, sum <= limits.maximumUncompressedBytes else {
                    throw LocalImportError.decompressionLimitExceeded
                }
                totalUncompressed = sum

                if entry.uncompressedSize > 0 {
                    guard entry.compressedSize > 0 else {
                        throw LocalImportError.decompressionLimitExceeded
                    }
                    let ratio = Double(entry.uncompressedSize) / Double(entry.compressedSize)
                    guard ratio <= limits.maximumCompressionRatio else {
                        throw LocalImportError.decompressionLimitExceeded
                    }
                }

                let normalizedPath = entry.path.replacingOccurrences(of: "\\", with: "/")
                let lowercasedPath = normalizedPath.lowercased()
                if Self.supportedImageExtensions.contains(URL(fileURLWithPath: lowercasedPath).pathExtension) {
                    containsImage = true
                }
                if normalizedPath == "META-INF/container.xml" {
                    hasEPUBContainer = true
                }
                if normalizedPath == "mimetype" {
                    let accumulator = LimitedDataAccumulator(maximumBytes: 128)
                    _ = try await archive.extract(entry) { chunk in
                        try await accumulator.append(chunk)
                    }
                    let data = await accumulator.value()
                    hasEPUBMimetype = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip"
                }
            }
        } catch let error as LocalImportError {
            throw error
        } catch {
            throw LocalImportError.invalidArchive
        }

        switch format {
        case .epub:
            guard hasEPUBMimetype, hasEPUBContainer else {
                throw LocalImportError.invalidEPUB
            }
        case .cbz:
            guard containsImage else {
                throw LocalImportError.imageArchiveContainsNoImages
            }
        case .pdf, .remoteImageSequence:
            break
        }
    }

    private static let supportedImageExtensions: Set<String> = [
        "avif", "gif", "heic", "heif", "jpeg", "jpg", "png", "webp",
    ]

    private static func validateArchivePath(_ path: String) throws {
        guard !path.isEmpty, !path.contains("\0") else {
            throw LocalImportError.unsafeArchivePath(path)
        }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/") else {
            throw LocalImportError.unsafeArchivePath(path)
        }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("..") else {
            throw LocalImportError.unsafeArchivePath(path)
        }
        if let first = components.first, first.contains(":") {
            throw LocalImportError.unsafeArchivePath(path)
        }
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw LocalImportError.unableToReadSource
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            throw LocalImportError.unableToReadSource
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

actor LimitedDataAccumulator {
    private let maximumBytes: Int
    private var data = Data()

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func append(_ chunk: Data) throws {
        guard data.count + chunk.count <= maximumBytes else {
            throw MankoDataError.corruptBackup("An archive entry expanded beyond its limit.")
        }
        data.append(chunk)
    }

    func value() -> Data {
        data
    }
}
