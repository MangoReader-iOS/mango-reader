import Foundation
import ImageIO
import MangoReaderData
import MangoReaderDomain
import MangoReaderExtensions
import MangoReaderReaders
import MangoReaderSources
import MangoReaderSync
import Observation
import OSLog
import SwiftUI
import WebKit

extension AppModel {
    func synchronizeCloud() async {
        guard !isPrivate else { return }
        guard cloudSyncEngine != nil else {
            settingsSyncModel.cloudSyncAvailability = .unavailable("iCloud sync is not available in this build.")
            return
        }
        await synchronizeCloud(seedAllRecords: true)
        if case .available = settingsSyncModel.cloudSyncAvailability {
            feedback.showStatus("Library and reading positions synced. File transfers may still be pending.", systemImage: "checkmark.icloud")
        }
    }

    func setSyncImportedFiles(_ enabled: Bool) {
        guard !isPrivate else { return }
        guard !settingsSyncModel.isUpdatingImportedFileSync else { return }
        settingsSyncModel.syncImportedFiles = enabled
        defaults.set(enabled, forKey: "syncImportedFiles")
        settingsSyncModel.isUpdatingImportedFileSync = true
        settingsSyncModel.importedFileSyncNeedsRetry = false
        settingsSyncModel.importedFileSyncStatus = "Applying file sync preference…"
        Task { [weak self] in
            guard let self else { return }
            defer { self.settingsSyncModel.isUpdatingImportedFileSync = false }
            guard let importedOriginalCloudOrchestrator else {
                self.settingsSyncModel.importedFileSyncStatus = "Preference saved. File sync services are not available yet."
                self.settingsSyncModel.importedFileSyncNeedsRetry = true
                return
            }
            let report = await importedOriginalCloudOrchestrator
                .setGlobalImportedFileSyncEnabled(enabled)
            if let failure = report.failures.first {
                self.settingsSyncModel.importedFileSyncNeedsRetry = true
                self.settingsSyncModel.importedFileSyncStatus = "Preference saved, but \(report.failures.count) file sync operation\(report.failures.count == 1 ? "" : "s") failed. \(failure.message)"
            } else if report.reconciliations.contains(where: { $0.status == .containerUnavailable }) {
                self.settingsSyncModel.importedFileSyncNeedsRetry = true
                self.settingsSyncModel.importedFileSyncStatus = "Preference saved. File transfer is waiting for iCloud Drive."
            } else {
                self.settingsSyncModel.importedFileSyncStatus = "File sync preference applied."
            }
            if report.changedLocalInstallmentPath {
                await refreshAfterRemoteSync()
            }
        }
    }

    func setCloudFilePolicy(_ policy: CloudFilePolicy, for work: Work) async -> Bool {
        guard !isPrivate else { return false }
        guard work.sourceID == .local, let database else { return false }
        do {
            guard
                var entry = try await database.libraryEntry(for: work.id),
                var updatedWork = try await database.work(id: work.id)
            else {
                return false
            }
            entry.cloudFilePolicy = policy
            updatedWork.modifiedAt = .now
            try await database.save(work: updatedWork, entry: entry)
            applyUpdatedWork(updatedWork)
            await settingsSyncModel.queueCloudSave(CloudSyncRecordID.work(work.id))
            if let importedOriginalCloudOrchestrator {
                _ = await importedOriginalCloudOrchestrator
                    .reconcilePolicyChange(workID: work.id)
            }
            return true
        } catch {
            sourcesModel.show(error, title: "Couldn’t update file sync policy")
            return false
        }
    }

    func setLayout(_ mode: LayoutMode) {
        settingsSyncModel.layoutMode = mode
        defaults.set(mode.rawValue, forKey: "libraryLayout")
        syncedSettingsDefaultsDidChange()
    }

    func setSort(_ sort: LibrarySort) {
        settingsSyncModel.librarySort = sort
        defaults.set(sort.rawValue, forKey: "librarySort")
        syncedSettingsDefaultsDidChange()
        Task { await libraryModel.refreshLibrary() }
    }

    func setAppearance(_ value: String) {
        settingsSyncModel.preferredAppearance = value
        defaults.set(value, forKey: "preferredAppearance")
        syncedSettingsDefaultsDidChange()
    }

