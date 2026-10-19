import Foundation
import ImageIO
import MankoData
import MankoDomain
import MankoExtensions
import MankoReaders
import MankoSources
import MankoSync
import Observation
import OSLog
import SwiftUI
import WebKit

extension AppModel {
    func runAutomationNow() async -> Bool {
        if isPrivate { return await runLibraryAutomation(trigger: .manual) }
        guard !settingsSyncModel.isRequestingAutomation else { return false }
        guard !libraryModel.isCheckingLibraryUpdates || settingsSyncModel.isRunningAutomation else {
            settingsSyncModel.automationLastError = "Wait for the current library update check to finish."
            return false
        }
        settingsSyncModel.isRequestingAutomation = true
        defer { settingsSyncModel.isRequestingAutomation = false }
        do {
            try await sourcesModel.restorePendingCloudflareVerificationRequirements()
        } catch {
            sourcesModel.show(error, title: "Couldn’t resume source verification")
            return false
        }
        let succeeded = await libraryAutomationHandoff.perform(.manual)
        await synchronizeAfterProcessAutomation(refreshesContent: true)
        feedback.showStatus(
            succeeded ? "Saved automation rules finished." : (settingsSyncModel.automationLastError ?? "Automation could not finish. Try again."),
            systemImage: succeeded ? "checkmark.circle" : "exclamationmark.triangle"
        )
        return succeeded
    }

    func startPostStartupMaintenance() {
        guard isReadyForInteraction, !isLibraryAutomationProcess,
              !didStartStartupMaintenance, !sourcesModel.isSessionLocked else { return }
        didStartStartupMaintenance = true
        startupMaintenanceTask = Task { [weak self] in
            guard let self else { return }
            let started = ContinuousClock.now
            defer {
                startupMaintenanceTask = nil
                Self.startupLogger.notice("Post-startup maintenance finished after \(String(describing: started.duration(to: .now)), privacy: .public)")
            }
            do {
                try await startupMaintenanceHookForTesting?()
                try Task.checkCancellation()
                guard !sourcesModel.isSessionLocked else { return }
                let covers = startGeneratedCoversForManagedImports()
                await performReadyLibraryMaintenance(trigger: .launch)
                guard !Task.isCancelled, !sourcesModel.isSessionLocked else { return }
                await covers?.value
            } catch is CancellationError {
                return
            } catch {
                guard !sourcesModel.isSessionLocked else { return }
                sourcesModel.show(error, title: "Couldn’t finish startup maintenance")
            }
        }
    }

    func performForegroundLibraryMaintenance() async {
        guard isReadyForInteraction, !isPrivate, !isLibraryAutomationProcess else { return }
        #if DEBUG
        if MankoScreenshotMode.isEnabled { return }
        #endif
        // An activation during startup is satisfied by that pass, including its
        // verification recovery and automation. Do not immediately repeat it.
        if let startupMaintenanceTask {
            await startupMaintenanceTask.value
            return
        }
        if let foregroundMaintenanceTask {
            await foregroundMaintenanceTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { foregroundMaintenanceTask = nil }
            await performReadyLibraryMaintenance(trigger: .foreground)
        }
        foregroundMaintenanceTask = task
        await task.value
    }

    private func performReadyLibraryMaintenance(trigger: LibraryAutomationTrigger) async {
        guard !Task.isCancelled, !sourcesModel.isSessionLocked else { return }
        if trigger == .foreground, let repositoryStore {
            let repositories = await repositoryStore.repositories()
            let installed = await repositoryStore.installedSources()
            guard !Task.isCancelled, !sourcesModel.isSessionLocked else { return }
            sourcesModel.sourceRepositories = repositories
            sourcesModel.installedRepositorySources = installed
            sourcesModel.reconcileInstalledSourceIndex(announcesRecovery: true)
        }
        await sourcesModel.refreshSourceHealth()
        guard !Task.isCancelled, !sourcesModel.isSessionLocked else { return }
        do {
            try await sourcesModel.restorePendingCloudflareVerificationRequirements()
        } catch is CancellationError {
            return
        } catch {
            sourcesModel.show(error, title: "Couldn’t resume source verification")
            return
        }
        guard !Task.isCancelled, !sourcesModel.isSessionLocked, !isPrivate else { return }
        if let trackerQueue {
            let pendingCount = await trackerQueue.pending().count
            guard !Task.isCancelled else { return }
            trackingModel.trackerPendingCount = pendingCount
        }
        let outcome = await libraryAutomationHandoff.performWithOutcome(trigger)
        guard !Task.isCancelled else { return }
        await synchronizeAfterProcessAutomation(refreshesContent: outcome.contentChanged)
        if trigger == .foreground { await trackingModel.deliverRepositoryTrackerQueue() }
    }

