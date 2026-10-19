import CryptoKit
import Foundation
import MankoDomain

/// Resolves the global imported-file preference together with a title override.
/// The global preference is deliberately off unless a caller opts in.
public enum ImportedOriginalCloudPolicyResolver {
    public static func shouldSync(
        globalImportedFileSyncEnabled: Bool = false,
        titlePolicy: CloudFilePolicy
    ) -> Bool {
        switch titlePolicy {
        case .inheritGlobal:
            globalImportedFileSyncEnabled
        case .localOnly:
            false
        case .syncOriginal:
            true
        }
    }
}

public enum ImportedOriginalCloudReconciliationStatus: String, Codable, Hashable, Sendable {
    case policyDisabled
    case containerUnavailable
    case uploaded
    case cloudContentAlreadyPresent
    case downloaded
    case localContentAlreadyPresent
}

/// Stable output for UI/database orchestration. Operational skips are values;
/// malformed inputs and integrity failures remain typed errors.
public struct ImportedOriginalCloudReconciliation: Codable, Hashable, Sendable {
    public var status: ImportedOriginalCloudReconciliationStatus
    public var descriptor: ImportedOriginalReference?
    public var localRelativePath: String?

    public init(
        status: ImportedOriginalCloudReconciliationStatus,
        descriptor: ImportedOriginalReference? = nil,
        localRelativePath: String? = nil
    ) {
        self.status = status
        self.descriptor = descriptor
        self.localRelativePath = localRelativePath
    }
}

public enum ImportedOriginalCloudTransferError: Error, Equatable, Sendable, LocalizedError {
    case nonLocalSource
    case unsupportedFormat
    case unsafeRelativePath
    case invalidManagedFile
    case invalidCloudFile
    case descriptorMismatch
    case cloudFileMissing
    case localContentConflict
    case commitFailed

    public var errorDescription: String? {
        switch self {
        case .nonLocalSource:
            "Only originals imported from this device can sync through iCloud Drive."
        case .unsupportedFormat:
            "Only imported EPUB, PDF, and CBZ originals can sync through iCloud Drive."
        case .unsafeRelativePath:
            "The imported original does not have a safe managed-library path."
        case .invalidManagedFile:
            "The managed imported original is missing, unreadable, or does not match its content address."
        case .invalidCloudFile:
            "The iCloud copy is malformed or does not match its content address."
        case .descriptorMismatch:
            "The iCloud copy does not match its synchronized file metadata."
        case .cloudFileMissing:
            "The synchronized imported original is not present in iCloud Drive."
        case .localContentConflict:
            "A different or invalid local file already occupies the imported original's content address."
        case .commitFailed:
            "Manko could not atomically commit the imported original transfer."
        }
    }
}

