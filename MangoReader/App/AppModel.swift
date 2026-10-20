import Foundation
import LocalAuthentication
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

@MainActor
@Observable
final class AppModel {
    let isPrivate: Bool
    @ObservationIgnored let serviceProvider: SharedAppServices
    let libraryModel: LibraryModel
    let sourcesModel: SourcesModel
    let searchModel: SearchModel
    let transfersModel: TransfersModel
    let trackingModel: TrackingModel
    let settingsSyncModel: SettingsSyncModel
    let feedback: AppFeedback
    let readerSetup: ReaderSetupCoordinator
    @ObservationIgnored var publicationImportTask: Task<Void, Never>?
    @ObservationIgnored let readerWrites = ReaderWriteQueue()
    @ObservationIgnored var readerRefreshWorkIDs: Set<WorkID> = []

    static let startupLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "manko",
        category: "Startup"
    )

    enum LayoutMode: String, CaseIterable {
        case grid
        case list
    }

    private(set) var bootstrapPhase: AppBootstrapPhase = .idle

    let defaults: UserDefaults

    let isLibraryAutomationProcess: Bool

    let deviceID: String

    @ObservationIgnored let cloudSaveQueue: CloudSaveQueue?

    var storagePaths: StoragePaths?

    var database: MangoReaderDatabase?

    var importer: LocalPublicationImporter?

    var localPublicationCoverService: LocalPublicationCoverService?

    var customCoverStore: CustomCoverStore?

    var backupService: BackupService?

    var downloadCoordinator: DownloadCoordinator?

    @ObservationIgnored var repositoryClient: SourceRepositoryClient?

    @ObservationIgnored var repositoryStore: SourceRepositoryStore?

    @ObservationIgnored var repositoryInstaller: RepositoryInstaller?

    @ObservationIgnored var extensionRuntimeRegistry: ExtensionRuntimeRegistry?

    @ObservationIgnored var cloudRecordStore: DatabaseCloudRecordStore?

    @ObservationIgnored var cloudSyncEngine: CloudSyncEngine?

    @ObservationIgnored var importedOriginalCloudOrchestrator: ImportedOriginalCloudOrchestrator?

    @ObservationIgnored var trackerQueue: TrackerUpdateQueue?

    @ObservationIgnored var downloadObservationTask: Task<Void, Never>?

    @ObservationIgnored var cloudStatusTask: Task<Void, Never>?

    @ObservationIgnored var cloudChangeTask: Task<Void, Never>?

    @ObservationIgnored var cloudBootstrapTask: Task<Void, Never>?
    @ObservationIgnored var cloudSynchronizationTask: Task<Void, Never>?
    @ObservationIgnored var cloudSynchronizationID: UUID?
    @ObservationIgnored var cloudSynchronizationSeedsRecords = false
    @ObservationIgnored var cloudSynchronizationAccountRevision = 0
    @ObservationIgnored var cloudAccountRevision = 0
    @ObservationIgnored var importedFileReconciliationTask: Task<Void, Never>?
    @ObservationIgnored var importedFileReconciliationPending = false
    @ObservationIgnored var importedFilePrefetchTask: Task<Void, Never>?
    var importedFileAvailability: [InstallmentID: ImportedFileAvailability] = [:]
    @ObservationIgnored var importedReadOperations: [InstallmentID: UUID] = [:]
    var cloudReadingRevision = 0
    var importedBookRecovery: ImportedBookRecovery?
    var recoveredImportedBook: PreparedReaderContent?

    @ObservationIgnored var didStartStartupMaintenance = false
    @ObservationIgnored var startupMaintenanceTask: Task<Void, Never>?
    @ObservationIgnored var foregroundMaintenanceTask: Task<Void, Never>?
    @ObservationIgnored var generatedCoversTask: Task<Void, Never>?
    @ObservationIgnored var startupMaintenanceHookForTesting: (@MainActor () async throws -> Void)?
    @ObservationIgnored var generatedCoversHookForTesting: (@MainActor () async throws -> Void)?
    @ObservationIgnored let libraryAutomationHandoff: LibraryAutomationHandoff

    private(set) var hasBootstrapped = false

    init(
        defaults: UserDefaults = .standard,
        isLibraryAutomationProcess: Bool = false,
        database: MangoReaderDatabase? = nil,
        downloadCoordinator: DownloadCoordinator? = nil,
        cloudSaveQueue: CloudSaveQueue? = nil,
        isPrivate: Bool = false,
        serviceProvider: SharedAppServices = .shared,
        libraryAutomationHandoff: LibraryAutomationHandoff = .shared
    ) {
        self.isPrivate = isPrivate
        self.serviceProvider = serviceProvider
        self.libraryAutomationHandoff = libraryAutomationHandoff
        self.defaults = defaults
        self.isLibraryAutomationProcess = isLibraryAutomationProcess
        self.database = database
        self.downloadCoordinator = downloadCoordinator
        self.cloudSaveQueue = cloudSaveQueue
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--mangoreader-ui-test-reset"),
           !AppFixtures.didResetPersistentStateForUITesting
        {
            AppFixtures.resetPersistentStateForUITesting(defaults: defaults)
            AppFixtures.didResetPersistentStateForUITesting = true
        }
        #endif
        var existingInstallation = database != nil || defaults.string(forKey: "deviceID") != nil ||
            ((try? StoragePaths.applicationSupport()).map { FileManager.default.fileExists(atPath: $0.databaseURL.path) } ?? false)
        var bypassReaderSetup = isLibraryAutomationProcess || MangoReaderTestEnvironment.isUnitTesting
        #if DEBUG
        bypassReaderSetup = bypassReaderSetup || ProcessInfo.processInfo.arguments.contains("--mangoreader-ui-test-reset")
        if MangoReaderDemoMode.isEnabled {
            existingInstallation = defaults.bool(forKey: ReaderSetupCoordinator.completedKey)
        }
        bypassReaderSetup = bypassReaderSetup || ServerLabFixture.isEnabled || ExtensionAuditFixture.isEnabled || MangoReaderScreenshotMode.isEnabled || AppFixtures.isVerifyingReaderOpening
        #endif
        readerSetup = ReaderSetupCoordinator.shared(
            defaults: (defaults as? ProtectedLibraryDefaults)?.readingDefaults ?? defaults, existingInstallation: existingInstallation,
            bypass: bypassReaderSetup
        )
        if let storedDeviceID = defaults.string(forKey: "deviceID") {
            deviceID = storedDeviceID
        } else {
            let generatedDeviceID = UUID().uuidString
            defaults.set(generatedDeviceID, forKey: "deviceID")
            deviceID = generatedDeviceID
        }
        feedback = AppFeedback()
        sourcesModel = SourcesModel(defaults: defaults, isLibraryAutomationProcess: isLibraryAutomationProcess, feedback: feedback, isPrivate: isPrivate)
        settingsSyncModel = SettingsSyncModel(cloudSaveQueue: cloudSaveQueue, database: database, defaults: defaults, deviceID: deviceID, sourcesModel: sourcesModel)
        libraryModel = LibraryModel(database: database, defaults: defaults, deviceID: deviceID, feedback: feedback, settingsSyncModel: settingsSyncModel, sourcesModel: sourcesModel)
        searchModel = SearchModel(database: database, sourcesModel: sourcesModel)
        transfersModel = TransfersModel(defaults: defaults, downloadCoordinator: downloadCoordinator, isLibraryAutomationProcess: isLibraryAutomationProcess, feedback: feedback, settingsSyncModel: settingsSyncModel, sourcesModel: sourcesModel)
        trackingModel = TrackingModel(database: database, feedback: feedback, settingsSyncModel: settingsSyncModel, sourcesModel: sourcesModel)

        if let storedTheme = defaults.string(forKey: "publicationTheme") {
            let canonicalTheme = (PublicationTheme(rawValue: storedTheme) ?? .system).rawValue
            if canonicalTheme != storedTheme {
                defaults.set(canonicalTheme, forKey: "publicationTheme")
            }
        }
        settingsSyncModel.layoutMode = defaults.string(forKey: "libraryLayout").flatMap(LayoutMode.init(rawValue:)) ?? .grid
        settingsSyncModel.librarySort = defaults.string(forKey: "librarySort").flatMap(LibrarySort.init(rawValue:)) ?? .recentlyAdded
        settingsSyncModel.incognitoMode = defaults.bool(forKey: "incognitoMode")
        defaults.removeObject(forKey: "explicitAgeConfirmed")
        defaults.removeObject(forKey: "explicitContentEnabled")
        settingsSyncModel.syncImportedFiles = defaults.bool(forKey: "syncImportedFiles")
        settingsSyncModel.preferredAppearance = defaults.string(forKey: "preferredAppearance") ?? "system"
        settingsSyncModel.wifiOnlyDownloads = defaults.object(forKey: "wifiOnlyDownloads") as? Bool ?? true
        sourcesModel.sources = SourcesModel.loadSources(from: defaults)
        #if DEBUG
        if AppFixtures.shouldSeedBrowseSourcesForUITesting {
            sourcesModel.sources = AppFixtures.browseSourcesForUITesting
        } else if AppFixtures.shouldSeedMetadataTagSearchForUITesting {
            sourcesModel.sources = [AppFixtures.metadataTagSearchSourceForUITesting]
        }
        #endif
        sourcesModel.sourceCredentialAccounts = SourcesModel.loadSourceCredentialAccounts(from: defaults)
        sourcesModel.sourceOptions = SourcesModel.loadSourceOptions(from: defaults)
        sourcesModel.sourceSearchExclusions = SourcesModel.loadSourceSearchExclusions(from: defaults)
        sourcesModel.pendingManualSourceCleanups = SourcesModel.loadPendingManualSourceCleanups(from: defaults)
        settingsSyncModel.automationRules = SettingsSyncModel.loadAutomationRules(from: defaults)
        settingsSyncModel.lastAutomationRun = SettingsSyncModel.loadLastAutomationRun(from: defaults)
        libraryModel.libraryUpdatesLastCheckedAt = defaults.object(
            forKey: "lastLibraryAutomationUpdateCheck"
        ) as? Date
        libraryModel.activeSavedFilterID = defaults.string(forKey: "activeSavedFilterID").flatMap(UUID.init(uuidString:))
        if let storedCategoryScope = defaults.string(forKey: "activeLibraryCategoryScope") {
            libraryModel.libraryCategoryScope = LibraryCategoryScope(storageValue: storedCategoryScope)
        } else {
            let migratedScope = LibraryCategoryScope(
                storageValue: defaults.string(forKey: "activeLibraryCategoryID")
            )
            libraryModel.libraryCategoryScope = migratedScope
            if let storageValue = migratedScope.storageValue {
                defaults.set(storageValue, forKey: "activeLibraryCategoryScope")
            }
            defaults.removeObject(forKey: "activeLibraryCategoryID")
        }
#if DEBUG
        if AppFixtures.shouldSeedSearchCloudflareSummaryForUITesting {
            sourcesModel.sources = AppFixtures.searchCloudflareSourcesForUITesting
            searchModel.searchSourcePageLoaderForTesting = { descriptor, _ in
                throw MangoReaderExtensionRuntimeError.cloudflareHandoff(
                    CloudflareChallengeContext(
                        url: descriptor.baseURL,
                        namespace: "ui-test-\(descriptor.id.rawValue)",
                        permittedBrowserHosts: Set(
                            descriptor.baseURL?.host.map { [$0] } ?? []
                        )
                    )
                )
            }
        }
#endif
    }

    var isReadyForInteraction: Bool {
        bootstrapPhase.isReadyForInteraction
    }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        bootstrapPhase = .loading
        let startupStarted = ContinuousClock.now

