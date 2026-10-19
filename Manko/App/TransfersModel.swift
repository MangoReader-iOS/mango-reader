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

@MainActor
@Observable
final class TransfersModel {
    @ObservationIgnored var backupService: BackupService?
    let defaults: UserDefaults
    @ObservationIgnored var downloadCoordinator: DownloadCoordinator?
    let isLibraryAutomationProcess: Bool
    @ObservationIgnored var repositoryStore: SourceRepositoryStore?
    @ObservationIgnored var storagePaths: StoragePaths?
    let feedback: AppFeedback
    let settingsSyncModel: SettingsSyncModel
    let sourcesModel: SourcesModel

    init(
        defaults: UserDefaults,
        downloadCoordinator: DownloadCoordinator?,
        isLibraryAutomationProcess: Bool,
        feedback: AppFeedback,
        settingsSyncModel: SettingsSyncModel,
        sourcesModel: SourcesModel
    ) {
        self.defaults = defaults
        self.downloadCoordinator = downloadCoordinator
        self.isLibraryAutomationProcess = isLibraryAutomationProcess
        self.feedback = feedback
        self.settingsSyncModel = settingsSyncModel
        self.sourcesModel = sourcesModel
    }

    var downloads: [DownloadSnapshot] = []

    var publicationImportProgress = PublicationImportProgress()

    var isImporting = false

    var isExportingBackup = false
    var isSelectingBackupContents = false

    var isRestoringBackup = false

    var backupExport: BackupExportItem?

    var stagedRestore: StagedBackupRestore?

    var backupOperation: BackupOperation?
    var backupFailure: String?

    var isBackupBusy: Bool { backupOperation != nil || backupExport != nil || stagedRestore != nil }

    var pendingDownloadIDs: Set<UUID> = []

    var preparingDownloadInstallmentIDs: Set<InstallmentID> = []

    var isQueuingDownloads = false

    var isUpdatingWiFiOnlyDownloads = false

    var isExportingCompletedCBZ = false

    var completedCBZExport: CompletedCBZExportItem?

    var preparingCBZExportID: UUID?

    @ObservationIgnored var backupExporterForTesting: (@Sendable (URL, Bool) async throws -> Void)?

    @ObservationIgnored var downloadVerificationRecoveryTasks: [UUID: Task<Void, Never>] = [:]

    var wifiOnlyUpdateGeneration = 0

    var isSceneActive = false

    func prepareBackup(includeFiles: Bool) async {
        var selection = BackupRestoreSelection.exportDefault
        selection.set(.importedMedia, isEnabled: includeFiles)
        await prepareBackup(selection: selection)
    }

    func prepareBackup(selection: BackupRestoreSelection) async {
        let includeFiles = selection.contains(.importedMedia)
        guard !sourcesModel.isPrivate else { return }
        guard !isBackupBusy else { return }
        backupFailure = nil
        guard backupService != nil || backupExporterForTesting != nil else {
            let message = "Backup services are still starting. Try again shortly."
            backupFailure = message
            if !isSelectingBackupContents { feedback.alert = AppAlert(title: "Backup unavailable", message: message) }
            return
        }
        backupOperation = .preparingExport
        defer { backupOperation = nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Manko-\(UUID().uuidString).mankobackup")
        do {
            if let backupExporterForTesting {
                try await backupExporterForTesting(url, includeFiles)
            } else if let backupService {
                _ = try await backupService.export(
                    to: url,
                    includeLibraryFiles: includeFiles,
                    settingsData: selection.includesSetup ? try encodedBackupSetup(selection: selection) : nil,
                    selection: selection
                )
            }
            try Task.checkCancellation()
            backupExport = BackupExportItem(url: url)
            if !isSelectingBackupContents { isExportingBackup = true }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            backupFailure = error.localizedDescription
            if !isSelectingBackupContents { sourcesModel.show(error, title: "Couldn’t create backup") }
        }
    }

    func finishBackupExport(url: URL?, error: Error? = nil, completed: Bool = false) {
        guard let url, backupExport?.url == url else { return }
        try? FileManager.default.removeItem(at: url)
        backupExport = nil
        isExportingBackup = false
        if let error, (error as NSError).code != NSUserCancelledError {
            feedback.alert = AppAlert(title: "Backup export failed", message: error.localizedDescription)
        } else if completed {
            feedback.showStatus("Backup exported.", systemImage: "checkmark.circle")
        }
    }

    func inspectBackup(_ result: Result<[URL], Error>) async {
        guard !isBackupBusy else { return }
        guard let backupService else {
            feedback.alert = AppAlert(title: "Restore unavailable", message: "Backup services are still starting. Try again shortly.")
            return
        }
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            backupOperation = .inspecting
            defer { backupOperation = nil }
            do {
                let staged = try await backupService.stageRestore(from: url)
                if Task.isCancelled {
                    try? await backupService.discard(staged)
                    return
                }
                backupFailure = nil
                stagedRestore = staged
            } catch {
                sourcesModel.show(error, title: "Couldn’t inspect backup")
            }
        case let .failure(error):
            if (error as NSError).code != NSUserCancelledError {
                sourcesModel.show(error, title: "Couldn’t open backup")
            }
        }
    }

