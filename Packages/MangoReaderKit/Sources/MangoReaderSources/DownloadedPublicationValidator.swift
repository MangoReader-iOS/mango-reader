import Foundation
import MangoReaderDomain
import ReadiumZIPFoundation

/// Resource ceilings applied before a completed network transfer is admitted
/// to OfflineDownloads. They constrain metadata as well as expansion, so a ZIP
/// bomb is rejected without extracting it.
public struct DownloadValidationLimits: Codable, Hashable, Sendable {
    public var maximumFileBytes: UInt64
    public var maximumEntryCount: Int
    public var maximumEntryUncompressedBytes: UInt64
    public var maximumTotalUncompressedBytes: UInt64
    public var maximumExpansionRatio: Double
    public var maximumCBZPageCount: Int
    public var maximumCBZPageBytes: UInt64

    public init(
        maximumFileBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024,
        maximumEntryCount: Int = 100_000,
        maximumEntryUncompressedBytes: UInt64 = 512 * 1_024 * 1_024,
        maximumTotalUncompressedBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024,
        maximumExpansionRatio: Double = 200,
        maximumCBZPageCount: Int = 50_000,
        maximumCBZPageBytes: UInt64 = 128 * 1_024 * 1_024
    ) {
        self.maximumFileBytes = max(1, maximumFileBytes)
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.maximumEntryUncompressedBytes = max(1, maximumEntryUncompressedBytes)
        self.maximumTotalUncompressedBytes = max(1, maximumTotalUncompressedBytes)
        self.maximumExpansionRatio = max(1, maximumExpansionRatio)
        self.maximumCBZPageCount = max(1, maximumCBZPageCount)
        self.maximumCBZPageBytes = max(1, maximumCBZPageBytes)
    }

    public static let publication = Self()
}

public enum DownloadValidationError: Error, Codable, Hashable, Sendable, LocalizedError {
    case missingFile
    case emptyFile
    case fileTooLarge
    case invalidPDF
    case invalidZIP
    case unsafeArchivePath(String)
    case symbolicLink(String)
    case duplicateArchivePath(String)
    case tooManyEntries
    case entryTooLarge(String)
    case expandedArchiveTooLarge
    case excessiveExpansion(String)
    case malformedEPUB
    case noReadableImages
    case tooManyImages
    case imageTooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .missingFile: "The downloaded file is missing."
        case .emptyFile: "The downloaded file is empty."
        case .fileTooLarge: "The downloaded publication exceeds the configured size limit."
        case .invalidPDF: "The server response is not a valid PDF."
        case .invalidZIP: "The server response is not a valid ZIP-based publication."
        case let .unsafeArchivePath(path): "The archive contains an unsafe path: \(path)"
        case let .symbolicLink(path): "The archive contains a symbolic link: \(path)"
        case let .duplicateArchivePath(path): "The archive contains a duplicate path: \(path)"
        case .tooManyEntries: "The archive contains too many entries."
        case let .entryTooLarge(path): "An archive entry is too large: \(path)"
        case .expandedArchiveTooLarge: "The expanded archive exceeds the configured size limit."
        case let .excessiveExpansion(path): "An archive entry expands excessively: \(path)"
        case .malformedEPUB: "The EPUB package structure is incomplete."
        case .noReadableImages: "The comic archive contains no supported images."
        case .tooManyImages: "The comic archive contains too many pages."
        case let .imageTooLarge(path): "A comic page is too large: \(path)"
        }
    }
}

public struct DownloadedPublicationValidation: Codable, Hashable, Sendable {
    public var format: PublicationFormat
    public var fileBytes: UInt64
    public var entryCount: Int?
    public var imageCount: Int?

    public init(format: PublicationFormat, fileBytes: UInt64, entryCount: Int? = nil, imageCount: Int? = nil) {
        self.format = format
        self.fileBytes = fileBytes
        self.entryCount = entryCount
        self.imageCount = imageCount
    }
}

/// Validates completed downloads in-place before the coordinator atomically
/// moves them into the durable offline library. No archive entry is extracted.
public struct DownloadedPublicationValidator: Sendable {
    public let limits: DownloadValidationLimits

    public init(limits: DownloadValidationLimits = .publication) {
        self.limits = limits
    }

