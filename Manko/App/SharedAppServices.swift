import Foundation
import MankoData
import MankoExtensions
import MankoReaders
import MankoSources
import MankoSync

struct AppServiceBundle: Sendable {
    let storagePaths: StoragePaths
    let database: MankoDatabase
    let importer: LocalPublicationImporter
    let localPublicationCoverService: LocalPublicationCoverService
    let customCoverStore: CustomCoverStore
    let backupService: BackupService
    let downloadCoordinator: DownloadCoordinator
    let cloudRecordStore: DatabaseCloudRecordStore
    let cloudSyncEngine: CloudSyncEngine?
    let importedOriginalCloudOrchestrator: ImportedOriginalCloudOrchestrator
    let trackerQueue: TrackerUpdateQueue
    let repositoryClient: SourceRepositoryClient
    let repositoryStore: SourceRepositoryStore
    let repositoryInstaller: RepositoryInstaller
    let extensionRuntimeRegistry: ExtensionRuntimeRegistry
}

/// Owns process-wide actors while every WindowGroup scene retains its own
/// navigation and presentation model.
@MainActor
final class SharedAppServices {
    static let shared = SharedAppServices()

    private var loadingTask: Task<AppServiceBundle, Error>?
    private let isPrivate: Bool
    private let suppliedStoragePaths: StoragePaths?

    init(storagePaths: StoragePaths? = nil, isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        suppliedStoragePaths = storagePaths
    }

