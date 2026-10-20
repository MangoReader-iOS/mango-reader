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
    func refreshLibraryFromSources() async -> LibraryUpdateBatchSummary? {
        guard !libraryModel.isCheckingLibraryUpdates, !settingsSyncModel.isRunningAutomation else { return nil }
        libraryModel.isCheckingLibraryUpdates = true
        defer { libraryModel.isCheckingLibraryUpdates = false }

        do {
            let run = try await performLibraryUpdateBatch()
            libraryModel.showLibraryUpdateSummary(run.summary)
            return run.summary
        } catch let interruption as LibraryUpdateBatchInterruption {
            feedback.showStatus(
                interruption.localizedDescription,
                systemImage: "exclamationmark.triangle.fill"
            )
            return nil
        } catch {
            feedback.showStatus(
                "Couldn’t check for updates. \(error.localizedDescription)",
                systemImage: "exclamationmark.triangle.fill"
            )
            return nil
        }
    }

    func performLibraryUpdateBatch(
        verificationMode: CloudflareRecoveryMode = .foreground
    ) async throws -> LibraryUpdateBatchRun {
        guard let database else {
            throw LibraryUpdateBatchInterruption(
                checkedTitleCount: 0,
                message: "Library storage is still starting. Try again in a moment."
            )
        }

        let remoteWorks: [Work]
        do {
            remoteWorks = try await database.library(sort: .title)
                .filter { $0.sourceID != .local }
        } catch {
            throw LibraryUpdateBatchInterruption(
                checkedTitleCount: 0,
                message: "Couldn’t load the titles to check. \(error.localizedDescription)"
            )
        }

        var results: [LibraryUpdateResult] = []
        var checkedTitleCount = 0
        for work in remoteWorks {
            do {
                try Task.checkCancellation()
                let descriptor = sourcesModel.sources.first(where: { $0.id == work.sourceID })
                let existingInstallments = try await database.installments(for: work.id)
                let planLoaderForTesting = libraryModel.libraryUpdatePlanLoaderForTesting
                let plan = try await sourcesModel.performSourceOperation(mode: verificationMode) { [weak self] in
                    guard let self else { throw CancellationError() }
                    if let loader = planLoaderForTesting {
                        return try await loader(work, existingInstallments)
                    }
                    let source = try await self.sourcesModel.makeRemoteSource(for: descriptor)
                    return try await RemoteLibraryPlanner(source: source).planUpdate(
                        existingWork: work,
                        existingInstallments: existingInstallments
                    )
                }
                try Task.checkCancellation()
                results.append(LibraryUpdateResult(work: work, plan: plan))
            } catch is CancellationError {
                throw LibraryUpdateBatchInterruption(
                    checkedTitleCount: checkedTitleCount,
                    message: "Update check stopped."
                )
            } catch let error as CloudflareVerificationRequiredError {
                throw LibraryUpdateBatchInterruption(
                    checkedTitleCount: checkedTitleCount,
                    message: error.localizedDescription
                )
            } catch let error as CloudflareVerificationPersistenceError {
                throw LibraryUpdateBatchInterruption(
                    checkedTitleCount: checkedTitleCount,
                    message: error.localizedDescription
                )
            } catch {
                results.append(LibraryUpdateResult(
                    work: work,
                    errorMessage: error.localizedDescription
                ))
            }
            checkedTitleCount += 1
        }

        do {
            try Task.checkCancellation()
        } catch {
            throw LibraryUpdateBatchInterruption(
                checkedTitleCount: checkedTitleCount,
                message: "Update check stopped."
            )
        }

        var appliedUpdates: [AppliedLibraryUpdate] = []
        var failedTitleCount = results.lazy.filter { $0.errorMessage != nil }.count
        for result in results where result.hasApplicableChanges {
            do {
                if let applied = try await applyLibraryUpdate(result, database: database) {
                    appliedUpdates.append(applied)
                }
            } catch {
                failedTitleCount += 1
            }
        }

        await settingsSyncModel.queueCloudSaves(appliedUpdates.map { CloudSyncRecordID.work($0.work.id) })
        if !appliedUpdates.isEmpty {
            await libraryModel.refreshLibrary(showsLoadingIndicator: false)
        }

        let completedAt = Date.now
        libraryModel.libraryUpdatesLastCheckedAt = completedAt
        defaults.set(completedAt, forKey: "lastLibraryAutomationUpdateCheck")

        return LibraryUpdateBatchRun(
            summary: LibraryUpdateBatchSummary(
                checkedTitleCount: checkedTitleCount,
                updatedTitleCount: appliedUpdates.count,
                failedTitleCount: failedTitleCount
            ),
            appliedUpdates: appliedUpdates
        )
    }

    func applyLibraryUpdate(
        _ result: LibraryUpdateResult,
        database: MangoReaderDatabase
    ) async throws -> AppliedLibraryUpdate? {
        guard result.hasApplicableChanges, let plan = result.plan else { return nil }
        guard let entry = try await database.libraryEntry(for: result.id) else {
            throw SourceError.notFound
        }

        var proposedWork = plan.proposedWork
        proposedWork.modifiedAt = .now
        var updatedEntry = entry
        let (updatedUnreadCount, unreadCountOverflowed) = entry.unreadCount.addingReportingOverflow(
            plan.newlyAvailableInstallments.count
        )
        updatedEntry.unreadCount = unreadCountOverflowed ? Int.max : max(0, updatedUnreadCount)

        // This write is intentionally upsert-only. Installments no longer listed
        // by the source remain available in the library.
        try await database.save(
            work: proposedWork,
            entry: updatedEntry,
            installments: plan.proposedInstallments
        )
        applyUpdatedWork(proposedWork)
        return AppliedLibraryUpdate(
            work: proposedWork,
            newInstallments: plan.newlyAvailableInstallments
        )
    }

    func clearHistory() async -> Bool {
        guard let database else { return false }
        do {
            let deletedSessionIDs = try await database.deleteReadingSessions()
            if let cloudSyncEngine {
                for sessionID in deletedSessionIDs {
                    await cloudSyncEngine.queueDelete(
                        recordName: CloudSyncRecordID.session(sessionID)
                    )
                }
            }
            libraryModel.sessions = []
            libraryModel.historyWorks = [:]
            libraryModel.historyInstallments = [:]
            libraryModel.continueReadingItem = nil
            libraryModel.continueReadingItemsByWorkID = [:]
            libraryModel.readingInsights = nil
            libraryModel.readingStats = nil
            await libraryModel.refreshHistory()
            return true
        } catch {
            sourcesModel.show(error, title: "Couldn’t clear history")
            return false
        }
    }

    func refreshSearchAfterLibraryChanges(database: MangoReaderDatabase) async {
        guard !searchModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let results = try? await database.search(searchModel.searchText, limit: 100) { searchModel.searchResults = results }
        searchModel.search(searchModel.searchText)
    }

    func setCustomCover(_ data: Data, for workID: WorkID) async -> Bool {
        guard let database, let customCoverStore else { return false }

        var newPath: String?
        do {
            let storedPath = try await customCoverStore.store(data, for: workID)
            newPath = storedPath
            guard
                var updatedWork = try await database.work(id: workID),
                let entry = try await database.libraryEntry(for: workID)
            else {
                try await customCoverStore.remove(path: storedPath)
                return false
            }

            let previousPath = updatedWork.customCoverPath
            updatedWork.customCoverPath = storedPath
            updatedWork.modifiedAt = .now
            try await database.save(work: updatedWork, entry: entry)
            applyUpdatedWork(updatedWork)
            if let previousPath, previousPath != storedPath {
                try? await customCoverStore.remove(path: previousPath)
            }
            return true
        } catch {
            if let newPath {
                try? await customCoverStore.remove(path: newPath)
            }
            sourcesModel.show(error, title: "Couldn’t set custom cover")
            return false
        }
    }

    func removeCustomCover(for workID: WorkID) async -> Bool {
        guard let database, let customCoverStore else { return false }
        do {
            guard
                var updatedWork = try await database.work(id: workID),
                let entry = try await database.libraryEntry(for: workID)
            else { return false }
            guard let previousPath = updatedWork.customCoverPath else { return true }

            updatedWork.customCoverPath = nil
            updatedWork.modifiedAt = .now
            try await database.save(work: updatedWork, entry: entry)
            applyUpdatedWork(updatedWork)
            try await customCoverStore.remove(path: previousPath)
            return true
        } catch {
            sourcesModel.show(error, title: "Couldn’t restore source cover")
            return false
        }
    }

    func applyUpdatedWork(_ work: Work) {
        if let index = libraryModel.library.firstIndex(where: { $0.id == work.id }) {
            libraryModel.library[index] = work
        }
        if let index = searchModel.searchResults.firstIndex(where: { $0.id == work.id }) {
            searchModel.searchResults[index] = work
        }
        if libraryModel.historyWorks[work.id] != nil {
            libraryModel.historyWorks[work.id] = work
        }
    }

    @discardableResult
    func saveTitleState(
        for workID: WorkID,
        rating: TenPointRating?,
        status: TrackerReadingStatus?,
        dateUpdates: TrackerDateUpdates? = nil,
        modifiedAt: Date = .now
    ) async -> UserTitleState? {
        guard !settingsSyncModel.incognitoMode else {
            feedback.alert = AppAlert(
                title: "Incognito mode is on",
                message: "Turn off incognito mode before editing tracking."
            )
            return nil
        }
        guard let database else { return nil }
        do {
            let current = try await database.titleState(for: workID)
            var changedFields: Set<TrackerSyncField> = []
            if current?.rating != rating { changedFields.insert(.rating) }
            if current?.status != status { changedFields.insert(.status) }
            let start = dateUpdates?.fields.contains(.startDate) == true ? dateUpdates?.startDate : current?.startDate
            let finish = dateUpdates?.fields.contains(.finishDate) == true ? dateUpdates?.finishDate : current?.finishDate
            if current?.startDate != start { changedFields.insert(.startDate) }
            if current?.finishDate != finish { changedFields.insert(.finishDate) }
            let state = UserTitleState(
                workID: workID,
                rating: rating,
                status: status,
                startDate: start,
                finishDate: finish,
                modifiedAt: modifiedAt,
                deviceID: deviceID
            )
            if state.isEmpty {
                if await libraryModel.deleteTitleState(for: workID) {
                    await trackingModel.enqueueTrackerSnapshot(for: workID, changedFields: changedFields)
                }
                return nil
            }
            let result = try await database.save(titleState: state)
            guard result.didSave else {
                feedback.alert = AppAlert(
                    title: "Couldn’t save tracking",
                    message: "A newer deletion was synced from another device. Try saving again."
                )
                return nil
            }
            if let tombstoneID = result.supersededTombstoneID {
                await cloudSyncEngine?.queueDelete(
                    recordName: CloudSyncRecordID.tombstone(tombstoneID)
                )
            }
            libraryModel.userTitleStates[workID] = state
            await settingsSyncModel.queueCloudSave(CloudSyncRecordID.titleState(workID: workID))
            if libraryModel.readingStats != nil { _ = await libraryModel.loadReadingStats() }
            await trackingModel.enqueueTrackerSnapshot(for: workID, changedFields: changedFields)
            return state
        } catch {
            sourcesModel.show(error, title: "Couldn’t save tracking")
            return nil
        }
    }

    func updateRating(for workID: WorkID, rating: TenPointRating?) async -> Bool {
        let current = await libraryModel.titleState(for: workID)
        if rating == nil, current?.status == nil, current?.startDate == nil, current?.finishDate == nil {
            let deleted = await libraryModel.deleteTitleState(for: workID)
            if deleted { await trackingModel.enqueueTrackerSnapshot(for: workID, changedFields: [.rating]) }
            return deleted
        }
        return await saveTitleState(
            for: workID,
            rating: rating,
            status: current?.status
        ) != nil
    }

    func updateReadingStatus(
        for workID: WorkID,
        status: TrackerReadingStatus?,
        now: Date = .now
    ) async -> Bool {
        let current = await libraryModel.titleState(for: workID)
        if status == nil, current?.rating == nil, current?.startDate == nil, current?.finishDate == nil {
            let deleted = await libraryModel.deleteTitleState(for: workID)
            if deleted { await trackingModel.enqueueTrackerSnapshot(for: workID, changedFields: [.status]) }
            return deleted
        }
        var start = current?.startDate
        var finish = current?.finishDate
        if status != current?.status {
            if (status == .reading || status == .rereading), start == nil { start = TrackerDate(now) }
            if status == .completed, finish == nil { finish = TrackerDate(now) }
        }
        guard TrackerDate.areOrdered(start: start, finish: finish) else { return false }
        return await saveTitleState(
            for: workID,
            rating: current?.rating,
            status: status,
            dateUpdates: .init(startDate: start, finishDate: finish)
        ) != nil
    }

    func updateTrackingDates(for workID: WorkID, dates: TrackerDateUpdates) async -> Bool {
        guard !settingsSyncModel.incognitoMode else { return false }
        let current = await libraryModel.titleState(for: workID, reload: true)
        let start = dates.fields.contains(.startDate) ? dates.startDate : current?.startDate
        let finish = dates.fields.contains(.finishDate) ? dates.finishDate : current?.finishDate
        guard start?.isValid != false, finish?.isValid != false,
              TrackerDate.areOrdered(start: start, finish: finish) else { return false }
        if current?.rating == nil, current?.status == nil, start == nil, finish == nil {
            let deleted = await libraryModel.deleteTitleState(for: workID)
            if deleted { await trackingModel.enqueueTrackerSnapshot(for: workID, changedFields: dates.fields) }
            return deleted
        }
        return await saveTitleState(for: workID, rating: current?.rating, status: current?.status, dateUpdates: dates) != nil
    }

    func fillTrackingStartDate(for workID: WorkID, now: Date = .now) async {
        guard !settingsSyncModel.incognitoMode else { return }
        let current = await libraryModel.titleState(for: workID, reload: true)
        guard current?.startDate == nil else { return }
        let start = TrackerDate(now)
        guard TrackerDate.areOrdered(start: start, finish: current?.finishDate) else { return }
        _ = await saveTitleState(for: workID, rating: current?.rating, status: current?.status,
                                 dateUpdates: .init(startDate: start, finishDate: nil, fields: [.startDate]))
    }

    func applyForwardChapterCount(
        _ count: Double,
        workID: WorkID,
        installments: [Installment],
        updatesTrackingStatus: Bool = true
    ) async throws {
        guard let mapped = TrackerChapterMapping.importChapters(boundary: count, chapters: installments) else {
            throw SourceError.transport(TrackerChapterMapping.issue(in: installments) ?? "Tracker progress cannot be matched safely.")
        }
        try await markInstallmentsComplete(mapped, workID: workID, updatesTrackingStatus: updatesTrackingStatus)
    }

    func markInstallmentsComplete(_ installments: [Installment], workID: WorkID, updatesTrackingStatus: Bool = true) async throws {
        guard let database else { return }
        let ids = try await database.completeInstallmentsPreservingPositions(workID: workID, installments: installments, deviceID: deviceID)
        await settingsSyncModel.queueCloudSaves(ids.map(CloudSyncRecordID.chapterProgress) + [CloudSyncRecordID.progress(workID: workID)])
        if updatesTrackingStatus { await advanceStatusAfterFirstCompletion(workID: workID) }
    }

    func advanceStatusAfterFirstCompletion(workID: WorkID) async {
        guard let database else { return }
        let existing = try? await database.titleState(for: workID)
        guard existing?.status == nil || existing?.status == .planning else { return }
        _ = await updateReadingStatus(for: workID, status: .reading)
    }

    func refreshCachedWorkFromStorage(_ workID: WorkID) async {
        guard let database,
              let refreshedWork = try? await database.work(id: workID)
        else { return }
        applyUpdatedWork(refreshedWork)
    }

    func applyBulkSourceMigration(
        _ preview: BulkSourceMigrationPreview
    ) async throws -> BulkSourceMigrationCommitResult {
        guard !libraryModel.isApplyingBulkSourceMigration, !libraryModel.isPerformingSelectionAction else {
            throw SourceMigrationApplicationError.alreadyApplying
        }
        guard let database else {
            throw SourceMigrationApplicationError.libraryUnavailable
        }
        guard sourcesModel.sources.contains(where: {
            $0.id == preview.destinationSourceID && $0.isEnabled && $0.kind != .local
        }) else {
            throw SourceMigrationApplicationError.sourceUnavailable
        }
        guard
            !preview.items.isEmpty,
            preview.items.count <= BulkSourceMigrationCommitLimits.maximumWorks,
            Set(preview.items.map(\.id)).count == preview.items.count
        else {
            throw SourceMigrationApplicationError.invalidBulkPreview
        }

        let commits = try preview.items.compactMap { item -> LibrarySourceMigrationCommit? in
            guard case let .ready(targetWork, plan) = item.outcome else { return nil }
            guard
                item.existingWork.sourceID != .local,
                targetWork.sourceID == preview.destinationSourceID,
                plan.proposedWork.id == item.existingWork.id,
                plan.proposedWork.sourceID == preview.destinationSourceID,
                plan.ambiguousMatches.isEmpty
            else {
                throw SourceMigrationApplicationError.invalidBulkPreview
            }
            var committedWork = plan.proposedWork
            committedWork.modifiedAt = .now
            return LibrarySourceMigrationCommit(
                expectedSourceID: item.existingWork.sourceID,
                expectedModifiedAt: item.existingWork.modifiedAt,
                proposedWork: committedWork,
                proposedInstallments: plan.proposedInstallments
            )
        }
        guard !commits.isEmpty else {
            throw SourceMigrationApplicationError.noReadyMigrations
        }

        libraryModel.isApplyingBulkSourceMigration = true
        defer { libraryModel.isApplyingBulkSourceMigration = false }

        let result = try await database.applySourceMigrations(commits)
        for workID in result.updatedIDs {
            await libraryModel.refreshLibraryCounts(for: workID)
            if let refreshedWork = try? await database.work(id: workID) {
                applyUpdatedWork(refreshedWork)
            }
        }
        await settingsSyncModel.queueCloudSaves(result.updatedIDs.map(CloudSyncRecordID.work))

        await libraryModel.refreshLibrary()
        await refreshSearchAfterLibraryChanges(database: database)

        let skippedCount = max(0, preview.items.count - result.updatedIDs.count)
        let migratedCount = result.updatedIDs.count
        let skippedSentence = skippedCount == 0
            ? ""
            : " \(skippedCount) title\(skippedCount == 1 ? " was" : "s were") skipped because \(skippedCount == 1 ? "it needs" : "they need") per-title review or could not be matched safely."
        feedback.alert = AppAlert(
            title: "Sources migrated",
            message: "Migrated \(migratedCount) title\(migratedCount == 1 ? "" : "s") to the selected source." + skippedSentence
        )
        return result
    }

    func removeFromLibrary(workIDs: Set<WorkID>) async -> Bool {
        guard let database, !workIDs.isEmpty else { return false }

        do {
            let persistedWorks = try await database.works(ids: workIDs)
            let localWorkIDs = Set(
                persistedWorks
                    .filter { $0.sourceID == .local }
                    .map(\.id)
            )
            let remoteWorkIDs = workIDs.subtracting(localWorkIDs)
            var localFiles: Set<URL> = []
            var localChapterIDs: Set<InstallmentID> = []
            var managedCoverPaths: Set<String> = []
            for workID in localWorkIDs {
                guard let storedWork = try await database.work(id: workID) else { continue }
                if let path = storedWork.customCoverPath {
                    managedCoverPaths.insert(path)
                }
                if let customCoverStore,
                   let coverURL = storedWork.coverURL,
                   let path = try? customCoverStore.managedPath(for: coverURL)
                {
                    managedCoverPaths.insert(path)
                }
            }
            for workID in localWorkIDs {
                let workInstallments = try await database.installments(for: workID)
                localChapterIDs.formUnion(workInstallments.map(\.id))
                localFiles.formUnion(
                    workInstallments.compactMap { installment in
                        guard installment.acquisitionURL?.isFileURL == true else { return nil }
                        return installment.acquisitionURL
                    }
                )
            }

            let matchingDownloads = transfersModel.downloads.filter {
                localWorkIDs.contains($0.transfer.workID)
            }
            let matchingSessions = try await database.sessions(limit: 10_000).filter {
                localWorkIDs.contains($0.workID)
            }
            let importedOriginalReferences = try await database.importedOriginalReferences(
                for: localWorkIDs
            )
            let demotedWorkIDs = try await database.demoteLibraryWorksToReadingContent(
                workIDs: remoteWorkIDs
            )
            if !localWorkIDs.isEmpty {
                try await database.remove(workIDs: localWorkIDs, deviceID: deviceID)
            }

            for workID in demotedWorkIDs {
                await settingsSyncModel.queueCloudSave(CloudSyncRecordID.readingContent(workID))
                await cloudSyncEngine?.queueDelete(recordName: CloudSyncRecordID.work(workID))
            }
            if let cloudSyncEngine {
                for chapterID in localChapterIDs {
                    await cloudSyncEngine.queueDelete(recordName: CloudSyncRecordID.chapterProgress(chapterID))
                }
                for workID in localWorkIDs {
                    await cloudSyncEngine.queueDelete(recordName: CloudSyncRecordID.work(workID))
                    await cloudSyncEngine.queueDelete(
                        recordName: CloudSyncRecordID.readingContent(workID)
                    )
                    await cloudSyncEngine.queueDelete(
                        recordName: CloudSyncRecordID.progress(workID: workID)
                    )
                    await cloudSyncEngine.queueDelete(
                        recordName: CloudSyncRecordID.titleState(workID: workID)
                    )
                }
                for session in matchingSessions {
                    await cloudSyncEngine.queueDelete(
                        recordName: CloudSyncRecordID.session(session.id)
                    )
                }
                for reference in importedOriginalReferences {
                    await cloudSyncEngine.queueDelete(
                        recordName: CloudSyncRecordID.importedOriginal(reference.installmentID)
                    )
                }
                if let cloudRecordStore {
                    let tombstones = try await cloudRecordStore.recordNames().filter {
                        $0.hasPrefix("tombstone:")
                    }
                    await cloudSyncEngine.queueSaves(recordNames: tombstones)
                }
            }

            if let downloadCoordinator {
                for download in matchingDownloads {
                    try? await downloadCoordinator.remove(download.id)
                }
                transfersModel.downloads = await downloadCoordinator.snapshots()
            }

            if let libraryRoot = storagePaths?.libraryFilesDirectory, !localFiles.isEmpty {
                await TransfersModel.removeManagedFiles(localFiles, beneath: libraryRoot)
            }
            if let customCoverStore {
                for path in managedCoverPaths {
                    try? await customCoverStore.remove(path: path)
                }
            }

            let removedLibraryWorkIDs = demotedWorkIDs.union(localWorkIDs)
            libraryModel.library.removeAll { removedLibraryWorkIDs.contains($0.id) }
            libraryModel.pinnedWorkIDs.subtract(removedLibraryWorkIDs)
            libraryModel.historyWorks = libraryModel.historyWorks.filter { !localWorkIDs.contains($0.key) }
            libraryModel.userTitleStates = libraryModel.userTitleStates.filter { !localWorkIDs.contains($0.key) }
            trackingModel.trackerLinksByWork = trackingModel.trackerLinksByWork.filter { !localWorkIDs.contains($0.key) }
            libraryModel.sessions.removeAll { localWorkIDs.contains($0.workID) }
            await libraryModel.refreshLibrary()
            await libraryModel.refreshHistory()
            if localWorkIDs.isEmpty {
                feedback.showStatus(
                    demotedWorkIDs.count == 1
                        ? "Removed from Library. Reading data and downloads were kept."
                        : "Removed \(demotedWorkIDs.count) titles from Library. Reading data and downloads were kept.",
                    systemImage: "bookmark"
                )
            } else if demotedWorkIDs.isEmpty {
                feedback.showStatus(
                    localWorkIDs.count == 1
                        ? "Deleted the import and its Mango Reader-managed files."
                        : "Deleted \(localWorkIDs.count) imports and their Mango Reader-managed files.",
                    systemImage: "trash.fill"
                )
            } else {
                feedback.showStatus(
                    "Removed \(demotedWorkIDs.count) remote title\(demotedWorkIDs.count == 1 ? "" : "s") and deleted \(localWorkIDs.count) import\(localWorkIDs.count == 1 ? "" : "s").",
                    systemImage: "bookmark"
                )
            }
            return true
        } catch {
            sourcesModel.show(error, title: "Couldn’t update Library")
            return false
        }
    }

    func ensureGeneratedCoversForManagedImports() async {
        await startGeneratedCoversForManagedImports()?.value
    }

    func startGeneratedCoversForManagedImports() -> Task<Void, Never>? {
        guard !Task.isCancelled, !sourcesModel.isSessionLocked else { return nil }
        if let generatedCoversTask { return generatedCoversTask }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { generatedCoversTask = nil }
            do {
                try await generatedCoversHookForTesting?()
                try Task.checkCancellation()
                await generateMissingImportedCovers()
            } catch { return }
        }
        generatedCoversTask = task
        return task
    }

    private func generateMissingImportedCovers() async {
        guard !sourcesModel.isSessionLocked, let database, let storagePaths else { return }
        let originals: [ManagedImportedOriginal]
        do {
            originals = try await database.managedImportedOriginals()
        } catch {
            return
        }

        var seen: Set<WorkID> = []
        for original in originals where seen.insert(original.workID).inserted {
            guard !Task.isCancelled, !sourcesModel.isSessionLocked else { return }
            let fileURL = storagePaths.libraryFilesDirectory.appending(
                path: original.localRelativePath,
                directoryHint: .notDirectory
            )
            await ensureGeneratedCover(
                for: original.workID,
                fileURL: fileURL,
                format: original.format
            )
        }
    }

    func ensureGeneratedCover(
        for workID: WorkID,
        fileURL: URL,
        format: PublicationFormat
    ) async {
        guard
            !libraryModel.localCoverAttemptedWorkIDs.contains(workID),
            FileManager.default.fileExists(atPath: fileURL.path),
            let database,
            let customCoverStore,
            var work = try? await database.work(id: workID),
            let entry = try? await database.libraryEntry(for: workID)
        else {
            return
        }

        guard !Task.isCancelled, !sourcesModel.isSessionLocked else { return }
        if let coverURL = work.coverURL,
           !coverURL.isFileURL || FileManager.default.fileExists(atPath: coverURL.path) {
            return
        }

        let hadMissingLocalCover = work.coverURL?.isFileURL == true
        libraryModel.localCoverAttemptedWorkIDs.insert(workID)
        work.coverURL = nil
        let generatedCover = await libraryModel.workByAddingGeneratedCover(
            to: work,
            fileURL: fileURL,
            format: format
        )
        guard !Task.isCancelled, !sourcesModel.isSessionLocked else {
            if let path = generatedCover.managedPath { try? await customCoverStore.remove(path: path) }
            return
        }
        guard let path = generatedCover.managedPath else {
            if hadMissingLocalCover {
                try? await database.save(work: work, entry: entry)
                guard !Task.isCancelled, !sourcesModel.isSessionLocked else { return }
                applyUpdatedWork(work)
            }
            return
        }

        do {
            try await database.save(work: generatedCover.work, entry: entry)
            guard !Task.isCancelled, !sourcesModel.isSessionLocked else { return }
            applyUpdatedWork(generatedCover.work)
        } catch {
            try? await customCoverStore.remove(path: path)
        }
    }
}