#if DEBUG
        if ExtensionAuditFixture.isEnabled {
            do {
                try await ExtensionAuditFixture.bootstrap(model: self)
                bootstrapPhase = .ready
            } catch {
                feedback.alert = AppAlert(title: "Extension audit fixture failed", message: error.localizedDescription)
                bootstrapPhase = .failed
                hasBootstrapped = false
            }
            return
        }
        if MangoReaderScreenshotMode.isEnabled {
            do {
                try await MangoReaderScreenshotMode.bootstrap(model: self)
                bootstrapPhase = .ready
            } catch {
                MangoReaderScreenshotMode.report(error: error)
                hasBootstrapped = false
                bootstrapPhase = .failed
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--mangoreader-ui-test-startup-delay") {
            try? await Task.sleep(for: .seconds(8))
        }
#endif

        do {
            let services = try await serviceProvider.load(
                wifiOnlyDownloads: settingsSyncModel.wifiOnlyDownloads,
                deviceID: deviceID
            )
            storagePaths = services.storagePaths
            database = services.database
            #if DEBUG
            if AppFixtures.shouldSeedLibraryLayoutForUITesting {
                try await AppFixtures.seedLibraryLayoutForUITesting(in: services.database)
            } else if AppFixtures.shouldSeedLibraryForUITesting {
                try await AppFixtures.seedLibraryForUITesting(in: services.database)
            }
            if AppFixtures.shouldSeedSearchAndHistoryForUITesting {
                try await AppFixtures.seedSearchAndHistoryForUITesting(in: services.database)
                sourcesModel.sources = [AppFixtures.searchSourceForUITesting]
                sourcesModel.saveSources()
            }
            if AppFixtures.shouldSeedReadingContentForUITesting {
                try await AppFixtures.seedReadingContentForUITesting(in: services.database)
            }
            #endif
            importer = services.importer
            localPublicationCoverService = services.localPublicationCoverService
            customCoverStore = services.customCoverStore
            backupService = services.backupService
            downloadCoordinator = services.downloadCoordinator
            cloudRecordStore = isPrivate ? nil : services.cloudRecordStore
            cloudSyncEngine = services.cloudSyncEngine
            importedOriginalCloudOrchestrator = isPrivate ? nil : services.importedOriginalCloudOrchestrator
            trackerQueue = isPrivate ? nil : services.trackerQueue
            repositoryClient = services.repositoryClient
            repositoryStore = services.repositoryStore
            repositoryInstaller = services.repositoryInstaller
            extensionRuntimeRegistry = services.extensionRuntimeRegistry
            libraryModel.cloudSyncEngine = services.cloudSyncEngine
            libraryModel.customCoverStore = services.customCoverStore
            libraryModel.database = services.database
            libraryModel.localPublicationCoverService = services.localPublicationCoverService
            sourcesModel.extensionRuntimeRegistry = services.extensionRuntimeRegistry
            sourcesModel.repositoryClient = services.repositoryClient
            sourcesModel.repositoryInstaller = services.repositoryInstaller
            sourcesModel.repositoryStore = services.repositoryStore
            searchModel.database = services.database
            transfersModel.backupService = services.backupService
            sourcesModel.downloadCoordinator = services.downloadCoordinator
            transfersModel.downloadCoordinator = services.downloadCoordinator
            transfersModel.repositoryStore = services.repositoryStore
            transfersModel.storagePaths = services.storagePaths
            trackingModel.database = services.database
            trackingModel.extensionRuntimeRegistry = services.extensionRuntimeRegistry
            trackingModel.trackerQueue = isPrivate ? nil : services.trackerQueue
            settingsSyncModel.cloudSyncEngine = services.cloudSyncEngine
            settingsSyncModel.database = services.database
#if DEBUG
            if AppFixtures.shouldSeedTrackerExtensionForUITesting {
                try await AppFixtures.seedTrackerExtensionForUITesting(in: services.repositoryStore)
            }
            if AppFixtures.shouldSeedBrowseSourcesForUITesting {
                try await AppFixtures.seedBrowseRepositoryForUITesting(in: services.repositoryStore)
            }
            if ServerLabFixture.isEnabled {
                try await ServerLabFixture.prepare(services: services)
            }
            if MangoReaderDemoMode.isEnabled {
                try await MangoReaderDemoMode.prepare(services: services, defaults: defaults)
            }
            if ProcessInfo.processInfo.arguments.contains("--mangoreader-ui-test-reset"),
               ProcessInfo.processInfo.arguments.contains("--mangoreader-wasm-migration-verification") {
                try await AppFixtures.seedWasmMigrationForVerification(in: services.repositoryStore)
            }
#endif
            sourcesModel.repositoryIconDiskCache = ContentCache(
                directory: services.storagePaths.cachesDirectory.appendingPathComponent("RepositoryIcons"),
                byteLimit: 16 * 1_024 * 1_024, memoryOnly: isPrivate
            )
            sourcesModel.sourceRepositories = await services.repositoryStore.repositories()
            sourcesModel.installedRepositorySources = await services.repositoryStore.installedSources()
            await sourcesModel.resumePendingManualSourceCleanups()
            await resumePendingRepositoryCleanups()
            sourcesModel.reconcileInstalledSourceIndex(announcesRecovery: true)
            await settingsSyncModel.bootstrapSyncedAppSettings()
            let repairedWorks = try await services.database.repairExtensionChapters(
                sourceIDs: Set(sourcesModel.sources.filter { $0.kind == .mangoReaderExtension }.map(\.id))
                    .union(sourcesModel.installedRepositorySources.filter { $0.descriptor.kind == .mangoReaderExtension }.map { $0.descriptor.id }))
            if !repairedWorks.isEmpty {
                await sourcesModel.contentCache.clear()
                for source in sourcesModel.sources where source.kind == .mangoReaderExtension {
                    sourcesModel.invalidateSourceContent(source.id)
                }
                for source in sourcesModel.installedRepositorySources where source.descriptor.kind == .mangoReaderExtension {
                    await services.extensionRuntimeRegistry.invalidate(installedSourceID: source.id)
                }
            }
            let repairQueue = try await services.database.chapterRepairQueue()
            if let engine = services.cloudSyncEngine, !repairQueue.isEmpty {
                // The same durable queue survives a failed bootstrap/CloudKit save.
                let names = try await cloudRecordStore?.recordNames() ?? []
                await engine.queueSaves(recordNames: names)
                try await services.database.acknowledgeChapterRepairs()
            }


            if !isPrivate { BackgroundDownloadHandoff.shared.register(services.downloadCoordinator) }
            let events = await services.downloadCoordinator.progress()
            downloadObservationTask = Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    await self.receiveDownload(event, from: services.downloadCoordinator)
                }
            }
            transfersModel.downloads = await services.downloadCoordinator.snapshots()
            transfersModel.resumePendingDownloadVerificationRequirements()

            if !isLibraryAutomationProcess, let cloudSyncEngine = services.cloudSyncEngine {
                let statusUpdates = await cloudSyncEngine.statusUpdates()
                cloudStatusTask = Task { [weak self] in
                    var previousStatus: CloudSyncAvailability?
                    for await status in statusUpdates {
                        guard let self else { return }
                        defer { previousStatus = status }
                        settingsSyncModel.cloudSyncAvailability = status
                        let accountAvailability: Bool?
                        switch status {
                        case .available:
                            accountAvailability = true
                        case .switchedAccount:
                            accountAvailability = nil
                            cloudAccountRevision &+= 1
                            importedFileReconciliationTask?.cancel()
                            importedFilePrefetchTask?.cancel()
                            importedFileAvailability.removeAll()
                            let cleanup = await services.importedOriginalCloudOrchestrator
                                .cloudAccountDidSwitch()
                            guard cleanup.failures.isEmpty else {
                                settingsSyncModel.cloudSyncAvailability = .failed(
                                    cleanup.failures.first?.message
                                        ?? "Couldn’t finish the iCloud account change."
                                )
                                continue
                            }
                            do {
                                // The singleton's conflict metadata belongs to
                                // the former database. Keep the live
                                // UserDefaults values, but remove that durable
                                // winner without queuing a CloudKit deletion so
                                // the new account is fetched in isolation.
                                try await services.database.deleteSyncedAppSettings()
                                settingsSyncModel.lastAppliedSyncedSettings = nil
                                defaults.removeObject(
                                    forKey: SettingsSyncModel.syncedSettingsModifiedAtKey
                                )
                            } catch {
                                settingsSyncModel.cloudSyncAvailability = .failed(
                                    "Couldn’t reset synchronized settings after the iCloud account change."
                                )
                                continue
                            }
                            guard await cloudSyncEngine.resumeAfterAccountChange() else {
                                settingsSyncModel.cloudSyncAvailability = await cloudSyncEngine.status()
                                continue
                            }
                            let report = await services.importedOriginalCloudOrchestrator
                                .setCloudAccountAvailable(
                                    true,
                                    globalImportedFileSyncEnabled: settingsSyncModel.syncImportedFiles,
                                    reconcile: false
                                )
                            if report.changedLocalInstallmentPath {
                                await refreshAfterRemoteSync()
                            }
                            await synchronizeCloud(seedAllRecords: true)
                            scheduleImportedFileReconciliation()
                        case .stopped, .signedOut, .unavailable:
                            accountAvailability = false
                        case .failed:
                            // A transient CloudKit request failure does not prove
                            // that the iCloud Drive account or container changed.
                            accountAvailability = nil
                        }
                        if let accountAvailability {
                            let report = await services.importedOriginalCloudOrchestrator
                                .setCloudAccountAvailable(
                                    accountAvailability,
                                    globalImportedFileSyncEnabled: settingsSyncModel.syncImportedFiles,
                                    reconcile: false
                                )
                            if report.changedLocalInstallmentPath {
                                await refreshAfterRemoteSync()
                            }
                        }
                        if case .available = status,
                           previousStatus != .switchedAccount
                        {
                            // Initial bootstrap is already in flight and the
                            // reentrancy guard makes this a no-op there. A later
                            // sign-in or recovered account transition reseeds
                            // every current record into the newly reset zone.
                            await synchronizeCloud(seedAllRecords: true)
                            scheduleImportedFileReconciliation()
                        }
                    }
                }
                let remoteChanges = await cloudSyncEngine.remoteChangeUpdates()
                cloudChangeTask = Task { [weak self] in
                    for await _ in remoteChanges {
                        guard let self else { return }
                        await self.refreshAfterRemoteSync()
                        self.scheduleImportedFileReconciliation()
                    }
                }
                cloudBootstrapTask = Task { [weak self] in
                    await self?.synchronizeCloud(seedAllRecords: true)
                }
            } else {
                settingsSyncModel.cloudSyncAvailability = .unavailable("iCloud sync is unavailable in this build.")
                _ = await services.importedOriginalCloudOrchestrator.setCloudAccountAvailable(
                    false, globalImportedFileSyncEnabled: settingsSyncModel.syncImportedFiles, reconcile: false
                )
            }

        } catch {
            Self.startupLogger.error("Bootstrap failed: \(error.localizedDescription, privacy: .public)")
            #if DEBUG
            let missingTable = ["importedOriginalReferences", "syncedAppSettings"].first {
                error.localizedDescription.contains("no such table: \($0)")
            }
            print("Mango Reader startup diagnostic: \(String(reflecting: type(of: error))); code=\((error as NSError).code); missingTable=\(missingTable ?? "none")")
            #endif
            hasBootstrapped = false
            bootstrapPhase = .failed
            return
        }

        if !isPrivate && !isLibraryAutomationProcess {
            libraryAutomationHandoff.registerForegroundOperation({ [weak self] trigger in
                guard let self, self.isReadyForInteraction else { return false }
                return await self.runLibraryAutomation(trigger: trigger)
            }, error: { [weak self] in self?.settingsSyncModel.automationLastError },
               report: { [weak self] in self?.settingsSyncModel.lastAutomationRun })
        }
        settingsSyncModel.configureLibraryAutomation()
        await sourcesModel.loadCacheVisits()
        await sourcesModel.contentCache.setLimit(defaults.object(forKey: "contentCacheLimit") as? Int ?? ContentCache.defaultLimit)
        guard !isLibraryAutomationProcess else {
            bootstrapPhase = .ready
            return
        }