    @concurrent
    public func validate(
        _ url: URL,
        expectedFormat: PublicationFormat
    ) async throws -> DownloadedPublicationValidation {
        try Task.checkCancellation()
        let fileBytes = try fileSize(at: url)

        switch expectedFormat {
        case .pdf:
            try validatePDF(at: url)
            return DownloadedPublicationValidation(format: .pdf, fileBytes: fileBytes)

        case .epub:
            let inspection = try await inspectZIP(at: url)
            let paths = Set(inspection.entries.map { $0.path.lowercased() })
            guard
                paths.contains("meta-inf/container.xml"),
                paths.contains(where: { $0.hasSuffix(".opf") })
            else {
                throw DownloadValidationError.malformedEPUB
            }
            return DownloadedPublicationValidation(
                format: .epub,
                fileBytes: fileBytes,
                entryCount: inspection.entries.count
            )

        case .cbz, .remoteImageSequence:
            let inspection = try await inspectZIP(at: url)
            let images = inspection.entries.filter { entry in
                entry.isFile && Self.isSupportedImagePath(entry.path)
            }
            guard !images.isEmpty else {
                throw DownloadValidationError.noReadableImages
            }
            guard images.count <= limits.maximumCBZPageCount else {
                throw DownloadValidationError.tooManyImages
            }
            for image in images {
                try Task.checkCancellation()
                guard image.uncompressedBytes > 0, image.uncompressedBytes <= limits.maximumCBZPageBytes else {
                    throw DownloadValidationError.imageTooLarge(image.path)
                }
            }
            return DownloadedPublicationValidation(
                format: .cbz,
                fileBytes: fileBytes,
                entryCount: inspection.entries.count,
                imageCount: images.count
            )
        }
    }

    private func fileSize(at url: URL) throws -> UInt64 {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw DownloadValidationError.missingFile
        }
        guard values.isRegularFile == true else {
            throw DownloadValidationError.missingFile
        }
        let size = UInt64(max(0, values.fileSize ?? 0))
        guard size > 0 else {
            throw DownloadValidationError.emptyFile
        }
        guard size <= limits.maximumFileBytes else {
            throw DownloadValidationError.fileTooLarge
        }
        return size
    }

    private func validatePDF(at url: URL) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw DownloadValidationError.missingFile
        }
        defer { try? handle.close() }
        let prefix: Data
        do {
            prefix = try handle.read(upToCount: 5) ?? Data()
        } catch {
            throw DownloadValidationError.invalidPDF
        }
        guard prefix == Data("%PDF-".utf8) else {
            throw DownloadValidationError.invalidPDF
        }
    }

    private func inspectZIP(at url: URL) async throws -> ZIPInspection {
        let archive: Archive
        do {
            archive = try await Archive(url: url, accessMode: .read)
        } catch {
            throw DownloadValidationError.invalidZIP
        }

        let archiveEntries: [Entry]
        do {
            archiveEntries = try await archive.entries()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DownloadValidationError.invalidZIP
        }
        guard archiveEntries.count <= limits.maximumEntryCount else {
            throw DownloadValidationError.tooManyEntries
        }

        var entries: [ZIPEntryInspection] = []
        entries.reserveCapacity(archiveEntries.count)
        var totalUncompressed: UInt64 = 0
        var normalizedPaths: Set<String> = []

        for entry in archiveEntries {
            try Task.checkCancellation()
            let path = entry.path
            guard Self.isSafeArchivePath(path) else {
                throw DownloadValidationError.unsafeArchivePath(path)
            }
            guard entry.type != .symlink else {
                throw DownloadValidationError.symbolicLink(path)
            }
            let normalized = path.precomposedStringWithCanonicalMapping.lowercased()
            guard normalizedPaths.insert(normalized).inserted else {
                throw DownloadValidationError.duplicateArchivePath(path)
            }

            let uncompressed = entry.uncompressedSize
            let compressed = entry.compressedSize
            guard uncompressed <= limits.maximumEntryUncompressedBytes else {
                throw DownloadValidationError.entryTooLarge(path)
            }
            let (newTotal, overflow) = totalUncompressed.addingReportingOverflow(uncompressed)
            guard !overflow, newTotal <= limits.maximumTotalUncompressedBytes else {
                throw DownloadValidationError.expandedArchiveTooLarge
            }
            totalUncompressed = newTotal

            if uncompressed > 0 {
                guard compressed > 0,
                      Double(uncompressed) / Double(compressed) <= limits.maximumExpansionRatio
                else {
                    throw DownloadValidationError.excessiveExpansion(path)
                }
            }

            entries.append(
                ZIPEntryInspection(
                    path: path,
                    uncompressedBytes: uncompressed,
                    isFile: entry.type == .file
                )
            )
        }

        return ZIPInspection(entries: entries)
    }

    static func isSafeArchivePath(_ path: String) -> Bool {
        guard
            !path.isEmpty,
            !path.hasPrefix("/"),
            !path.hasPrefix("\\"),
            !path.contains("\\"),
            !path.contains(":"),
            !path.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(where: { $0 == ".." })
    }

    private static func isSupportedImagePath(_ path: String) -> Bool {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp":
            true
        default:
            false
        }
    }
}

private struct ZIPInspection: Sendable {
    var entries: [ZIPEntryInspection]
}

private struct ZIPEntryInspection: Sendable {
    var path: String
    var uncompressedBytes: UInt64
    var isFile: Bool
}