    func performReadingCompletedLibraryMaintenance() async {
        if ReadingRefreshPolicy.current == .afterReaderCloses {
            Task(priority: .utility) { await runReadingCompletedLibraryMaintenance() }
        } else {
            await runReadingCompletedLibraryMaintenance()
        }
    }

    private func runReadingCompletedLibraryMaintenance() async {
        #if DEBUG
        if MankoScreenshotMode.isEnabled { return }
        #endif
        do {
            try await sourcesModel.restorePendingCloudflareVerificationRequirements()
        } catch {
            sourcesModel.show(error, title: "Couldn’t resume source verification")
            return
        }
        _ = await libraryAutomationHandoff.perform(.readingCompleted)
        await synchronizeAfterProcessAutomation(refreshesContent: false)
    }

    func reloadProcessLibraryAutomationConfiguration() async {
        guard isLibraryAutomationProcess else { return }
        sourcesModel.sources = SourcesModel.loadSources(from: defaults)
        sourcesModel.sourceCredentialAccounts = SourcesModel.loadSourceCredentialAccounts(from: defaults)
        sourcesModel.sourceOptions = SourcesModel.loadSourceOptions(from: defaults)
        sourcesModel.sourceSearchExclusions = SourcesModel.loadSourceSearchExclusions(from: defaults)
        settingsSyncModel.automationRules = SettingsSyncModel.loadAutomationRules(from: defaults)
        libraryModel.libraryUpdatesLastCheckedAt = defaults.object(
            forKey: "lastLibraryAutomationUpdateCheck"
        ) as? Date
        settingsSyncModel.lastAutomationRun = SettingsSyncModel.loadLastAutomationRun(from: defaults)
        settingsSyncModel.wifiOnlyDownloads = defaults.object(forKey: "wifiOnlyDownloads") as? Bool ?? true
        if let downloadCoordinator {
            transfersModel.downloads = await downloadCoordinator.snapshots()
        }
        settingsSyncModel.configureLibraryAutomation()
    }