    func discardRestore() async {
        guard let stagedRestore else { return }
        await discardRestore(stagedRestore)
    }

    func discardRestore(_ stagedRestore: StagedBackupRestore) async {
        guard backupOperation != .restoring else { return }
        try? await backupService?.discard(stagedRestore)
        if self.stagedRestore?.id == stagedRestore.id {
            self.stagedRestore = nil
        }
    }

    func downloadSnapshot(for installmentID: InstallmentID) -> DownloadSnapshot? {
        downloads
            .filter { $0.transfer.installmentID == installmentID }
            .max { $0.modifiedAt < $1.modifiedAt }
    }

    func downloadedPublicationURL(for installmentID: InstallmentID) async -> URL? {
        guard let snapshot = downloadSnapshot(for: installmentID),
              snapshot.state == .completed,
              let downloadCoordinator,
              let url = await downloadCoordinator.localFileURL(for: snapshot.id),
              FileManager.default.fileExists(atPath: url.path)
        else {
            return nil
        }
        return url
    }

    var downloadBatchInProgressResult: DownloadBatchResult {
        var result = DownloadBatchResult()
        result.record(.failed("Another download request is still being prepared."))
        return result
    }

    func beginDownloadBatch() -> Bool {
        guard !isQueuingDownloads else { return false }
        isQueuingDownloads = true
        return true
    }

    func enqueueOutcome(for transferID: UUID) -> DownloadEnqueueOutcome {
        guard let snapshot = downloads.first(where: { $0.id == transferID }) else {
            return .failed("The download did not remain in the queue. Try again.")
        }
        if snapshot.state == .failed {
            return .failed(snapshot.lastError?.localizedDescription ?? "The download could not start.")
        }
        return snapshot.state == .cancelled ? .cancelled : .queued
    }

    func showDownloadBatchResult(_ result: DownloadBatchResult) {
        if result.failedCount > 0 {
            feedback.alert = AppAlert(title: "Some downloads couldn’t be queued", message: result.message)
        } else {
            feedback.showStatus(result.message, systemImage: result.queuedCount > 0 ? "arrow.down.circle.fill" : "info.circle")
        }
    }

    func canMoveDownloadUp(_ snapshot: DownloadSnapshot) -> Bool {
        downloadMoveTarget(for: snapshot, offset: -1) != nil
    }

    func canMoveDownloadDown(_ snapshot: DownloadSnapshot) -> Bool {
        downloadMoveTarget(for: snapshot, offset: 1) != nil
    }

    func moveDownloadUp(_ snapshot: DownloadSnapshot) async {
        guard let target = downloadMoveTarget(for: snapshot, offset: -1) else { return }
        await performDownloadAction("Couldn’t move download", id: snapshot.id) {
            try await $0.move(snapshot.id, before: target.id)
        }
    }

    func moveDownloadDown(_ snapshot: DownloadSnapshot) async {
        guard let target = downloadMoveTarget(for: snapshot, offset: 1) else { return }
        await performDownloadAction("Couldn’t move download", id: snapshot.id) {
            try await $0.move(snapshot.id, after: target.id)
        }
    }

