import CoreGraphics
import Foundation
import MankoDomain

public struct PublicationProtectionEvidence: Codable, Hashable, Sendable {
    public let fileExtension: String
    public let archiveEntryPaths: Set<String>
    public let hasEncryptedArchiveEntries: Bool
    public let pdfIsEncrypted: Bool
    public let pdfIsUnlocked: Bool

    public init(
        fileExtension: String,
        archiveEntryPaths: Set<String> = [],
        hasEncryptedArchiveEntries: Bool = false,
        pdfIsEncrypted: Bool = false,
        pdfIsUnlocked: Bool = true
    ) {
        self.fileExtension = fileExtension.lowercased()
        self.archiveEntryPaths = Set(archiveEntryPaths.map { $0.lowercased() })
        self.hasEncryptedArchiveEntries = hasEncryptedArchiveEntries
        self.pdfIsEncrypted = pdfIsEncrypted
        self.pdfIsUnlocked = pdfIsUnlocked
    }
}

public protocol PublicationProtectionDetecting: Sendable {
    func protection(at url: URL) async throws -> PublicationProtection
}

public struct DefaultPublicationProtectionDetector: PublicationProtectionDetecting {
    private let limits: ZIPInspectionLimits

    public init(limits: ZIPInspectionLimits = .publication) {
        self.limits = limits
    }

    public func protection(for evidence: PublicationProtectionEvidence) -> PublicationProtection {
        if evidence.fileExtension == "lcpl" || evidence.archiveEntryPaths.contains("meta-inf/license.lcpl") {
            return .readiumLCP
        }
        if evidence.archiveEntryPaths.contains("meta-inf/rights.xml") {
            return .adobeDRM
        }
        if evidence.fileExtension == "pdf", evidence.pdfIsEncrypted, !evidence.pdfIsUnlocked {
            return .passwordProtectedPDF
        }
        if evidence.hasEncryptedArchiveEntries {
            return .unknown
        }
        return .none
    }

    @concurrent
    public func protection(at url: URL) async throws -> PublicationProtection {
        let fileExtension = url.pathExtension.lowercased()
        if fileExtension == "lcpl" {
            return .readiumLCP
        }

        if fileExtension == "pdf" {
            let document = CGPDFDocument(url as CFURL)
            return protection(
                for: PublicationProtectionEvidence(
                    fileExtension: fileExtension,
                    pdfIsEncrypted: document?.isEncrypted ?? false,
                    pdfIsUnlocked: document?.isUnlocked ?? true
                )
            )
        }

        guard ["epub", "cbz", "zip"].contains(fileExtension) else {
            return .none
        }
        let inspection = try ZIPStructureInspector(limits: limits).inspect(url: url)
        return protection(
            for: PublicationProtectionEvidence(
                fileExtension: fileExtension,
                archiveEntryPaths: Set(inspection.entries.map(\.path)),
                hasEncryptedArchiveEntries: inspection.entries.contains(where: \.isEncrypted)
            )
        )
    }
}

public struct LocalPublicationValidation: Codable, Hashable, Sendable {
    public let url: URL
    public let format: PublicationFormat
    public let protection: PublicationProtection
    public let fileSize: UInt64
    public let archiveEntryCount: Int?
    public let imageCount: Int?

    public init(
        url: URL,
        format: PublicationFormat,
        protection: PublicationProtection,
        fileSize: UInt64,
        archiveEntryCount: Int? = nil,
        imageCount: Int? = nil
    ) {
        self.url = url
        self.format = format
        self.protection = protection
        self.fileSize = fileSize
        self.archiveEntryCount = archiveEntryCount
        self.imageCount = imageCount
    }
}

public protocol LocalPublicationValidating: Sendable {
    func validate(_ url: URL, expectedFormat: PublicationFormat) async throws -> LocalPublicationValidation
}

public struct DefaultLocalPublicationValidator: LocalPublicationValidating {
    private let protectionDetector: any PublicationProtectionDetecting
    private let limits: ZIPInspectionLimits

    public init(
        protectionDetector: any PublicationProtectionDetecting = DefaultPublicationProtectionDetector(),
        limits: ZIPInspectionLimits = .publication
    ) {
        self.protectionDetector = protectionDetector
        self.limits = limits
    }

