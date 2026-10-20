import Foundation

/// A validated, app-managed publication that can be considered for optional
/// iCloud Drive transfer. The path is relative to Application Support's
/// `LibraryFiles` directory and never enters CloudKit.
public struct ManagedImportedOriginal: Hashable, Sendable {
    public var workID: WorkID
    public var installmentID: InstallmentID
    public var sourceID: SourceID
    public var format: PublicationFormat
    public var localRelativePath: String
    public var cloudFilePolicy: CloudFilePolicy

    public init(
        workID: WorkID,
        installmentID: InstallmentID,
        sourceID: SourceID,
        format: PublicationFormat,
        localRelativePath: String,
        cloudFilePolicy: CloudFilePolicy
    ) {
        self.workID = workID
        self.installmentID = installmentID
        self.sourceID = sourceID
        self.format = format
        self.localRelativePath = localRelativePath
        self.cloudFilePolicy = cloudFilePolicy
    }
}

/// Non-secret metadata that binds one local-library installment to a
/// content-addressed original in Mango Reader's iCloud Drive container.
///
/// Absolute sandbox paths, source requests, credentials, remote download
/// locations, and user-facing filenames are intentionally absent. The stable
/// IDs let multiple titles reference the same digest while preserving distinct
/// library relationships.
public struct ImportedOriginalReference: Codable, Hashable, Sendable, Identifiable {
    public static let maximumByteCount: Int64 = 8 * 1_024 * 1_024 * 1_024

    public var workID: WorkID
    public var installmentID: InstallmentID
    public var sourceID: SourceID
    public var format: PublicationFormat
    public var sha256Hex: String
    public var byteCount: Int64
    public var modifiedAt: Date
    public var deviceID: String

    public var id: InstallmentID { installmentID }

    public init(
        workID: WorkID,
        installmentID: InstallmentID,
        sourceID: SourceID,
        format: PublicationFormat,
        sha256Hex: String,
        byteCount: Int64,
        modifiedAt: Date = .now,
        deviceID: String = ""
    ) {
        self.workID = workID
        self.installmentID = installmentID
        self.sourceID = sourceID
        self.format = format
        self.sha256Hex = sha256Hex
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
    }

    /// The canonical managed filename used on every device. Returning `nil`
    /// rejects malformed or future-incompatible references before they can be
    /// persisted, encoded for CloudKit, or mapped to a local file URL.
    public var canonicalRelativePath: String? {
        guard
            sourceID == .local,
            let fileExtension = format.importedOriginalFileExtension,
            sha256Hex.utf8.count == 64,
            sha256Hex.utf8.allSatisfy(Self.isLowercaseHexDigit),
            byteCount > 0,
            byteCount <= Self.maximumByteCount,
            modifiedAt.timeIntervalSinceReferenceDate.isFinite,
            deviceID.utf8.count <= 128
        else {
            return nil
        }
        return "\(sha256Hex).\(fileExtension)"
    }

    public var isValidForCloudSync: Bool {
        canonicalRelativePath != nil && !deviceID.isEmpty
    }

    public func merging(_ other: Self) -> Self {
        precondition(installmentID == other.installmentID)
        guard modifiedAt == other.modifiedAt else {
            return modifiedAt > other.modifiedAt ? self : other
        }
        return deviceID >= other.deviceID ? self : other
    }

    private static func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte) || (0x61 ... 0x66).contains(byte)
    }
}

/// A persisted cloud reference paired with the current library policy. It is
/// produced only after the database verifies that the work and installment
/// relationship exists and still describes a supported local publication.
public struct ImportedOriginalDownloadCandidate: Hashable, Sendable {
    public var reference: ImportedOriginalReference
    public var cloudFilePolicy: CloudFilePolicy

    public init(reference: ImportedOriginalReference, cloudFilePolicy: CloudFilePolicy) {
        self.reference = reference
        self.cloudFilePolicy = cloudFilePolicy
    }
}

public extension PublicationFormat {
    var importedOriginalFileExtension: String? {
        switch self {
        case .cbz: "cbz"
        case .epub: "epub"
        case .pdf: "pdf"
        case .remoteImageSequence: nil
        }
    }
}
