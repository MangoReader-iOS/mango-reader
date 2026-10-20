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

@MainActor
@Observable
final class SourcesModel {
    let isPrivate: Bool
    var isSessionLocked = false
    let coverImageCache: ExtensionCoverImageCache
    let defaults: UserDefaults
    @ObservationIgnored var extensionRuntimeRegistry: ExtensionRuntimeRegistry?
    let isLibraryAutomationProcess: Bool
    @ObservationIgnored var repositoryClient: SourceRepositoryClient?
    @ObservationIgnored var repositoryInstaller: RepositoryInstaller?
    @ObservationIgnored var repositoryStore: SourceRepositoryStore?
    let feedback: AppFeedback

    init(
        defaults: UserDefaults,
        isLibraryAutomationProcess: Bool,
        feedback: AppFeedback,
        isPrivate: Bool = false
    ) {
        self.isPrivate = isPrivate
        coverImageCache = isPrivate ? ExtensionCoverImageCache() : .shared
        credentialStore = KeychainCredentialStore(service: isPrivate ? "com.k800k.manko.private.sources" : "com.k800k.manko.sources", isPrivate: isPrivate)
        contentCache = isPrivate ? ContentCache(memoryOnly: true) : .shared
        self.defaults = defaults
        self.isLibraryAutomationProcess = isLibraryAutomationProcess
        self.feedback = feedback
    }