#if DEBUG
        startCloudflareUITestFixtureIfNeeded()
        if ProcessInfo.processInfo.arguments.contains("--mangoreader-reader-chapter-samples") {
            do { try await AppFixtures.seedReaderChapterSamples(model: self) }
            catch { sourcesModel.show(error, title: "Couldn’t prepare reader samples") }
        }
        if AppFixtures.shouldSeedCloudBooks, let database, let storagePaths {
            do { importedOriginalCloudOrchestrator = try await AppFixtures.seedCloudBooks(database: database, paths: storagePaths) }
            catch { sourcesModel.show(error, title: "Couldn’t prepare local-book fixtures") }
        }
#endif

        await libraryModel.refreshSavedFilters()
        await libraryModel.refreshCategories()
        async let libraryLoad: Void = libraryModel.refreshLibrary()
        async let historyLoad: Void = libraryModel.refreshHistory()
        _ = await (libraryLoad, historyLoad)
        sourcesModel.contentCacheConfigurationLoaded = true
#if DEBUG && targetEnvironment(simulator)
        // Opt-in live audit: invalidate only the named locally installed source.
        // Credentials are deliberately retained. Drop the runtime afterwards so
        // the selection-to-cover measurement includes its cold initialization.
        if let auditedID = ProcessInfo.processInfo.environment["MANGOREADER_SOURCE_AUDIT_COLD"],
           let installed = sourcesModel.installedRepositorySources.first(where: {
               $0.repositoryID == "local-source-audit" && $0.sourceID == auditedID
           }) {
            do {
                try await sourcesModel.invalidateContentCache(for: installed.descriptor)
                sourcesModel.invalidateSourceContent(installed.descriptor.id)
                await extensionRuntimeRegistry?.invalidate(installedSourceID: installed.id)
            } catch {
                sourcesModel.show(error, title: "Couldn’t clear audit source cache")
            }
        }