/// Copies imported originals between app-managed Application Support and an
/// app-provided iCloud Documents directory. The service never removes a local
/// original. Content-addressed destinations make repeated reconciliation and
/// cross-title deduplication deterministic.
public actor ImportedOriginalCloudTransferService {
    private struct CloudSession: Sendable {
        var root: URL
        var generation: UInt64
        var token: ImportedOriginalCloudTransferToken
    }

    private let libraryFilesDirectory: URL
    private var cloudDocumentsDirectory: URL?
    private var cloudGeneration: UInt64 = 0
    private var cloudToken = ImportedOriginalCloudTransferToken(generation: 0)
    private let fileAccess: ImportedOriginalCloudFileAccess
    private let faultInjector: @Sendable (ImportedOriginalCloudTransferFaultPoint) throws -> Void

    public init(
        libraryFilesDirectory: URL,
        cloudDocumentsDirectory: URL?
    ) {
        self.libraryFilesDirectory = libraryFilesDirectory.standardizedFileURL
        self.cloudDocumentsDirectory = cloudDocumentsDirectory?.standardizedFileURL
        fileAccess = .system
        faultInjector = { _ in }
    }

    init(
        libraryFilesDirectory: URL,
        cloudDocumentsDirectory: URL?,
        fileAccess: ImportedOriginalCloudFileAccess = .system,
        faultInjector: @escaping @Sendable (ImportedOriginalCloudTransferFaultPoint) throws -> Void = { _ in }
    ) {
        self.libraryFilesDirectory = libraryFilesDirectory.standardizedFileURL
        self.cloudDocumentsDirectory = cloudDocumentsDirectory?.standardizedFileURL
        self.fileAccess = fileAccess
        self.faultInjector = faultInjector
    }

    /// Lets the app respond to iCloud account/container availability changes.
    /// Passing `nil` disables transfer attempts without touching local files.
    public func updateCloudDocumentsDirectory(_ directory: URL?) {
        let standardizedDirectory = directory?.standardizedFileURL
        guard standardizedDirectory != cloudDocumentsDirectory else {
            return
        }
        cloudToken.invalidate()
        cloudGeneration &+= 1
        cloudToken = ImportedOriginalCloudTransferToken(generation: cloudGeneration)
        cloudDocumentsDirectory = standardizedDirectory
    }

    public func reconcileUpload(
        _ original: ManagedImportedOriginal,
        globalImportedFileSyncEnabled: Bool = false
    ) async throws -> ImportedOriginalCloudReconciliation {
        let expectedDigest = try Self.validate(original: original)
        guard ImportedOriginalCloudPolicyResolver.shouldSync(
            globalImportedFileSyncEnabled: globalImportedFileSyncEnabled,
            titlePolicy: original.cloudFilePolicy
        ) else {
            return ImportedOriginalCloudReconciliation(
                status: .policyDisabled,
                localRelativePath: original.localRelativePath
            )
        }
        guard let session = currentCloudSession() else {
            return ImportedOriginalCloudReconciliation(
                status: .containerUnavailable,
                localRelativePath: original.localRelativePath
            )
        }
        let directories: ImportedOriginalCloudDirectories
        do {
            try validate(session)
            directories = try await fileAccess.prepareDirectories(session.root, session.token)
            try validate(session)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ImportedOriginalCloudReconciliation(
                status: .containerUnavailable,
                localRelativePath: original.localRelativePath
            )
        }

        let sourceURL = libraryFilesDirectory.appendingPathComponent(
            original.localRelativePath,
            isDirectory: false
        )
        let sourceInspection: ImportedOriginalCloudFileInspection
        do {
            sourceInspection = try await ImportedOriginalCloudFileInspector.inspect(
                at: sourceURL,
                format: original.format,
                expectedDigest: expectedDigest,
                token: session.token
            )
            try validate(session)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ImportedOriginalCloudTransferError.invalidManagedFile
        }

        let descriptor = ImportedOriginalReference(
            workID: original.workID,
            installmentID: original.installmentID,
            sourceID: original.sourceID,
            format: original.format,
            sha256Hex: expectedDigest,
            byteCount: sourceInspection.byteCount
        )
        let destinationURL = directories.originals.appendingPathComponent(
            Self.canonicalFilename(digest: expectedDigest, format: original.format),
            isDirectory: false
        )

        let existingInspection: ImportedOriginalCloudInspection
        do {
            try validate(session)
            existingInspection = try await fileAccess.inspectCloudFile(
                destinationURL,
                descriptor.format,
                descriptor.sha256Hex,
                descriptor.byteCount,
                session.token
            )
            try validate(session)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ImportedOriginalCloudReconciliation(
                status: .containerUnavailable,
                descriptor: descriptor,
                localRelativePath: original.localRelativePath
            )
        }
        switch existingInspection {
        case .missing:
            break
        case .valid:
            return ImportedOriginalCloudReconciliation(
                status: .cloudContentAlreadyPresent,
                descriptor: descriptor,
                localRelativePath: original.localRelativePath
            )
        case .unavailable:
            return ImportedOriginalCloudReconciliation(
                status: .containerUnavailable,
                descriptor: descriptor,
                localRelativePath: original.localRelativePath
            )
        case .invalid:
            throw ImportedOriginalCloudTransferError.invalidCloudFile
        }

        let stagingURL = directories.staging.appendingPathComponent(
            ".\(UUID().uuidString).uploading",
            isDirectory: false
        )
        do {
            try validate(session)
            try await fileAccess.copyToCloudStaging(
                sourceURL,
                stagingURL,
                descriptor.format,
                descriptor.sha256Hex,
                descriptor.byteCount,
                session.token
            )
            try validate(session)
        } catch is CancellationError {
            await fileAccess.removeCloudItem(stagingURL)
            throw CancellationError()
        } catch {
            await fileAccess.removeCloudItem(stagingURL)
            return ImportedOriginalCloudReconciliation(
                status: .containerUnavailable,
                descriptor: descriptor,
                localRelativePath: original.localRelativePath
            )
        }

        do {
            try faultInjector(.beforeCloudCommit)
            try validate(session)
            try await fileAccess.commitCloudMove(stagingURL, destinationURL, session.token)
            try validate(session)
        } catch is CancellationError {
            await fileAccess.removeCloudItem(stagingURL)
            throw CancellationError()
        } catch {
            let recoveryInspection: ImportedOriginalCloudInspection
            do {
                try validate(session)
                let inspectedDestination = try await fileAccess.inspectCloudFile(
                    destinationURL,
                    descriptor.format,
                    descriptor.sha256Hex,
                    descriptor.byteCount,
                    session.token
                )
                try validate(session)
                recoveryInspection = inspectedDestination
            } catch is CancellationError {
                await fileAccess.removeCloudItem(stagingURL)
                throw CancellationError()
            } catch {
                recoveryInspection = .unavailable
            }
            await fileAccess.removeCloudItem(stagingURL)
            if recoveryInspection == .valid {
                return ImportedOriginalCloudReconciliation(
                    status: .cloudContentAlreadyPresent,
                    descriptor: descriptor,
                    localRelativePath: original.localRelativePath
                )
            }
            throw ImportedOriginalCloudTransferError.commitFailed
        }
        await fileAccess.removeCloudItem(stagingURL)

        return ImportedOriginalCloudReconciliation(
            status: .uploaded,
            descriptor: descriptor,
            localRelativePath: original.localRelativePath
        )
    }

    /// An existing descriptor is already content-addressed. Probe availability
    /// without materializing every cloud file during metadata reconciliation.
    public func reconcileKnownUpload(
        _ original: ManagedImportedOriginal, reference: ImportedOriginalReference,
        globalImportedFileSyncEnabled: Bool = false
    ) async throws -> ImportedOriginalCloudReconciliation {
        let digest = try Self.validate(original: original)
        try Self.validate(descriptor: reference)
        guard reference.workID == original.workID, reference.installmentID == original.installmentID,
              reference.sha256Hex == digest, reference.canonicalRelativePath == original.localRelativePath
        else { throw ImportedOriginalCloudTransferError.descriptorMismatch }
        guard ImportedOriginalCloudPolicyResolver.shouldSync(
            globalImportedFileSyncEnabled: globalImportedFileSyncEnabled, titlePolicy: original.cloudFilePolicy
        ) else { return .init(status: .policyDisabled, descriptor: reference) }
        guard let session = currentCloudSession() else { return .init(status: .containerUnavailable, descriptor: reference) }
        do {
            let directories = try await fileAccess.prepareDirectories(session.root, session.token)
            let url = directories.originals.appendingPathComponent(original.localRelativePath)
            let state = try await fileAccess.metadataState(url, session.token)
            try validate(session)
            if state != .missing {
                return .init(status: .cloudContentAlreadyPresent, descriptor: reference,
                    localRelativePath: original.localRelativePath)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { return .init(status: .containerUnavailable, descriptor: reference) }
        return try await reconcileUpload(original, globalImportedFileSyncEnabled: globalImportedFileSyncEnabled)
    }

    public func reconcileDownload(
        _ descriptor: ImportedOriginalReference,
        titlePolicy: CloudFilePolicy,
        globalImportedFileSyncEnabled: Bool = false
    ) async throws -> ImportedOriginalCloudReconciliation {
        try Self.validate(descriptor: descriptor)
        let localRelativePath = Self.canonicalFilename(
            digest: descriptor.sha256Hex,
            format: descriptor.format
        )
        guard ImportedOriginalCloudPolicyResolver.shouldSync(
            globalImportedFileSyncEnabled: globalImportedFileSyncEnabled,
            titlePolicy: titlePolicy
        ) else {
            return ImportedOriginalCloudReconciliation(
                status: .policyDisabled,
                descriptor: descriptor,
                localRelativePath: localRelativePath
            )
        }
        guard let session = currentCloudSession() else {
            return ImportedOriginalCloudReconciliation(
                status: .containerUnavailable,
                descriptor: descriptor,
                localRelativePath: localRelativePath
            )
        }
        let directories: ImportedOriginalCloudDirectories
        do {
            try validate(session)
            directories = try await fileAccess.prepareDirectories(session.root, session.token)
            try validate(session)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ImportedOriginalCloudReconciliation(
                status: .containerUnavailable,
                descriptor: descriptor,
                localRelativePath: localRelativePath
            )
        }

        let cloudURL = directories.originals.appendingPathComponent(
            localRelativePath,
            isDirectory: false
        )
        let cloudInspection: ImportedOriginalCloudInspection
        do {
            try validate(session)
            cloudInspection = try await fileAccess.inspectCloudFile(
                cloudURL,
                descriptor.format,
                descriptor.sha256Hex,
                descriptor.byteCount,
                session.token
            )
            try validate(session)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ImportedOriginalCloudReconciliation(
                status: .containerUnavailable,
                descriptor: descriptor,
                localRelativePath: localRelativePath
            )
        }
        switch cloudInspection {
        case .missing:
            throw ImportedOriginalCloudTransferError.cloudFileMissing
        case .valid:
            break
        case .unavailable:
            return ImportedOriginalCloudReconciliation(
                status: .containerUnavailable,
                descriptor: descriptor,
                localRelativePath: localRelativePath
            )
        case .invalid:
            throw ImportedOriginalCloudTransferError.invalidCloudFile
        }

        do {
            try FileManager.default.createDirectory(
                at: libraryFilesDirectory,
                withIntermediateDirectories: true
            )
            guard Self.isSafeDirectory(libraryFilesDirectory) else {
                throw ImportedOriginalCloudTransferError.commitFailed
            }
        } catch {
            throw ImportedOriginalCloudTransferError.commitFailed
        }
        let localURL = libraryFilesDirectory.appendingPathComponent(
            localRelativePath,
            isDirectory: false
        )
        if FileManager.default.fileExists(atPath: localURL.path) {
            do {
                let inspection = try await ImportedOriginalCloudFileInspector.inspect(
                    at: localURL,
                    format: descriptor.format,
                    expectedDigest: descriptor.sha256Hex,
                    token: session.token
                )
                guard inspection.byteCount == descriptor.byteCount else {
                    throw ImportedOriginalCloudTransferError.localContentConflict
                }
                return ImportedOriginalCloudReconciliation(
                    status: .localContentAlreadyPresent,
                    descriptor: descriptor,
                    localRelativePath: localRelativePath
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let values = try localURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw ImportedOriginalCloudTransferError.localContentConflict
                }
                // Keep the damaged original until a verified replacement is
                // ready. The commit below retains it as a recovery backup.
            }
        }

        let localStagingDirectory = libraryFilesDirectory.appendingPathComponent(
            ".CloudTransferStaging",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: localStagingDirectory,
                withIntermediateDirectories: true
            )
            guard Self.isSafeDirectory(localStagingDirectory) else {
                throw ImportedOriginalCloudTransferError.commitFailed
            }
        } catch {
            throw ImportedOriginalCloudTransferError.commitFailed
        }
        let stagingURL = localStagingDirectory.appendingPathComponent(
            ".\(UUID().uuidString).downloading",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        do {
            try validate(session)
            try await fileAccess.copyFromCloud(cloudURL, stagingURL, session.token)
            try validate(session)
            let inspection = try await ImportedOriginalCloudFileInspector.inspect(
                at: stagingURL,
                format: descriptor.format,
                expectedDigest: descriptor.sha256Hex,
                token: session.token
            )
            guard inspection.byteCount == descriptor.byteCount else {
                throw ImportedOriginalCloudTransferError.descriptorMismatch
            }
            try Self.applyStandardProtection(to: stagingURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ImportedOriginalCloudTransferError {
            throw error
        } catch {
            return ImportedOriginalCloudReconciliation(
                status: .containerUnavailable,
                descriptor: descriptor,
                localRelativePath: localRelativePath
            )
        }

        do {
            try faultInjector(.beforeLocalCommit)
            try validate(session)
            if FileManager.default.fileExists(atPath: localURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    localURL, withItemAt: stagingURL,
                    backupItemName: ".RecoveredOriginal-\(UUID().uuidString).\(localURL.pathExtension)",
                    options: .withoutDeletingBackupItem
                )
            } else {
                try FileManager.default.moveItem(at: stagingURL, to: localURL)
            }
            try validate(session)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            do {
                if FileManager.default.fileExists(atPath: localURL.path) {
                    let inspection = try await ImportedOriginalCloudFileInspector.inspect(
                        at: localURL,
                        format: descriptor.format,
                        expectedDigest: descriptor.sha256Hex,
                        token: session.token
                    )
                    try validate(session)
                    if inspection.byteCount == descriptor.byteCount {
                        return ImportedOriginalCloudReconciliation(
                            status: .localContentAlreadyPresent,
                            descriptor: descriptor,
                            localRelativePath: localRelativePath
                        )
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The original commit error remains authoritative.
            }
            throw ImportedOriginalCloudTransferError.commitFailed
        }

        return ImportedOriginalCloudReconciliation(
            status: .downloaded,
            descriptor: descriptor,
            localRelativePath: localRelativePath
        )
    }

    private func currentCloudSession() -> CloudSession? {
        guard let cloudDocumentsDirectory, cloudDocumentsDirectory.isFileURL else {
            return nil
        }
        return CloudSession(
            root: cloudDocumentsDirectory,
            generation: cloudGeneration,
            token: cloudToken
        )
    }

    private func validate(_ session: CloudSession) throws {
        try session.token.checkCancellation()
        guard
            session.generation == cloudGeneration,
            session.token === cloudToken,
            session.root == cloudDocumentsDirectory
        else {
            throw CancellationError()
        }
    }

    private static func validate(original: ManagedImportedOriginal) throws -> String {
        guard original.sourceID == .local else {
            throw ImportedOriginalCloudTransferError.nonLocalSource
        }
        guard supportedExtension(for: original.format) != nil else {
            throw ImportedOriginalCloudTransferError.unsupportedFormat
        }
        return try digest(
            fromCanonicalRelativePath: original.localRelativePath,
            format: original.format
        )
    }

    private static func validate(descriptor: ImportedOriginalReference) throws {
        guard descriptor.sourceID == .local else {
            throw ImportedOriginalCloudTransferError.nonLocalSource
        }
        guard supportedExtension(for: descriptor.format) != nil else {
            throw ImportedOriginalCloudTransferError.unsupportedFormat
        }
        guard isSHA256Hex(descriptor.sha256Hex), descriptor.byteCount > 0 else {
            throw ImportedOriginalCloudTransferError.descriptorMismatch
        }
    }

    private static func digest(
        fromCanonicalRelativePath relativePath: String,
        format: PublicationFormat
    ) throws -> String {
        guard
            !relativePath.isEmpty,
            !relativePath.contains("/"),
            !relativePath.contains("\\"),
            !relativePath.contains("\0"),
            relativePath == URL(fileURLWithPath: relativePath).lastPathComponent,
            let fileExtension = supportedExtension(for: format),
            URL(fileURLWithPath: relativePath).pathExtension.lowercased() == fileExtension
        else {
            throw ImportedOriginalCloudTransferError.unsafeRelativePath
        }
        let digest = String(relativePath.dropLast(fileExtension.count + 1))
        guard isSHA256Hex(digest), relativePath == canonicalFilename(digest: digest, format: format) else {
            throw ImportedOriginalCloudTransferError.unsafeRelativePath
        }
        return digest
    }

    private static func supportedExtension(for format: PublicationFormat) -> String? {
        switch format {
        case .epub: "epub"
        case .pdf: "pdf"
        case .cbz: "cbz"
        case .remoteImageSequence: nil
        }
    }

    private static func canonicalFilename(digest: String, format: PublicationFormat) -> String {
        "\(digest).\(supportedExtension(for: format) ?? format.rawValue)"
    }

    private static func isSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (0x30 ... 0x39).contains(byte) || (0x61 ... 0x66).contains(byte)
        }
    }

    private static func isSafeDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func applyStandardProtection(to url: URL) throws {
        #if os(iOS) || os(tvOS) || os(watchOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #else
        _ = url
        #endif
    }
}
