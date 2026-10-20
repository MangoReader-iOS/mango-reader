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
    @discardableResult
    func commitRestore(selection requestedSelection: BackupRestoreSelection, mode: BackupRestoreMode = .merge) async -> Bool {
        guard transfersModel.backupOperation == nil else { return false }
        guard let backupService, let stagedRestore = transfersModel.stagedRestore else { return false }
        transfersModel.backupFailure = nil
        transfersModel.backupOperation = .restoring
        defer { transfersModel.backupOperation = nil }
        do {
            let selection = requestedSelection.normalized(for: stagedRestore.manifest)
            guard !selection.isEmpty else {
                feedback.alert = AppAlert(
                    title: "Nothing selected",
                    message: "Choose at least one backup section to restore."
                )
                return false
            }

            let candidate: PreparedSetupImport?
            if let data = try await backupService.settingsData(for: stagedRestore) {
                candidate = try transfersModel.prepareSetupImport(BackupSetupPayload.decodeCompatible(from: data),
                    selection: selection, mode: mode)
            } else { candidate = nil }
            let report = try await backupService.commitRestore(
                stagedRestore,
                selection: selection,
                mode: mode,
                sourceIDMapping: candidate?.sourceIDMapping ?? [:]
            ) { [self, candidate, selection] in
                if let candidate, selection.includesSetup { try await transfersModel.applySetupImport(candidate) }
            }
            self.transfersModel.stagedRestore = nil
            if selection.includesSetup {
                _ = await settingsSyncModel.persistSyncedSettingsIfChanged()
            }
            if selection.restoresDatabaseRecords {
                _ = await settingsSyncModel.persistSyncedSettingsIfChanged(
                    modifiedAt: .now,
                    forceMetadataRefresh: true
                )
                await libraryModel.refreshLibrary()
                await libraryModel.refreshHistory()
                await libraryModel.refreshCategories()
                await libraryModel.refreshSavedFilters()
                if let importedOriginalCloudOrchestrator {
                    let report = await importedOriginalCloudOrchestrator
                        .setGlobalImportedFileSyncEnabled(settingsSyncModel.syncImportedFiles)
                    if report.changedLocalInstallmentPath {
                        await refreshAfterRemoteSync()
                    }
                }
                await synchronizeCloud(seedAllRecords: true)
            }
            let skipped = report.skippedConflicts + (candidate?.skippedConflicts ?? 0)
            let installations = candidate?.needsInstallation ?? 0
            var summary = "Imported \(selection.groups.count) backup section\(selection.groups.count == 1 ? "" : "s")."
            if skipped > 0 { summary += " Kept \(skipped) existing record\(skipped == 1 ? "" : "s")." }
            if installations > 0 { summary += " \(installations) extension\(installations == 1 ? " needs" : "s need") installation." }
            feedback.showStatus(summary, systemImage: "checkmark.circle.fill")
            return true
        } catch {
            transfersModel.backupFailure = error.localizedDescription
            return false
        }
    }

    func recoverMissingDownloadedPublication(
        work: Work,
        installment: Installment
    ) async -> Bool {
        guard work.sourceID != .local else { return false }
        var remoteInstallment = installment

        if let staleDownload = transfersModel.downloadSnapshot(for: installment.id) {
            remoteInstallment.acquisitionURL = staleDownload.transfer.remoteURL
            guard await removeDownload(staleDownload, announcesErrors: false) else {
                feedback.showStatus("Couldn’t prepare the download. Try again.", systemImage: "exclamationmark.circle")
                return false
            }
        }

        return await enqueueDownload(work: work, installment: remoteInstallment)
    }

    @discardableResult
    func enqueueDownload(
        work: Work,
        installment: Installment,
        priority: Int = 0,
        announces: Bool = true,
        verificationMode: CloudflareRecoveryMode = .foreground
    ) async -> Bool {
        let outcome = await enqueueDownloadOutcome(
            work: work, installment: installment, priority: priority,
            verificationMode: verificationMode
        )
        if announces {
            switch outcome {
            case .queued: feedback.showStatus("Queued \(installment.title) for download.", systemImage: "arrow.down.circle.fill")
            case .alreadyAvailable: feedback.showStatus("\(installment.title) is already offline or queued.", systemImage: "checkmark.circle")
            case let .failed(message): feedback.alert = AppAlert(title: "Couldn’t download \(installment.title)", message: message)
            case .cancelled: break
            }
        }
        return outcome == .queued
    }

    func enqueueDownloadOutcome(
        work: Work,
        installment: Installment,
        priority: Int = 0,
        verificationMode: CloudflareRecoveryMode = .foreground
    ) async -> DownloadEnqueueOutcome {
        guard !Task.isCancelled else { return .cancelled }
        if let url = installment.acquisitionURL, url.isFileURL,
           FileManager.default.fileExists(atPath: url.path) {
            return .alreadyAvailable
        }
        guard transfersModel.preparingDownloadInstallmentIDs.insert(installment.id).inserted else {
            return .failed("A download request for this installment is already being prepared.")
        }
        defer { transfersModel.preparingDownloadInstallmentIDs.remove(installment.id) }
        guard let downloadCoordinator else { return .failed("Download services are still starting. Try again shortly.") }
        if let existing = transfersModel.downloadSnapshot(for: installment.id) {
            guard [.failed, .cancelled].contains(existing.state) else { return .alreadyAvailable }
            guard !transfersModel.isDownloadOperationPending(existing.id) else {
                return .failed("Another action for this download is still running.")
            }
            transfersModel.pendingDownloadIDs.insert(existing.id)
            defer { transfersModel.pendingDownloadIDs.remove(existing.id) }
            do {
                try await downloadCoordinator.retry(existing.id)
                transfersModel.downloads = await downloadCoordinator.snapshots()
                return transfersModel.enqueueOutcome(for: existing.id)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(error.localizedDescription)
            }
        }

        do {
            let descriptor = sourcesModel.sources.first(where: { $0.id == work.sourceID })
            let preparedDownload = try await sourcesModel.performSourceOperation(
                mode: verificationMode
            ) { [weak self] in
                guard let self else { throw CancellationError() }
                if let descriptor {
                    let source = try await self.sourcesModel.makeRemoteSource(for: descriptor)
                    let prepared = try await self.libraryModel.prepareExtensionContent(
                        source: source,
                        work: work,
                        installment: installment
                    )
                    let verificationReference = await self.sourcesModel.downloadVerificationReference(
                        for: descriptor
                    )
                    let acquisitionURL: URL
                    if descriptor.id.rawValue.hasSuffix(".LNori") {
                        let content = try await self.sourcesModel.cachedPublicationContent(work: work,
                            installment: prepared.selectedInstallment, descriptor: descriptor)
                        acquisitionURL = try await MangoReaderExtensionEPUBBuilder().build(content: content,
                            title: prepared.selectedInstallment.title, sourceNamespace: descriptor.id.rawValue, sectioned: true)
                    } else { acquisitionURL = try await source.acquisitionURL(for: prepared.selectedInstallment) }
                    return PreparedDownload(
                        remoteURL: acquisitionURL,
                        installment: prepared.selectedInstallment,
                        configuration: try await self.sourcesModel.makeSourceConfiguration(for: descriptor),
                        verificationReference: verificationReference
                    )
                }
                if let url = installment.acquisitionURL, !url.isFileURL {
                    return PreparedDownload(
                        remoteURL: url,
                        installment: installment,
                        configuration: nil,
                        verificationReference: nil
                    )
                }
                throw SourceError.notFound
            }
            guard !Task.isCancelled else { return .cancelled }
            let remoteURL = preparedDownload.remoteURL
            let resolvedInstallment = preparedDownload.installment
            let configuration = preparedDownload.configuration

            let fileExtension = remoteURL.pathExtension.isEmpty
                ? resolvedInstallment.format.preferredFileExtension
                : remoteURL.pathExtension
            let filename = "\(resolvedInstallment.title).\(fileExtension)"
            let transfer = DownloadTransfer(
                workID: work.id,
                installmentID: resolvedInstallment.id,
                remoteURL: remoteURL,
                suggestedFilename: filename,
                expectedFormat: resolvedInstallment.format,
                verificationReference: preparedDownload.verificationReference,
                credentialAccount: configuration?.credentialAccount,
                credentialOrigin: configuration?.baseURL,
                endpointAccess: configuration?.endpointAccess ?? EndpointAccess(),
                priority: priority
            )
            let transferID = try await downloadCoordinator.enqueue(transfer)
            transfersModel.downloads = await downloadCoordinator.snapshots()
            return transfersModel.enqueueOutcome(for: transferID)
        } catch is CancellationError {
            return .cancelled
        } catch let error as CloudflareVerificationRequiredError {
            guard !Task.isCancelled else { return .cancelled }
            settingsSyncModel.automationVerificationInterruptionDescription = error.localizedDescription
            return .failed(error.localizedDescription)
        } catch let error as CloudflareVerificationPersistenceError {
            guard !Task.isCancelled else { return .cancelled }
            settingsSyncModel.automationVerificationInterruptionDescription = error.localizedDescription
            return .failed(error.localizedDescription)
        } catch let error as CloudflareBrowserOnlyProtectionError {
            guard !Task.isCancelled else { return .cancelled }
            settingsSyncModel.automationVerificationInterruptionDescription = error.localizedDescription
            return .failed(error.localizedDescription)
        } catch {
            guard !Task.isCancelled else { return .cancelled }
            return .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func downloadAll(_ work: Work, installments: [Installment]) async -> DownloadBatchResult {
        guard transfersModel.beginDownloadBatch() else { return transfersModel.downloadBatchInProgressResult }
        defer { transfersModel.isQueuingDownloads = false }
        let result = await queueDownloadBatch(installments.map { (work, $0) })
        transfersModel.showDownloadBatchResult(result)
        return result
    }

    @discardableResult
    func downloadAll(workIDs: Set<WorkID>) async -> DownloadBatchResult {
        guard transfersModel.beginDownloadBatch() else { return transfersModel.downloadBatchInProgressResult }
        defer { transfersModel.isQueuingDownloads = false }
        var result = DownloadBatchResult()
        guard let database else {
            result.record(.failed("Library storage is still starting."))
            transfersModel.showDownloadBatchResult(result)
            return result
        }
        let worksByID = Dictionary(uniqueKeysWithValues: libraryModel.library.map { ($0.id, $0) })
        var requests: [(Work, Installment)] = []
        for workID in workIDs.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            if Task.isCancelled { result.record(.cancelled); break }
            do {
                let work: Work
                if let loaded = worksByID[workID] {
                    work = loaded
                } else if let loaded = try await database.work(id: workID) {
                    work = loaded
                } else {
                    result.record(.failed("A selected title is no longer in the library."))
                    continue
                }

                let workInstallments = try await database.installments(for: workID)
                requests.append(contentsOf: workInstallments.map { (work, $0) })
            } catch {
                result.record(.failed(error.localizedDescription))
            }
        }
        result = await queueDownloadBatch(requests, initialResult: result)
        transfersModel.showDownloadBatchResult(result)
        return result
    }

    func queueDownloadBatch(
        _ requests: [(Work, Installment)],
        initialResult: DownloadBatchResult = .init()
    ) async -> DownloadBatchResult {
        var result = initialResult
        guard result.cancelledCount == 0 else { return result }
        for (index, request) in requests.enumerated() {
            if Task.isCancelled { result.record(.cancelled); break }
            let outcome = await enqueueDownloadOutcome(
                work: request.0, installment: request.1, priority: requests.count - index
            )
            result.record(outcome)
            if outcome == .cancelled { break }
        }
        return result
    }

    @discardableResult
    func removeDownload(
        _ snapshot: DownloadSnapshot,
        announcesErrors: Bool = true
    ) async -> Bool {
        guard !transfersModel.isDownloadOperationPending(snapshot.id) else { return false }
        guard let downloadCoordinator else {
            if announcesErrors { feedback.alert = AppAlert(title: "Download unavailable", message: "Download services are still starting.") }
            return false
        }
        transfersModel.pendingDownloadIDs.insert(snapshot.id)
        defer { transfersModel.pendingDownloadIDs.remove(snapshot.id) }
        transfersModel.downloadVerificationRecoveryTasks[snapshot.id]?.cancel()
        transfersModel.downloadVerificationRecoveryTasks[snapshot.id] = nil
        do {
            try await downloadCoordinator.remove(snapshot.id)
            if let database {
                var workInstallments = try await database.installments(for: snapshot.transfer.workID)
                if let index = workInstallments.firstIndex(where: { $0.id == snapshot.transfer.installmentID }) {
                    workInstallments[index].acquisitionURL = snapshot.transfer.remoteURL
                    try await database.save(installments: [workInstallments[index]])
                    await libraryModel.refreshLibraryCounts(for: snapshot.transfer.workID)
                }
            }
            transfersModel.downloads = await downloadCoordinator.snapshots()
            return true
        } catch {
            transfersModel.downloads = await downloadCoordinator.snapshots()
            if announcesErrors {
                sourcesModel.show(error, title: "Couldn’t remove download")
            }
            return false
        }
    }

    /// The task is owned by the app, rather than the screen that opened the picker.
    @discardableResult
    func beginImport(_ result: Result<[URL], Error>) -> Task<Void, Never> {
        if case let .success(urls) = result { readerSetup.importAccepted(urls) }
        let previous = publicationImportTask
        let task = Task { [self] in
            await previous?.value
            await performImport(result)
        }
        publicationImportTask = task
        return task
    }

    func importFiles(_ result: Result<[URL], Error>) async {
        await beginImport(result).value
    }

    private func performImport(_ result: Result<[URL], Error>) async {
        switch result {
        case let .success(urls):
            guard let importer, let database, let storagePaths else { return }
            transfersModel.publicationImportProgress = PublicationImportProgress(total: urls.count)
            libraryModel.isLoading = true
            defer { libraryModel.isLoading = false }
            var importedCount = 0
            var duplicateCount = 0
            for url in urls {
                defer { transfersModel.publicationImportProgress.processed += 1 }
                do {
                    let imported = try await importer.importPublication(from: url)
                    if imported.wasDuplicate {
                        duplicateCount += 1
                        transfersModel.publicationImportProgress.duplicates += 1
                        continue
                    }
                    let title = url.deletingPathExtension().lastPathComponent
                    let kind: ContentKind = imported.format == .cbz ? .comic : (imported.format == .epub ? .lightNovel : .book)
                    var work = Work(sourceID: .local, title: title, kind: kind)
                    let fileURL = storagePaths.libraryFilesDirectory.appendingPathComponent(imported.relativePath)
                    let generatedCover = await libraryModel.workByAddingGeneratedCover(
                        to: work,
                        fileURL: fileURL,
                        format: imported.format
                    )
                    work = generatedCover.work
                    let installment = Installment(
                        workID: work.id,
                        title: "Complete edition",
                        format: imported.format,
                        acquisitionURL: fileURL
                    )
                    do {
                        try await database.save(
                            work: work,
                            entry: LibraryEntry(workID: work.id, unreadCount: 1, downloadedCount: 1),
                            installments: [installment]
                        )
                    } catch {
                        if let path = generatedCover.managedPath {
                            try? await customCoverStore?.remove(path: path)
                        }
                        throw error
                    }
                    await libraryModel.refreshLibraryCounts(for: work.id)
                    await settingsSyncModel.queueCloudSave(CloudSyncRecordID.work(work.id))
                    importedCount += 1
                    transfersModel.publicationImportProgress.imported += 1
                    // Publish completed imports even if setup finishes before the batch.
                    await libraryModel.refreshLibrary()
                } catch {
                    transfersModel.publicationImportProgress.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    if !readerSetup.isActive { sourcesModel.show(error, title: "Couldn’t import \(url.lastPathComponent)") }
                }
            }
            await finishImport(importedCount: importedCount, duplicateCount: duplicateCount)
            if importedCount > 0 { scheduleImportedFileReconciliation() }
        case let .failure(error):
            if (error as NSError).code != NSUserCancelledError {
                sourcesModel.show(error, title: "Import failed")
            }
        }
    }

    func finishImport(importedCount: Int, duplicateCount: Int) async {
        if importedCount > 0 {
            libraryModel.activeSavedFilterID = nil
            defaults.removeObject(forKey: "activeSavedFilterID")
            libraryModel.setLibraryCategoryScope(.all)
        }
        await libraryModel.refreshLibrary()
        feedback.showStatus(
            "Imported \(importedCount) publication\(importedCount == 1 ? "" : "s").\(duplicateCount > 0 ? " Skipped \(duplicateCount) duplicate\(duplicateCount == 1 ? "" : "s")." : "")",
            systemImage: "checkmark.circle.fill"
        )
    }

    /// Reattaches a user-selected original to an existing local import after
    /// its app-managed copy has gone missing. The importer validates the
    /// replacement before the database path changes.
    func relinkImportedPublication(
        _ result: Result<[URL], Error>,
        installment: Installment
    ) async -> URL? {
        do {
            let urls = try result.get()
            guard let sourceURL = urls.first,
                  let importer,
                  let database,
                  let storagePaths
            else { return nil }

            let imported = try await importer.importPublication(
                from: sourceURL,
                expectedFormat: installment.format
            )
            let fileURL = storagePaths.libraryFilesDirectory.appending(
                path: imported.relativePath,
                directoryHint: .notDirectory
            )
            var updated = installment
            updated.acquisitionURL = fileURL
            try await database.save(installments: [updated])

            libraryModel.localCoverAttemptedWorkIDs.remove(updated.workID)
            await ensureGeneratedCover(
                for: updated.workID,
                fileURL: fileURL,
                format: updated.format
            )
            await libraryModel.refreshLibraryCounts(for: updated.workID)
            feedback.showStatus("Reconnected \(sourceURL.lastPathComponent).", systemImage: "link.circle.fill")
            return fileURL
        } catch {
            if (error as NSError).code != NSUserCancelledError {
                sourcesModel.show(error, title: "Couldn’t reconnect publication")
            }
            return nil
        }
    }

    func receiveDownload(
        _ event: DownloadEvent,
        from coordinator: DownloadCoordinator
    ) async {
        transfersModel.downloads = await coordinator.snapshots()
        guard let snapshot = event.snapshot else { return }

        if (isLibraryAutomationProcess || transfersModel.isSceneActive),
           [.restored, .verificationRequired].contains(event.kind),
           let requirement = snapshot.verificationRequirement
        {
            transfersModel.beginDownloadVerificationRecovery(
                requirement,
                coordinator: coordinator
            )
        } else if event.kind == .removed
            || [.cancelled, .completed, .failed].contains(snapshot.state)
        {
            transfersModel.downloadVerificationRecoveryTasks[snapshot.id]?.cancel()
            transfersModel.downloadVerificationRecoveryTasks[snapshot.id] = nil
        }

        if event.kind != .progress {
            try? await database?.save(download: snapshot.domainJob)
        }

        guard event.kind == .completed,
              let localURL = await coordinator.localFileURL(for: snapshot.id),
              let database
        else { return }

        do {
            var workInstallments = try await database.installments(for: snapshot.transfer.workID)
            guard let index = workInstallments.firstIndex(where: { $0.id == snapshot.transfer.installmentID }) else { return }
            workInstallments[index].acquisitionURL = localURL
            try await database.save(installments: [workInstallments[index]])
            await libraryModel.refreshLibraryCounts(for: snapshot.transfer.workID)
        } catch {
            sourcesModel.show(error, title: "Download finished but couldn’t update the library")
        }
    }
}