#endif
        guard !Task.isCancelled, !sourcesModel.isSessionLocked else { return }
        bootstrapPhase = .ready
        Self.startupLogger.notice("Ready for interaction after \(String(describing: startupStarted.duration(to: .now)), privacy: .public)")
        startPostStartupMaintenance()
    }

    var isReadyForProcessLibraryAutomation: Bool {
        isLibraryAutomationProcess && database != nil
    }

    func updateSceneIsActive(_ isActive: Bool) {
        #if DEBUG
        if MangoReaderScreenshotMode.isEnabled || ExtensionAuditFixture.isEnabled {
            transfersModel.isSceneActive = isActive
            return
        }
        #endif
        if !isPrivate { SourceCacheRefresh.shared.update(model: self, active: isActive) }
        if isActive, sourcesModel.lastCacheActivation.map({ Date.now.timeIntervalSince($0) >= ContentCache.freshness }) ?? true {
            sourcesModel.lastCacheActivation = .now
            sourcesModel.contentCacheActivationRevision &+= 1
        }
        transfersModel.isSceneActive = isActive
        guard isActive else { return }
        transfersModel.resumePendingDownloadVerificationRequirements()
    }

    enum RepositoryLinkReviewError: Error, Equatable, LocalizedError {
        case repositoryBlocked
        case repositoryIdentityCollision(name: String, existingHost: String, incomingHost: String)
        case sourceMissing(String)
        case sourceNotInstallable(String)
        case sourceUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .repositoryBlocked:
                "This repository is blocked and can’t be used."
            case let .repositoryIdentityCollision(name, existingHost, incomingHost):
                "“\(name)” is already saved from \(existingHost). A link from \(incomingHost) can’t replace that repository identity."
            case let .sourceMissing(sourceID):
                "The selected extension “\(sourceID)” no longer exists in this repository."
            case let .sourceNotInstallable(sourceID):
                "The selected extension “\(sourceID)” is not a compatible installable extension."
            case let .sourceUnavailable(sourceID):
                "The selected extension “\(sourceID)” is not currently available to install."
            }
        }
    }

    #if DEBUG
    func startCloudflareUITestFixtureIfNeeded() {
        guard CloudflareUITestFixture.isEnabled else { return }
        let operation = CloudflareUITestRecoveryOperation.shared
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                await operation.reset()
                let message = try await self.sourcesModel.performSourceOperation {
                    try await operation.perform()
                }
                self.feedback.showStatus(message, systemImage: "checkmark.shield.fill")
            } catch is CancellationError {
                return
            } catch {
                self.sourcesModel.show(error, title: "Cloudflare fixture failed")
            }
        }
    }