    static let sourceManagementLog = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "manko",
        category: "SourceManagement"
    )

    var sources: [SourceDescriptor] = [] {
        didSet {
            let ids = Set((oldValue + sources).map(\.id))
            for id in ids where oldValue.first(where: { $0.id == id }) != sources.first(where: { $0.id == id }) {
                invalidateSourceContent(id)
            }
        }
    }

    var sourceRepositories: [RepositoryRecord] = []

    var installedRepositorySources: [InstalledRepositorySource] = [] {
        didSet {
            if installedRepositorySources.contains(where: { $0.sourceID == "LNori" && $0.isEnabled && $0.version.compare("0.1.1", options: .numeric) != .orderedAscending }) {
                ProgressivePublicationReaderView.prepareRenderer()
            }
            let ids = Set((oldValue + installedRepositorySources).map { $0.descriptor.id })
            for id in ids where oldValue.first(where: { $0.descriptor.id == id }) != installedRepositorySources.first(where: { $0.descriptor.id == id }) {
                invalidateSourceContent(id)
            }
            let providerIDs = Set((oldValue + installedRepositorySources).filter { $0.connectorKind != nil }.map(\.id))
            for source in sources where sourceOptions[source.id.rawValue]?["connectorExtensionID"].map(providerIDs.contains) == true {
                invalidateSourceContent(source.id)
            }
        }
    }

    @ObservationIgnored let workDetailCache = SourceWorkDetailCache()
    @ObservationIgnored var contentCache: ContentCache
    @ObservationIgnored var suggestionStores: [SourceID: SourceSuggestionStore] = [:]
    var sourceSuggestionRevision = 0
    var contentCacheActivationRevision = 0
    @ObservationIgnored var lastCacheActivation: Date?
    @ObservationIgnored var cacheVisits: [SourceCacheVisit] = []
    @ObservationIgnored var cacheVisitGeneration = UUID()
    var contentCacheConfigurationLoaded = false
    var isPerformingQuietRefresh = false
    private(set) var contentRevisions: [SourceID: Int] = [:]

    func invalidateSourceContent(_ sourceID: SourceID) {
        suggestionStores.removeValue(forKey: sourceID)?.coordinator.invalidate()
        sourceSuggestionRevision &+= 1
        if contentCacheConfigurationLoaded {
            defaults.set(UUID().uuidString, forKey: "contentCacheEpoch.\(sourceID.rawValue)")
        }
        contentRevisions[sourceID, default: 0] &+= 1
        workDetailCache.invalidate(sourceID: sourceID)
        coverImageCache.invalidate(sourceID: sourceID)
    }

    func detailCacheKey(for work: Work) -> SourceWorkDetailCache.Key {
        .init(sourceID: work.sourceID, workID: work.id, remoteID: work.remoteID,
              revision: contentRevisions[work.sourceID, default: 0])
    }

    func coverCacheKey(for work: Work, url: URL? = nil) -> String {
        return "\(work.sourceID.rawValue)|\(contentCacheScope(work.sourceID))|\(usesPersistentContentCache ? "stored" : "private")|\((url ?? work.coverURL)?.absoluteString ?? "")"
    }

    var sourceHealth = SourceHealthState()

    var isCheckingSources = false

    var isResettingSources = false

    var isRefreshingRepositories = false

    var repositoryRefreshSummary: RepositoryRefreshSummary?

    var pendingRepositoryLink: RepositoryLinkRequest?

    var pendingCloudflareHandoff: CloudflareHandoffRequest? {
        didSet {
            if pendingCloudflareHandoff == nil, let oldValue {
                dismissingCloudflareHandoffNamespace = oldValue.namespace
            }
        }
    }

    var cloudflareVerificationRevision = 0

    @ObservationIgnored var queuedCloudflareHandoffs: [CloudflareHandoffRequest] = []

    @ObservationIgnored var dismissingCloudflareHandoffNamespace: String?

    @ObservationIgnored var recentlyDismissedCloudflareHandoffNamespace: String?

    var repositoryInstallResults: [RepositoryInstallResult] = []

    @ObservationIgnored var downloadCoordinator: DownloadCoordinator?
    @ObservationIgnored let credentialStore: KeychainCredentialStore

    var sourceCredentialAccounts: [String: String] = [:] {
        didSet {
            for id in Set(oldValue.keys).union(sourceCredentialAccounts.keys) where oldValue[id] != sourceCredentialAccounts[id] {
                invalidateSourceContent(SourceID(rawValue: id))
            }
        }
    }

    var sourceOptions: [String: [String: String]] = [:] {
        didSet {
            for id in Set(oldValue.keys).union(sourceOptions.keys) where oldValue[id] != sourceOptions[id] {
                invalidateSourceContent(SourceID(rawValue: id))
            }
        }
    }

    var sourceSearchExclusions: [String: [SourceSearchSelection]] = [:]

    var pendingManualSourceCleanups: [PendingManualSourceCleanup] = []

    @ObservationIgnored let cloudflareRecoveryCoordinator = CloudflareRecoveryCoordinator.shared

    @ObservationIgnored let trackerCredentialWriteFence = TrackerCredentialWriteFence()

    @ObservationIgnored var repositoryIconCache: [String: Data] = [:]

    @ObservationIgnored var repositoryIconCacheOrder: [String] = []

    @ObservationIgnored var repositoryIconCacheBytes = 0

    @ObservationIgnored var repositoryIconFlights: [String: RepositoryIconFlight] = [:]

    @ObservationIgnored var repositoryIconDiskCache = ContentCache(memoryOnly: true)

    func repositoryIconIdentity(repositoryID: String, entryID: String) -> String {
        guard let repository = sourceRepositories.first(where: { $0.id == repositoryID }),
              let entry = repository.manifest.sources.first(where: { $0.id == entryID }) else { return "" }
        return "\(entry.icon)::\(repository.checkedAt.timeIntervalSinceReferenceDate)"
    }

    @ObservationIgnored var repositoryIconContentLoaderForTesting: (@Sendable (String, String) async throws -> RepositoryIconContent)?

    @ObservationIgnored var pendingCloudflareVerificationRecorderForTesting: (@MainActor @Sendable (CloudflareChallengeContext) async throws -> Void)?

    @ObservationIgnored var cloudflareVerificationPresenterForTesting: CloudflareRecoveryCoordinator.Presenter?

    @ObservationIgnored var trackerAuthenticationDescriptorLoaderForTesting: (@Sendable (InstalledRepositorySource) async throws -> TrackerAuthenticationDescriptor)?

    func trackerAuthenticationDescriptor(for installed: InstalledRepositorySource) async throws -> TrackerAuthenticationDescriptor {
        let descriptorLoaderForTesting = trackerAuthenticationDescriptorLoaderForTesting
        let runtimeRegistry = extensionRuntimeRegistry
        return try await performSourceOperation {
            if let descriptorLoaderForTesting {
                return try await descriptorLoaderForTesting(installed)
            }
            guard let runtimeRegistry else {
                throw SourceError.transport("Tracker services are still starting.")
            }
            return try await runtimeRegistry.trackerAuthentication(for: installed)
        }
    }

    func trackerIsAuthenticated(_ installed: InstalledRepositorySource) async -> Bool {
        #if DEBUG
        if ExtensionAuditFixture.isEnabled, installed.repositoryID == "extension-audit" { return true }
        #endif
        guard let extensionRuntimeRegistry else { return false }
        return (try? await extensionRuntimeRegistry.trackerIsAuthenticated(installed)) == true
    }

    func isCurrentInstallation(_ installed: InstalledRepositorySource) -> Bool {
        installedRepositorySources.contains {
            $0.id == installed.id && $0.installedAt == installed.installedAt
        }
    }

    func signOutTracker(_ installed: InstalledRepositorySource) async throws {
        guard let extensionRuntimeRegistry else { throw SourceError.transport("Tracker services are still starting.") }
        try await extensionRuntimeRegistry.signOutTracker(installed)
    }

    func addSource(
        name: String,
        kind: SourceKind,
        baseURL: URL,
        languageCodes: [String] = [],
        credential: SourceCredential? = nil,
        options: [String: String] = [:]
    ) async throws {
        guard !sources.contains(where: { $0.kind == kind && $0.baseURL == baseURL }) else {
            throw SourceError.transport("This server is already in Browse.")
        }
        var descriptor = SourceDescriptor(
            id: SourceID(rawValue: "\(kind.rawValue)-\(UUID().uuidString)"),
            name: name,
            kind: kind,
            baseURL: baseURL,
            languageCodes: languageCodes
        )

        var savedCredentialAccount: String?
        do {
            try Task.checkCancellation()
            if let credential {
                let credential = try await SourceRequestAuthorizer().resolvedServerCredential(credential,
                    kind: kind, baseURL: baseURL,
                    endpointAccess: EndpointAccess(allowsUserConfirmedLANHTTP: options["allowsLANHTTP"] == "true"))
                try Task.checkCancellation()
                let account = "source.\(descriptor.id.rawValue)"
                try await credentialStore.save(credential, account: account)
                try Task.checkCancellation()
                sourceCredentialAccounts[descriptor.id.rawValue] = account
                savedCredentialAccount = account
            }
            sourceOptions[descriptor.id.rawValue] = options

            let source = try await makeRemoteSource(for: descriptor)
            if let discoverer = source as? any SourceCapabilityDiscovering {
                descriptor.capabilities = try await discoverer.discoverCapabilities()
            } else {
                descriptor.capabilities = await source.descriptor.capabilities
            }
            try Task.checkCancellation()
            sources.append(descriptor)
            saveSources()
        } catch {
            try? await extensionRuntimeRegistry?.removeConnectorConnection(sourceID: descriptor.id)
            sourceOptions.removeValue(forKey: descriptor.id.rawValue)
            sourceCredentialAccounts.removeValue(forKey: descriptor.id.rawValue)
            if let savedCredentialAccount {
                try? await credentialStore.remove(account: savedCredentialAccount)
            }
            throw error
        }
    }

    @discardableResult
    func reconcileInstalledSourceIndex(announcesRecovery: Bool = false) -> SourceIndexReconciliation {
        let result = SourceIndexReconciler.reconcile(
            sources: sources,
            sourceOptions: sourceOptions,
            installedSources: installedRepositorySources,
            repositories: sourceRepositories
        )
        let didChange = sources != result.sources || sourceOptions != result.sourceOptions
        guard didChange else { return result }

        sources = result.sources
        sourceOptions = result.sourceOptions
        saveSources()
        guard announcesRecovery, !isLibraryAutomationProcess else { return result }
        if result.restoredCount > 0 {
            let noun = result.restoredCount == 1 ? "source" : "sources"
            feedback.showStatus(
                "Restored \(result.restoredCount) \(noun).",
                systemImage: "wrench.and.screwdriver.fill"
            )
        } else {
            feedback.showStatus("Repaired source settings.", systemImage: "wrench.and.screwdriver.fill")
        }
        return result
    }

    func refreshSourceHealth(
        repairFailures: [RepositorySourceHealthIssue] = []
    ) async {
        guard let repositoryInstaller else {
            sourceHealth = SourceHealthState(repairFailures: repairFailures)
            return
        }
        let report = await repositoryInstaller.diagnoseInstalledSources()
        guard !Task.isCancelled, !isSessionLocked else { return }
        let repairableIssues = SourceHealthState.repairableIssues(report.issues, installations: installedRepositorySources)
        sourceHealth = SourceHealthState(
            packageIssues: repairableIssues,
            repairFailures: repairFailures.filter { failure in
                repairableIssues.contains(where: { $0.id == failure.id })
            }
        )
    }

    func checkAndRepairSources() async {
        guard !isCheckingSources, !isResettingSources,
              let repositoryInstaller, let repositoryStore
        else { return }

        isCheckingSources = true
        defer { isCheckingSources = false }
        let firstReconciliation = reconcileInstalledSourceIndex()
        let repair = await repositoryInstaller.repairInstalledSources()
        sourceRepositories = await repositoryStore.repositories()
        installedRepositorySources = await repositoryStore.installedSources()
        let secondReconciliation = reconcileInstalledSourceIndex()
        await refreshSourceHealth(repairFailures: repair.failures)

        let restoredCount = firstReconciliation.restoredCount + secondReconciliation.restoredCount
        let repairedCount = restoredCount + repair.repairedCount
        if sourceHealth.needsAttention {
            let count = sourceHealth.issues.count
            let noun = count == 1 ? "source still needs" : "sources still need"
            feedback.showStatus(
                "\(count) \(noun) attention.",
                systemImage: "exclamationmark.triangle.fill"
            )
        } else if repairedCount > 0 {
            let noun = repairedCount == 1 ? "source" : "sources"
            feedback.showStatus(
                "Repaired \(repairedCount) \(noun).",
                systemImage: "checkmark.circle.fill"
            )
        } else if installedRepositorySources.contains(where: { !$0.isRuntimeCompatible }) {
            feedback.showStatus("Incompatible extensions require a compatible update.", systemImage: "arrow.down.circle")
        } else {
            feedback.showStatus("All installed sources are ready.", systemImage: "checkmark.circle.fill")
        }
    }

    func openRepositoryLink(_ url: URL) {
        do {
            let action = try RepositoryDeepLinkParser().parse(url)
            switch action {
            case let .add(repositoryURL):
                pendingRepositoryLink = RepositoryLinkRequest(repositoryURL: repositoryURL, sourceIDs: [])
            case let .install(repositoryURL, sourceIDs):
                pendingRepositoryLink = RepositoryLinkRequest(repositoryURL: repositoryURL, sourceIDs: sourceIDs)
            }
        } catch {
            show(error, title: "Couldn’t open repository link")
        }
    }

    static func fetchRepositoryLinkPreview(
        at url: URL,
        client: SourceRepositoryClient
    ) async throws -> RepositoryRecord {
        try await client.fetchRepository(at: url)
    }

    @discardableResult
    func addRepository(at url: URL) async throws -> RepositoryRecord {
        guard let repositoryClient, let repositoryStore else {
            throw SourceError.transport("Repository storage is still starting. Try again in a moment.")
        }
        let record = try await Self.fetchAndStoreRepository(
            at: url,
            client: repositoryClient,
            store: repositoryStore
        )
        sourceRepositories = await repositoryStore.repositories()
        installedRepositorySources = await repositoryStore.installedSources()
        reconcileInstalledSourceIndex()
        await refreshSourceHealth()
        return record
    }

    static func fetchAndStoreRepository(
        at url: URL,
        client: SourceRepositoryClient,
        store: SourceRepositoryStore
    ) async throws -> RepositoryRecord {
        // Fetch and validate before touching persistence so a failed external or
        // manually entered URL cannot leave a partial repository behind.
        try Task.checkCancellation()
        let record = try await client.fetchRepository(at: url)
        try Task.checkCancellation()
        try await store.upsert(record)
        return await store.repository(id: record.id) ?? record
    }

    @discardableResult
    func refreshRepositories(repositoryIDs: Set<String>? = nil) async -> RepositoryRefreshSummary {
        guard !isRefreshingRepositories else {
            return repositoryRefreshSummary ?? RepositoryRefreshSummary()
        }
        guard let repositoryClient, let repositoryStore else {
            let records = sourceRepositories.filter { repositoryIDs?.contains($0.id) ?? true }
            let summary = RepositoryRefreshSummary(failures: records.map {
                RepositoryRefreshFailure(
                    repositoryID: $0.id,
                    message: "Repository storage is still starting. Try again in a moment."
                )
            })
            repositoryRefreshSummary = summary
            return summary
        }

        let records = sourceRepositories.filter { repositoryIDs?.contains($0.id) ?? true }
        guard !records.isEmpty else {
            let summary = RepositoryRefreshSummary()
            repositoryRefreshSummary = summary
            return summary
        }

        isRefreshingRepositories = true
        let signpostID = OSSignpostID(log: Self.sourceManagementLog)
        os_signpost(
            .begin,
            log: Self.sourceManagementLog,
            name: "Repository Refresh",
            signpostID: signpostID,
            "count=%{public}d",
            records.count
        )
        defer {
            isRefreshingRepositories = false
            os_signpost(.end, log: Self.sourceManagementLog, name: "Repository Refresh", signpostID: signpostID)
        }

        var outcomes: [RepositoryRefreshOutcome] = []
        outcomes.reserveCapacity(records.count)
        await withTaskGroup(of: RepositoryRefreshOutcome.self) { group in
            var nextIndex = 0

            func enqueueNext() {
                guard nextIndex < records.count else { return }
                let record = records[nextIndex]
                nextIndex += 1
                group.addTask {
                    do {
                        let fetched = try await repositoryClient.fetchRepository(at: record.repositoryURL)
                        guard fetched.id == record.id else {
                            throw SourceError.transport("The refreshed repository identity did not match the saved repository.")
                        }
                        let delta = try await repositoryStore.refresh(fetched)
                        return .refreshed(delta)
                    } catch is CancellationError {
                        return .failed(.init(repositoryID: record.id, message: "Refresh cancelled."))
                    } catch {
                        return .failed(.init(repositoryID: record.id, message: error.localizedDescription))
                    }
                }
            }

            for _ in 0 ..< min(4, records.count) { enqueueNext() }
            while let outcome = await group.next() {
                outcomes.append(outcome)
                enqueueNext()
            }
        }

        let deltas = outcomes.compactMap { outcome -> RepositoryRefreshDelta? in
            guard case let .refreshed(delta) = outcome else { return nil }
            return delta
        }.sorted { $0.repositoryID < $1.repositoryID }
        let failures = outcomes.compactMap { outcome -> RepositoryRefreshFailure? in
            guard case let .failed(failure) = outcome else { return nil }
            return failure
        }.sorted { $0.repositoryID < $1.repositoryID }
        let summary = RepositoryRefreshSummary(deltas: deltas, failures: failures)
        sourceRepositories = await repositoryStore.repositories()
        installedRepositorySources = await repositoryStore.installedSources()
        reconcileInstalledSourceIndex()
        await refreshSourceHealth()
        invalidateRepositoryIcons(for: Set(deltas.map(\.repositoryID)))
        repositoryRefreshSummary = summary
        feedback.showStatus(repositoryRefreshSummaryText, systemImage: failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        return summary
    }

    func retryFailedRepositoryRefreshes() async {
        guard let repositoryRefreshSummary, !repositoryRefreshSummary.failedRepositoryIDs.isEmpty else { return }
        await refreshRepositories(repositoryIDs: repositoryRefreshSummary.failedRepositoryIDs)
    }

    var repositoryRefreshSummaryText: String {
        guard let summary = repositoryRefreshSummary else { return "Not checked yet" }
        if summary.checkedCount == 0 { return "No repositories to refresh." }
        var parts = ["Checked \(summary.checkedCount)"]
        if summary.newCount > 0 { parts.append("\(summary.newCount) new") }
        if summary.updateCount > 0 { parts.append("\(summary.updateCount) updates") }
        if summary.failedCount > 0 { parts.append("\(summary.failedCount) failed") }
        if parts.count == 1 { parts.append("up to date") }
        return parts.joined(separator: " · ")
    }

    func repositorySourceHasUpdate(repositoryID: String, entryID: String) -> Bool {
        guard let entry = sourceRepositories.first(where: { $0.id == repositoryID })?
            .manifest.sources.first(where: { $0.id == entryID })
        else { return false }
        let installed = installedRepositorySources.first {
            $0.repositoryID == repositoryID && $0.sourceID == entryID
        }
        return RepositoryVersion.hasUpdate(entry: entry, installed: installed)
    }

    func repositoryIconData(repositoryID: String, entryID: String) async throws -> Data {
        guard let repository = sourceRepositories.first(where: { $0.id == repositoryID }),
              let entry = repository.manifest.sources.first(where: { $0.id == entryID }),
              !entry.icon.isEmpty
        else { throw SourceError.transport("No source icon is available.") }
        let resolvedIconURL = try RepositoryURLPolicy.resolvedURL(
            entry.icon,
            relativeTo: repository.repositoryURL
        )
        let key = "\(repositoryID)::\(resolvedIconURL.absoluteString)::\(repository.checkedAt.timeIntervalSinceReferenceDate)"
        if let cached = repositoryIconCache[key] { return cached }
        let waiterID = UUID()
        let flight: RepositoryIconFlight
        if var existing = repositoryIconFlights[key] {
            existing.waiters.insert(waiterID)
            repositoryIconFlights[key] = existing
            flight = existing
        } else {
            let signpostID = OSSignpostID(log: Self.sourceManagementLog)
            os_signpost(.begin, log: Self.sourceManagementLog, name: "Repository Icon", signpostID: signpostID)
            let task: Task<RepositoryIconContent, Error>
            let loader = repositoryIconContentLoaderForTesting
            if loader == nil && repositoryClient == nil {
                    os_signpost(
                        .end,
                        log: Self.sourceManagementLog,
                        name: "Repository Icon",
                        signpostID: signpostID,
                        "unavailable"
                    )
                    throw SourceError.transport("No source icon is available.")
            }
            let diskCache = repositoryIconDiskCache
            let client = repositoryClient
            task = Task {
                let imageKey = ContentCache.key(["repository-icon-rendered-v1", key])
                let rawKey = ContentCache.key(["repository-icon-original-v1", key])
                let token = await diskCache.writeToken()
                if let cached = await diskCache.entry(for: imageKey), Self.isDecodableRepositoryIcon(cached.data) {
                    return RepositoryIconContent(data: cached.data, mediaType: cached.mediaType)
                }
                let content: RepositoryIconContent
                if let cached = await diskCache.entry(for: rawKey) {
                    content = RepositoryIconContent(data: cached.data, mediaType: cached.mediaType)
                } else if let loader {
                    content = try await loader(repositoryID, entryID)
                } else {
                    #if DEBUG
                    if MangoReaderDemoMode.isEnabled, repositoryID == "demo-video" {
                        content = try MangoReaderDemoMode.iconContent(entry: entry)
                    } else {
                        content = try await client!.fetchIconContent(for: entry, in: repository)
                    }
                    #else
                    content = try await client!.fetchIconContent(for: entry, in: repository)
                    #endif
                }
                let data = try await Self.renderedRepositoryIconData(content)
                try Task.checkCancellation()
                await diskCache.store(content.data, for: rawKey, mediaType: content.mediaType, token: token)
                let mediaType = content.mediaType?.lowercased().hasPrefix("image/svg+xml") == true ? "image/png" : content.mediaType
                await diskCache.store(data, for: imageKey, mediaType: mediaType, token: token)
                await diskCache.flush()
                return RepositoryIconContent(data: data, mediaType: mediaType)
            }
            flight = RepositoryIconFlight(
                id: UUID(),
                task: task,
                signpostID: signpostID,
                waiters: [waiterID]
            )
            repositoryIconFlights[key] = flight
        }

        do {
            let content = try await withTaskCancellationHandler {
                let value = try await Self.awaitRepositoryIconFlight(flight.task)
                try Task.checkCancellation()
                return value
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelRepositoryIconWaiter(waiterID, key: key, flightID: flight.id)
                }
            }
            let data = try Self.validatedRepositoryIconData(content)
            finishRepositoryIconWaiter(
                key: key,
                flightID: flight.id,
                succeeded: true,
                cacheData: data
            )
            return data
        } catch is CancellationError {
            cancelRepositoryIconWaiter(waiterID, key: key, flightID: flight.id)
            throw CancellationError()
        } catch {
            finishRepositoryIconWaiter(
                key: key,
                flightID: flight.id,
                succeeded: false
            )
            throw error
        }
    }

    static func awaitRepositoryIconFlight(
        _ task: Task<RepositoryIconContent, Error>
    ) async throws -> RepositoryIconContent {
        let channel = AsyncStream<Result<RepositoryIconContent, Error>>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        Task {
            let result: Result<RepositoryIconContent, Error>
            do {
                result = .success(try await task.value)
            } catch {
                result = .failure(error)
            }
            channel.continuation.yield(result)
            channel.continuation.finish()
        }
        return try await withTaskCancellationHandler {
            var iterator = channel.stream.makeAsyncIterator()
            guard let result = await iterator.next() else { throw CancellationError() }
            return try result.get()
        } onCancel: {
            channel.continuation.finish()
        }
    }

    func cancelRepositoryIconWaiter(_ waiterID: UUID, key: String, flightID: UUID) {
        guard var flight = repositoryIconFlights[key], flight.id == flightID else { return }
        flight.waiters.remove(waiterID)
        guard flight.waiters.isEmpty else {
            repositoryIconFlights[key] = flight
            return
        }
        repositoryIconFlights[key] = nil
        flight.task.cancel()
        os_signpost(
            .end,
            log: Self.sourceManagementLog,
            name: "Repository Icon",
            signpostID: flight.signpostID,
            "cancelled"
        )
    }

    func finishRepositoryIconWaiter(
        key: String,
        flightID: UUID,
        succeeded: Bool,
        cacheData: Data? = nil
    ) {
        guard let flight = repositoryIconFlights[key], flight.id == flightID else { return }
        repositoryIconFlights[key] = nil
        if let cacheData { cacheRepositoryIcon(cacheData, key: key) }
        if succeeded {
            os_signpost(
                .end,
                log: Self.sourceManagementLog,
                name: "Repository Icon",
                signpostID: flight.signpostID,
                "success"
            )
        } else {
            os_signpost(
                .end,
                log: Self.sourceManagementLog,
                name: "Repository Icon",
                signpostID: flight.signpostID,
                "failure"
            )
        }
    }

    func cacheRepositoryIcon(_ data: Data, key: String) {
        let byteLimit = 16 * 1_024 * 1_024
        guard data.count <= SourceRepositoryLimits.iconBytes else { return }
        if let previous = repositoryIconCache.updateValue(data, forKey: key) {
            repositoryIconCacheBytes -= previous.count
            repositoryIconCacheOrder.removeAll { $0 == key }
        }
        repositoryIconCacheBytes += data.count
        repositoryIconCacheOrder.append(key)
        while repositoryIconCacheBytes > byteLimit, let oldest = repositoryIconCacheOrder.first {
            repositoryIconCacheOrder.removeFirst()
            if let removed = repositoryIconCache.removeValue(forKey: oldest) {
                repositoryIconCacheBytes -= removed.count
            }
        }
    }

    static func isDecodableRepositoryIcon(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    static func validatedRepositoryIconData(_ content: RepositoryIconContent) throws -> Data {
        guard content.data.count <= SourceRepositoryLimits.iconBytes,
              ExtensionCoverMediaTypePolicy.allows(content.mediaType),
              isDecodableRepositoryIcon(content.data)
        else { throw SourceError.unsupportedResponse }
        return content.data
    }

    static func renderedRepositoryIconData(_ content: RepositoryIconContent) async throws -> Data {
        try Task.checkCancellation()
        guard content.data.count <= SourceRepositoryLimits.iconBytes else { throw SourceError.unsupportedResponse }
        if content.mediaType?.split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "image/svg+xml" {
            return try await RepositorySVGRenderer.render(content.data)
        }
        return try validatedRepositoryIconData(content)
    }

    func invalidateRepositoryIcons(for repositoryIDs: Set<String>) {
        guard !repositoryIDs.isEmpty else { return }
        let keys = repositoryIconCache.keys.filter { key in
            repositoryIDs.contains(where: { key.hasPrefix("\($0)::") })
        }
        for key in keys {
            if let removed = repositoryIconCache.removeValue(forKey: key) {
                repositoryIconCacheBytes -= removed.count
            }
            repositoryIconCacheOrder.removeAll { $0 == key }
        }
        let inFlightKeys = repositoryIconFlights.keys.filter { key in
            repositoryIDs.contains(where: { key.hasPrefix("\($0)::") })
        }
        for key in inFlightKeys {
            guard let flight = repositoryIconFlights.removeValue(forKey: key) else { continue }
            flight.task.cancel()
            os_signpost(
                .end,
                log: Self.sourceManagementLog,
                name: "Repository Icon",
                signpostID: flight.signpostID,
                "invalidated"
            )
        }
    }

    func installRepositorySource(
        _ sourceID: String,
        fromRepositoryID repositoryID: String,
        approval: ExtensionAccessGrant? = nil
    ) async -> RepositoryInstallResult {
        guard let record = sourceRepositories.first(where: { $0.id == repositoryID }) else {
            return RepositoryInstallResult(
                sourceID: sourceID,
                sourceName: sourceID,
                installed: false,
                message: "The repository is no longer available."
            )
        }
        return await installRepositorySources([sourceID], from: record, approvals: approval.map { [sourceID: $0] } ?? [:]).first
            ?? RepositoryInstallResult(
                sourceID: sourceID,
                sourceName: sourceID,
                installed: false,
                message: "The source could not be installed."
            )
    }

    func installRepositorySources(
        _ sourceIDs: [String],
        from record: RepositoryRecord,
        approvals: [String: ExtensionAccessGrant] = [:]
    ) async -> [RepositoryInstallResult] {
        guard let repositoryInstaller, let repositoryStore else {
            let result = sourceIDs.map {
                RepositoryInstallResult(
                    sourceID: $0,
                    sourceName: $0,
                    installed: false,
                    message: "Repository storage is still starting."
                )
            }
            repositoryInstallResults = result
            return result
        }
        let liveRecord = await repositoryStore.repository(id: record.id) ?? record
        let signpostID = OSSignpostID(log: Self.sourceManagementLog)
        os_signpost(.begin, log: Self.sourceManagementLog, name: "Source Install", signpostID: signpostID)
        let (installed, results) = await repositoryInstaller.installBatch(
            sourceIDs: sourceIDs,
            from: liveRecord,
            approvals: approvals
        )
        for installedSource in installed {
            if let previous = installedRepositorySources.first(where: { $0.id == installedSource.id }),
               previous.accessGrant?.generation != installedSource.accessGrant?.generation {
                try? await downloadCoordinator?.invalidateVerificationSessions(namespaces: [runtimeNamespace(
                    repositoryID: previous.repositoryID, sourceID: previous.sourceID)])
            }
            if installedSource.kind != .tracker {
                if let index = sources.firstIndex(where: { $0.id == installedSource.descriptor.id }) {
                    sources[index] = installedSource.descriptor
                } else {
                    sources.append(installedSource.descriptor)
                }
            }
            if installedSource.entryType == .connectorPreset,
               let entry = liveRecord.manifest.sources.first(where: { $0.id == installedSource.sourceID }),
               let preset = entry.connectorPreset {
                sourceOptions[installedSource.descriptor.id.rawValue] = preset.options
            }
        }
        saveSources()
        sourceRepositories = await repositoryStore.repositories()
        installedRepositorySources = await repositoryStore.installedSources()
        reconcileInstalledSourceIndex()
        await refreshSourceHealth()
        repositoryInstallResults = results
        os_signpost(.end, log: Self.sourceManagementLog, name: "Source Install", signpostID: signpostID)
        return results
    }

    @discardableResult
    func retryInstalledRepositorySource(_ installed: InstalledRepositorySource) async -> Bool {
        guard let extensionRuntimeRegistry else {
            feedback.showStatus("Source services are still starting. Try again.", systemImage: "exclamationmark.triangle")
            return false
        }
        await extensionRuntimeRegistry.invalidate(installedSourceID: installed.id)
        invalidateSourceContent(installed.descriptor.id)
        feedback.showStatus("\(installed.descriptor.name) will start a fresh isolated session on its next request.", systemImage: "arrow.clockwise.circle.fill")
        return true
    }

    @discardableResult
    func setInstalledRepositorySource(_ installed: InstalledRepositorySource, isEnabled: Bool) async -> Bool {
        guard let repositoryStore else {
            feedback.showStatus("Source services are still starting. Try again.", systemImage: "exclamationmark.triangle")
            return false
        }
        guard !isEnabled || (installed.availability == .available && installed.isRuntimeCompatible) else {
            feedback.showStatus(installed.isRuntimeCompatible ? "This extension is not currently available." : "This extension requires a WASM update.", systemImage: "exclamationmark.triangle")
            return false
        }
        do {
            let updated = try await repositoryStore.setInstalledSourceEnabled(id: installed.id, isEnabled: isEnabled)
            if !isEnabled {
                try await downloadCoordinator?.invalidateVerificationSessions(namespaces: [runtimeNamespace(
                    repositoryID: installed.repositoryID, sourceID: installed.sourceID)])
                clearVerificationRequests(for: [installed])
                await extensionRuntimeRegistry?.invalidate(installedSourceID: installed.id)
            }
            if let index = sources.firstIndex(where: { $0.id == updated.descriptor.id }) {
                sources[index] = updated.descriptor
            }
            saveSources()
            installedRepositorySources = await repositoryStore.installedSources()
            reconcileInstalledSourceIndex()
            await refreshSourceHealth()
            return true
        } catch {
            show(error, title: "Couldn’t update source")
            return false
        }
    }

    func detachInstalledSourcesFromBrowse(_ installedSources: [InstalledRepositorySource]) {
        guard !installedSources.isEmpty else { return }
        let descriptorIDs = Set(installedSources.map(\.descriptor.id))
        sources.removeAll { descriptorIDs.contains($0.id) }
        for descriptorID in descriptorIDs {
            sourceOptions.removeValue(forKey: descriptorID.rawValue)
            sourceSearchExclusions.removeValue(forKey: descriptorID.rawValue)
        }
        clearVerificationRequests(for: installedSources)
        saveSources()
    }

    func clearVerificationRequests(for installedSources: [InstalledRepositorySource]) {
        let namespaces = Set(installedSources.map { installed in
            runtimeNamespace(
                repositoryID: installed.repositoryID,
                sourceID: installed.sourceID
            )
        })
        guard !namespaces.isEmpty else { return }
        cloudflareRecoveryCoordinator.cancel(namespaces: namespaces)
        queuedCloudflareHandoffs.removeAll { namespaces.contains($0.namespace) }
        if let request = pendingCloudflareHandoff, namespaces.contains(request.namespace) {
            pendingCloudflareHandoff = nil
        }
        if let namespace = dismissingCloudflareHandoffNamespace, namespaces.contains(namespace) {
            dismissingCloudflareHandoffNamespace = nil
        }
        if let namespace = recentlyDismissedCloudflareHandoffNamespace, namespaces.contains(namespace) {
            recentlyDismissedCloudflareHandoffNamespace = nil
        }
    }

    func invalidateContentCache(for descriptor: SourceDescriptor) async throws {
#if DEBUG
        if AppFixtures.shouldUseSourceLayoutForUITesting,
           descriptor.id == AppFixtures.metadataTagSearchSourceForUITesting.id { return }
#endif
        let source = try await makeRemoteSource(for: descriptor)
        if let source = source as? MangoReaderExtensionSourceAdapter {
            try await source.invalidateContentCache()
        }
    }

    func browse(
        _ descriptor: SourceDescriptor,
        page: Int = 1,
        text: String = "",
        kinds: Set<ContentKind> = [],
        filters: [String: String] = [:],
        searchSelections: [SourceSearchSelection] = [],
        sortID: String? = nil,
        cursor: SourceCursor? = nil,
        force: Bool = false,
        recoveryMode: CloudflareRecoveryMode? = nil,
        onProgress: (@MainActor @Sendable ([Work]) -> Void)? = nil,
        onCached: (@MainActor (SourcePage<Work>) -> Void)? = nil
    ) async throws -> SourcePage<Work> {
#if DEBUG
        if AppFixtures.shouldSeedMetadataTagSearchForUITesting,
           descriptor.id == AppFixtures.metadataTagSearchSourceForUITesting.id {
            if AppFixtures.shouldUseSourceLayoutForUITesting {
                return try await AppFixtures.sourceLayoutPageForUITesting(page: page, query: text)
            }
            return SourcePage(items: AppFixtures.metadataTagSearchResultsForUITesting)
        }
#endif
        let effectiveSelections = effectiveSearchSelections(
            for: descriptor,
            temporary: searchSelections
        )
        let query = SourceQuery(
            text: text,
            page: page,
            pageSize: 40,
            languageCodes: Set(descriptor.languageCodes),
            kinds: kinds,
            filters: filters,
            searchSelections: effectiveSelections,
            sortID: sortID,
            cursor: cursor
        )
        let isBrowse = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && effectiveSelections.isEmpty
            && sortID == nil
        let key = await sourcePageCacheKey(descriptor.id, operation: isBrowse ? "browse" : "search", query: query)
        let progressScope = contentCacheScope(descriptor.id)
        let progress: (@Sendable ([Work]) async -> Void)? = onProgress.map { callback in
            { @MainActor [weak self] works in
                guard !Task.isCancelled, let self,
                      self.contentCacheScope(descriptor.id) == progressScope else { return }
                callback(works)
            }
        }
        let result: SourcePage<Work> = try await cachedSourceValue(sourceID: descriptor.id, key: key, force: force, recoveryMode: recoveryMode, onCached: onCached) { [weak self] in
            guard let self else { throw CancellationError() }
            let source = try await self.makeRemoteSource(for: descriptor)
            if isBrowse {
                if let source = source as? MangoReaderExtensionSourceAdapter {
                    return try await source.browse(query, onProgress: progress)
                }
                return try await source.browse(query)
            }
            return try await self.suggestionStore(for: descriptor.id).coordinator.run(key: key) {
                if let source = source as? MangoReaderExtensionSourceAdapter {
                    return try await source.search(query, onProgress: progress)
                }
                return try await source.search(query)
            }
        }
        await learnSourceFacets(result.items, for: descriptor.id)
        return SourcePage(
            items: result.items,
            nextPage: result.nextPage,
            totalCount: result.totalCount,
            nextCursor: result.nextCursor
        )
    }

    func sourceDiscoverSections(
        for descriptor: SourceDescriptor,
        force: Bool = false,
        recoveryMode: CloudflareRecoveryMode? = nil,
        onCached: (@MainActor ([SourceDiscoverSection]) -> Void)? = nil
    ) async throws -> [SourceDiscoverSection] {
#if DEBUG
        if AppFixtures.shouldUseSourceLayoutForUITesting,
           descriptor.id == AppFixtures.metadataTagSearchSourceForUITesting.id {
            return [SourceDiscoverSection(id: "latest", title: "Latest", presentation: .latestGallery)]
        }
#endif
        recordCacheVisit(sourceID: descriptor.id)
        let key = sourceCacheKey(descriptor.id, operation: "sections", query: "")
        return try await cachedSourceValue(sourceID: descriptor.id, key: key, force: force, recoveryMode: recoveryMode, onCached: onCached) { [weak self] in
            guard let self else { throw CancellationError() }
            let source = try await self.makeRemoteSource(for: descriptor)
            guard let provider = source as? any SourceDiscoverSectionProviding else {
                return []
            }
            return try await provider.discoverSections()
        }
    }

    func discover(
        _ descriptor: SourceDescriptor,
        sectionID: String,
        page: Int = 1,
        kinds: Set<ContentKind> = [],
        filters: [String: String] = [:],
        sortID: String? = nil,
        cursor: SourceCursor? = nil,
        force: Bool = false,
        recoveryMode: CloudflareRecoveryMode? = nil,
        onProgress: (@MainActor @Sendable ([Work]) -> Void)? = nil,
        onCached: (@MainActor (SourcePage<Work>) -> Void)? = nil
    ) async throws -> SourcePage<Work> {
#if DEBUG
        if AppFixtures.shouldUseSourceLayoutForUITesting,
           descriptor.id == AppFixtures.metadataTagSearchSourceForUITesting.id {
            return try await AppFixtures.sourceLayoutPageForUITesting(page: page, query: "")
        }
#endif
        let query = SourceQuery(
            page: page,
            pageSize: 40,
            languageCodes: Set(descriptor.languageCodes),
            kinds: kinds,
            filters: filters,
            searchSelections: effectiveSearchSelections(for: descriptor, temporary: []),
            sortID: sortID,
            cursor: cursor
        )
        let key = await sourcePageCacheKey(descriptor.id, operation: "discover:\(sectionID)", query: query)
        let progressScope = contentCacheScope(descriptor.id)
        let progress: (@Sendable ([Work]) async -> Void)? = onProgress.map { callback in
            { @MainActor [weak self] works in
                guard !Task.isCancelled, let self,
                      self.contentCacheScope(descriptor.id) == progressScope else { return }
                callback(works)
            }
        }
        let result: SourcePage<Work> = try await cachedSourceValue(sourceID: descriptor.id, key: key, force: force, recoveryMode: recoveryMode, onCached: onCached) { [weak self] in
            guard let self else { throw CancellationError() }
            let source = try await self.makeRemoteSource(for: descriptor)
            guard let provider = source as? any SourceDiscoverSectionProviding else {
                throw SourceError.unsupportedResponse
            }
            if let source = source as? MangoReaderExtensionSourceAdapter {
                return try await source.discover(sectionID: sectionID, query: query, onProgress: progress)
            }
            return try await provider.discover(sectionID: sectionID, query: query)
        }
        await learnSourceFacets(result.items, for: descriptor.id)
        return SourcePage(
            items: result.items,
            nextPage: result.nextPage,
            totalCount: result.totalCount,
            nextCursor: result.nextCursor
        )
    }

    func browseFilterDefaults(for descriptor: SourceDescriptor) -> [String: String] {
        let catalog = CompiledSourceFilterCatalog.shared
        var result = catalog.defaultSelections(for: descriptor.kind, scope: .query)
        let queryKeys = Set(
            catalog.definitions(for: descriptor.kind, scope: .query).map(\.key)
        )
        let persisted = (sourceOptions[descriptor.id.rawValue] ?? [:]).filter { entry in
            queryKeys.contains(entry.key)
        }
        if let normalized = try? catalog.normalize(
            persisted,
            for: descriptor.kind,
            scope: .query
        ) {
            result.merge(normalized) { _, configured in configured }
        }
        return result
    }

    func sourceSearchConfiguration(
        for descriptor: SourceDescriptor,
        force: Bool = false,
        recoveryMode: CloudflareRecoveryMode? = nil,
        onCached: (@MainActor (SourceSearchConfiguration?) -> Void)? = nil
    ) async throws -> SourceSearchConfiguration? {
#if DEBUG
        if AppFixtures.shouldSeedMetadataTagSearchForUITesting,
           descriptor.id == AppFixtures.metadataTagSearchSourceForUITesting.id {
            return AppFixtures.metadataTagSearchConfigurationForUITesting
        }
#endif
        let key = sourceCacheKey(descriptor.id, operation: "searchConfiguration", query: "")
        await loadSourceSuggestionStore(for: descriptor.id)
        let result: SourceSearchConfiguration? = try await cachedSourceValue(sourceID: descriptor.id, key: key, force: force, recoveryMode: recoveryMode, onCached: onCached) { [weak self] in
            guard let self else { throw CancellationError() }
            let source = try await self.makeRemoteSource(for: descriptor)
            guard let provider = source as? any SourceSearchConfigurationProviding else {
                return nil
            }
            return try await provider.searchConfiguration()
        }
        if let result {
            await learnSourceSuggestions(result.fields.flatMap { field in
                field.options.map { SourceSearchSuggestion(fieldID: field.id, value: $0.id, title: $0.title, subtitle: $0.subtitle) }
            }, for: descriptor.id)
        }
        return result
    }

    func sourceSearchSuggestions(
        for descriptor: SourceDescriptor,
        request: SourceSearchSuggestionRequest,
        onCached: (@MainActor ([SourceSearchSuggestion]) -> Void)? = nil
    ) async throws -> [SourceSearchSuggestion] {
#if DEBUG
        if AppFixtures.shouldSeedMetadataTagSearchForUITesting,
           descriptor.id == AppFixtures.metadataTagSearchSourceForUITesting.id {
            let query = request.query.lowercased()
            return AppFixtures.metadataTagSuggestionsForUITesting.filter { suggestion in
                (request.fieldID == nil || request.fieldID == suggestion.fieldID)
                    && suggestion.value.lowercased().contains(query)
            }
            .prefix(request.limit)
            .map { $0 }
        }
#endif
        let key = sourceCacheKey(descriptor.id, operation: "suggestions", query: request)
        let result = try await cachedSourceValue(sourceID: descriptor.id, key: key, onCached: onCached) { [weak self] in
            guard let self else { throw CancellationError() }
            let source = try await self.makeRemoteSource(for: descriptor)
            guard let provider = source as? any SourceSearchConfigurationProviding else {
                return []
            }
            return try await self.suggestionStore(for: descriptor.id).coordinator.run(key: key) {
                try await provider.searchSuggestions(for: request)
            }
        }
        await learnSourceSuggestions(result, for: descriptor.id)
        return result
    }

    func persistentSearchExclusions(for descriptor: SourceDescriptor) -> [SourceSearchSelection] {
        guard sourceSupportsPersistentSearchExclusions(descriptor) else { return [] }
        return sourceSearchExclusions[descriptor.id.rawValue] ?? []
    }

    func setPersistentSearchExclusions(
        _ selections: [SourceSearchSelection],
        for descriptor: SourceDescriptor
    ) {
        guard sourceSupportsPersistentSearchExclusions(descriptor) else {
            sourceSearchExclusions.removeValue(forKey: descriptor.id.rawValue)
            saveSources()
            return
        }
        let bounded = Self.boundedSearchExclusions(selections)
        if bounded.isEmpty {
            sourceSearchExclusions.removeValue(forKey: descriptor.id.rawValue)
        } else {
            sourceSearchExclusions[descriptor.id.rawValue] = bounded
        }
        saveSources()
    }

    func sourceSupportsPersistentSearchExclusions(
        _ descriptor: SourceDescriptor
    ) -> Bool {
        if descriptor.capabilities.contains(.filters) {
            return true
        }
        return installedRepositorySources.contains { installed in
            installed.isEnabled
                && installed.descriptor.id == descriptor.id
                && installed.capabilities.contains(.filters)
        }
    }

    func effectiveSearchSelections(
        for descriptor: SourceDescriptor,
        temporary: [SourceSearchSelection]
    ) -> [SourceSearchSelection] {
        var result: [String: SourceSearchSelection] = [:]
        for selection in temporary {
            result["\(selection.fieldID)|\(selection.value)"] = selection
        }
        for exclusion in persistentSearchExclusions(for: descriptor) {
            result["\(exclusion.fieldID)|\(exclusion.value)"] = exclusion
        }
        return result.values.sorted {
            ($0.fieldID, $0.value, $0.polarity.rawValue)
                < ($1.fieldID, $1.value, $1.polarity.rawValue)
        }
    }

    static func boundedSearchExclusions(
        _ selections: [SourceSearchSelection]
    ) -> [SourceSearchSelection] {
        var seen: Set<String> = []
        return selections
            .filter {
                $0.polarity == .exclude
                    && !$0.fieldID.isEmpty && $0.fieldID.count <= 64
                    && !$0.value.isEmpty && $0.value.count <= 256
                    && !$0.title.isEmpty && $0.title.count <= 256
                    && seen.insert("\($0.fieldID)|\($0.value)").inserted
            }
            .prefix(100)
            .map { $0 }
    }

    func resumePendingManualSourceCleanups() async {
        for cleanup in pendingManualSourceCleanups {
            let sourceID = SourceID(rawValue: cleanup.sourceID)
            sources.removeAll { $0.id == sourceID }
            sourceCredentialAccounts.removeValue(forKey: cleanup.sourceID)
            sourceOptions.removeValue(forKey: cleanup.sourceID)
            sourceSearchExclusions.removeValue(forKey: cleanup.sourceID)
            saveSources()
            await performManualSourceCleanup(cleanup, announcesFailure: false)
        }
    }

    func performManualSourceCleanup(
        _ cleanup: PendingManualSourceCleanup,
        announcesFailure: Bool
    ) async {
        do {
            try await extensionRuntimeRegistry?.removeConnectorConnection(sourceID: SourceID(rawValue: cleanup.sourceID))
            if let account = cleanup.credentialAccount {
                try await credentialStore.remove(account: account)
            }
            pendingManualSourceCleanups.removeAll { $0.id == cleanup.id }
            savePendingManualSourceCleanups()
        } catch {
            if announcesFailure {
                feedback.showStatus(
                    "The source was removed. Saved credential cleanup will retry automatically.",
                    systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
                )
            }
        }
    }

    func saveSources() {
        if let data = try? JSONEncoder().encode(sources) {
            defaults.set(data, forKey: "configuredSources")
        }
        if let data = try? JSONEncoder().encode(sourceCredentialAccounts) {
            defaults.set(data, forKey: "sourceCredentialAccounts")
        }
        if let data = try? JSONEncoder().encode(sourceOptions) {
            defaults.set(data, forKey: "sourceOptions")
        }
        if sourceSearchExclusions.isEmpty {
            defaults.removeObject(forKey: "sourceSearchExclusions")
        } else if let data = try? JSONEncoder().encode(sourceSearchExclusions) {
            defaults.set(data, forKey: "sourceSearchExclusions")
        }
    }

    func savePendingManualSourceCleanups() {
        if pendingManualSourceCleanups.isEmpty {
            defaults.removeObject(forKey: "pendingManualSourceCleanups")
        } else if let data = try? JSONEncoder().encode(pendingManualSourceCleanups) {
            defaults.set(data, forKey: "pendingManualSourceCleanups")
        }
    }

    static func loadSources(from defaults: UserDefaults) -> [SourceDescriptor] {
        guard let data = defaults.data(forKey: "configuredSources") else { return [] }
        return (try? JSONDecoder().decode([SourceDescriptor].self, from: data)) ?? []
    }

    static func loadSourceCredentialAccounts(from defaults: UserDefaults) -> [String: String] {
        guard let data = defaults.data(forKey: "sourceCredentialAccounts") else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static func loadSourceOptions(from defaults: UserDefaults) -> [String: [String: String]] {
        guard let data = defaults.data(forKey: "sourceOptions") else { return [:] }
        return (try? JSONDecoder().decode([String: [String: String]].self, from: data)) ?? [:]
    }

    static func loadSourceSearchExclusions(
        from defaults: UserDefaults
    ) -> [String: [SourceSearchSelection]] {
        guard let data = defaults.data(forKey: "sourceSearchExclusions"),
              let decoded = try? JSONDecoder().decode(
                  [String: [SourceSearchSelection]].self,
                  from: data
              )
        else { return [:] }
        return decoded.reduce(into: [:]) { result, entry in
            let selections = boundedSearchExclusions(entry.value)
            if !selections.isEmpty {
                result[entry.key] = selections
            }
        }
    }

    static func loadPendingManualSourceCleanups(
        from defaults: UserDefaults
    ) -> [PendingManualSourceCleanup] {
        guard let data = defaults.data(forKey: "pendingManualSourceCleanups") else { return [] }
        return (try? JSONDecoder().decode([PendingManualSourceCleanup].self, from: data)) ?? []
    }

    var requestSpeedRevision = 0

    func requestSpeed(for source: SourceDescriptor) -> ExtensionRequestSpeed {
        _ = requestSpeedRevision
        return defaults.string(forKey: "sourceRequestSpeed.\(source.id.rawValue)")
            .flatMap(ExtensionRequestSpeed.init(rawValue:)) ?? .standard
    }

    func setRequestSpeed(_ speed: ExtensionRequestSpeed, for source: SourceDescriptor) {
        defaults.set(speed.rawValue, forKey: "sourceRequestSpeed.\(source.id.rawValue)")
        requestSpeedRevision &+= 1
        guard let installed = installedRepositorySources.first(where: { $0.descriptor.id == source.id }),
              let registry = extensionRuntimeRegistry else { return }
        Task { await registry.setRequestSpeed(speed, installedSourceID: installed.id) }
    }

    func makeRemoteSource(for descriptor: SourceDescriptor?) async throws -> any ContentSource {
        guard !isSessionLocked else { throw CancellationError() }
        guard let descriptor else { throw SourceError.invalidURL }
        #if DEBUG
        if let source = ExtensionAuditFixture.sources[descriptor.id] { return source }
        if descriptor.id == CacheVerificationSource.descriptor.id { return CacheVerificationSource.shared }
        #endif
        if descriptor.kind == .mangoReaderExtension {
            guard let installed = installedRepositorySources.first(where: { $0.descriptor.id == descriptor.id }),
                  let extensionRuntimeRegistry
            else { throw SourceError.notFound }
            return try await extensionRuntimeRegistry.source(for: installed, requestSpeed: requestSpeed(for: installed.descriptor))
        }
        let configuration = try makeSourceConfiguration(for: descriptor)
        if let providerID = configuration.options["connectorExtensionID"] {
            guard let installed = installedRepositorySources.first(where: { $0.id == providerID }),
                  let extensionRuntimeRegistry else { throw MangoReaderExtensionRuntimeError.sourceUnavailable }
            let source = try await extensionRuntimeRegistry.connector(for: installed,
                configuration: configuration, credentialLoader: credentialStore)
            guard installedRepositorySources.contains(installed),
                  sourceOptions[descriptor.id.rawValue]?["connectorExtensionID"] == installed.id else {
                throw MangoReaderExtensionRuntimeError.sourceUnavailable
            }
            return source
        }
        throw MangoReaderExtensionRuntimeError.operationFailed("Connector required. Install a matching server extension and select it in Source Settings.")
    }

    func availableConnectors(for kind: SourceKind) -> [InstalledRepositorySource] {
        installedRepositorySources.filter {
            $0.connectorKind == kind && $0.kind == .content && $0.isEnabled &&
            $0.isRuntimeCompatible && $0.availability == .available
        }.sorted { $0.id < $1.id }
    }

    func setConnector(_ providerID: String?, for descriptor: SourceDescriptor) async throws {
        guard [.opds, .komga, .kavita, .suwayomi].contains(descriptor.kind), sources.contains(where: { $0.id == descriptor.id }),
              let registry = extensionRuntimeRegistry else { throw SourceError.notFound }
        guard let providerID, !providerID.isEmpty else {
            throw MangoReaderExtensionRuntimeError.operationFailed("Select an installed server connector.")
        }
        let originalOptions = sourceOptions[descriptor.id.rawValue] ?? [:]
        var configuration = try makeSourceConfiguration(for: descriptor)
        configuration.options["connectorExtensionID"] = providerID
        do {
            guard let installed = availableConnectors(for: descriptor.kind).first(where: { $0.id == providerID })
            else { throw MangoReaderExtensionRuntimeError.sourceUnavailable }
            let source = try await registry.connector(for: installed, configuration: configuration, credentialLoader: credentialStore)
            _ = try await source.discoverCapabilities()
            try Task.checkCancellation()
            guard availableConnectors(for: descriptor.kind).contains(installed) else {
                throw MangoReaderExtensionRuntimeError.sourceUnavailable
            }
        }
        guard sources.contains(where: { $0.id == descriptor.id }),
              (sourceOptions[descriptor.id.rawValue] ?? [:]) == originalOptions else { throw CancellationError() }
        sourceOptions[descriptor.id.rawValue] = configuration.options
        saveSources()
    }

    func runtimeNamespace(repositoryID: String, sourceID: String) -> String {
        ExtensionRuntimeNamespace.primary(repositoryID: isPrivate ? "private-" + repositoryID : repositoryID, sourceID: sourceID)
    }

    func downloadVerificationReference(
        for descriptor: SourceDescriptor
    ) -> DownloadVerificationReference? {
        let connectorID = sourceOptions[descriptor.id.rawValue]?["connectorExtensionID"]
        guard let installed = installedRepositorySources.first(where: {
            $0.descriptor.id == descriptor.id || $0.id == connectorID
        }), installed.isEnabled, installed.isRuntimeCompatible else { return nil }
        let reference = DownloadVerificationReference(
            namespace: runtimeNamespace(
                repositoryID: installed.repositoryID,
                sourceID: installed.sourceID
            ),
            permittedBrowserHosts: Set(installed.allowedHTTPSHosts),
            serverOrigin: installed.connectorKind == nil ? nil : descriptor.baseURL,
            accessGeneration: installed.accessGrant?.generation
        )
        return reference.isValid ? reference : nil
    }

    func performSourceOperation<Value: Sendable>(
        mode: CloudflareRecoveryMode = .foreground,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard !isSessionLocked else { throw CancellationError() }
        #if DEBUG
        // Audit sessions have isolated runtimes and deliberately do not open
        // verification browsers. Preserve the source's challenge error instead
        // of replacing it with a missing production-registry lookup error.
        if ExtensionAuditFixture.isEnabled { return try await operation() }
        #endif
        let verificationPresenterForTesting = cloudflareVerificationPresenterForTesting
        do {
            return try await cloudflareRecoveryCoordinator.perform(
                mode: mode,
                operation: { [weak self] in
                    guard await self?.isSessionLocked == false else { throw CancellationError() }
                    return try await operation()
                },
                present: { [weak self] context in
                    if let verificationPresenterForTesting {
                        try await verificationPresenterForTesting(context)
                        return
                    }
                    guard let self else { throw CancellationError() }
                    try await self.presentCloudflareVerification(for: context)
                },
                abandon: { [weak self] namespace in
                    self?.abandonCloudflareVerification(namespace: namespace)
                }
            )
        } catch let verificationError as CloudflareVerificationRequiredError {
            do {
                try await persistCloudflareVerificationRequirement(
                    verificationError.context
                )
            } catch {
                throw CloudflareVerificationPersistenceError(
                    context: verificationError.context,
                    reason: error.localizedDescription
                )
            }
            throw verificationError
        }
    }

    func persistCloudflareVerificationRequirement(
        _ context: CloudflareChallengeContext
    ) async throws {
        if let recorder = pendingCloudflareVerificationRecorderForTesting {
            try await recorder(context)
            return
        }
        guard let extensionRuntimeRegistry else {
            throw SourceError.transport("Source verification storage is unavailable.")
        }
        try await extensionRuntimeRegistry.recordPendingCloudflareVerification(context)
    }

    func presentCloudflareVerification(
        for context: CloudflareChallengeContext
    ) async throws {
#if DEBUG
        if CloudflareUITestFixture.isEnabled,
           context.namespace == CloudflareUITestFixture.namespace
        {
            guard let request = CloudflareHandoffRequest(
                context: context,
                seed: ExtensionBrowserSessionSeed()
            ) else {
                throw SourceError.invalidURL
            }
            guard enqueueCloudflareHandoff(request, source: .recovery) else {
                throw CloudflareVerificationCancelledError()
            }
            return
        }
#endif
        guard RepositoryURLPolicy.isSafeIdentifier(context.namespace),
              let extensionRuntimeRegistry,
              let installed = installedRepositorySources.first(where: { installed in
                  runtimeNamespace(
                      repositoryID: installed.repositoryID,
                      sourceID: installed.sourceID
                  ) == context.namespace
              })
        else {
            throw SourceError.invalidURL
        }
        let installedContext = context.bindingDeclaredBrowserHosts(
            to: Set(installed.allowedHTTPSHosts)
        )
        // A restored download can be the first source activity after launch.
        // Recreate the registry's write authorization before presenting so
        // completion can persist the verified browser identity instead of
        // failing as a stale, warm-runtime-only handoff.
        if installed.kind == .tracker {
            _ = try await extensionRuntimeRegistry.tracker(for: installed)
        } else {
            _ = try await extensionRuntimeRegistry.source(for: installed, requestSpeed: requestSpeed(for: installed.descriptor))
        }
        let seed = try await extensionRuntimeRegistry.browserSessionSeed(for: installedContext)
        try Task.checkCancellation()
        guard let request = CloudflareHandoffRequest(context: installedContext, seed: seed) else {
            throw SourceError.invalidURL
        }
        guard enqueueCloudflareHandoff(request, source: .recovery) else {
            throw CloudflareVerificationCancelledError()
        }
    }

    func restorePendingCloudflareVerificationRequirements() async throws {
        guard !isLibraryAutomationProcess, let extensionRuntimeRegistry else { return }
        for installed in installedRepositorySources where installed.isEnabled {
            try Task.checkCancellation()
            guard !isSessionLocked else { throw CancellationError() }
            let namespace = runtimeNamespace(
                repositoryID: installed.repositoryID,
                sourceID: installed.sourceID
            )
            guard let context = try await extensionRuntimeRegistry
                .pendingCloudflareVerification(namespace: namespace)
            else { continue }
            try Task.checkCancellation()
            guard !isSessionLocked else { throw CancellationError() }
            cloudflareRecoveryCoordinator.recordBackgroundRequirement(context)
            do {
                try await presentCloudflareVerification(for: context)
            } catch is CancellationError {
                return
            } catch {
                show(error, title: "Couldn’t resume source verification")
            }
        }
    }

    func isInstalledExtensionNamespace(_ namespace: String) -> Bool {
        installedRepositorySources.contains { installed in
            runtimeNamespace(
                repositoryID: installed.repositoryID,
                sourceID: installed.sourceID
            ) == namespace
        }
    }

    func abandonCloudflareVerification(namespace: String) {
        queuedCloudflareHandoffs.removeAll { $0.namespace == namespace }
        if pendingCloudflareHandoff?.namespace == namespace {
            pendingCloudflareHandoff = nil
        }
    }

    func isExtensionBacked(_ work: Work) -> Bool {
        sources.first(where: { $0.id == work.sourceID })?.kind == .mangoReaderExtension
            || sourceOptions[work.sourceID.rawValue]?["connectorExtensionID"] != nil
    }

    func extensionCoverImageData(for work: Work, at url: URL? = nil, force: Bool = false) async throws -> Data? {
        guard let coverURL = url ?? work.coverURL,
              let descriptor = sources.first(where: {
                  $0.id == work.sourceID && $0.isEnabled
              })
        else { return nil }
        let key = ContentCache.key([coverCacheKey(for: work, url: coverURL), "cover"])
        if usesPersistentContentCache, !force, let cached = await contentCache.entry(for: key) {
            if !cached.isFresh(lifetime: 86_400) {
                Task(priority: .utility) { [weak self] in _ = try? await self?.extensionCoverImageData(for: work, at: coverURL, force: true) }
            }
            return cached.data
        }
        let token = await contentCache.writeToken()
        let data: Data? = try await performSourceOperation(mode: force ? .background : .foreground) { [weak self] in
            guard let self else { throw CancellationError() }
            let source = try await self.makeRemoteSource(for: descriptor)
            let content: RemoteImagePageContent
            if let extensionSource = source as? MangoReaderExtensionSourceAdapter {
                content = try await extensionSource.coverImageContent(at: coverURL)
            } else if let connector = source as? MangoReaderConnectorSourceAdapter {
                content = try await connector.coverImageContent(at: coverURL)
            } else { return nil }
            guard ExtensionCoverMediaTypePolicy.allows(content.mediaType) else {
                throw SourceError.unsupportedResponse
            }
            guard await ImagePageDecoder.isValidImageData(content.data) else { throw SourceError.unsupportedResponse }
            return content.data
        }
        if usesPersistentContentCache, key == ContentCache.key([coverCacheKey(for: work, url: coverURL), "cover"]), let data {
            await contentCache.store(data, for: key, token: token)
        }
        return data
    }

    func makeSourceConfiguration(for descriptor: SourceDescriptor) throws -> SourceEndpointConfiguration {
        guard let baseURL = descriptor.baseURL else { throw SourceError.invalidURL }
        return SourceEndpointConfiguration(
            id: descriptor.id,
            name: descriptor.name,
            kind: descriptor.kind,
            baseURL: baseURL,
            languageCodes: descriptor.languageCodes,
            credentialAccount: sourceCredentialAccounts[descriptor.id.rawValue],
            endpointAccess: EndpointAccess(
                allowsUserConfirmedLANHTTP: sourceOptions[descriptor.id.rawValue]?["allowsLANHTTP"] == "true"
            ),
            options: sourceOptions[descriptor.id.rawValue] ?? [:]
        )
    }

    @discardableResult
    func handleCloudflareHandoff(_ error: Error) -> Bool {
#if DEBUG
        // Offline audit failures must never open a live verification browser.
        if ExtensionAuditFixture.isEnabled { return false }
#endif
        guard case let MangoReaderExtensionRuntimeError.cloudflareHandoff(context) = error,
              RepositoryURLPolicy.isSafeIdentifier(context.namespace),
              let request = CloudflareHandoffRequest(
                  context: context,
                  seed: ExtensionBrowserSessionSeed()
              )
        else { return false }
        _ = enqueueCloudflareHandoff(request, source: .legacyError)
        return true
    }

    @discardableResult
    func enqueueCloudflareHandoff(
        _ request: CloudflareHandoffRequest,
        source: CloudflareHandoffEnqueueSource
    ) -> Bool {
        guard !isSessionLocked else { return false }
        let namespace = request.namespace
        if recentlyDismissedCloudflareHandoffNamespace == namespace,
           source == .legacyError {
            return false
        }
        // A sheet that is already on screen owns the current verification
        // session. Same-source reports are duplicates even if their handoff
        // URLs differ; other sources wait for the current sheet to dismiss.
        if let pendingCloudflareHandoff {
            if pendingCloudflareHandoff.namespace == namespace {
                return true
            }
            guard !queuedCloudflareHandoffs.contains(where: { $0.namespace == namespace })
            else { return true }
            queuedCloudflareHandoffs.append(request)
            return true
        }
        if dismissingCloudflareHandoffNamespace != nil {
            guard !queuedCloudflareHandoffs.contains(where: { $0.namespace == namespace })
            else { return true }
            if dismissingCloudflareHandoffNamespace != namespace {
                queuedCloudflareHandoffs.append(request)
                return true
            }
            return false
        }
        guard !queuedCloudflareHandoffs.contains(where: { $0.namespace == namespace }) else {
            return true
        }
        recentlyDismissedCloudflareHandoffNamespace = nil
        pendingCloudflareHandoff = request
        return true
    }

    func show(_ error: Error, title: String) {
        if handleCloudflareHandoff(error) { return }
        feedback.alert = AppAlert(title: title, message: error.localizedDescription)
    }

    func cancelCloudflareHandoff(_ request: CloudflareHandoffRequest) {
        guard pendingCloudflareHandoff?.id == request.id else { return }
        cloudflareRecoveryCoordinator.cancel(namespace: request.namespace)
        dismissCloudflareHandoff(request)
    }

    func dismissCloudflareHandoff(_ request: CloudflareHandoffRequest) {
        guard pendingCloudflareHandoff?.id == request.id else { return }
        pendingCloudflareHandoff = nil
    }

    func cloudflareHandoffDidDismiss() {
        guard pendingCloudflareHandoff == nil else { return }
        let dismissedNamespace = dismissingCloudflareHandoffNamespace
        dismissingCloudflareHandoffNamespace = nil
        if let dismissedNamespace {
            cloudflareRecoveryCoordinator.cancel(namespace: dismissedNamespace)
        }
        recentlyDismissedCloudflareHandoffNamespace = dismissedNamespace
        if !queuedCloudflareHandoffs.isEmpty {
            pendingCloudflareHandoff = queuedCloudflareHandoffs.removeFirst()
        }
        guard let dismissedNamespace else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard self?.recentlyDismissedCloudflareHandoffNamespace == dismissedNamespace else { return }
            self?.recentlyDismissedCloudflareHandoffNamespace = nil
        }
    }
}