    /// Called by the root AppStorage observer when any reader default changes.
    /// Slider changes are coalesced, and the final payload is compared without
    /// metadata so applying a remote record cannot echo it back to CloudKit.
    func syncedSettingsDefaultsDidChange() {
        let previousSort = settingsSyncModel.librarySort
        settingsSyncModel.layoutMode = defaults.string(forKey: "libraryLayout")
            .flatMap(LayoutMode.init(rawValue:)) ?? .grid
        settingsSyncModel.librarySort = defaults.string(forKey: "librarySort")
            .flatMap(LibrarySort.init(rawValue:)) ?? .recentlyAdded
        settingsSyncModel.preferredAppearance = SyncedAppearancePreferences(
            mode: defaults.string(forKey: "preferredAppearance") ?? "system"
        ).mode
        if settingsSyncModel.librarySort != previousSort {
            Task { [weak self] in await self?.libraryModel.refreshLibrary() }
        }
        guard hasBootstrapped else { return }
        settingsSyncModel.syncedSettingsSaveTask?.cancel()
        settingsSyncModel.syncedSettingsSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self else { return }
                _ = await self.settingsSyncModel.persistSyncedSettingsIfChanged()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    func synchronizeCloud(seedAllRecords: Bool) async {
        if let task = cloudSynchronizationTask {
            let id = cloudSynchronizationID
            let seeded = cloudSynchronizationSeedsRecords
            let account = cloudSynchronizationAccountRevision
            await task.value
            if cloudSynchronizationID == id {
                cloudSynchronizationTask = nil
                cloudSynchronizationID = nil
            }
            // An account switch or full-sync request must not be swallowed by
            // an older, lighter progress refresh that happened to be running.
            if !Task.isCancelled, account != cloudAccountRevision || (seedAllRecords && !seeded) {
                await synchronizeCloud(seedAllRecords: true)
            }
            return
        }
        let id = UUID()
        let task = Task<Void, Never> { [weak self] in
            await self?.performCloudSynchronization(seedAllRecords: seedAllRecords)
        }
        cloudSynchronizationID = id
        cloudSynchronizationSeedsRecords = seedAllRecords
        cloudSynchronizationAccountRevision = cloudAccountRevision
        cloudSynchronizationTask = task
        await task.value
        if cloudSynchronizationID == id {
            cloudSynchronizationTask = nil
            cloudSynchronizationID = nil
        }
    }

    private func performCloudSynchronization(seedAllRecords: Bool) async {
        guard let cloudSyncEngine, let cloudRecordStore else { return }
        settingsSyncModel.isCloudSyncing = true
        defer { settingsSyncModel.isCloudSyncing = false }

        await cloudSyncEngine.start()
        let startingStatus = await cloudSyncEngine.status()
        settingsSyncModel.cloudSyncAvailability = startingStatus
        switch startingStatus {
        case .available, .failed: break
        default: return
        }

        do {
            if seedAllRecords {
                // Do not add fresh record changes until the remote zone has
                // been fetched. CKSyncEngine's automatic sync could otherwise
                // send the seed before fetchChanges() resolves existing data.
                guard await cloudSyncEngine.fetchRemoteChanges() else {
                    settingsSyncModel.cloudSyncAvailability = await cloudSyncEngine.status()
                    return
                }
                await refreshAfterRemoteSync()
                await settingsSyncModel.ensureSyncedAppSettingsRecordExists()
                let recordNames = try await cloudRecordStore.recordNames()
                await cloudSyncEngine.queueSaves(recordNames: recordNames)
                await cloudSyncEngine.sendPendingChanges()
            } else {
                await cloudSyncEngine.synchronize()
            }
            settingsSyncModel.cloudSyncAvailability = await cloudSyncEngine.status()
            await refreshAfterRemoteSync()
        } catch {
            settingsSyncModel.cloudSyncAvailability = .failed(error.localizedDescription)
        }
    }

    func refreshAfterRemoteSync() async {
        await settingsSyncModel.refreshSyncedAppSettingsFromDatabase()
        await libraryModel.refreshLibrary()
        await ensureGeneratedCoversForManagedImports()
        await libraryModel.refreshCategories()
        await libraryModel.refreshHistory()
        cloudReadingRevision &+= 1
        if libraryModel.readingStats != nil { _ = await libraryModel.loadReadingStats() }
        if let database, let cloudSyncEngine, let cloudRecordStore,
           let repaired = try? await database.chapterRepairQueue(), !repaired.isEmpty,
           let names = try? await cloudRecordStore.recordNames() {
            await cloudSyncEngine.queueSaves(recordNames: names)
            try? await database.acknowledgeChapterRepairs()
        }
    }
}

extension AppModel {
    func scheduleImportedFileReconciliation() {
        guard let importedOriginalCloudOrchestrator else { return }
        if importedFileReconciliationTask != nil {
            importedFileReconciliationPending = true
            return
        }
        importedFileReconciliationPending = false
        importedFileReconciliationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                importedFileReconciliationTask = nil
                if importedFileReconciliationPending { scheduleImportedFileReconciliation() }
            }
            let report = await importedOriginalCloudOrchestrator.reconcileRemoteChanges()
            guard !Task.isCancelled else { return }
            if let failure = report.failures.first {
                settingsSyncModel.importedFileSyncStatus = failure.message
                settingsSyncModel.importedFileSyncNeedsRetry = true
            } else if report.reconciliations.contains(where: { $0.status == .containerUnavailable }) {
                settingsSyncModel.importedFileSyncStatus = "Waiting for iCloud to transfer imported files."
                settingsSyncModel.importedFileSyncNeedsRetry = true
            } else {
                settingsSyncModel.importedFileSyncStatus = "Imported files download when you open them. Recently read books are prepared automatically."
                settingsSyncModel.importedFileSyncNeedsRetry = false
            }
        }
    }

    func prefetchRecentImportedBooks() async {
        guard SourceCacheRefresh.shared.canRefresh, importedFilePrefetchTask == nil,
              !settingsSyncModel.incognitoMode, let database, let importedOriginalCloudOrchestrator
        else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                if let cloudSyncEngine {
                    await cloudSyncEngine.start()
                    if case .available = await cloudSyncEngine.status() {
                        _ = await importedOriginalCloudOrchestrator.setCloudAccountAvailable(
                            true, globalImportedFileSyncEnabled: settingsSyncModel.syncImportedFiles, reconcile: false
                        )
                    }
                }
                let candidates = try await database.importedOriginalDownloadCandidates().filter {
                    ImportedOriginalCloudPolicyResolver.shouldSync(
                        globalImportedFileSyncEnabled: settingsSyncModel.syncImportedFiles, titlePolicy: $0.cloudFilePolicy
                    )
                }
                let ids = ImportedOriginalPrefetchPolicy.select(
                    progresses: try await database.progresses(), references: candidates.map(\.reference)
                )
                for id in ids {
                    guard !Task.isCancelled, SourceCacheRefresh.shared.canRefresh else { return }
                    do {
                        _ = try await importedOriginalCloudOrchestrator.prepareOriginal(installmentID: id)
                        guard !Task.isCancelled else { return }
                        importedFileAvailability[id] = .ready
                    } catch is CancellationError { return }
                    catch { /* Direct Read owns visible errors and retry. */ }
                }
            } catch { /* Cached originals remain usable. */ }
        }
        importedFilePrefetchTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        importedFilePrefetchTask = nil
    }

    func prepareImportedBook(work: Work, installment: Installment, announcesFailure: Bool = true) async -> Installment? {
        guard let database, let importedOriginalCloudOrchestrator else {
            importedFileAvailability[installment.id] = .failed("File preparation is unavailable. Try again after Mango Reader finishes starting.")
            if announcesFailure { importedBookRecovery = ImportedBookRecovery(work: work, installment: installment) }
            return nil
        }
        let operationID = UUID()
        importedReadOperations[installment.id] = operationID
        defer { if importedReadOperations[installment.id] == operationID { importedReadOperations[installment.id] = nil } }
        importedFileAvailability[installment.id] = .checking
        let refresh = Task { await synchronizeCloud(seedAllRecords: false) }
        do {
            let hasLocalCopy = (try? await importedOriginalCloudOrchestrator.localFileURL(for: installment)) != nil
            if hasLocalCopy {
                await ReadingSyncDeadline.wait(for: refresh)
            } else {
                await refresh.value
            }
            try Task.checkCancellation()
            if case .available = settingsSyncModel.cloudSyncAvailability {
                _ = await importedOriginalCloudOrchestrator.setCloudAccountAvailable(
                    true, globalImportedFileSyncEnabled: settingsSyncModel.syncImportedFiles, reconcile: false
                )
            }
            let url = try await importedOriginalCloudOrchestrator.prepareOriginal(installmentID: installment.id) { [weak self] in
                await MainActor.run {
                    guard let self, self.importedReadOperations[installment.id] == operationID else { return }
                    self.importedFileAvailability[installment.id] = .downloading
                }
            }
            try Task.checkCancellation()
            var readable = try await database.installments(ids: [installment.id]).first ?? installment
            readable.acquisitionURL = url
            if importedReadOperations[installment.id] == operationID { importedFileAvailability[installment.id] = .ready }
            return readable
        } catch is CancellationError {
            if importedReadOperations[installment.id] == operationID { importedFileAvailability[installment.id] = nil }
        } catch ImportedOriginalPreparationError.syncDisabled {
            if importedReadOperations[installment.id] == operationID { importedFileAvailability[installment.id] = .syncDisabled }
        } catch ImportedOriginalPreparationError.waitingForCloud {
            if importedReadOperations[installment.id] == operationID { importedFileAvailability[installment.id] = .waitingForCloud }
        } catch {
            if importedReadOperations[installment.id] == operationID { importedFileAvailability[installment.id] = .failed(error.localizedDescription) }
        }
        if announcesFailure, !Task.isCancelled, importedReadOperations[installment.id] == operationID {
            importedBookRecovery = ImportedBookRecovery(work: work, installment: installment)
        }
        return nil
    }

    func inspectImportedBookAvailability(_ installment: Installment, refresh: Bool = false) async {
        guard importedReadOperations[installment.id] == nil,
              refresh || importedFileAvailability[installment.id] == nil else { return }
        let hasLocalFile = installment.acquisitionURL.map {
            $0.isFileURL && FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        let managedURL = try? await importedOriginalCloudOrchestrator?.localFileURL(for: installment)
        let policy = (try? await database?.libraryEntry(for: installment.workID)?.cloudFilePolicy) ?? .inheritGlobal
        guard !Task.isCancelled, importedReadOperations[installment.id] == nil else { return }
        if hasLocalFile || managedURL != nil {
            importedFileAvailability[installment.id] = .ready
        } else {
            importedFileAvailability[installment.id] = ImportedOriginalCloudPolicyResolver.shouldSync(
                globalImportedFileSyncEnabled: settingsSyncModel.syncImportedFiles,
                titlePolicy: policy
            ) ? .waitingForCloud : .syncDisabled
        }
    }
}
