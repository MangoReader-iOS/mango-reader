import Foundation
import MangoReaderData
import MangoReaderDomain

public protocol ImportedOriginalCloudDocumentsResolving: Sendable {
    func documentsDirectory() async -> URL?
}

/// Resolves the app's ubiquitous container away from MainActor. A `nil` result
/// is an ordinary offline/signed-out state, not a storage failure.
public struct SystemImportedOriginalCloudDocumentsResolver: ImportedOriginalCloudDocumentsResolving {
    public var containerIdentifier: String

    public init(containerIdentifier: String = "iCloud.com.k800k.manko") {
        self.containerIdentifier = containerIdentifier
    }

    @concurrent
    public func documentsDirectory() async -> URL? {
        guard
            let root = FileManager().url(
                forUbiquityContainerIdentifier: containerIdentifier
            )?.standardizedFileURL,
            root.isFileURL
        else {
            return nil
        }
        return root.appendingPathComponent("Documents", isDirectory: true)
    }
}

public protocol ImportedOriginalCloudTransferring: Sendable {
    func updateCloudDocumentsDirectory(_ directory: URL?) async
    func reconcileUpload(
        _ original: ManagedImportedOriginal,
        globalImportedFileSyncEnabled: Bool
    ) async throws -> ImportedOriginalCloudReconciliation
    func reconcileKnownUpload(
        _ original: ManagedImportedOriginal,
        reference: ImportedOriginalReference,
        globalImportedFileSyncEnabled: Bool
    ) async throws -> ImportedOriginalCloudReconciliation
    func reconcileDownload(
        _ descriptor: ImportedOriginalReference,
        titlePolicy: CloudFilePolicy,
        globalImportedFileSyncEnabled: Bool
    ) async throws -> ImportedOriginalCloudReconciliation
}

extension ImportedOriginalCloudTransferService: ImportedOriginalCloudTransferring {}

public extension ImportedOriginalCloudTransferring {
    func reconcileKnownUpload(_ original: ManagedImportedOriginal, reference: ImportedOriginalReference,
                              globalImportedFileSyncEnabled: Bool) async throws -> ImportedOriginalCloudReconciliation {
        try await reconcileUpload(original, globalImportedFileSyncEnabled: globalImportedFileSyncEnabled)
    }
}

public enum ImportedOriginalCloudRecordMutation: Hashable, Sendable {
    case save(InstallmentID)
    case delete(InstallmentID)

    public var recordName: String {
        switch self {
        case let .save(id), let .delete(id):
            CloudSyncRecordID.importedOriginal(id)
        }
    }
}

public struct ImportedOriginalCloudReconciliationFailure: Hashable, Sendable {
    public var installmentID: InstallmentID?
    public var message: String

    public init(installmentID: InstallmentID?, message: String) {
        self.installmentID = installmentID
        self.message = message
    }
}

public struct ImportedOriginalCloudReconciliationReport: Hashable, Sendable {
    public var reconciliations: [ImportedOriginalCloudReconciliation]
    public var deletedReferenceIDs: [InstallmentID]
    public var failures: [ImportedOriginalCloudReconciliationFailure]

    public init(
        reconciliations: [ImportedOriginalCloudReconciliation] = [],
        deletedReferenceIDs: [InstallmentID] = [],
        failures: [ImportedOriginalCloudReconciliationFailure] = []
    ) {
        self.reconciliations = reconciliations
        self.deletedReferenceIDs = deletedReferenceIDs
        self.failures = failures
    }

    public var changedLocalInstallmentPath: Bool {
        reconciliations.contains { reconciliation in
            reconciliation.status == .downloaded
                || reconciliation.status == .localContentAlreadyPresent
        }
    }

    mutating func append(_ other: Self) {
        reconciliations.append(contentsOf: other.reconciliations)
        deletedReferenceIDs.append(contentsOf: other.deletedReferenceIDs)
        failures.append(contentsOf: other.failures)
    }
}