    func pauseDownload(_ snapshot: DownloadSnapshot) async {
        await performDownloadAction("Couldn’t pause download", id: snapshot.id) {
            try await $0.pause(snapshot.id)
        }
    }

    func resumeDownload(_ snapshot: DownloadSnapshot) async {
        guard !isDownloadOperationPending(snapshot.id) else { return }
        if let requirement = snapshot.verificationRequirement,
           let downloadCoordinator
        {
            beginDownloadVerificationRecovery(
                requirement,
                coordinator: downloadCoordinator
            )
            return
        }
        await performDownloadAction("Couldn’t resume download", id: snapshot.id) {
            try await $0.resume(snapshot.id)
        }
    }

    func resumePendingDownloadVerificationRequirements() {
        guard isLibraryAutomationProcess || isSceneActive,
              let downloadCoordinator
        else { return }
        for snapshot in downloads {
            guard let requirement = snapshot.verificationRequirement else { continue }
            beginDownloadVerificationRecovery(
                requirement,
                coordinator: downloadCoordinator
            )
        }
    }

    func retryDownload(_ snapshot: DownloadSnapshot) async {
        await performDownloadAction("Couldn’t retry download", id: snapshot.id) {
            try await $0.retry(snapshot.id)
        }
    }

    func cancelDownload(_ snapshot: DownloadSnapshot) async {
        downloadVerificationRecoveryTasks[snapshot.id]?.cancel()
        downloadVerificationRecoveryTasks[snapshot.id] = nil
        await performDownloadAction("Couldn’t cancel download", id: snapshot.id) {
            try await $0.cancel(snapshot.id)
        }
    }