    @concurrent
    public func validate(_ url: URL, expectedFormat: PublicationFormat) async throws -> LocalPublicationValidation {
        guard url.isFileURL else {
            throw ReaderError.invalidFileURL
        }

        let resourceValues: URLResourceValues
        do {
            resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw ReaderError.fileNotFound
        }
        guard resourceValues.isRegularFile == true else {
            throw ReaderError.fileNotFound
        }
        let fileSize = UInt64(max(0, resourceValues.fileSize ?? 0))
        guard fileSize > 0 else {
            throw ReaderError.malformedPublication("the file is empty")
        }

        let protection = try await protectionDetector.protection(at: url)
        try rejectUnsupported(protection)

        switch expectedFormat {
        case .epub:
            return try validateEPUB(url: url, fileSize: fileSize, protection: protection)
        case .pdf:
            return try validatePDF(url: url, fileSize: fileSize, protection: protection)
        case .cbz:
            return try validateCBZ(url: url, fileSize: fileSize, protection: protection)
        case .remoteImageSequence:
            throw ReaderError.unsupportedFormat(.remoteImageSequence)
        }
    }

    private func rejectUnsupported(_ protection: PublicationProtection) throws {
        switch protection {
        case .none:
            return
        case .readiumLCP:
            throw ReaderError.unsupportedReadiumLCP
        case .adobeDRM:
            throw ReaderError.unsupportedAdobeDRM
        case .passwordProtectedPDF:
            throw ReaderError.passwordProtectedPDF
        case .unknown:
            throw ReaderError.unsupportedProtection(.unknown)
        }
    }

    private func validateEPUB(
        url: URL,
        fileSize: UInt64,
        protection: PublicationProtection
    ) throws -> LocalPublicationValidation {
        let inspection = try ZIPStructureInspector(limits: limits).inspect(url: url)
        let paths = Set(inspection.entries.map { $0.path.lowercased() })
        guard paths.contains("meta-inf/container.xml") else {
            throw ReaderError.formatMismatch(expected: .epub, detected: paths.contains(where: Self.isImagePath) ? .cbz : nil)
        }
        guard paths.contains(where: { $0.hasSuffix(".opf") }) else {
            throw ReaderError.malformedPublication("the EPUB package document is missing")
        }
        return LocalPublicationValidation(
            url: url,
            format: .epub,
            protection: protection,
            fileSize: fileSize,
            archiveEntryCount: inspection.entries.count
        )
    }

    private func validatePDF(
        url: URL,
        fileSize: UInt64,
        protection: PublicationProtection
    ) throws -> LocalPublicationValidation {
        let prefix: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            prefix = try handle.read(upToCount: 5) ?? Data()
        } catch {
            throw ReaderError.unreadableFile
        }
        guard prefix == Data("%PDF-".utf8), CGPDFDocument(url as CFURL) != nil else {
            throw ReaderError.formatMismatch(expected: .pdf, detected: nil)
        }
        return LocalPublicationValidation(
            url: url,
            format: .pdf,
            protection: protection,
            fileSize: fileSize
        )
    }

    private func validateCBZ(
        url: URL,
        fileSize: UInt64,
        protection: PublicationProtection
    ) throws -> LocalPublicationValidation {
        let inspection = try ZIPStructureInspector(limits: limits).inspect(url: url)
        let imageCount = inspection.entries.count { !$0.isDirectory && Self.isImagePath($0.path.lowercased()) }
        guard imageCount > 0 else {
            let paths = Set(inspection.entries.map { $0.path.lowercased() })
            if paths.contains("meta-inf/container.xml") {
                throw ReaderError.formatMismatch(expected: .cbz, detected: .epub)
            }
            throw ReaderError.noReadableImages
        }
        return LocalPublicationValidation(
            url: url,
            format: .cbz,
            protection: protection,
            fileSize: fileSize,
            archiveEntryCount: inspection.entries.count,
            imageCount: imageCount
        )
    }

    private static func isImagePath(_ path: String) -> Bool {
        guard let fileExtension = path.split(separator: ".").last?.lowercased() else {
            return false
        }
        return ["avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"].contains(fileExtension)
    }
}

public struct DRMFreeProtectionAdapter: PublicationProtectionAdapter {
    public let protection: PublicationProtection = .none
    private let detector: any PublicationProtectionDetecting

    public init(detector: any PublicationProtectionDetecting = DefaultPublicationProtectionDetector()) {
        self.detector = detector
    }

    public func canOpen(url: URL) async -> Bool {
        guard let detected = try? await detector.protection(at: url) else {
            return false
        }
        return detected == .none
    }
}