/// Coordinates durable descriptor metadata, private-zone record mutations, and
/// verified iCloud Drive transfers. All operations are local-first: a missing
/// account, unavailable container, or individual transfer failure leaves the
/// SQLite library and local originals usable.
public actor ImportedOriginalCloudOrchestrator {
    public typealias RecordMutationSink = @Sendable (ImportedOriginalCloudRecordMutation) async -> Void

    private let database: MangoReaderDatabase
    private let transfer: any ImportedOriginalCloudTransferring
    private let documentsResolver: any ImportedOriginalCloudDocumentsResolving
    private let libraryFilesDirectory: URL
    private let deviceID: String
    private let recordMutationSink: RecordMutationSink

    private var globalImportedFileSyncEnabled = false
    private var cloudAccountIsAvailable = false
    private var accountGeneration = UUID()
    private struct LocalValidation: Equatable {
        let digest: String
        let size: Int
        let modifiedAt: Date
    }
    private var localValidations: [URL: LocalValidation] = [:]
    private var preparations: [InstallmentID: (id: UUID, task: Task<URL, Error>, waiters: Set<UUID>)] = [:]

    public init(
        database: MangoReaderDatabase,
        transfer: any ImportedOriginalCloudTransferring,
        documentsResolver: any ImportedOriginalCloudDocumentsResolving = SystemImportedOriginalCloudDocumentsResolver(),
        libraryFilesDirectory: URL,
        deviceID: String,
        recordMutationSink: @escaping RecordMutationSink = { _ in }
    ) {
        self.database = database
        self.transfer = transfer
        self.documentsResolver = documentsResolver
        self.libraryFilesDirectory = libraryFilesDirectory.standardizedFileURL
        self.deviceID = deviceID
        self.recordMutationSink = recordMutationSink
    }

    /// Invalidates stale coordinated operations immediately on sign-out or an
    /// account switch. Becoming available resolves the current container again
    /// before any transfer begins.
    @discardableResult
    public func setCloudAccountAvailable(
        _ isAvailable: Bool,
        globalImportedFileSyncEnabled: Bool,
        reconcile: Bool = true
    ) async -> ImportedOriginalCloudReconciliationReport {
        self.globalImportedFileSyncEnabled = globalImportedFileSyncEnabled
        cloudAccountIsAvailable = isAvailable
        guard isAvailable else {
            invalidatePreparations()
            await transfer.updateCloudDocumentsDirectory(nil)
            return ImportedOriginalCloudReconciliationReport()
        }
        await refreshCloudDocumentsDirectory()
        if reconcile { return await reconcileAll() }
        return ImportedOriginalCloudReconciliationReport()
    }

    /// Treats an explicit CKSyncEngine account switch as a hard metadata
    /// boundary. Old-account descriptors are discarded locally without
    /// queueing CloudKit deletes (which could target the new account), while
    /// local originals and retained content-addressed bytes remain untouched.
    /// The next `.available` transition recreates descriptors from eligible
    /// local publications and downloads only references fetched for that account.
    @discardableResult
    public func cloudAccountDidSwitch() async -> ImportedOriginalCloudReconciliationReport {
        cloudAccountIsAvailable = false
        invalidatePreparations()
        await transfer.updateCloudDocumentsDirectory(nil)
        do {
            let removed = try await database.deleteAllImportedOriginalReferences()
            return ImportedOriginalCloudReconciliationReport(deletedReferenceIDs: removed)
        } catch {
            return ImportedOriginalCloudReconciliationReport(failures: [
                .init(installmentID: nil, message: error.localizedDescription),
            ])
        }
    }

    /// Policy changes control transfers, not shared identity. A device opting
    /// out must not delete descriptors needed by another device.
    @discardableResult
    public func setGlobalImportedFileSyncEnabled(
        _ enabled: Bool
    ) async -> ImportedOriginalCloudReconciliationReport {
        globalImportedFileSyncEnabled = enabled
        if cloudAccountIsAvailable {
            await refreshCloudDocumentsDirectory()
        }
        return await reconcileAll()
    }

    @discardableResult
    public func reconcileAfterImport(
        workID: WorkID
    ) async -> ImportedOriginalCloudReconciliationReport {
        await reconcile(workIDs: [workID])
    }

    @discardableResult
    public func reconcilePolicyChange(
        workID: WorkID
    ) async -> ImportedOriginalCloudReconciliationReport {
        await reconcile(workIDs: [workID])
    }

    @discardableResult
    public func reconcileRemoteChanges() async -> ImportedOriginalCloudReconciliationReport {
        await reconcile(workIDs: nil)
    }

    @discardableResult
    public func reconcileAll() async -> ImportedOriginalCloudReconciliationReport {
        await reconcile(workIDs: nil)
    }

    private func refreshCloudDocumentsDirectory() async {
        guard cloudAccountIsAvailable else {
            await transfer.updateCloudDocumentsDirectory(nil)
            return
        }
        let generation = accountGeneration
        let documentsDirectory = await documentsResolver.documentsDirectory()
        guard generation == accountGeneration, cloudAccountIsAvailable else { return }
        await transfer.updateCloudDocumentsDirectory(documentsDirectory)
    }

    private func reconcile(
        workIDs: Set<WorkID>?
    ) async -> ImportedOriginalCloudReconciliationReport {
        var report = ImportedOriginalCloudReconciliationReport()
        let generation = accountGeneration
        do {
            let originals = try await database.managedImportedOriginals()
                .filter { original in
                    workIDs?.contains(original.workID) ?? true
                }
            for original in originals where ImportedOriginalCloudPolicyResolver.shouldSync(
                globalImportedFileSyncEnabled: globalImportedFileSyncEnabled,
                titlePolicy: original.cloudFilePolicy
            ) {
                do {
                    let existing = try await database.importedOriginalReference(
                        installmentID: original.installmentID
                    )
                    if let existing,
                       !Self.canValidateSameContent(existing, from: original)
                    {
                        // A fetched descriptor is authoritative for immutable
                        // imported originals. Do not manufacture a newer local
                        // timestamp and overwrite it; the download pass below
                        // will attach its content-addressed publication instead.
                        continue
                    }
                    let reconciliation: ImportedOriginalCloudReconciliation
                    if let existing {
                        reconciliation = try await transfer.reconcileKnownUpload(original, reference: existing,
                            globalImportedFileSyncEnabled: globalImportedFileSyncEnabled)
                    } else {
                        reconciliation = try await transfer.reconcileUpload(original,
                            globalImportedFileSyncEnabled: globalImportedFileSyncEnabled)
                    }
                    guard generation == accountGeneration, !Task.isCancelled else { return report }
                    report.reconciliations.append(reconciliation)
                    guard reconciliation.status == .uploaded || reconciliation.status == .cloudContentAlreadyPresent,
                          var reference = reconciliation.descriptor else { continue }
                    if let existing {
                        // Reconciliation may restore a missing iCloud Drive byte,
                        // but identical durable metadata is a true no-op. This
                        // prevents remote-change notifications from generating
                        // an endless sequence of CloudKit saves.
                        guard Self.hasSameContentBinding(existing, reference) else {
                            continue
                        }
                        continue
                    }
                    reference.modifiedAt = .now
                    reference.deviceID = deviceID
                    guard reference.isValidForCloudSync else {
                        throw MangoReaderDataError.invalidImportedOriginalReference
                    }
                    try await database.save(importedOriginalReference: reference)
                    await recordMutationSink(.save(reference.installmentID))
                } catch is CancellationError {
                    report.failures.append(.init(
                        installmentID: original.installmentID,
                        message: "Upload reconciliation was cancelled."
                    ))
                } catch {
                    report.failures.append(.init(
                        installmentID: original.installmentID,
                        message: error.localizedDescription
                    ))
                }
            }
        } catch {
            report.failures.append(.init(installmentID: nil, message: error.localizedDescription))
        }

        // Metadata reconciliation uploads eligible originals only. Downloads
        // are requested by Read or the bounded recent-title prefetcher.
        return report
    }

    private static func canValidateSameContent(
        _ reference: ImportedOriginalReference,
        from original: ManagedImportedOriginal
    ) -> Bool {
        reference.workID == original.workID
            && reference.installmentID == original.installmentID
            && reference.sourceID == original.sourceID
            && reference.format == original.format
            && reference.canonicalRelativePath == original.localRelativePath
    }

    private static func hasSameContentBinding(
        _ lhs: ImportedOriginalReference,
        _ rhs: ImportedOriginalReference
    ) -> Bool {
        lhs.workID == rhs.workID
            && lhs.installmentID == rhs.installmentID
            && lhs.sourceID == rhs.sourceID
            && lhs.format == rhs.format
            && lhs.sha256Hex == rhs.sha256Hex
            && lhs.byteCount == rhs.byteCount
    }

    private func invalidatePreparations() {
        accountGeneration = UUID()
        for preparation in preparations.values { preparation.task.cancel() }
        preparations.removeAll()
    }

    /// Reads only this device's verified, app-managed copy. It works offline
    /// and never makes file-sync opt-in a prerequisite for reading local files.
    public func localFileURL(for installment: Installment) async throws -> URL? {
        let reference = try await database.importedOriginalReference(installmentID: installment.id)
        let candidate = reference?.canonicalRelativePath.map {
            libraryFilesDirectory.appendingPathComponent($0)
        } ?? installment.acquisitionURL
        guard let candidate, candidate.isFileURL,
              candidate.standardizedFileURL.deletingLastPathComponent() == libraryFilesDirectory,
              FileManager.default.fileExists(atPath: candidate.path)
        else { return nil }
        let values = try candidate.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              FileManager.default.isReadableFile(atPath: candidate.path)
        else { return nil }
        let digest = reference?.sha256Hex ?? candidate.deletingPathExtension().lastPathComponent
        guard digest.count == 64 else { return candidate } // Retain readable legacy imports.
        let stamp = LocalValidation(digest: digest, size: values.fileSize ?? -1,
            modifiedAt: values.contentModificationDate ?? .distantPast)
        if let reference, Int64(stamp.size) != reference.byteCount {
            throw ImportedOriginalCloudTransferError.localContentConflict
        }
        if localValidations[candidate] == stamp { return candidate }
        let inspection = try await ImportedOriginalCloudFileInspector.inspect(
            at: candidate, format: installment.format, expectedDigest: digest,
            token: ImportedOriginalCloudTransferToken(generation: 0)
        )
        if let reference, inspection.byteCount != reference.byteCount {
            throw ImportedOriginalCloudTransferError.localContentConflict
        }
        localValidations[candidate] = stamp
        return candidate
    }

    /// All callers join a single transfer per installment. Cancelling one Read
    /// doesn't cancel a shared download needed by another caller; its caller
    /// still checks cancellation before presenting the reader.
    public func prepareOriginal(
        installmentID: InstallmentID,
        onDownloading: @escaping @Sendable () async -> Void = {}
    ) async throws -> URL {
        try Task.checkCancellation()
        let waiter = UUID()
        let operation: (id: UUID, task: Task<URL, Error>)
        if var existing = preparations[installmentID] {
            existing.waiters.insert(waiter)
            preparations[installmentID] = existing
            operation = (existing.id, existing.task)
        } else {
            let id = UUID(), generation = accountGeneration
            let task = Task { try await self.prepareOriginalUncoalesced(
                installmentID: installmentID, generation: generation, onDownloading: onDownloading
            ) }
            preparations[installmentID] = (id, task, [waiter])
            operation = (id, task)
        }
        return try await withTaskCancellationHandler {
            defer { releasePreparation(installmentID, id: operation.id, waiter: waiter, cancelled: false) }
            let result = try await operation.task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            Task { await self.releasePreparation(installmentID, id: operation.id, waiter: waiter, cancelled: true) }
        }
    }

    func preparationWaiterCount(for installmentID: InstallmentID) -> Int {
        preparations[installmentID]?.waiters.count ?? 0
    }

    private func releasePreparation(_ installmentID: InstallmentID, id: UUID, waiter: UUID, cancelled: Bool) {
        guard var operation = preparations[installmentID], operation.id == id else { return }
        operation.waiters.remove(waiter)
        if operation.waiters.isEmpty {
            if cancelled { operation.task.cancel() }
            preparations[installmentID] = nil
        } else {
            preparations[installmentID] = operation
        }
    }

    private func prepareOriginalUncoalesced(
        installmentID: InstallmentID, generation: UUID,
        onDownloading: @Sendable () async -> Void
    ) async throws -> URL {
        guard let installment = try await database.installments(ids: [installmentID]).first,
              let work = try await database.work(id: installment.workID), work.sourceID == .local
        else { throw ImportedOriginalPreparationError.unavailable }
        if let local = try? await localFileURL(for: installment) {
            if local != installment.acquisitionURL,
               let reference = try await database.importedOriginalReference(installmentID: installmentID) {
                _ = try await database.attachManagedImportedOriginal(reference, fileURL: local)
            }
            return local
        }
        let policy = try await database.libraryEntry(for: work.id)?.cloudFilePolicy ?? .inheritGlobal
        guard ImportedOriginalCloudPolicyResolver.shouldSync(
            globalImportedFileSyncEnabled: globalImportedFileSyncEnabled, titlePolicy: policy
        ) else { throw ImportedOriginalPreparationError.syncDisabled }
        guard cloudAccountIsAvailable else { throw ImportedOriginalPreparationError.waitingForCloud }
        await refreshCloudDocumentsDirectory()
        guard let reference = try await database.importedOriginalReference(installmentID: installmentID)
        else { throw ImportedOriginalPreparationError.waitingForCloud }
        try Task.checkCancellation()
        await onDownloading()
        let result: ImportedOriginalCloudReconciliation
        do {
            result = try await transfer.reconcileDownload(
                reference, titlePolicy: policy, globalImportedFileSyncEnabled: globalImportedFileSyncEnabled
            )
        } catch ImportedOriginalCloudTransferError.cloudFileMissing {
            throw ImportedOriginalPreparationError.waitingForCloud
        }
        try Task.checkCancellation()
        guard generation == accountGeneration else { throw CancellationError() }
        guard result.status == .downloaded || result.status == .localContentAlreadyPresent,
              let relativePath = result.localRelativePath,
              relativePath == reference.canonicalRelativePath
        else { throw ImportedOriginalPreparationError.waitingForCloud }
        let url = libraryFilesDirectory.appendingPathComponent(relativePath).standardizedFileURL
        guard url.deletingLastPathComponent() == libraryFilesDirectory,
              FileManager.default.fileExists(atPath: url.path)
        else { throw ImportedOriginalPreparationError.unavailable }
        // A remote deletion/replacement or policy change may arrive during IO.
        guard try await database.importedOriginalReference(installmentID: installmentID) == reference,
              ImportedOriginalCloudPolicyResolver.shouldSync(
                globalImportedFileSyncEnabled: globalImportedFileSyncEnabled,
                titlePolicy: try await database.libraryEntry(for: work.id)?.cloudFilePolicy ?? .inheritGlobal
              )
        else { throw CancellationError() }
        _ = try await database.attachManagedImportedOriginal(reference, fileURL: url)
        return url
    }
}

public enum ImportedOriginalPreparationError: Error, Sendable, LocalizedError {
    case syncDisabled, waitingForCloud, unavailable

    public var errorDescription: String? {
        switch self {
        case .syncDisabled: "File sync is off for this title or device. Enable it in Sync & Backup or the title’s file sync options."
        case .waitingForCloud: "Waiting for iCloud. The original may still be uploading from your other device."
        case .unavailable: "This imported file isn’t available on this device."
        }
    }
}