    func runLibraryAutomation(trigger: LibraryAutomationTrigger) async -> Bool {
        guard !settingsSyncModel.isRunningAutomation,
              !libraryModel.isCheckingLibraryUpdates
        else {
            settingsSyncModel.automationLastError = "A library maintenance operation is already running."
            return false
        }
        guard settingsSyncModel.automationRules.checksForUpdates || settingsSyncModel.automationRules.deletesCompletedDownloads else {
            settingsSyncModel.automationLastError = nil
            return true
        }
        guard let database else {
            settingsSyncModel.automationLastError = "Library storage is still starting."
            return false
        }

        settingsSyncModel.isRunningAutomation = true
        settingsSyncModel.automationLastError = nil
        settingsSyncModel.automationVerificationInterruptionDescription = nil
        if isLibraryAutomationProcess {
            await trackingModel.deliverRepositoryTrackerQueue(mode: .background)
        }
        let startedAt = Date.now
        var checkedWorkCount = 0
        var updatedWorkCount = 0
        var queuedDownloadCount = 0
        var deletedDownloadCount = 0
        var failureCount = 0
        var updateCheckInterruptionDescription: String?
        defer { settingsSyncModel.isRunningAutomation = false }

        let shouldCheckForUpdates = settingsSyncModel.automationRules.checksForUpdates
            && trigger != .readingCompleted
            && (trigger == .manual || LibraryAutomationPolicy.updateCheckIsDue(
                rules: settingsSyncModel.automationRules,
                lastCheck: libraryModel.libraryUpdatesLastCheckedAt,
                now: startedAt
            ))

        if shouldCheckForUpdates {
            libraryModel.isCheckingLibraryUpdates = true
            var updateRun: LibraryUpdateBatchRun?
            do {
                updateRun = try await performLibraryUpdateBatch(
                    verificationMode: isLibraryAutomationProcess ? .background : .foreground
                )
            } catch let interruption as LibraryUpdateBatchInterruption {
                checkedWorkCount = interruption.checkedTitleCount
                failureCount += 1
                updateCheckInterruptionDescription = interruption.localizedDescription
            } catch {
                failureCount += 1
                updateCheckInterruptionDescription = error.localizedDescription
            }
            libraryModel.isCheckingLibraryUpdates = false

            // Applied mutations still count when cancellation arrives after the
            // batch committed; coalesced callers must refresh those changes.
            if let updateRun {
                checkedWorkCount = updateRun.summary.checkedTitleCount
                updatedWorkCount = updateRun.summary.updatedTitleCount
                failureCount += updateRun.summary.failedTitleCount
            }
            if let updateRun, updateCheckInterruptionDescription == nil, !Task.isCancelled {
                automationUpdates: for update in updateRun.appliedUpdates {
                    if Task.isCancelled {
                        failureCount += 1
                        break
                    }

                    guard settingsSyncModel.automationRules.downloadsNewInstallments else { continue }
                    for installment in update.newInstallments {
                        if Task.isCancelled { break }
                        let didEnqueue = await enqueueDownload(
                            work: update.work,
                            installment: installment,
                            announces: false,
                            verificationMode: isLibraryAutomationProcess ? .background : .foreground
                        )
                        if let interruption = settingsSyncModel.automationVerificationInterruptionDescription {
                            updateCheckInterruptionDescription = interruption
                            failureCount += 1
                            break automationUpdates
                        }
                        if didEnqueue {
                            queuedDownloadCount += 1
                        } else if transfersModel.downloadSnapshot(for: installment.id) == nil {
                            failureCount += 1
                        }
                    }
                }
            }
        }

        if updateCheckInterruptionDescription == nil,
           settingsSyncModel.automationRules.deletesCompletedDownloads,
           !Task.isCancelled
        {
            let completedDownloads = transfersModel.downloads.filter { $0.state == .completed }
            for snapshot in completedDownloads {
                if Task.isCancelled { break }
                do {
                    let progress = try await database.progress(
                        workID: snapshot.transfer.workID,
                        installmentID: snapshot.transfer.installmentID
                    )
                    guard LibraryAutomationPolicy.downloadIsEligibleForDeletion(
                        rules: settingsSyncModel.automationRules,
                        state: snapshot.state,
                        completedAt: snapshot.modifiedAt,
                        highestProgression: progress?.highestProgression
                    ) else { continue }
                    if await removeDownload(snapshot, announcesErrors: false) {
                        deletedDownloadCount += 1
                    } else {
                        failureCount += 1
                    }
                } catch {
                    failureCount += 1
                }
            }
        }

        if Task.isCancelled { failureCount += 1 }
        let report = LibraryAutomationRunReport(
            trigger: trigger,
            startedAt: startedAt,
            finishedAt: .now,
            checkedWorkCount: checkedWorkCount,
            updatedWorkCount: updatedWorkCount,
            queuedDownloadCount: queuedDownloadCount,
            deletedDownloadCount: deletedDownloadCount,
            failureCount: failureCount
        )
        settingsSyncModel.lastAutomationRun = report
        do {
            defaults.set(
                try JSONEncoder().encode(report),
                forKey: "lastLibraryAutomationRun"
            )
        } catch {
            settingsSyncModel.automationLastError = "Couldn’t save automation status: \(error.localizedDescription)"
            return false
        }
        if let updateCheckInterruptionDescription {
            settingsSyncModel.automationLastError = updateCheckInterruptionDescription
        } else if failureCount > 0 {
            settingsSyncModel.automationLastError = "\(failureCount) automation operation\(failureCount == 1 ? "" : "s") did not finish."
        }
        return failureCount == 0
    }

    func synchronizeAfterProcessAutomation(refreshesContent: Bool) async {
        libraryModel.libraryUpdatesLastCheckedAt = defaults.object(
            forKey: "lastLibraryAutomationUpdateCheck"
        ) as? Date
        settingsSyncModel.lastAutomationRun = SettingsSyncModel.loadLastAutomationRun(from: defaults)
        settingsSyncModel.automationLastError = libraryAutomationHandoff.lastError
        if let downloadCoordinator {
            transfersModel.downloads = await downloadCoordinator.snapshots()
        }
        if refreshesContent {
            await refreshAfterRemoteSync()
        }
    }
}