#endif
}

/// UserDefaults-compatible facade for AppStorage. Private preferences never enter
/// a Foundation persistent domain; only the protected plist is durable.
nonisolated final class ProtectedLibraryDefaults: UserDefaults {
    static let readingKeys: Set<String> = [
        "readerAdditionalPreferences", "readerDirection", "epubScroll", "publisherStyles",
        "verticalWriting", "publicationTheme", "readerFontPreset", "readerFontScale",
        "readerFontWeight", "readerLineHeight", "readerParagraphSpacing", "readerParagraphIndent",
        "readerPageMargins", "readerWordSpacing", "readerLetterSpacing", "readerHyphenation",
        "readerTextNormalization", "readerTextAlignment", "readerColumnCount", "pdfDoublePage",
        "pdfContinuous", "reduceReaderTransitions", "imageReaderPageSpread", "imageReaderWidePageBehavior",
        "imageReaderCropMargins", "imageReaderLiveText", "imageReaderTransition", "imageReaderTapLeadingAction",
        "imageReaderTapCenterAction", "imageReaderTapTrailingAction", "readerShowCoverWhenFolded",
        "readerPauseReadAloudWhenFolded", "readerSetupDraft.v1", "readerSetupCompleted.v1",
    ]
    let readingDefaults: UserDefaults
    private let fileURL: URL
    private let mutex = NSRecursiveLock()
    private var values: [String: Any]
    private var registered: [String: Any] = [:]
    private var locked = false
    private(set) var persistenceError: Error?

    init(fileURL: URL, readingDefaults: UserDefaults) throws {
        self.fileURL = fileURL
        self.readingDefaults = readingDefaults
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let decoded = try PropertyListSerialization.propertyList(from: Data(contentsOf: fileURL), format: nil)
            guard let dictionary = decoded as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            values = dictionary.filter { !Self.readingKeys.contains($0.key) }
        } else { values = [:] }
        super.init(suiteName: "com.k800k.manko.private-memory")!
        NotificationCenter.default.addObserver(self, selector: #selector(readingDefaultsChanged), name: UserDefaults.didChangeNotification, object: readingDefaults)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func readingDefaultsChanged() {
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }

    override func object(forKey key: String) -> Any? {
        if Self.readingKeys.contains(key) { return readingDefaults.object(forKey: key) }
        return mutex.withLock { locked ? nil : values[key] ?? registered[key] }
    }

    override func set(_ value: Any?, forKey key: String) {
        if Self.readingKeys.contains(key) {
            guard mutex.withLock({ !locked }) else { return }
            readingDefaults.set(value, forKey: key)
            return
        }
        willChangeValue(forKey: key)
        mutex.withLock {
            guard !locked else { return }
            var next = values
            next[key] = value
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: next, format: .binary, options: 0)
                try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
                values = next
                persistenceError = nil
            } catch { persistenceError = error }
        }
        didChangeValue(forKey: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }

    override func removeObject(forKey key: String) { set(nil as Any?, forKey: key) }
    override func set(_ value: Bool, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    override func set(_ value: Int, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    override func set(_ value: Double, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    override func set(_ value: Float, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    override func set(_ url: URL?, forKey key: String) { set(url?.absoluteString as Any?, forKey: key) }
    override func bool(forKey key: String) -> Bool { (object(forKey: key) as? NSNumber)?.boolValue ?? false }
    override func integer(forKey key: String) -> Int { (object(forKey: key) as? NSNumber)?.intValue ?? 0 }
    override func double(forKey key: String) -> Double { (object(forKey: key) as? NSNumber)?.doubleValue ?? 0 }
    override func float(forKey key: String) -> Float { (object(forKey: key) as? NSNumber)?.floatValue ?? 0 }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    override func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    override func url(forKey key: String) -> URL? { string(forKey: key).flatMap(URL.init(string:)) }
    override func register(defaults: [String: Any]) { mutex.withLock { registered.merge(defaults) { _, new in new } } }
    override func dictionaryRepresentation() -> [String: Any] {
        var result = mutex.withLock { locked ? [:] : registered.merging(values) { _, new in new } }
        for key in Self.readingKeys { result[key] = readingDefaults.object(forKey: key) }
        return result
    }
    override func synchronize() -> Bool { mutex.withLock { persistenceError == nil } }

    func lock() { mutex.withLock { locked = true; values.removeAll(); registered.removeAll() } }
}

@MainActor
protocol LibraryAuthenticating {
    func authenticate() async throws -> Bool
    func cancel()
}

@MainActor
final class DeviceLibraryAuthentication: LibraryAuthenticating {
    private var context: LAContext?
    func authenticate() async throws -> Bool {
        let context = LAContext()
        self.context = context
        defer { self.context = nil }
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            if let error { throw error }
            throw LAError(.passcodeNotSet)
        }
        return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Authenticate to open your library.")
    }
    func cancel() { context?.invalidate() }
}

/// One private session for the process; switching or locking invalidates every window.
@MainActor @Observable
final class PrivateLibraryCoordinator {
    static let shared = PrivateLibraryCoordinator()
    private(set) var model: AppModel?
    private(set) var isOpening = false
    private(set) var revision = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let authentication: any LibraryAuthenticating
    @ObservationIgnored private let suppliedStoragePaths: StoragePaths?
    @ObservationIgnored private var cleanup: Task<Void, Never>?
    @ObservationIgnored private var openingModel: AppModel?

    init(authentication: any LibraryAuthenticating = DeviceLibraryAuthentication(), storagePaths: StoragePaths? = nil) {
        self.authentication = authentication
        suppliedStoragePaths = storagePaths
    }

    func toggle(readingDefaults: UserDefaults, feedback: AppFeedback) async {
        if model != nil { lock(); return }
        guard !isOpening else { return }
        isOpening = true
        generation += 1
        let attempt = generation
        defer { isOpening = false }
        await cleanup?.value
        guard attempt == generation else { return }
        do {
            guard try await authentication.authenticate(), attempt == generation else { return }
            try Task.checkCancellation()
            let base = try suppliedStoragePaths ?? StoragePaths.applicationSupport(bundleIdentifier: "com.k800k.manko.private")
            let paths = StoragePaths(applicationSupportDirectory: base.applicationSupportDirectory,
                cachesDirectory: base.cachesDirectory, isPrivate: true)
            try paths.prepare()
            let defaults = try ProtectedLibraryDefaults(fileURL: paths.applicationSupportDirectory.appending(path: "Preferences.plist"), readingDefaults: readingDefaults)
            let privateModel = AppModel(defaults: defaults, isPrivate: true,
                serviceProvider: SharedAppServices(storagePaths: paths, isPrivate: true))
            openingModel = privateModel
            await privateModel.bootstrap()
            guard attempt == generation, !Task.isCancelled else {
                await privateModel.closePrivateSession()
                return
            }
            openingModel = nil
            guard privateModel.isReadyForInteraction else {
                await privateModel.closePrivateSession()
                throw CocoaError(.fileReadUnknown)
            }
            model = privateModel
            revision += 1
        } catch {
            guard attempt == generation else { return }
            openingModel = nil
            if let error = error as? LAError, [.userCancel, .systemCancel, .appCancel].contains(error.code) { return }
            if error is CancellationError { return }
            feedback.alert = AppAlert(title: "Library unavailable", message: error.localizedDescription)
        }
    }

    func waitForLock() async { await cleanup?.value }

    func lock() {
        generation += 1
        authentication.cancel()
        // Keep an unfinished opening attempt exclusive until its bootstrap and cleanup finish.
        let wasPresented = model != nil
        let previous = model ?? openingModel
        model = nil
        openingModel = nil
        // Backgrounding the normal library must not look like a library switch
        // to reader presentation. Pending authentication is still cancelled.
        if wasPresented { revision += 1 }
        guard let previous else { return }
        previous.cancelPrivateWork()
        let priorCleanup = cleanup
        cleanup = Task {
            await priorCleanup?.value
            await previous.closePrivateSession()
        }
    }
}

extension AppModel {
    func cancelPrivateWork() {
        guard isPrivate else { return }
        searchModel.discardPendingSearch()
        publicationImportTask?.cancel()
        startupMaintenanceTask?.cancel()
        foregroundMaintenanceTask?.cancel()
        generatedCoversTask?.cancel()
        downloadObservationTask?.cancel()
        cloudStatusTask?.cancel()
        cloudChangeTask?.cancel()
        cloudBootstrapTask?.cancel()
        cloudSynchronizationTask?.cancel()
        importedFileReconciliationTask?.cancel()
        importedFilePrefetchTask?.cancel()
        settingsSyncModel.syncedSettingsSaveTask?.cancel()
        for task in transfersModel.downloadVerificationRecoveryTasks.values { task.cancel() }
        sourcesModel.isSessionLocked = true
        sourcesModel.clearVerificationRequests(for: sourcesModel.installedRepositorySources)
        sourcesModel.pendingCloudflareHandoff = nil
        sourcesModel.pendingRepositoryLink = nil
        sourcesModel.clearSourceSuggestionMemory()
        sourcesModel.coverImageCache.clear()
        PublicationImageCache.clearMemory()
        ExtensionVerifiedBrowserSessionPool.discardPrivateSessions()
        (defaults as? ProtectedLibraryDefaults)?.lock()
    }

    func closePrivateSession() async {
        guard isPrivate else { return }
        cancelPrivateWork()
        await startupMaintenanceTask?.value
        await foregroundMaintenanceTask?.value
        await generatedCoversTask?.value
        do { try await downloadCoordinator?.lock() }
        catch { Self.startupLogger.error("Could not pause private downloads: \(error.localizedDescription, privacy: .private)") }
        await extensionRuntimeRegistry?.lock()
        await sourcesModel.contentCache.clear()
        try? await database?.close()
    }
}