    func load(wifiOnlyDownloads: Bool, deviceID: String, demoMode: Bool? = nil) async throws -> AppServiceBundle {
        if let loadingTask {
            return try await loadingTask.value
        }

        let isPrivate = self.isPrivate
        let task = Task<AppServiceBundle, Error> {
            #if DEBUG
            let isDemo = demoMode ?? MankoDemoMode.isEnabled
            #else
            let isDemo = false
            #endif
            if !isDemo && !isPrivate { LegacyPurchaseStateCleanup.removeFromDefaultLocation() }
            let paths = try suppliedStoragePaths ?? StoragePaths.applicationSupport(
                bundleIdentifier: isDemo ? "com.k800k.manko.demo-video" : "com.k800k.manko"
            )
            let database = try await MankoDatabase.open(storagePaths: paths)
            try await database.reconcileManagedImportedFileURLs(libraryFilesDirectory: paths.libraryFilesDirectory)
            let importer = LocalPublicationImporter(storagePaths: paths)
            let localPublicationCoverService = LocalPublicationCoverService()
            let customCoverStore = CustomCoverStore(storagePaths: paths)
            let backupService = try BackupService(database: database, storagePaths: paths)
            let repositoryClient = SourceRepositoryClient()
            let repositoryStore = try SourceRepositoryStore(directory: paths.sourceRepositoriesDirectory, isPrivate: isPrivate)
            let extensionPackageStore = try ExtensionPackageStore(rootDirectory: paths.sourceExtensionsDirectory, isPrivate: isPrivate)
            let extensionStateStore = try ExtensionStateStore(rootDirectory: paths.sourceExtensionStateDirectory, isPrivate: isPrivate)
            let extensionSecureStateStore = ExtensionSecureStateStore(
                service: isPrivate ? "com.k800k.manko.private.extensions" : (isDemo ? "com.k800k.manko.demo-video.extensions" : "com.k800k.manko.extensions"),
                isPrivate: isPrivate
            )
            let extensionRuntimeRegistry = ExtensionRuntimeRegistry(
                packageStore: extensionPackageStore,
                stateStore: extensionStateStore,
                secureStateStore: extensionSecureStateStore,
                isPrivate: isPrivate
            )
            let repositoryInstaller = RepositoryInstaller(
                client: repositoryClient,
                store: repositoryStore,
                packageStore: extensionPackageStore,
                runtimeRegistry: extensionRuntimeRegistry
            )
            let downloadStore = FileDownloadStateStore(
                directory: paths.applicationSupportDirectory.appendingPathComponent("DownloadQueue", isDirectory: true),
                isPrivate: isPrivate
            )
            let downloadCoordinator = DownloadCoordinator(
                configuration: DownloadCoordinator.Configuration(
                    maximumConcurrentDownloads: 3,
                    wifiOnly: wifiOnlyDownloads,
                    offlineDownloadsDirectory: paths.offlineDownloadsDirectory,
                    isPrivate: isPrivate
                ),
                stateStore: downloadStore,
                credentialLoader: KeychainCredentialStore(
                    service: isPrivate ? "com.k800k.manko.private.sources" : (isDemo ? "com.k800k.manko.demo-video.sources" : "com.k800k.manko.sources"),
                    isPrivate: isPrivate
                ),
                redirectIdentityLoader: { reference, requestURL in
                    guard reference.isValid,
                          requestURL.host != nil,
                          let installed = await repositoryStore.installedSources().first(where: {
                              ExtensionRuntimeNamespace.primary(
                                  repositoryID: isPrivate ? "private-" + $0.repositoryID : $0.repositoryID,
                                  sourceID: $0.sourceID
                              ) == reference.namespace
                          }),
                          installed.isEnabled, installed.isRuntimeCompatible,
                          installed.accessGrant?.generation == reference.accessGeneration,
                          Set(installed.allowedHTTPSHosts) == reference.permittedBrowserHosts,
                          ExtensionNetworkPolicy(hosts: reference.permittedBrowserHosts, serverOrigin: reference.serverOrigin).allows(requestURL)
                    else { throw ExtensionSecurityError.approvalRequired }
                    if installed.connectorKind != nil { return nil }
                    guard let identity = try await extensionRuntimeRegistry.downloadRedirectIdentity(
                        namespace: reference.namespace,
                        requestURL: requestURL
                    ), let identityHost = identity.origin.host?.lowercased(), {
                        let currentHosts = Set(installed.allowedHTTPSHosts)
                        return currentHosts.isEmpty
                            ? reference.permittedBrowserHosts.isEmpty
                            : HTTPSHostAccess.allows(
                                identityHost,
                                declarations: currentHosts
                            )
                    }()
                    else { return nil }
                    return identity
                }
            )
            let installed = await repositoryStore.installedSources()
            let repairedWorks = try await database.repairExtensionChapters(sourceIDs:
                Set(installed.filter { $0.descriptor.kind == .mankoExtension }.map { $0.descriptor.id }))
            if !isPrivate, !repairedWorks.isEmpty { await ContentCache.shared.clear() }
            try await downloadCoordinator.restore { snapshot in
                let result = try await database.normalizedDownloadForRestoration(snapshot.domainJob)
                var repaired = snapshot
                repaired.transfer.installmentID = result.job.installmentID
                if result.requiresRefresh {
                    repaired.state = .failed
                    repaired.localRelativePath = nil
                    repaired.lastError = .chapterOwnershipMismatch
                }
                return repaired
            }

            let cloudSystemFieldsStore = CloudRecordSystemFieldsStore(
                directoryURL: (isDemo || isPrivate) ? paths.applicationSupportDirectory.appendingPathComponent("CloudSystemFields") : nil
            )
            let cloudRecordStore = DatabaseCloudRecordStore(
                database: database,
                deviceID: deviceID,
                systemFieldsStore: cloudSystemFieldsStore
            )
            // CKContainer.default() raises an Objective-C exception when the
            // process has no CloudKit entitlement. Entitlement-free internal
            // builds opt out explicitly so local storage remains fully usable.
            let isUITesting = ProcessInfo.processInfo.arguments.contains("--manko-ui-test-reset")
                || ProcessInfo.processInfo.arguments.contains("--manko-ui-test-no-cloud")
            let isUnitTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            #if MANKO_DISABLE_CLOUD_SYNC
            let isCloudSyncDisabledForBuild = true
            #else
            let isCloudSyncDisabledForBuild = false
            #endif
            let cloudSyncEngine = (isPrivate || isDemo || isUITesting || isUnitTesting || isCloudSyncDisabledForBuild)
                ? nil
                : CloudSyncEngine(backingStore: cloudRecordStore)
            let importedOriginalTransfer = ImportedOriginalCloudTransferService(
                libraryFilesDirectory: paths.libraryFilesDirectory,
                cloudDocumentsDirectory: nil
            )
            let importedOriginalCloudOrchestrator = ImportedOriginalCloudOrchestrator(
                database: database,
                transfer: importedOriginalTransfer,
                documentsResolver: (isDemo || isPrivate) ? DemoLocalDocumentsResolver() : SystemImportedOriginalCloudDocumentsResolver(),
                libraryFilesDirectory: paths.libraryFilesDirectory,
                deviceID: deviceID
            ) { mutation in
                guard let cloudSyncEngine else { return }
                switch mutation {
                case .save:
                    await cloudSyncEngine.queueSave(recordName: mutation.recordName)
                case .delete:
                    await cloudSyncEngine.queueDelete(recordName: mutation.recordName)
                }
            }
            let trackerQueue = TrackerUpdateQueue(fileURL: isPrivate ? paths.applicationSupportDirectory.appending(path: "Tracking/queue.json") : nil, isPrivate: isPrivate)

            return AppServiceBundle(
                storagePaths: paths,
                database: database,
                importer: importer,
                localPublicationCoverService: localPublicationCoverService,
                customCoverStore: customCoverStore,
                backupService: backupService,
                downloadCoordinator: downloadCoordinator,
                cloudRecordStore: cloudRecordStore,
                cloudSyncEngine: cloudSyncEngine,
                importedOriginalCloudOrchestrator: importedOriginalCloudOrchestrator,
                trackerQueue: trackerQueue,
                repositoryClient: repositoryClient,
                repositoryStore: repositoryStore,
                repositoryInstaller: repositoryInstaller,
                extensionRuntimeRegistry: extensionRuntimeRegistry
            )
        }
        loadingTask = task

        do {
            return try await task.value
        } catch {
            loadingTask = nil
            throw error
        }
    }
}

private struct DemoLocalDocumentsResolver: ImportedOriginalCloudDocumentsResolving {
    func documentsDirectory() async -> URL? { nil }
}

enum LegacyPurchaseStateCleanup {
    static func removeFromDefaultLocation(fileManager: FileManager = .default) {
        guard let applicationSupportRoot = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }
        remove(from: applicationSupportRoot, fileManager: fileManager)
    }

    static func remove(
        from applicationSupportRoot: URL,
        fileManager: FileManager = .default
    ) {
        let directory = applicationSupportRoot
            .appendingPathComponent("manko", isDirectory: true)
            .appendingPathComponent("Entitlements", isDirectory: true)
        let ledger = directory.appendingPathComponent("plus.json", isDirectory: false)

        try? fileManager.removeItem(at: ledger)
        guard
            let remaining = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ),
            remaining.isEmpty
        else { return }
        try? fileManager.removeItem(at: directory)
    }
}