    func prepareCompletedCBZExport(_ snapshot: DownloadSnapshot) async {
        guard !sourcesModel.isPrivate else { return }
        guard preparingCBZExportID == nil, completedCBZExport == nil,
              !isDownloadOperationPending(snapshot.id) else { return }
        guard let storagePaths else {
            feedback.alert = AppAlert(
                title: "Couldn’t prepare comic archive",
                message: "Download storage is not available yet. Try again after Manko finishes loading."
            )
            return
        }

        preparingCBZExportID = snapshot.id
        defer { preparingCBZExportID = nil }
        clearCompletedCBZExport()

        let filename = completedCBZExportFilename(for: snapshot)
        let stagingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manko-\(UUID().uuidString).\((filename as NSString).pathExtension)")

        do {
            _ = try await CompletedCBZExportService().export(
                snapshot,
                offlineDownloadsRoot: storagePaths.offlineDownloadsDirectory,
                to: stagingURL
            )
            completedCBZExport = CompletedCBZExportItem(
                url: stagingURL,
                defaultFilename: filename
            )
            isExportingCompletedCBZ = true
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: stagingURL)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            sourcesModel.show(error, title: "Couldn’t prepare comic archive")
        }
    }

    func finishCompletedCBZExport(error: Error? = nil) {
        clearCompletedCBZExport()
        if let error, (error as NSError).code != NSUserCancelledError {
            feedback.alert = AppAlert(title: "Comic archive export failed", message: error.localizedDescription)
        }
    }

    func setWiFiOnlyDownloads(_ enabled: Bool) async {
        wifiOnlyUpdateGeneration += 1
        let generation = wifiOnlyUpdateGeneration
        isUpdatingWiFiOnlyDownloads = true
        defer {
            if wifiOnlyUpdateGeneration == generation {
                isUpdatingWiFiOnlyDownloads = false
            }
        }

        guard let downloadCoordinator else {
            settingsSyncModel.wifiOnlyDownloads = enabled
            defaults.set(enabled, forKey: "wifiOnlyDownloads")
            return
        }

        do {
            try await downloadCoordinator.setWiFiOnly(enabled)
            guard wifiOnlyUpdateGeneration == generation else { return }
            settingsSyncModel.wifiOnlyDownloads = enabled
            defaults.set(enabled, forKey: "wifiOnlyDownloads")
        } catch {
            guard wifiOnlyUpdateGeneration == generation else { return }
            sourcesModel.show(error, title: "Couldn’t update download settings")
        }
    }

    func beginDownloadVerificationRecovery(
        _ requirement: DownloadVerificationRequirement,
        coordinator: DownloadCoordinator
    ) {
        guard downloadVerificationRecoveryTasks[requirement.transferID] == nil else { return }
        let transferID = requirement.transferID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.downloadVerificationRecoveryTasks[transferID] = nil }
            await self.recoverDownloadVerification(
                requirement,
                coordinator: coordinator
            )
        }
        downloadVerificationRecoveryTasks[transferID] = task
    }

    func recoverDownloadVerification(
        _ requirement: DownloadVerificationRequirement,
        coordinator: DownloadCoordinator
    ) async {
        let persistedReference = DownloadVerificationReference(
            namespace: requirement.namespace,
            permittedBrowserHosts: requirement.permittedBrowserHosts
        )
        guard DownloadVerificationRequirement.sanitizedChallengeURL(requirement.url)
                == requirement.url,
              persistedReference.isValid,
              let installed = sourcesModel.installedRepositorySources.first(where: {
                  sourcesModel.runtimeNamespace(
                      repositoryID: $0.repositoryID,
                      sourceID: $0.sourceID
                  ) == requirement.namespace
              }),
              let challengedHost = requirement.url.host?.lowercased(),
              {
                  let currentHosts = Set(installed.allowedHTTPSHosts)
                  guard installed.isEnabled, installed.isRuntimeCompatible,
                        currentHosts == persistedReference.permittedBrowserHosts else { return false }
                  return HTTPSHostAccess.allows(
                      challengedHost,
                      declarations: currentHosts
                  )
              }()
        else {
            await coordinator.rejectVerificationRequirement(requirement.transferID)
            downloads = await coordinator.snapshots()
            return
        }
        let context = CloudflareChallengeContext.brokerObserved(
            url: requirement.url,
            namespace: requirement.namespace,
            permittedBrowserHosts: Set(installed.allowedHTTPSHosts)
        )
        let verificationPresenterForTesting = sourcesModel.cloudflareVerificationPresenterForTesting
        let mode: CloudflareRecoveryMode = isLibraryAutomationProcess || !isSceneActive
            ? .background
            : .foreground
        do {
            try await sourcesModel.cloudflareRecoveryCoordinator.recoverDownload(
                context: context,
                mode: mode,
                retry: {
                    try await coordinator.retryAfterVerification(requirement.transferID)
                },
                present: { [weak self] context in
                    if let verificationPresenterForTesting {
                        try await verificationPresenterForTesting(context)
                        return
                    }
                    guard let self else { throw CancellationError() }
                    try await self.sourcesModel.presentCloudflareVerification(for: context)
                },
                abandon: { [weak self] namespace in
                    self?.sourcesModel.abandonCloudflareVerification(namespace: namespace)
                }
            )
            downloads = await coordinator.snapshots()
        } catch is CancellationError {
            return
        } catch let error as CloudflareVerificationRequiredError {
            settingsSyncModel.automationVerificationInterruptionDescription = error.localizedDescription
            do {
                try await sourcesModel.persistCloudflareVerificationRequirement(error.context)
            } catch {
                settingsSyncModel.automationVerificationInterruptionDescription = CloudflareVerificationPersistenceError(
                    context: context,
                    reason: error.localizedDescription
                ).localizedDescription
            }
        } catch {
            guard !isLibraryAutomationProcess else { return }
            sourcesModel.show(error, title: "Couldn’t resume download")
        }
    }

    func downloadMoveTarget(
        for snapshot: DownloadSnapshot,
        offset: Int
    ) -> DownloadSnapshot? {
        guard [.queued, .paused, .failed].contains(snapshot.state) else { return nil }
        let orderedQueue = downloads.filter {
            [.downloading, .queued, .paused, .failed].contains($0.state)
        }
        guard
            let index = orderedQueue.firstIndex(where: { $0.id == snapshot.id }),
            orderedQueue.indices.contains(index + offset)
        else {
            return nil
        }
        return orderedQueue[index + offset]
    }

    func completedCBZExportFilename(for snapshot: DownloadSnapshot) -> String {
        let lastPathComponent = (snapshot.transfer.suggestedFilename as NSString).lastPathComponent
        let filename = lastPathComponent as NSString
        let proposedStem = filename.deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = proposedStem.isEmpty || proposedStem == "." || proposedStem == ".."
            ? "Manko Comic"
            : proposedStem
        let proposedExtension = filename.pathExtension.lowercased()
        let supportedExtensions: Set<String> = ["cbz", "zip"]
        let fileExtension = supportedExtensions.contains(proposedExtension) ? proposedExtension : "cbz"
        return "\(stem).\(fileExtension)"
    }

    func clearCompletedCBZExport() {
        isExportingCompletedCBZ = false
        if let url = completedCBZExport?.url {
            try? FileManager.default.removeItem(at: url)
        }
        completedCBZExport = nil
    }

    func isDownloadOperationPending(_ id: UUID) -> Bool {
        pendingDownloadIDs.contains(id) || preparingCBZExportID == id
    }

    func performDownloadAction(
        _ failureTitle: String,
        id: UUID,
        action: (DownloadCoordinator) async throws -> Void
    ) async {
        guard !isDownloadOperationPending(id) else { return }
        guard let downloadCoordinator else {
            feedback.alert = AppAlert(title: failureTitle, message: "Download services are still starting. Try again shortly.")
            return
        }
        pendingDownloadIDs.insert(id)
        defer { pendingDownloadIDs.remove(id) }
        do {
            try await action(downloadCoordinator)
            downloads = await downloadCoordinator.snapshots()
        } catch {
            sourcesModel.show(error, title: failureTitle)
        }
    }

    func encodedBackupSetup(selection: BackupRestoreSelection) throws -> Data {
        var payload = BackupSetupPayload()
        if selection.contains(.extensions) {
            payload.extensions = .init(repositories: sourcesModel.sourceRepositories,
                installed: sourcesModel.installedRepositorySources.filter { $0.entryType == .mankoExtension }.map { var item = $0; item.accessGrant = nil; return item },
                sources: sourcesModel.sources.filter { $0.kind == .mankoExtension })
        }
        if selection.contains(.servers) {
            let servers = sourcesModel.sources.filter { $0.kind != .mankoExtension && $0.kind != .local }
            let ids = Set(servers.map { $0.id.rawValue })
            payload.servers = .init(sources: servers, options: sourcesModel.sourceOptions.filter { ids.contains($0.key) }
                .mapValues { $0.filter { BackupSetupPayload.safeSourceOptions.contains($0.key) } })
        }
        func preferences(_ keys: Set<String>) throws -> [String: Data] {
            var values: [String: Data] = [:]
            for key in keys {
                if let value = defaults.object(forKey: key) { values[key] = try BackupSetupPayload.encodePreference(value) }
            }
            return values
        }
        if selection.contains(.readerPreferences) { payload.readerPreferences = try preferences(BackupSetupPayload.readerKeys) }
        if selection.contains(.settings) { payload.settings = try preferences(BackupSetupPayload.appKeys) }
        return try JSONEncoder().encode(payload.validated(selection: selection))
    }

    /// Build the complete candidate before mutating any local state.
    func prepareSetupImport(_ payload: BackupSetupPayload, selection: BackupRestoreSelection,
                            mode: BackupRestoreMode) throws -> PreparedSetupImport {
        let metadata = payload
        let payload = try payload.validated(selection: selection)
        var candidate = PreparedSetupImport(sources: sourcesModel.sources, options: sourcesModel.sourceOptions,
            credentials: sourcesModel.sourceCredentialAccounts, repositories: sourcesModel.sourceRepositories,
            installed: sourcesModel.installedRepositorySources)
        if mode == .merge {
            // Use source metadata for identity matching even if its setup section is unchecked.
            for incoming in metadata.servers?.sources ?? [] {
                guard let endpoint = BackupPrivacy.publicURL(incoming.baseURL) else { continue }
                if let existing = sourcesModel.sources.first(where: {
                    $0.kind == incoming.kind && Self.serverEndpoint($0.baseURL) == Self.serverEndpoint(endpoint)
                }) { candidate.sourceIDMapping[incoming.id.rawValue] = existing.id.rawValue }
            }
            for incoming in metadata.extensions?.installed ?? [] {
                if let existing = candidate.installed.first(where: { $0.id == incoming.id }) {
                    candidate.sourceIDMapping[incoming.descriptor.id.rawValue] = existing.descriptor.id.rawValue
                }
            }
        }
        func merge<T, Key: Hashable>(_ current: [T], _ incoming: [T], key: (T) -> Key) -> [T] {
            var ids = Set(current.map(key))
            return current + incoming.filter {
                if !ids.insert(key($0)).inserted { candidate.skippedConflicts += 1; return false }
                return true
            }
        }
        if let refs = payload.extensions {
            candidate.replacesExtensions = true
            candidate.repositories = mode == .merge ? merge(candidate.repositories, refs.repositories, key: \.id) : refs.repositories
            let existingIDs = Set(candidate.installed.map(\.id))
            let imported = refs.installed.map { source in
                var source = source; source.accessGrant = nil
                if source.entryType == .mankoExtension { source.isEnabled = false; source.descriptor.isEnabled = false }
                return source
            }
            candidate.installed = mode == .merge ? merge(candidate.installed, imported, key: \.id) : imported
            candidate.needsInstallation = imported.filter { mode == .replace || !existingIDs.contains($0.id) }.filter { $0.entryType == .mankoExtension }.count
            let refsSources = refs.sources.map { descriptor in
                var descriptor = descriptor
                if let mapped = candidate.sourceIDMapping[descriptor.id.rawValue] { descriptor.id = SourceID(rawValue: mapped) }
                if candidate.installed.contains(where: { $0.descriptor.id == descriptor.id && !$0.isEnabled }) { descriptor.isEnabled = false }
                return descriptor
            }
            if mode == .replace { candidate.sources.removeAll { $0.kind == .mankoExtension } }
            candidate.sources = merge(candidate.sources, refsSources, key: \.id)
        }
        if let servers = payload.servers {
            let current = candidate.sources.filter { $0.kind != .mankoExtension && $0.kind != .local }
            if mode == .replace {
                let ids = Set(current.map { $0.id.rawValue })
                candidate.sources.removeAll { ids.contains($0.id.rawValue) }
                candidate.options = candidate.options.filter { !ids.contains($0.key) }
            }
            for incoming in servers.sources {
                if mode == .merge, let existing = candidate.sources.first(where: { $0.kind == incoming.kind && Self.serverEndpoint($0.baseURL) == Self.serverEndpoint(incoming.baseURL) }) {
                    candidate.sourceIDMapping[incoming.id.rawValue] = existing.id.rawValue
                    candidate.skippedConflicts += 1
                    continue
                }
                // Reusing a stable ID for a different endpoint must never reuse its credential.
                if let existing = candidate.sources.first(where: { $0.id == incoming.id }) {
                    if mode == .merge {
                        guard existing.kind == incoming.kind, Self.serverEndpoint(existing.baseURL) == Self.serverEndpoint(incoming.baseURL) else {
                            throw CocoaError(.coderReadCorrupt)
                        }
                        candidate.skippedConflicts += 1; continue
                    }
                    throw CocoaError(.coderReadCorrupt)
                }
                candidate.sources.append(incoming)
                candidate.options[incoming.id.rawValue] = servers.options[incoming.id.rawValue] ?? [:]
            }
        }
        candidate.credentials = candidate.credentials.filter { id, _ in
            guard let old = sourcesModel.sources.first(where: { $0.id.rawValue == id }),
                  let new = candidate.sources.first(where: { $0.id.rawValue == id }) else { return false }
            return old.kind == new.kind && Self.serverEndpoint(old.baseURL) == Self.serverEndpoint(new.baseURL)
                && sourcesModel.sourceOptions[id]?["connectorExtensionID"] == candidate.options[id]?["connectorExtensionID"]
        }
        for (values, keys) in [(payload.readerPreferences, BackupSetupPayload.readerKeys), (payload.settings, BackupSetupPayload.appKeys)] {
            guard let values else { continue }
            for key in keys {
                if mode == .merge, defaults.object(forKey: key) != nil {
                    if values[key] != nil { candidate.skippedConflicts += 1 }
                    continue
                }
                candidate.preferenceKeys.insert(key)
                if let value = values[key] { candidate.preferences[key] = value }
            }
        }
        // Decode every value before repository persistence or database commit.
        for value in candidate.preferences.values { _ = try BackupSetupPayload.decodePreference(value) }
        return candidate
    }

    static func serverEndpoint(_ url: URL?) -> String? {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.string
    }

    func applySetupImport(_ candidate: PreparedSetupImport) async throws {
        let decoded = try candidate.preferences.mapValues { try BackupSetupPayload.decodePreference($0) }
        let previousWiFiOnly = settingsSyncModel.wifiOnlyDownloads
        let incomingWiFiOnly = candidate.preferenceKeys.contains("wifiOnlyDownloads")
            ? decoded["wifiOnlyDownloads"] as? Bool ?? true : previousWiFiOnly
        if incomingWiFiOnly != previousWiFiOnly { try await downloadCoordinator?.setWiFiOnly(incomingWiFiOnly) }
        do {
            if candidate.replacesExtensions {
                guard let repositoryStore else { throw CocoaError(.fileWriteUnknown) }
                try await repositoryStore.restoreReferences(repositories: candidate.repositories,
                    installedSources: candidate.installed, preservingExistingInstallations: true)
            }
        } catch {
            if incomingWiFiOnly != previousWiFiOnly { try await downloadCoordinator?.setWiFiOnly(previousWiFiOnly) }
            throw error
        }
        sourcesModel.sources = candidate.sources
        sourcesModel.sourceOptions = candidate.options
        sourcesModel.sourceCredentialAccounts = candidate.credentials
        if let repositoryStore {
            sourcesModel.sourceRepositories = await repositoryStore.repositories()
            sourcesModel.installedRepositorySources = await repositoryStore.installedSources()
        }
        for key in candidate.preferenceKeys {
            if let value = decoded[key] { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        settingsSyncModel.layoutMode = AppModel.LayoutMode(rawValue: defaults.string(forKey: "libraryLayout") ?? "grid") ?? .grid
        settingsSyncModel.librarySort = LibrarySort(rawValue: defaults.string(forKey: "librarySort") ?? "recentlyAdded") ?? .recentlyAdded
        settingsSyncModel.preferredAppearance = defaults.string(forKey: "preferredAppearance") ?? "system"
        settingsSyncModel.syncImportedFiles = defaults.bool(forKey: "syncImportedFiles")
        settingsSyncModel.wifiOnlyDownloads = defaults.object(forKey: "wifiOnlyDownloads") as? Bool ?? true
        settingsSyncModel.automationRules = defaults.data(forKey: "libraryAutomationRules")
            .flatMap { try? JSONDecoder().decode(LibraryAutomationRules.self, from: $0) } ?? .disabled
        LibraryAutomationHandoff.shared.updateRules(settingsSyncModel.automationRules)
        sourcesModel.sourceSearchExclusions = defaults.data(forKey: "sourceSearchExclusions")
            .flatMap { try? JSONDecoder().decode([String: [SourceSearchSelection]].self, from: $0) } ?? [:]
        sourcesModel.reconcileInstalledSourceIndex()
        sourcesModel.saveSources()
    }

    @concurrent
    static func removeManagedFiles(_ files: Set<URL>, beneath root: URL) async {
        let rootPath = root.standardizedFileURL.path + "/"
        for file in files {
            let standardizedFile = file.standardizedFileURL
            guard standardizedFile.path.hasPrefix(rootPath) else { continue }
            try? FileManager.default.removeItem(at: standardizedFile)
        }
    }

}

struct PreparedSetupImport: Sendable {
    var sources: [SourceDescriptor]
    var options: [String: [String: String]]
    var credentials: [String: String]
    var repositories: [RepositoryRecord]
    var installed: [InstalledRepositorySource]
    var preferences: [String: Data] = [:]
    var preferenceKeys: Set<String> = []
    var sourceIDMapping: [String: String] = [:]
    var replacesExtensions = false
    var skippedConflicts = 0
    var needsInstallation = 0
}
