import Foundation
import MankoDomain
import MankoSources
import OSLog

private enum ExtensionDestinationPolicy {
    static let endpointAccess = EndpointAccess(allowsSystemPermittedHTTP: true)

    static func validatedURL(_ value: String) -> URL? {
        guard let url = URL(string: value) else { return nil }
        return validatedURL(url)
    }

    static func validatedURL(_ url: URL) -> URL? {
        guard (try? EndpointPolicy().validate(url, access: endpointAccess)) != nil else { return nil }
        return url
    }
}

actor MankoRequestPermitPool {
    private var available: Int
    private struct Waiter {
        let id: UUID
        var priority: Int
        let owner: UUID?
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []

    init(limit: Int) { available = max(1, limit) }

    func acquire(priority: Int = 0, owner: UUID? = nil) async throws {
        try Task.checkCancellation()
        if available > 0 { available -= 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError()); return
                }
                waiters.append(Waiter(id: id, priority: priority, owner: owner, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    func setPriority(_ priority: Int, owner: UUID) {
        for index in waiters.indices where waiters[index].owner == owner { waiters[index].priority = priority }
    }

    func release() {
        guard !waiters.isEmpty else { available += 1; return }
        let priority = waiters.map(\.priority).max()!
        let index = waiters.firstIndex { $0.priority == priority }!
        waiters.remove(at: index).continuation.resume()
    }
}

/// Local catalog pacing; extension-defined page sizes remain unchanged.
public enum ExtensionRequestSpeed: String, CaseIterable, Sendable {
    case standard, slow, verySlow

    public var interval: TimeInterval {
        switch self {
        case .standard: 1
        case .slow: 2
        case .verySlow: 5
        }
    }
}

/// Shared by every catalog invocation in one installed source. Rechecking the
/// deadline after suspension prevents concurrent waiters from starting together.
@MainActor
final class ExtensionCatalogRequestGate {
    var speed: ExtensionRequestSpeed
    private var lastStart: TimeInterval?
    private var cooldown: TimeInterval = 0
    private let standardInterval: TimeInterval
    private let now: @MainActor () -> TimeInterval
    private let sleep: @MainActor (Duration) async throws -> Void

    init(speed: ExtensionRequestSpeed = .standard, sourceID: String? = nil,
         now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.speed = speed
        // Hitomi and MangaFire start catalog requests together in browser traces. Keep
        // transport concurrency bounded, without imposing a per-start delay.
        standardInterval = ["HitomiLA", "MangaFire"].contains(sourceID ?? "") ? 0 : ExtensionRequestSpeed.standard.interval
        self.now = now
        self.sleep = sleep
    }

    var retryAfterSeconds: TimeInterval { max(0, cooldown - now()) }

    func waitForStart(failDuringCooldown: Bool = false, reservesStart: Bool = true) async throws {
        try Task.checkCancellation()
        while true {
            if failDuringCooldown, retryAfterSeconds > 0 {
                throw SourceError.rateLimited(retryAfterSeconds: min(ceil(retryAfterSeconds), 86_400))
            }
            let interval = speed == .standard ? standardInterval : speed.interval
            let deadline = max(lastStart.map { $0 + interval } ?? now(), cooldown)
            let remaining = deadline - now()
            if remaining <= 0 {
                try Task.checkCancellation()
                if reservesStart { recordStart() }
                return
            }
            try await sleep(.seconds(min(60, remaining)))
            try Task.checkCancellation()
        }
    }

    func recordStart() { lastStart = now() }

    func reportRateLimit(retryAfter: String?, at date: Date = .now) {
        let delay = HTTPClient.retryDelay(from: retryAfter, now: date)
            .flatMap { $0.isFinite ? $0 : nil } ?? 5
        cooldown = max(cooldown, now() + max(0, delay))
    }
}

@MainActor
public final class MankoExtensionRuntime: NSObject {
    private static let maximumInvocationEnvelopeBytes = 32 * 1_024 * 1_024
    private static let runtimeLogger = Logger(
        subsystem: "com.k800k.manko",
        category: "ExtensionRuntime"
    )
    private static let performanceLog = OSLog(
        subsystem: "com.k800k.manko",
        category: "ExtensionPerformance"
    )

    public struct Configuration: Sendable {
        public var namespace: String
        public var entryID: String
        public var apiVersion: String
        public var kind: ExtensionKind?
        public var scriptURL: URL
        public var allowedHTTPSHosts: Set<String>
        public var permissions: ExtensionPermissionSet
        public var operationTimeout: Duration
        public var connectorKind: SourceKind?
        public var connection: SourceEndpointConfiguration?
        public var credentialLoader: (any SourceCredentialLoading)?
        public var accountPolicy: ExtensionAccountPolicy?
        public var offlineValidation: Bool
        public var searchOperationTimeout: Duration

        public init(
            namespace: String,
            entryID: String,
            apiVersion: String = MankoExtensionPayload.supportedAPIVersion,
            kind: ExtensionKind? = nil,
            scriptURL: URL,
            allowedHTTPSHosts: Set<String> = [],
            permissions: ExtensionPermissionSet = .init(),
            operationTimeout: Duration = .seconds(60),
            searchOperationTimeout: Duration = .seconds(15),
            connectorKind: SourceKind? = nil,
            connection: SourceEndpointConfiguration? = nil,
            credentialLoader: (any SourceCredentialLoading)? = nil,
            accountPolicy: ExtensionAccountPolicy? = nil,
            offlineValidation: Bool = false
        ) {
            self.namespace = namespace
            self.entryID = entryID
            self.apiVersion = apiVersion
            self.kind = kind
            self.scriptURL = scriptURL
            self.allowedHTTPSHosts = Set(allowedHTTPSHosts.map { $0.lowercased() })
            self.permissions = permissions
            self.operationTimeout = operationTimeout
            self.searchOperationTimeout = searchOperationTimeout
            self.connectorKind = connectorKind
            self.connection = connection
            self.credentialLoader = credentialLoader
            self.accountPolicy = accountPolicy
            self.offlineValidation = offlineValidation
        }
    }

    public private(set) var isValid = true
    public private(set) var lastCloudflareHandoffURL: URL?

    private let runtimeConfiguration: Configuration
    private let httpClient: HTTPClient
    private let stateStore: ExtensionStateStore
    private let secureStateStore: ExtensionSecureStateStore
    let storageWriteAuthorization: ExtensionStorageWriteAuthorization
    private let permits = MankoRequestPermitPool(limit: 4)
    private var metadataLoadPermits: [String: MankoRequestPermitPool] = [:]
    private var metadataLoadOwners: [String: UUID] = [:]
    private var metadataLoadUsers: [String: Int] = [:]
    private var metadataKeys: Set<String> = []
    private let catalogStartPermits = MankoRequestPermitPool(limit: 1)
    private let catalogRequestGate: ExtensionCatalogRequestGate?
    private let wasm = MankoWasmInstance()
    private var invocationContexts: [UUID: MankoWasmInstance.InvocationContext] = [:]
    private var invocationCleanups: [UUID: Task<Void, Never>] = [:]
    // Internal injection keeps deadline tests independent of wall-clock delays.
    var operationSleep: @MainActor @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    private var serviceContinuations: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var nativeRequestTasks: [String: Task<Void, Never>] = [:]
    /// Native HTTP challenges cross the untrusted WASM continuation boundary
    /// before an invocation returns. A Swift-generated invocation identifier
    /// preserves the provenance of response URLs actually observed by the
    /// broker without accepting a guest-supplied authorization marker.
    private var activeInvocationIDs: Set<UUID> = []
    private var invocationMethods: [UUID: String] = [:]
    private var catalogProgressHandlers: [UUID: @MainActor @Sendable (JSONValue) async throws -> Void] = [:]
    private var scriptCacheIdentity: String?
    private var cacheConfigurationRevision = UUID()
    private var cacheSettingsIdentity: String?
    private struct MetadataPermitLoad {
        let id: UUID
        let task: Task<ContentCache.MetadataPermit, Never>
    }
    private struct CacheInvocation {
        let searchCoordinator: SourceSearchRequestCoordinator?
        let isSuggestion: Bool
        let isCatalog: Bool
        var catalogFailure: SourceError?
        var searchTransportCount = 0
        let configurationRevision: UUID
        let scope: String
        let reload: Bool
        let isPrivate: Bool
        let generation: UUID
        let freshness: SourceCacheFreshness?
        var permits: [String: ContentCache.MetadataPermit] = [:]
        var permitLoads: [String: MetadataPermitLoad] = [:]
        var writtenKeys: Set<String> = []
    }
    private var cacheInvocations: [UUID: CacheInvocation] = [:]
    private var brokerObservedCloudflareContexts: [UUID: [CloudflareChallengeContext]] = [:]
    private var initializationTask: Task<Void, Error>?
    private var isInitialized = false
    private var browserSessionProfile: ExtensionBrowserSessionProfile?
    private var verifiedBrowserTransport: (any ExtensionVerifiedBrowserTransport)?
    private struct ImageConsumer {
        var priority: RemoteImageRequestPriority
        let continuation: CheckedContinuation<RemoteImagePageContent, Error>
        var onPartial: (@Sendable (RemoteImagePageContent) async -> Void)?
        var onProgress: RemoteImageDownloadProgressHandler?
    }
    private struct ImageCachePolicy: Equatable {
        let reload: Bool
        let isPrivate: Bool
        let scope: String?
        let generation: UUID
    }
    private struct ImageRequest {
        let url: URL
        let cachePolicy: ImageCachePolicy
        var waiters: [UUID: ImageConsumer]
        var invocationID: UUID?
        var priority: RemoteImageRequestPriority { waiters.values.map(\.priority).max() ?? .cover }
    }
    private struct ImageInvocation {
        let requestIDs: [UUID]
        let task: Task<Void, Never>
    }
    private struct NativeImageResource {
        let invocationID: UUID
        let content: RemoteImagePageContent
    }
    private var imageRequests: [UUID: ImageRequest] = [:]
    private var pendingImageRequests: [UUID] = []
    private var imageInvocations: [UUID: ImageInvocation] = [:]
    private var nativeImageResources: [String: NativeImageResource] = [:]
    private var publicationChunks: [UUID: @Sendable (HTTPResponse, Data) async throws -> Void] = [:]
    private var nativeRequestOwners: [String: UUID] = [:]
    private var supportsIndependentImages = false
    var retainedImageResourceCount: Int { nativeImageResources.count }
    var queuedImageRequestCount: Int { pendingImageRequests.count }


    public convenience init(
        configuration: Configuration,
        httpClient: HTTPClient,
        stateStore: ExtensionStateStore,
        secureStateStore: ExtensionSecureStateStore
    ) {
        self.init(
            configuration: configuration,
            httpClient: httpClient,
            stateStore: stateStore,
            secureStateStore: secureStateStore,
            storageWriteAuthorization: ExtensionStorageWriteAuthorization(
                namespace: configuration.namespace
            )
        )
    }

    init(
        configuration: Configuration,
        httpClient: HTTPClient,
        stateStore: ExtensionStateStore,
        secureStateStore: ExtensionSecureStateStore,
        storageWriteAuthorization: ExtensionStorageWriteAuthorization,
        verifiedBrowserTransport: (any ExtensionVerifiedBrowserTransport)? = nil,
        catalogRequestGate: ExtensionCatalogRequestGate? = nil
    ) {
        runtimeConfiguration = configuration
        self.httpClient = httpClient
        self.stateStore = stateStore
        self.secureStateStore = secureStateStore
        self.storageWriteAuthorization = storageWriteAuthorization
        self.verifiedBrowserTransport = verifiedBrowserTransport
        self.catalogRequestGate = catalogRequestGate
        super.init()
    }

    public func initialize() async throws {
        guard isValid else { throw MankoExtensionRuntimeError.runtimeTerminated }
        if isInitialized { return }
        if let initializationTask {
            return try await initializationTask.value
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { throw MankoExtensionRuntimeError.runtimeTerminated }
            let race = MankoOperationRace(sleep: operationSleep)
            let initializationID = UUID()
            let startedAt = ContinuousClock.now
            _ = try await race.run(timeout: runtimeConfiguration.operationTimeout,
                operation: { try await self.performInitialization(); return "" },
                onTimeout: {
                    let elapsed = String(describing: startedAt.duration(to: .now))
                    Self.runtimeLogger.notice("source=\(self.runtimeConfiguration.entryID, privacy: .public) operation=initialize invocation=\(initializationID.uuidString, privacy: .public) elapsed=\(elapsed, privacy: .public) WASM execution limit: wallClock")
                    self.invalidate()
                })
        }
        let signpostID = OSSignpostID(log: Self.performanceLog)
        os_signpost(
            .begin,
            log: Self.performanceLog,
            name: "Runtime Initialization",
            signpostID: signpostID
        )
        initializationTask = task
        do {
            try await task.value
            guard isValid else { throw MankoExtensionRuntimeError.runtimeTerminated }
            isInitialized = true
            initializationTask = nil
            os_signpost(
                .end,
                log: Self.performanceLog,
                name: "Runtime Initialization",
                signpostID: signpostID,
                "success"
            )
        } catch {
            initializationTask = nil
            invalidate(cancelInitialization: false)
            if error is CancellationError {
                os_signpost(
                    .end,
                    log: Self.performanceLog,
                    name: "Runtime Initialization",
                    signpostID: signpostID,
                    "cancel"
                )
            } else {
                os_signpost(
                    .end,
                    log: Self.performanceLog,
                    name: "Runtime Initialization",
                    signpostID: signpostID,
                    "failure"
                )
            }
            if let error = error as? MankoExtensionRuntimeError { throw error }
            if error is CancellationError { throw error }
            throw MankoExtensionRuntimeError.initializationFailed(error.localizedDescription)
        }
    }

    private func performInitialization() async throws {
        guard runtimeConfiguration.apiVersion == "3.0" else {
            throw MankoExtensionRuntimeError.initializationFailed("This extension requires a WASM update.")
        }
        try Task.checkCancellation()
        guard await stateStore.activateWriteAuthorization(storageWriteAuthorization),
              await secureStateStore.activateWriteAuthorization(storageWriteAuthorization)
        else { throw MankoExtensionRuntimeError.runtimeTerminated }
        let secureState = try await secureStateStore.values(namespace: runtimeConfiguration.namespace)
        browserSessionProfile = secureState[ExtensionBrowserSessionProfile.secureStateKey]
            .flatMap { try? JSONDecoder().decode(ExtensionBrowserSessionProfile.self, from: $0) }
            .flatMap { $0.isValid() ? $0 : nil }
        do {
            try await wasm.load(url: runtimeConfiguration.scriptURL)
            let owner = UUID()
            let metadata = try await wasm.dispatch(.object(["action": .string("metadata")]), owner: owner,
                context: .init(sourceID: runtimeConfiguration.entryID, operation: "metadata"))
            await wasm.finish(owner)
            guard case let .object(object) = metadata,
                  object["id"] == .string(runtimeConfiguration.entryID),
                  object["apiVersion"] == .string("3.0"),
                  object["kind"] == .string("content") || object["kind"] == .string("tracker"),
                  runtimeConfiguration.kind.map({ object["kind"] == .string($0.rawValue) }) ?? true else {
                throw MankoExtensionRuntimeError.invalidPackage
            }
            supportsIndependentImages = object["imageRequestMode"] == .string("independent")
            if !runtimeConfiguration.offlineValidation {
                _ = try await invoke(method: "initialize", arguments: .object([:]))
            }
            if let kind = runtimeConfiguration.connectorKind {
                let info = try await invoke(method: "connectorInfo", arguments: .object([:]))
                guard info == .object(["kind": .string(kind.rawValue), "version": .number(1)]) else {
                    throw MankoExtensionRuntimeError.invalidPackage
                }
            }
        } catch {
            invalidate(cancelInitialization: false)
            throw error
        }
    }

    /// Connector profile v1 uses native connection identity and credentials.
    /// Only endpoint/options enter the guest; downloads remain native transfers.
    func connector<Value: Decodable & Sendable>(
        _ type: Value.Type, operation: String, arguments: [String: JSONValue] = [:]
    ) async throws -> Value {
        guard let connection = runtimeConfiguration.connection,
              runtimeConfiguration.connectorKind == connection.kind else {
            throw MankoExtensionRuntimeError.sourceUnavailable
        }
        var input = arguments
        input["operation"] = .string(operation)
        input["baseURL"] = .string(connection.baseURL.absoluteString)
        input["options"] = try Self.jsonValue(connection.options.filter { $0.key != "connectorExtensionID" })
        return try decode(type, from: try await invoke(method: "connector", arguments: .object(input)))
    }

    public func search(
        title: String,
        selections: [SourceSearchSelection] = [],
        filters: [String: String] = [:],
        sortID: String? = nil,
        metadata: JSONValue?,
        onProgress: (@Sendable ([MankoSearchItem]) async -> Void)? = nil
    ) async throws -> MankoPagedValue<MankoSearchItem> {
        let selectionsValue = try Self.jsonValue(selections)
        let filtersValue = try Self.jsonValue(filters)
        return try decode(
            MankoPagedValue<MankoSearchItem>.self,
            from: try await invoke(
                method: "search",
                arguments: .object([
                    "title": .string(title),
                    "selections": selectionsValue,
                    "filters": filtersValue,
                    "sort": sortID.map(JSONValue.string) ?? .null,
                    "metadata": metadata ?? .null,
                    "catalogProgress": .bool(onProgress != nil),
                ]),
                timeout: runtimeConfiguration.searchOperationTimeout,
                catalogProgress: onProgress.map { callback -> @MainActor @Sendable (JSONValue) async throws -> Void in
                    { @MainActor [self] value in
                        await callback(try decode([MankoSearchItem].self, from: value))
                    }
                }
            )
        )
    }

    public func discoverSections() async throws -> [MankoDiscoverSection] {
        try decode(
            [MankoDiscoverSection].self,
            from: try await invoke(method: "discoverSections", arguments: .object([:]))
        )
    }

    public func discover(
        section: MankoDiscoverSection,
        selections: [SourceSearchSelection] = [],
        filters: [String: String] = [:],
        sortID: String? = nil,
        metadata: JSONValue?,
        onProgress: (@Sendable ([MankoDiscoverItem]) async -> Void)? = nil
    ) async throws -> MankoPagedValue<MankoDiscoverItem> {
        let sectionData = try JSONEncoder().encode(section)
        let sectionValue = try JSONDecoder().decode(JSONValue.self, from: sectionData)
        return try decode(
            MankoPagedValue<MankoDiscoverItem>.self,
            from: try await invoke(
                method: "discover",
                arguments: .object([
                    "section": sectionValue,
                    "selections": try Self.jsonValue(selections),
                    "filters": try Self.jsonValue(filters),
                    "sort": sortID.map(JSONValue.string) ?? .null,
                    "metadata": metadata ?? .null,
                    "catalogProgress": .bool(onProgress != nil),
                ]),
                catalogProgress: onProgress.map { callback -> @MainActor @Sendable (JSONValue) async throws -> Void in
                    { @MainActor [self] value in
                        await callback(try decode([MankoDiscoverItem].self, from: value))
                    }
                }
            )
        )
    }

    public func details(workID: String) async throws -> MankoSourceWork {
        try decode(
            MankoSourceWork.self,
            from: try await invoke(method: "details", arguments: .object(["workID": .string(workID)]))
        )
    }

    public func installments(sourceWork: MankoSourceWork) async throws -> [MankoInstallment] {
        let mangaData = try JSONEncoder().encode(sourceWork)
        let mangaValue = try JSONDecoder().decode(JSONValue.self, from: mangaData)
        return try decode(
            [MankoInstallment].self,
            from: try await invoke(method: "installments", arguments: .object(["sourceWork": mangaValue]))
        )
    }

    public func imagePages(extensionInstallment: MankoInstallment, sourceWork: MankoSourceWork) async throws -> MankoImagePageList {
        let chapterData = try JSONEncoder().encode(extensionInstallment)
        var chapterValue = try JSONDecoder().decode(JSONValue.self, from: chapterData)
        if case var .object(object) = chapterValue {
            object["sourceWork"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(sourceWork))
            chapterValue = .object(object)
        }
        return try decode(
            MankoImagePageList.self,
            from: try await invoke(method: "imagePages", arguments: .object(["extensionInstallment": chapterValue]))
        )
    }

    public func publicationContent(
        extensionInstallment: MankoInstallment,
        sourceWork: MankoSourceWork
    ) async throws -> MankoPublicationContent {
        let installmentData = try JSONEncoder().encode(extensionInstallment)
        var installmentValue = try JSONDecoder().decode(JSONValue.self, from: installmentData)
        if case var .object(object) = installmentValue {
            object["sourceWork"] = try JSONDecoder().decode(
                JSONValue.self,
                from: JSONEncoder().encode(sourceWork)
            )
            installmentValue = .object(object)
        }
        return try decode(
            MankoPublicationContent.self,
            from: try await invoke(
                method: "publicationContent",
                arguments: .object(["extensionInstallment": installmentValue])
            )
        )
    }

    public func publicationStream(bookID: String, workID: String) async throws -> MankoPublicationStream {
        try decode(MankoPublicationStream.self, from: await invoke(method: "publicationStream",
            arguments: .object(["installmentId": .string(bookID), "workId": .string(workID)])))
    }

    /// Reuses the broker's cookies, verification, permits, redirects and cooldowns.
    public func streamPublication(_ descriptor: MankoPublicationStream,
        onChunk: @escaping @Sendable (HTTPResponse, Data) async throws -> Void) async throws {
        guard isValid, runtimeConfiguration.entryID == "LNori",
              runtimeConfiguration.permissions.values.contains(.network),
              let url = ExtensionDestinationPolicy.validatedURL(descriptor.url),
              url.host == "lnori.com", url.path == "/book/" + descriptor.id,
              url.query == nil, url.fragment == nil else { throw SourceError.invalidURL }
        let owner = UUID(), nativeID = UUID().uuidString
        guard let request = NativeRequest(body: ["invocationID": owner.uuidString, "id": nativeID,
            "url": descriptor.url, "method": "GET", "headers": descriptor.headers]) else { throw SourceError.invalidURL }
        activeInvocationIDs.insert(owner)
        publicationChunks[owner] = onChunk
        nativeRequestOwners[nativeID] = owner
        defer {
            activeInvocationIDs.remove(owner); publicationChunks[owner] = nil
            nativeRequestOwners[nativeID] = nil; nativeRequestTasks[nativeID] = nil
        }
        let envelope: JSONValue = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                serviceContinuations[nativeID] = continuation
                nativeRequestTasks[nativeID] = Task { await handleRequest(request) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.nativeRequestTasks[nativeID]?.cancel()
                self?.serviceContinuations.removeValue(forKey: nativeID)?.resume(throwing: CancellationError())
            }
        }
        try Task.checkCancellation()
        guard case let .object(result) = envelope else { throw MankoExtensionRuntimeError.invalidPackage }
        if let failure = result["error"], failure != .null {
            throw runtimeError(from: try decode(MankoInvocationError.self, from: failure), invocationID: owner)
        }
        struct Status: Decodable, Sendable { let status: Int }
        let status = try decode(Status.self, from: result["payload"] ?? .null).status
        guard (200..<300).contains(status) else { throw SourceError.unsupportedResponse }
    }

    public func settingsForm() async throws -> JSONValue {
        try await invoke(method: "settings", arguments: .object([:]))
    }

    /// Compatibility entry point for clients that still consume base64 resources.
    public func imagePageContent(at url: URL) async throws -> MankoResource {
        let content = try await imagePageData(at: url)
        return MankoResource(dataBase64: content.data.base64EncodedString(), mimeType: content.mediaType)
    }

    public func imagePageData(
        at url: URL,
        priority: RemoteImageRequestPriority = .cover,
        onProgress: RemoteImageDownloadProgressHandler? = nil,
        onPartial: (@Sendable (RemoteImagePageContent) async -> Void)? = nil
    ) async throws -> RemoteImagePageContent {
        try ExtensionNetworkPolicy(hosts: runtimeConfiguration.allowedHTTPSHosts, serverOrigin: runtimeConfiguration.connection?.baseURL).validate(url)
        try Task.checkCancellation()
        guard isValid else { throw MankoExtensionRuntimeError.runtimeTerminated }
        let reload = SourceCachePolicy.reload, isPrivate = SourceCachePolicy.isPrivate, scope = SourceCachePolicy.scope
        let cachePolicy = ImageCachePolicy(reload: reload, isPrivate: isPrivate, scope: scope,
                                           generation: await ContentCache.shared.writeToken())
        try Task.checkCancellation()
        let waiterID = UUID()
        let requestID = imageRequests.first(where: { $0.value.url == url && $0.value.cachePolicy == cachePolicy })?.key ?? UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError()); return
                }
                if var existing = imageRequests[requestID] {
                    existing.waiters[waiterID] = ImageConsumer(priority: priority, continuation: continuation, onPartial: onPartial, onProgress: onProgress)
                    imageRequests[requestID] = existing
                } else {
                    imageRequests[requestID] = ImageRequest(
                        url: url, cachePolicy: cachePolicy, waiters: [waiterID: ImageConsumer(priority: priority, continuation: continuation, onPartial: onPartial, onProgress: onProgress)]
                    )
                    pendingImageRequests.append(requestID)
                }
                Task { [weak self] in self?.drainImageRequests() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelImageWaiter(waiterID, requestID: requestID) }
        }
    }

    public func setImagePriority(at url: URL, priority: RemoteImageRequestPriority) {
        for id in imageRequests.keys where imageRequests[id]?.url == url {
            guard var request = imageRequests[id] else { continue }
            for waiterID in request.waiters.keys where request.waiters[waiterID]?.priority != .cover {
                request.waiters[waiterID]?.priority = priority
            }
            imageRequests[id] = request
            updateTransportPriority(for: request.invocationID)
        }
    }

    private func updateTransportPriority(for owner: UUID?) {
        guard let owner, let invocation = imageInvocations[owner] else { return }
        let priority = invocation.requestIDs.compactMap { imageRequests[$0]?.priority.rawValue }.max() ?? 0
        Task { await permits.setPriority(priority, owner: owner) }
    }

    private func cancelImageWaiter(_ waiterID: UUID, requestID: UUID) {
        guard var request = imageRequests[requestID],
              let waiter = request.waiters.removeValue(forKey: waiterID) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        if request.waiters.isEmpty {
            imageRequests[requestID] = nil
            pendingImageRequests.removeAll { $0 == requestID }
            if let invocationID = request.invocationID,
               let invocation = imageInvocations[invocationID],
               invocation.requestIDs.allSatisfy({ imageRequests[$0] == nil }) {
                cancelImageInvocation(invocationID)
            }
        } else { imageRequests[requestID] = request }
        updateTransportPriority(for: request.invocationID)
        drainImageRequests()
    }

    private func cancelImageInvocation(_ id: UUID) {
        imageInvocations[id]?.task.cancel()
        cancelInvocation(id)
        nativeImageResources = nativeImageResources.filter { $0.value.invocationID != id }
    }

    private func drainImageRequests() {
        guard isValid else { return }
        let activeCount = imageInvocations.values.reduce(0) { $0 + $1.requestIDs.count }
        var slots = max(0, 4 - activeCount)
        pendingImageRequests.removeAll { imageRequests[$0] == nil }
        pendingImageRequests.sort { imageRequests[$0]!.priority > imageRequests[$1]!.priority }
        while slots > 0, !pendingImageRequests.isEmpty {
            let policy = imageRequests[pendingImageRequests[0]]!.cachePolicy
            let compatibleCount = pendingImageRequests.prefix(while: { imageRequests[$0]?.cachePolicy == policy }).count
            let count = supportsIndependentImages ? 1 : min(slots, compatibleCount)
            let ids = Array(pendingImageRequests.prefix(count))
            pendingImageRequests.removeFirst(count)
            let invocationID = UUID()
            for id in ids { imageRequests[id]?.invocationID = invocationID }
            let urls = ids.map { JSONValue.string(imageRequests[$0]!.url.absoluteString) }
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await SourceCachePolicy.$scope.withValue(policy.scope) {
                        try await SourceCachePolicy.$isPrivate.withValue(policy.isPrivate) {
                            try await SourceCachePolicy.$reload.withValue(policy.reload) {
                                try await invoke(
                                    method: "imagePageContents",
                                    arguments: .object([
                                        "urls": .array(urls),
                                        "requestIDs": .array(ids.map { .string($0.uuidString) })
                                    ]),
                                    invocationID: invocationID, cacheGeneration: policy.generation
                                )
                            }
                        }
                    }
                } catch {
                    for id in ids { finishImageRequest(id, result: .failure(error)) }
                }
                for id in ids where imageRequests[id] != nil {
                    finishImageRequest(id, result: .failure(MankoExtensionRuntimeError.operationFailed("Missing image response.")))
                }
                let transports = nativeRequestOwners.compactMap { key, owner in
                    owner == invocationID ? nativeRequestTasks[key] : nil
                }
                for transport in transports { await transport.value }
                nativeImageResources = nativeImageResources.filter { $0.value.invocationID != invocationID }
                imageInvocations[invocationID] = nil
                drainImageRequests()
            }
            imageInvocations[invocationID] = ImageInvocation(requestIDs: ids, task: task)
            slots -= count
        }
    }

    private func finishImageRequest(_ id: UUID, result: Result<RemoteImagePageContent, Error>) {
        guard let request = imageRequests.removeValue(forKey: id) else { return }
        for waiter in request.waiters.values { waiter.continuation.resume(with: result) }
    }

    private func deliverPartialImage(_ data: Data, mediaType: String?, invocationID: UUID, url: URL) async {
        // Only native, untransformed image resources reach this path. Response
        // interceptors and verified-browser transports still deliver final data.
        let callbacks = imageRequests.values.filter { $0.invocationID == invocationID && $0.url == url }
            .flatMap { $0.waiters.values }.filter { $0.priority == .visible }.compactMap(\.onPartial)
        for callback in callbacks { await callback(.init(data: data, mediaType: mediaType)) }
    }

    private func deliverImageProgress(_ progress: RemoteImageDownloadProgress, invocationID: UUID, url: URL) async {
        let callbacks = imageRequests.values.filter { $0.invocationID == invocationID && $0.url == url }
            .flatMap { $0.waiters.values }.compactMap(\.onProgress)
        for callback in callbacks { await callback(progress) }
    }

    private func receiveImageResult(_ body: Any) {
        guard let body = body as? [String: Any],
              let rawID = body["requestID"] as? String, let id = UUID(uuidString: rawID),
              let request = imageRequests[id], let owner = request.invocationID,
              body["invocationID"] as? String == owner.uuidString,
              let envelope = body["envelope"] else { return }
        do {
            let encoded = try JSONSerialization.data(withJSONObject: envelope)
            let result = try JSONDecoder().decode(MankoInvocationEnvelope.self, from: encoded)
            guard result.ok else { throw runtimeError(from: result.error, invocationID: owner) }
            let resource = try decode(ImageResourceEnvelope.self, from: result.value ?? .null)
            let content: RemoteImagePageContent
            if let resourceID = resource.resourceID {
                guard let stored = nativeImageResources[resourceID], stored.invocationID == owner else {
                    throw MankoExtensionRuntimeError.operationFailed("Invalid or expired image resource.")
                }
                nativeImageResources[resourceID] = nil
                content = stored.content
            } else {
                guard let base64 = resource.dataBase64, let bytes = Data(base64Encoded: base64) else {
                    throw MankoExtensionRuntimeError.operationFailed("Invalid image data.")
                }
                content = RemoteImagePageContent(data: bytes, mediaType: resource.mimeType)
            }
            guard !content.data.isEmpty, content.data.count <= 16 * 1_024 * 1_024 else {
                throw MankoExtensionRuntimeError.responseTooLarge
            }
            finishImageRequest(id, result: .success(content))
        } catch { finishImageRequest(id, result: .failure(error)) }
    }

    private struct ImageResourceEnvelope: Decodable {
        let resourceID: String?
        let dataBase64: String?
        let mimeType: String?
    }

    public func invalidateContentCache() async throws {
        cacheConfigurationRevision = UUID()
        try await stateStore.set(try JSONEncoder().encode(cacheConfigurationRevision.uuidString),
            key: "__manko_metadata_epoch", namespace: runtimeConfiguration.namespace, authorization: storageWriteAuthorization)
        cacheSettingsIdentity = nil
        for key in metadataKeys { await ContentCache.shared.remove(key) }
        metadataKeys.removeAll()
        _ = try await invoke(method: "invalidateCache", arguments: .object([:]))
    }

    public func searchFilters() async throws -> JSONValue {
        try await invoke(method: "searchFilters", arguments: .object([:]))
    }

    public func searchSuggestions(
        _ request: SourceSearchSuggestionRequest
    ) async throws -> JSONValue {
        try await invoke(
            method: "searchSuggestions",
            arguments: try Self.jsonValue(request),
            timeout: min(runtimeConfiguration.searchOperationTimeout, .seconds(10))
        )
    }

    public func updates(since: String?, cursor: JSONValue?) async throws -> JSONValue {
        try await invoke(method: "updates", arguments: .object([
            "since": since.map(JSONValue.string) ?? .null,
            "cursor": cursor ?? .null,
        ]))
    }

    public func managedCollections(cursor: JSONValue?) async throws -> JSONValue {
        try await invoke(method: "managedCollections", arguments: .object(["cursor": cursor ?? .null]))
    }

    public func synchronizeManagedCollection(_ collection: JSONValue) async throws {
        _ = try await invoke(method: "synchronizeManagedCollection", arguments: .object(["collection": collection]))
    }

    public func trackerOperation(_ method: String, arguments: JSONValue = .object([:])) async throws -> JSONValue {
        let allowed = Set(["authentication", "trackerSearch", "progress", "progressBatch", "update", "collections", "trackingCapabilities"])
        guard allowed.contains(method) else {
            throw MankoExtensionRuntimeError.operationFailed("Unsupported tracker operation.")
        }
        return try await invoke(method: method, arguments: arguments)
    }

    public func invalidate() {
        invalidate(cancelInitialization: true)
    }

    private func invalidate(cancelInitialization: Bool) {
        guard isValid else { return }
        isValid = false
        for invocation in imageInvocations.values { invocation.task.cancel() }
        imageInvocations.removeAll()
        nativeImageResources.removeAll()
        pendingImageRequests.removeAll()
        let images = imageRequests.values
        imageRequests.removeAll()
        for image in images {
            for waiter in image.waiters.values { waiter.continuation.resume(throwing: MankoExtensionRuntimeError.runtimeTerminated) }
        }
        isInitialized = false
        // Internal failures must reach the initialization race as their original
        // error. Cancelling its caller here would replace that error with cancellation.
        if cancelInitialization { initializationTask?.cancel() }
        initializationTask = nil
        for task in nativeRequestTasks.values { task.cancel() }
        nativeRequestTasks.removeAll()
        nativeRequestOwners.removeAll()
        for continuation in serviceContinuations.values {
            continuation.resume(throwing: MankoExtensionRuntimeError.runtimeTerminated)
        }
        serviceContinuations.removeAll()
        activeInvocationIDs.removeAll()
        catalogProgressHandlers.removeAll()
        brokerObservedCloudflareContexts.removeAll()
        Task { await wasm.invalidate() }
        verifiedBrowserTransport?.invalidate()
        verifiedBrowserTransport = nil
    }

    /// Used by staged package validation. Revocation happens inside each
    /// storage actor before deletion, so a delayed initializer write cannot
    /// recreate state after the staged runtime is discarded.
    func discardPersistentState() async throws {
        invalidate()
        try await stateStore.revokeAndReset(storageWriteAuthorization)
        try await secureStateStore.revokeAndRemove(storageWriteAuthorization)
    }

    private func invoke(
        method: String,
        arguments: JSONValue,
        timeout: Duration? = nil,
        catalogProgress: (@MainActor @Sendable (JSONValue) async throws -> Void)? = nil,
        receive: (@MainActor (JSONValue, UUID) throws -> Void)? = nil,
        invocationID: UUID = UUID(),
        cacheGeneration requestedCacheGeneration: UUID? = nil
    ) async throws -> JSONValue {
        try Task.checkCancellation()
        guard isValid else { throw MankoExtensionRuntimeError.runtimeTerminated }
#if DEBUG
        let auditStart = ContinuousClock.now
        defer {
            if ProcessInfo.processInfo.environment["MANKO_PERFORMANCE_RUN"] != nil {
                print("SourcePerformanceStage method=\(method) stage=invocation elapsed=\(auditStart.duration(to: .now))")
            }
        }
#endif
        let cacheGeneration: UUID
        if let requestedCacheGeneration { cacheGeneration = requestedCacheGeneration }
        else { cacheGeneration = await ContentCache.shared.writeToken() }
        if scriptCacheIdentity == nil { scriptCacheIdentity = (try? Data(contentsOf: runtimeConfiguration.scriptURL)).map { ContentCache.key([$0.base64EncodedString()]) } ?? runtimeConfiguration.scriptURL.lastPathComponent }
        let scriptIdentity = scriptCacheIdentity!
        if cacheSettingsIdentity == nil {
        let ordinary = (try? await stateStore.values(namespace: runtimeConfiguration.namespace)) ?? [:]
        let secureValues = (try? await secureStateStore.values(namespace: runtimeConfiguration.namespace)) ?? [:]
        let secure = secureValues.filter { !["cookie_store_cookies", ExtensionBrowserSessionProfile.secureStateKey, CloudflareChallengeContext.pendingSecureStateKey].contains($0.key) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        cacheSettingsIdentity = ContentCache.key([(try? encoder.encode(ordinary).base64EncodedString()) ?? "", (try? encoder.encode(secure).base64EncodedString()) ?? ""])
        }
        let settingsIdentity = cacheSettingsIdentity!
        try Task.checkCancellation()
        guard isValid else { throw MankoExtensionRuntimeError.runtimeTerminated }
        cacheInvocations[invocationID] = CacheInvocation(
            searchCoordinator: SourceCachePolicy.searchCoordinator,
            isSuggestion: method == "searchSuggestions",
            isCatalog: ["discoverSections", "discover", "search", "searchFilters", "searchSuggestions"].contains(method),
            configurationRevision: cacheConfigurationRevision,
            scope: ContentCache.key([runtimeConfiguration.namespace, runtimeConfiguration.entryID, scriptIdentity, settingsIdentity, SourceCachePolicy.scope ?? "direct"]),
            reload: SourceCachePolicy.reload, isPrivate: SourceCachePolicy.isPrivate, generation: cacheGeneration,
            freshness: SourceCachePolicy.freshness)
        activeInvocationIDs.insert(invocationID)
        catalogProgressHandlers[invocationID] = catalogProgress
        invocationMethods[invocationID] = method
        invocationContexts[invocationID] = .init(sourceID: runtimeConfiguration.entryID, operation: method)
        let signpostID = OSSignpostID(log: Self.performanceLog)
        os_signpost(.begin, log: Self.performanceLog, name: "Source Operation", signpostID: signpostID)

        do {
            let race = MankoOperationRace(sleep: operationSleep)
            let string = try await race.run(
                timeout: timeout ?? runtimeConfiguration.operationTimeout,
                operation: { [weak self] in
                    guard let self, self.isValid else { throw MankoExtensionRuntimeError.runtimeTerminated }
                    let result = try await executeWasm(method: method, arguments: arguments, owner: invocationID)
                    return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
                },
                onTimeout: { [weak self] in
                    self?.reportInvocationTimeout(invocationID)
                    self?.cancelInvocation(invocationID)
                },
                onCancellation: { [weak self] in
                    // Every operation can await a broker promise. Reject owned
                    // guest continuations as well as native work so its queue can advance.
                    self?.cancelInvocation(invocationID)
                }
            )
            if let failure = cacheInvocations[invocationID]?.catalogFailure { throw failure }
            guard string.utf8.count <= Self.maximumInvocationEnvelopeBytes * (method == "imagePageContents" ? 4 : 1) else {
                throw MankoExtensionRuntimeError.responseTooLarge
            }
            guard let data = string.data(using: .utf8) else {
                throw MankoExtensionRuntimeError.operationFailed("The source returned invalid JSON.")
            }
            let envelope: MankoInvocationEnvelope
            do {
                envelope = try JSONDecoder().decode(MankoInvocationEnvelope.self, from: data)
            } catch {
                throw MankoExtensionRuntimeError.operationFailed("The source returned an invalid operation envelope.")
            }
            if envelope.ok {
                if method == "imagePageContents", case let .array(results) = envelope.value {
                    for item in results {
                        guard case var .object(object) = item else { continue }
                        object["invocationID"] = .string(invocationID.uuidString)
                        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONValue.object(object)))
                        receiveImageResult(body)
                    }
                }
                try receive?(envelope.value ?? .null, invocationID)
                os_signpost(
                    .end,
                    log: Self.performanceLog,
                    name: "Source Operation",
                    signpostID: signpostID,
                    "success"
                )
                await finishInvocation(invocationID)
                return envelope.value ?? .null
            }
            throw runtimeError(from: envelope.error, invocationID: invocationID)
        } catch {
            await finishInvocation(invocationID)
            if error is CancellationError {
                os_signpost(
                    .end,
                    log: Self.performanceLog,
                    name: "Source Operation",
                    signpostID: signpostID,
                    "cancel"
                )
            } else {
                os_signpost(
                    .end,
                    log: Self.performanceLog,
                    name: "Source Operation",
                    signpostID: signpostID,
                    "failure"
                )
            }
            if error is CancellationError { throw error }
            if let sourceError = error as? SourceError { throw sourceError }
            if let runtimeError = error as? MankoExtensionRuntimeError { throw runtimeError }
            throw MankoExtensionRuntimeError.operationFailed(error.localizedDescription)
        }
    }

    private func reportInvocationTimeout(_ id: UUID) {
        guard let context = invocationContexts[id] else { return }
        let elapsed = String(describing: context.startedAt.duration(to: .now))
        Self.runtimeLogger.notice("source=\(context.sourceID, privacy: .public) operation=\(context.operation, privacy: .public) invocation=\(id.uuidString, privacy: .public) elapsed=\(elapsed, privacy: .public) WASM execution limit: wallClock")
    }

    @discardableResult
    private func cancelInvocation(_ id: UUID) -> Task<Void, Never>? {
        if let cleanup = invocationCleanups[id] { return cleanup }
        // Revoke native callbacks before any suspension or guest cancellation.
        guard activeInvocationIDs.remove(id) != nil else { return nil }
        catalogProgressHandlers[id] = nil
        var pools: [MankoRequestPermitPool] = []
        for key in metadataLoadOwners.keys where metadataLoadOwners[key] == id {
            metadataLoadOwners[key] = nil
            if let pool = metadataLoadPermits[key] { pools.append(pool) }
            releaseMetadataUser(key)
        }
        for requestID in nativeRequestOwners.keys where nativeRequestOwners[requestID] == id {
            nativeRequestTasks[requestID]?.cancel()
            serviceContinuations.removeValue(forKey: requestID)?.resume(throwing: CancellationError())
        }
        let context = invocationContexts[id]
        // This task deliberately has its own cancellation lifetime: even a
        // cancelled caller must finish guest cleanup before removing its budget.
        let cleanup = Task { [self] in
            for pool in pools { await pool.release() }
            do { try await wasm.cancelAndFinish(id, context: context) }
            catch { invalidate(cancelInitialization: false) }
        }
        invocationCleanups[id] = cleanup
        return cleanup
    }

    private func finishInvocation(_ id: UUID) async {
        let cleanup = cancelInvocation(id)
        await cleanup?.value
        invocationCleanups[id] = nil
        invocationMethods[id] = nil
        invocationContexts[id] = nil
        cacheInvocations[id] = nil
        brokerObservedCloudflareContexts[id] = nil
    }

    private func releaseMetadataUser(_ key: String) {
        let count = metadataLoadUsers[key, default: 1] - 1
        if count == 0 {
            metadataLoadUsers[key] = nil
            metadataLoadPermits[key] = nil
        } else { metadataLoadUsers[key] = count }
    }

    private func runtimeError(
        from descriptor: MankoInvocationError?,
        invocationID: UUID
    ) -> MankoExtensionRuntimeError {
        guard let descriptor else {
            return .operationFailed("The source operation failed without an error description.")
        }
        switch descriptor.code {
        case "undeclaredHost":
            return .undeclaredHost(descriptor.host ?? "unknown")
        case "responseTooLarge":
            return .responseTooLarge
        case "webExecutionDenied":
            return .webExecutionDenied
        case "webExecutionTimedOut":
            return .webExecutionTimedOut
        case "webExecutionResultTooLarge":
            return .webExecutionResultTooLarge
        case "runtimeTerminated":
            return .runtimeTerminated
        case "cloudflareHandoff":
            return cloudflareHandoff(from: descriptor.url, invocationID: invocationID)
        default:
            break
        }
        if descriptor.type == "challengeRequired" || descriptor.name == "ChallengeRequiredError" {
            return cloudflareHandoff(from: descriptor.url, invocationID: invocationID)
        }
        if let stack = descriptor.stack, !stack.isEmpty {
            Self.runtimeLogger.debug("Extension error stack: \(stack, privacy: .private)")
        }
        let message = descriptor.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message, !message.isEmpty {
            if let name = descriptor.name,
               !name.isEmpty,
               !["Error", "ThrownValue", "MankoExtensionRuntimeError"].contains(name) {
                return .operationFailed(MankoRuntimeText.boundedUTF8("\(name): \(message)", maximumBytes: 2 * 1_024))
            }
            return .operationFailed(MankoRuntimeText.boundedUTF8(message, maximumBytes: 2 * 1_024))
        }
        if let name = descriptor.name, !name.isEmpty {
            return .operationFailed(MankoRuntimeText.boundedUTF8(name, maximumBytes: 128))
        }
        return .operationFailed("The source operation failed.")
    }

    private func cloudflareHandoff(
        from rawURL: String?,
        invocationID: UUID
    ) -> MankoExtensionRuntimeError {
        let explicitURL = validatedHandoffURL(rawURL)
        let observed = brokerObservedCloudflareContexts[invocationID] ?? []

        // Promote browser-host authorization only when the final error URL
        // exactly matches a challenge response observed by native networking
        // during this invocation. The guest can copy a URL, but it cannot add
        // a host that the broker did not actually observe challenging.
        if let explicitURL,
           let context = observed.first(where: { $0.url == explicitURL })
        {
            lastCloudflareHandoffURL = context.url
            return .cloudflareHandoff(context)
        }
        if rawURL == nil {
            let uniqueObserved = Set(observed)
            if uniqueObserved.count == 1, let context = uniqueObserved.first {
                lastCloudflareHandoffURL = context.url
                return .cloudflareHandoff(context)
            }
        }

        // The guest supplies only the URL recorded during this
        // invocation. Never fall back to a prior operation's challenge URL.
        lastCloudflareHandoffURL = explicitURL
        return .cloudflareHandoff(cloudflareContext(url: explicitURL))
    }

    private func cloudflareContext(url: URL?) -> CloudflareChallengeContext {
        CloudflareChallengeContext(
            url: url,
            namespace: runtimeConfiguration.namespace,
            permittedBrowserHosts: runtimeConfiguration.allowedHTTPSHosts
        )
    }

    private func brokerObservedCloudflareContext(url: URL) -> CloudflareChallengeContext {
        CloudflareChallengeContext.brokerObserved(
            url: url,
            namespace: runtimeConfiguration.namespace,
            permittedBrowserHosts: runtimeConfiguration.allowedHTTPSHosts
        )
    }

    private func recordBrokerObservedCloudflareContext(
        _ context: CloudflareChallengeContext,
        invocationID: UUID
    ) {
        guard activeInvocationIDs.contains(invocationID) else { return }
        var contexts = brokerObservedCloudflareContexts[invocationID] ?? []
        if !contexts.contains(context) {
            contexts.append(context)
        }
        brokerObservedCloudflareContexts[invocationID] = contexts
    }

    private func validatedHandoffURL(_ rawURL: String?) -> URL? {
        guard let rawURL else { return nil }
        guard let url = ExtensionDestinationPolicy.validatedURL(rawURL),
              ExtensionNetworkPolicy(hosts: runtimeConfiguration.allowedHTTPSHosts).allows(url) else { return nil }
        return url
    }

    private func decode<Value: Decodable & Sendable>(
        _ type: Value.Type,
        from value: JSONValue
    ) throws -> Value {
        return try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    private func acquireRequestPermit(priority: Int, invocationID: UUID) async throws {
        guard (cacheInvocations[invocationID]?.isCatalog == true || publicationChunks[invocationID] != nil), let gate = catalogRequestGate else {
            try await permits.acquire(priority: priority, owner: invocationID)
            return
        }
        // Pacing waiters do not occupy the image/reader transport slots. Keep
        // catalog starts serialized until a transport permit is actually ready.
        try await catalogStartPermits.acquire(owner: invocationID)
        do {
            try await gate.waitForStart(failDuringCooldown: true, reservesStart: false)
            try await permits.acquire(priority: priority, owner: invocationID)
            gate.recordStart()
            await catalogStartPermits.release()
        } catch {
            await catalogStartPermits.release()
            throw error
        }
    }

    private func handleRequest(_ request: NativeRequest) async {
        guard isValid, activeInvocationIDs.contains(request.invocationID) else { return }
        do {
            if request.wantsImageResource, imageInvocations[request.invocationID] == nil {
                throw MankoExtensionRuntimeError.operationFailed("Native image resources require an active image request.")
            }
            guard let url = ExtensionDestinationPolicy.validatedURL(request.url) else {
                throw MankoExtensionRuntimeError.operationFailed("The source used an invalid HTTP URL.")
            }
            guard let method = HTTPMethod(rawValue: request.method.uppercased()) else {
                throw MankoExtensionRuntimeError.operationFailed("The source used an unsupported HTTP method.")
            }
            guard runtimeConfiguration.permissions.values.contains(.network), !runtimeConfiguration.offlineValidation else { throw ExtensionSecurityError.approvalRequired }
            let policy = ExtensionNetworkPolicy(hosts: runtimeConfiguration.allowedHTTPSHosts, serverOrigin: runtimeConfiguration.connection?.baseURL)
            guard policy.allows(url) else { throw ExtensionSecurityError.denied(url.host ?? "unknown") }
            let connection = runtimeConfiguration.connection
            if let connection {
                try EndpointPolicy().validate(url, access: connection.endpointAccess)
                guard SourceRequestAuthorizer.isSameOrigin(url, as: connection.baseURL) else {
                    throw MankoExtensionRuntimeError.operationFailed("The connector requested a different server origin.")
                }
            }
            var headers = request.headers.filter {
                !["authorization", "cookie", "proxy-authorization", "host", "connection", "transfer-encoding"].contains($0.key.lowercased())
            }
            if request.authenticated {
                guard runtimeConfiguration.permissions.values.contains(.authenticationHandoff),
                      let account = runtimeConfiguration.accountPolicy,
                      let operation = invocationMethods[request.invocationID],
                      account.permits(url, method: method.rawValue, operation: operation, body: request.bodyBase64.flatMap { Data(base64Encoded: $0) }),
                      operation != "update" || runtimeConfiguration.permissions.values.contains(.trackerUpdates),
                      let data = try await secureStateStore.value(namespace: runtimeConfiguration.namespace, key: "__native_oauth_access_token"),
                      let token = try? JSONDecoder().decode(String.self, from: data), !token.isEmpty
                else { throw SourceError.unauthorized }
                headers["Authorization"] = "Bearer " + token
            }
            if let connection {
                let nativeHeaders = try await SourceRequestAuthorizer().headers(
                    for: connection, credentialLoader: runtimeConfiguration.credentialLoader,
                    accepting: headers.first { $0.key.caseInsensitiveCompare("Accept") == .orderedSame }?.value ?? "application/json"
                )
                for (name, value) in nativeHeaders {
                    headers = headers.filter { $0.key.caseInsensitiveCompare(name) != .orderedSame }
                    headers[name] = value
                }
            }
            ["Host", "Connection", "Transfer-Encoding", "Proxy-Authorization"].forEach { forbidden in
                headers = headers.filter { $0.key.caseInsensitiveCompare(forbidden) != .orderedSame }
            }
            let allStoredCookies = runtimeConfiguration.permissions.values.contains(.cookies) ? await persistedCookies() : []
            let storedCookies = allStoredCookies.filter { $0.isApplicable(to: url) }
            let explicitCookieHeader = headers.first {
                $0.key.caseInsensitiveCompare("Cookie") == .orderedSame
            }?.value
            var extensionCookieValues: [String: String] = [:]
            for pair in Self.cookiePairs(from: explicitCookieHeader) {
                extensionCookieValues[pair.name] = pair.value
            }

            if !storedCookies.isEmpty || !request.cookies.isEmpty {
                headers = headers.filter { $0.key.caseInsensitiveCompare("Cookie") != .orderedSame }
                var cookieValues = extensionCookieValues
                var appliedPersistedClearance = false
                for cookie in storedCookies.sorted(by: { $0.path.count > $1.path.count }) {
                    if cookie.name.caseInsensitiveCompare("cf_clearance") == .orderedSame {
                        // The broker's dictionary representation can carry one
                        // value for a cookie name. Keep the first (longest-path)
                        // applicable clearance instead of letting a later root
                        // cookie overwrite the more specific verified value.
                        guard !appliedPersistedClearance else { continue }
                        for name in cookieValues.keys.filter({
                            $0.caseInsensitiveCompare("cf_clearance") == .orderedSame
                        }) {
                            cookieValues[name] = nil
                        }
                        cookieValues[cookie.name] = cookie.value
                        appliedPersistedClearance = true
                    } else if cookieValues[cookie.name] == nil {
                        cookieValues[cookie.name] = cookie.value
                    }
                }
                if !cookieValues.isEmpty {
                    headers["Cookie"] = cookieValues.sorted { $0.key < $1.key }
                        .map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
                }
            }
            if let browserSessionProfile,
               browserSessionProfile.matchesOrigin(of: url) {
                headers = headers.filter { $0.key.caseInsensitiveCompare("User-Agent") != .orderedSame }
                headers["User-Agent"] = browserSessionProfile.userAgent
            }
            let redirectIdentity = browserSessionProfile.map { profile in
                var identityCookies = allStoredCookies
                    .filter { $0.isValidForOrigin(profile.canonicalHTTPSOrigin) }
                    .map {
                        HTTPRedirectCookie(
                            name: $0.name,
                            value: $0.value,
                            path: $0.path,
                            secure: $0.secure
                        )
                    }
                // Cookies explicitly supplied for a request already on the
                // verified origin are safe to retain through that origin's
                // redirects. Never carry source-origin cookies into a
                // different verified redirect host.
                if profile.matchesOrigin(of: url) {
                    for (name, value) in extensionCookieValues
                    where name.caseInsensitiveCompare("cf_clearance") != .orderedSame {
                        identityCookies.removeAll {
                            $0.name.caseInsensitiveCompare(name) == .orderedSame
                        }
                        identityCookies.append(HTTPRedirectCookie(
                            name: name,
                            value: value,
                            path: "/",
                            secure: true
                        ))
                    }
                }
                return HTTPRedirectIdentity(
                    origin: profile.canonicalHTTPSOrigin,
                    userAgent: profile.userAgent,
                    cookies: identityCookies
                )
            }
            let body = request.bodyBase64.flatMap { Data(base64Encoded: $0) }
            guard (body?.count ?? 0) <= 16 * 1_024 * 1_024 else {
                throw MankoExtensionRuntimeError.responseTooLarge
            }
            let queueSignpost = OSSignpostID(log: Self.performanceLog)
            if let invocation = cacheInvocations[request.invocationID], let budget = invocation.searchCoordinator {
                cacheInvocations[request.invocationID]?.searchTransportCount += 1
                try await budget.waitForTransport(isFallback: invocation.isSuggestion && invocation.searchTransportCount > 0)
            }
            os_signpost(.begin, log: Self.performanceLog, name: "HTTP Queue", signpostID: queueSignpost)
            let imagePriority = imageInvocations[request.invocationID]?.requestIDs
                .compactMap { imageRequests[$0]?.priority.rawValue }.max() ?? 0
            do {
                try await acquireRequestPermit(priority: imagePriority, invocationID: request.invocationID)
            }
            catch {
                os_signpost(.end, log: Self.performanceLog, name: "HTTP Queue", signpostID: queueSignpost)
                throw error
            }
            os_signpost(.end, log: Self.performanceLog, name: "HTTP Queue", signpostID: queueSignpost)
            let networkSignpost = OSSignpostID(log: Self.performanceLog)
            os_signpost(.begin, log: Self.performanceLog, name: "HTTP Transfer", signpostID: networkSignpost)
            let response: HTTPResponse
            var verifiedBrowserCookies: [ExtensionHTTPStateCookie] = []
            do {
                try Task.checkCancellation()
                guard isValid, activeInvocationIDs.contains(request.invocationID) else { throw CancellationError() }
                if body == nil,
                   ExtensionVerifiedBrowserRequestPolicy.permits(
                       url: url,
                       method: method,
                       permissions: runtimeConfiguration.permissions,
                       profile: browserSessionProfile
                   ),
                   let profile = browserSessionProfile {
                    let transport: any ExtensionVerifiedBrowserTransport
                    if let existing = verifiedBrowserTransport {
                        transport = existing
                    } else {
                        let created = ExtensionVerifiedBrowserWebKitTransport(
                            namespace: runtimeConfiguration.namespace
                        )
                        verifiedBrowserTransport = created
                        transport = created
                    }
                    do {
                        let result = try await transport.response(
                            for: ExtensionVerifiedBrowserRequest(
                                url: url,
                                method: method,
                                headers: headers
                            ),
                            profile: profile,
                            cookies: allStoredCookies
                        )
                        response = result.response
                        verifiedBrowserCookies = result.cookies
                        if let consumer = publicationChunks[request.invocationID], (200..<300).contains(response.statusCode) {
                            try await consumer(response, response.data)
                        }
                    } catch ExtensionVerifiedBrowserTransportError.requiresForeground {
                        let context = brokerObservedCloudflareContext(url: url)
                        recordBrokerObservedCloudflareContext(
                            context,
                            invocationID: request.invocationID
                        )
                        lastCloudflareHandoffURL = url
                        throw MankoExtensionRuntimeError.cloudflareHandoff(context)
                    } catch ExtensionVerifiedBrowserTransportError.responseTooLarge {
                        throw MankoExtensionRuntimeError.responseTooLarge
                    } catch ExtensionVerifiedBrowserTransportError.redirectNotAllowed {
                        throw MankoExtensionRuntimeError.operationFailed(
                            "The verified browser request attempted a redirect outside its exact request."
                        )
                    } catch ExtensionVerifiedBrowserTransportError.invalidRequest {
                        throw MankoExtensionRuntimeError.operationFailed(
                            "The verified browser request was invalid."
                        )
                    } catch ExtensionVerifiedBrowserTransportError.invalidResponse {
                        throw MankoExtensionRuntimeError.operationFailed(
                            "The verified browser request failed."
                        )
                    }
                } else {
                    var partial: (@Sendable (Data, String?) async -> Void)?
                    let hasPreviewConsumer = imageInvocations[request.invocationID]?.requestIDs.contains { id in
                        imageRequests[id]?.waiters.values.contains { $0.priority == .visible && $0.onPartial != nil } == true
                    } == true
                    if request.wantsImageResource, hasPreviewConsumer {
                        partial = { @Sendable [weak self] data, mime in
                            await self?.deliverPartialImage(data, mediaType: mime, invocationID: request.invocationID, url: url)
                        }
                    }
                    // Subscribe for prefetch too: promotion to visible must retain
                    // the same transfer and its progress reporting.
                    var progress: RemoteImageDownloadProgressHandler?
                    let hasProgressConsumer = imageInvocations[request.invocationID]?.requestIDs.contains { id in
                        imageRequests[id]?.waiters.values.contains { $0.onProgress != nil } == true
                    } == true
                    if request.wantsImageResource, hasProgressConsumer {
                        progress = { @Sendable [weak self] value in
                            await self?.deliverImageProgress(value, invocationID: request.invocationID, url: url)
                        }
                    }
                    response = try await httpClient.response(
                        for: HTTPRequest(
                            url: url,
                            method: method,
                            headers: headers,
                            body: body,
                            endpointAccess: connection?.endpointAccess ?? ExtensionDestinationPolicy.endpointAccess,
                            credentialOrigin: connection?.baseURL,
                            allowedHTTPSHosts: connection == nil ? runtimeConfiguration.allowedHTTPSHosts : nil,
                            cachePartition: runtimeConfiguration.namespace,
                            redirectIdentity: redirectIdentity,
                            usesConditionalCache: false,
                            networkPolicy: policy,
                            followsRedirects: !request.authenticated,
                            statusPolicy: .returnResponse
                        ),
                        onProgress: progress,
                        onPartialImage: partial,
                        onChunk: publicationChunks[request.invocationID]
                    )
                }
            } catch {
                await permits.release()
                os_signpost(.end, log: Self.performanceLog, name: "HTTP Transfer", signpostID: networkSignpost)
                throw error
            }
            await permits.release()
            os_signpost(.end, log: Self.performanceLog, name: "HTTP Transfer", signpostID: networkSignpost)
            if response.statusCode == 429 {
                if cacheInvocations[request.invocationID]?.isCatalog == true || publicationChunks[request.invocationID] != nil {
                    catalogRequestGate?.reportRateLimit(retryAfter: response.header("Retry-After"))
                }
                if catalogRequestGate == nil || cacheInvocations[request.invocationID]?.isCatalog != true {
                    cacheInvocations[request.invocationID]?.searchCoordinator?.reportRateLimit(retryAfter: response.header("Retry-After"))
                }
            }
            try Task.checkCancellation()
            guard isValid, activeInvocationIDs.contains(request.invocationID) else { throw CancellationError() }
            guard response.data.count <= 16 * 1_024 * 1_024 else {
                throw MankoExtensionRuntimeError.responseTooLarge
            }
            if verifiedBrowserCookies.isEmpty {
                try await persistCookies(from: response)
            } else {
                try await persistCookies(
                    verifiedBrowserCookies,
                    for: response.url
                )
            }
            if ExtensionVerifiedBrowserResponsePolicy.isCloudflareChallenge(response) {
                let context = brokerObservedCloudflareContext(url: response.url)
                recordBrokerObservedCloudflareContext(
                    context,
                    invocationID: request.invocationID
                )
                lastCloudflareHandoffURL = response.url
                throw MankoExtensionRuntimeError.cloudflareHandoff(context)
            }
            if response.statusCode == 429, let catalogRequestGate,
               (cacheInvocations[request.invocationID]?.isCatalog == true || publicationChunks[request.invocationID] != nil) {
                let failure = SourceError.rateLimited(retryAfterSeconds: min(ceil(catalogRequestGate.retryAfterSeconds), 86_400))
                cacheInvocations[request.invocationID]?.catalogFailure = failure
                throw failure
            }
            let deliverySignpost = OSSignpostID(log: Self.performanceLog)
            os_signpost(.begin, log: Self.performanceLog, name: "HTTP Bridge Delivery", signpostID: deliverySignpost)
            defer { os_signpost(.end, log: Self.performanceLog, name: "HTTP Bridge Delivery", signpostID: deliverySignpost) }
            var payload: [String: Any] = [
                "url": response.url.absoluteString,
                "status": response.statusCode,
                "headers": response.headers.filter { !["set-cookie", "set-cookie2", "authorization", "proxy-authorization"].contains($0.key.lowercased()) },
                "mimeType": response.header("Content-Type").map { $0 as Any } ?? NSNull(),
                "cookies": [] as [String],
            ]
            let mimeType = response.header("Content-Type")?.split(separator: ";").first?.lowercased()
            if request.wantsImageResource, (200..<300).contains(response.statusCode),
               mimeType?.hasPrefix("image/") == true {
                guard imageInvocations[request.invocationID] != nil,
                      imageInvocations[request.invocationID]?.requestIDs.contains(where: { imageRequests[$0] != nil }) == true,
                      nativeImageResources.count < 16 else { throw CancellationError() }
                let resourceID = UUID().uuidString
                nativeImageResources[resourceID] = NativeImageResource(
                    invocationID: request.invocationID,
                    content: RemoteImagePageContent(data: response.data, mediaType: mimeType)
                )
                payload["resourceID"] = resourceID
            } else if publicationChunks[request.invocationID] == nil { payload["dataBase64"] = response.data.base64EncodedString() }
            try await resolveRequest(id: request.id, payload: payload, error: nil)
        } catch {
            if let failure = error as? SourceError, cacheInvocations[request.invocationID]?.isCatalog == true {
                cacheInvocations[request.invocationID]?.catalogFailure = failure
            }
            guard !Task.isCancelled else { return }
            try? await resolveRequest(
                id: request.id,
                payload: nil,
                error: Self.bridgeErrorDescriptor(for: error)
            )
        }
    }

    private static func bridgeErrorDescriptor(for error: Error) -> [String: Any] {
        var code = "nativeRequestFailed"
        var name = String(describing: type(of: error))
        var message = error.localizedDescription
        var url: String?
        var host: String?

        if let runtimeError = error as? MankoExtensionRuntimeError {
            name = "MankoExtensionRuntimeError"
            switch runtimeError {
            case .sourceUnavailable:
                code = "sourceUnavailable"
            case .invalidPackage:
                code = "invalidPackage"
            case let .initializationFailed(value):
                code = "initializationFailed"
                message = value
            case let .operationFailed(value):
                code = "operationFailed"
                message = value
            case .operationTimedOut:
                code = "operationTimedOut"
            case .executionBudgetExceeded:
                code = "executionBudgetExceeded"
            case .heartbeatLost:
                code = "heartbeatLost"
            case .runtimeTerminated:
                code = "runtimeTerminated"
            case let .undeclaredHost(value):
                code = "undeclaredHost"
                host = value
            case .responseTooLarge:
                code = "responseTooLarge"
            case .webExecutionDenied:
                code = "webExecutionDenied"
            case .webExecutionTimedOut:
                code = "webExecutionTimedOut"
            case .webExecutionResultTooLarge:
                code = "webExecutionResultTooLarge"
            case let .cloudflareHandoff(context):
                code = "cloudflareHandoff"
                url = context.url?.absoluteString
            }
        }

        var descriptor: [String: Any] = [
            "code": MankoRuntimeText.boundedUTF8(code, maximumBytes: 128),
            "name": MankoRuntimeText.boundedUTF8(name, maximumBytes: 128),
            "message": MankoRuntimeText.boundedUTF8(message, maximumBytes: 2 * 1_024),
        ]
        if let url {
            descriptor["url"] = MankoRuntimeText.boundedUTF8(url, maximumBytes: 2 * 1_024)
        }
        if let host {
            descriptor["host"] = MankoRuntimeText.boundedUTF8(host, maximumBytes: 128)
        }
        return descriptor
    }


    private static func cookies(from response: HTTPResponse) -> [[String: Any]] {
        HTTPCookie.cookies(withResponseHeaderFields: response.headers, for: response.url).map { cookie in
            var value: [String: Any] = [
                "name": cookie.name,
                "value": cookie.value,
                "domain": cookie.domain,
                "path": cookie.path,
                "secure": cookie.isSecure,
                "httpOnly": cookie.isHTTPOnly,
                "hostOnly": hostOnly(cookie: cookie, response: response),
            ]
            if let expiresDate = cookie.expiresDate {
                value["expires"] = expiresDate.ISO8601Format()
            }
            return value
        }
    }

    private static func cookies(
        from cookies: [ExtensionHTTPStateCookie]
    ) -> [[String: Any]] {
        cookies.map { cookie in
            var value: [String: Any] = [
                "name": cookie.name,
                "value": cookie.value,
                "domain": cookie.domain,
                "path": cookie.path,
                "secure": cookie.secure,
                "httpOnly": cookie.httpOnly,
                "hostOnly": cookie.hostOnly,
            ]
            if let expires = cookie.expires {
                value["expires"] = expires
            }
            return value
        }
    }

    private func persistCookies(from response: HTTPResponse) async throws {
        guard runtimeConfiguration.permissions.values.contains(.cookies) else { return }
        let received = HTTPCookie.cookies(withResponseHeaderFields: response.headers, for: response.url).map {
            ExtensionHTTPStateCookie(
                name: $0.name,
                value: $0.value,
                domain: $0.domain,
                path: $0.path,
                expires: $0.expiresDate?.ISO8601Format(),
                secure: $0.isSecure,
                httpOnly: $0.isHTTPOnly,
                hostOnly: Self.hostOnly(cookie: $0, response: response)
            )
        }
        guard !received.isEmpty else { return }
        try await secureStateStore.mergeCookies(
            received,
            for: response.url,
            namespace: runtimeConfiguration.namespace,
            authorization: storageWriteAuthorization
        )
    }

    private func persistCookies(
        _ cookies: [ExtensionHTTPStateCookie],
        for responseURL: URL
    ) async throws {
        guard runtimeConfiguration.permissions.values.contains(.cookies) else { return }
        let received = Array(cookies.lazy
            .filter { $0.isValidForOrigin(responseURL) }
            .prefix(100))
        guard !received.isEmpty else { return }
        try await secureStateStore.mergeCookies(
            received,
            for: responseURL,
            namespace: runtimeConfiguration.namespace,
            authorization: storageWriteAuthorization
        )
    }

    private func persistedCookies() async -> [ExtensionHTTPStateCookie] {
        guard let data = try? await secureStateStore.value(
            namespace: runtimeConfiguration.namespace,
            key: "cookie_store_cookies"
        ),
            let cookies = try? JSONDecoder().decode([ExtensionHTTPStateCookie].self, from: data)
        else { return [] }
        return Array(cookies.lazy.filter { !$0.isExpired() }.prefix(100))
    }

    private static func cookiePairs(from header: String?) -> [(name: String, value: String)] {
        guard let header else { return [] }
        return header.split(separator: ";").compactMap { field in
            let pieces = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { return nil }
            let name = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return (name, String(pieces[1]))
        }
    }

    nonisolated static func hostOnly(cookie: HTTPCookie, response: HTTPResponse) -> Bool {
        guard let host = response.url.host?.lowercased() else { return false }
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard domain == host.trimmingCharacters(in: CharacterSet(charactersIn: ".")) else {
            return false
        }

        // Recent Foundation releases normalize away the leading dot that used
        // to distinguish Domain cookies. Correlate this cookie with its own
        // Set-Cookie field instead; looking for `Domain` in the whole combined
        // header could incorrectly broaden a host-only sibling cookie.
        let setCookieHeader = response.headers.first {
            $0.key.caseInsensitiveCompare("Set-Cookie") == .orderedSame
        }?.value
        let matchingFields = setCookieHeader.map(combinedSetCookieFields) ?? []
        let candidates = matchingFields.filter { field in
            let components = field.split(separator: ";", omittingEmptySubsequences: false)
            guard let pair = components.first,
                  let equals = pair.firstIndex(of: "=")
            else { return false }
            let name = pair[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name == cookie.name else { return false }

            for component in components.dropFirst() {
                let attribute = component.trimmingCharacters(in: .whitespacesAndNewlines)
                let pieces = attribute.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pieces.count == 2 else { continue }
                let attributeName = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let attributeValue = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if attributeName.caseInsensitiveCompare("Domain") == .orderedSame,
                   attributeValue.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) != domain {
                    return false
                }
                if attributeName.caseInsensitiveCompare("Path") == .orderedSame,
                   attributeValue != cookie.path {
                    return false
                }
            }
            return true
        }
        if !candidates.isEmpty {
            // Ambiguous duplicate fields fail closed as host-only unless every
            // matching representation explicitly carried a Domain attribute.
            return candidates.contains { field in
                !field.split(separator: ";").dropFirst().contains { component in
                    guard let rawName = component.split(
                        separator: "=",
                        maxSplits: 1,
                        omittingEmptySubsequences: false
                    ).first else { return false }
                    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                    return name.caseInsensitiveCompare("Domain") == .orderedSame
                }
            }
        }

        // If the response representation is unavailable, narrowing the cookie
        // to the exact host is the safe compatibility behavior.
        return true
    }

    /// Separates response headers that Foundation coalesced with commas while
    /// leaving the comma in an Expires date inside its cookie field.
    nonisolated private static func combinedSetCookieFields(_ header: String) -> [Substring] {
        var fields: [Substring] = []
        var fieldStart = header.startIndex
        var cursor = header.startIndex

        while let comma = header[cursor...].firstIndex(of: ",") {
            let afterComma = header.index(after: comma)
            let candidateStart = header[afterComma...].firstIndex { !$0.isWhitespace }
                ?? header.endIndex
            let tail = header[candidateStart...]
            if let equals = tail.firstIndex(of: "="),
               tail[..<equals].allSatisfy(Self.isCookieNameCharacter),
               !tail[..<equals].isEmpty {
                fields.append(header[fieldStart..<comma])
                fieldStart = candidateStart
            }
            cursor = afterComma
        }
        fields.append(header[fieldStart...])
        return fields
    }

    nonisolated private static func isCookieNameCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x30 ... 0x39, 0x41 ... 0x5A, 0x61 ... 0x7A:
                true
            default:
                "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar)
            }
        }
    }

    private func handleCacheRequest(_ request: NativeCacheRequest) async {
        guard let invocation = cacheInvocations[request.invocationID], activeInvocationIDs.contains(request.invocationID) else { return }
        let key = ContentCache.key(["extension-metadata-v1", invocation.scope, request.key])
        if metadataKeys.count == 4096, let oldest = metadataKeys.first { metadataKeys.remove(oldest) }
        metadataKeys.insert(key)
        var payload: JSONValue = .null
        switch request.operation {
        case "acquire":
            let pool: MankoRequestPermitPool
            if let existing = metadataLoadPermits[key] { pool = existing }
            else {
                guard metadataLoadPermits.count < 256 else {
                    try? await resolveRequest(id: request.id, payload: nil, error: Self.bridgeErrorDescriptor(for: MankoExtensionRuntimeError.responseTooLarge))
                    return
                }
                pool = MankoRequestPermitPool(limit: 1)
                metadataLoadPermits[key] = pool
            }
            metadataLoadUsers[key, default: 0] += 1
            do {
                try await pool.acquire(owner: request.invocationID)
                guard isValid, activeInvocationIDs.contains(request.invocationID), !Task.isCancelled else {
                    await pool.release()
                    releaseMetadataUser(key)
                    return
                }
                metadataLoadOwners[key] = request.invocationID
            } catch {
                releaseMetadataUser(key)
                try? await resolveRequest(id: request.id, payload: nil, error: Self.bridgeErrorDescriptor(for: error))
                return
            }
        case "release":
            if metadataLoadOwners[key] == request.invocationID {
                metadataLoadOwners[key] = nil
                let pool = metadataLoadPermits[key]
                releaseMetadataUser(key)
                await pool?.release()
            }
        case "read":
            let permit: ContentCache.MetadataPermit
            if let existing = invocation.permits[key] { permit = existing }
            else {
                // Register before awaiting the actor so concurrent reads in one
                // forced invocation rotate the resource generation only once.
                let load: MetadataPermitLoad
                if let existing = invocation.permitLoads[key] { load = existing }
                else {
                    load = MetadataPermitLoad(id: UUID(), task: Task {
                        await ContentCache.shared.metadataPermit(for: key,
                            replacing: invocation.reload && request.ttlSeconds != nil,
                            invocationGeneration: invocation.generation)
                    })
                    cacheInvocations[request.invocationID]?.permitLoads[key] = load
                }
                permit = await load.task.value
                guard cacheInvocations[request.invocationID] != nil else { return }
                if cacheInvocations[request.invocationID]?.permitLoads[key]?.id == load.id {
                    cacheInvocations[request.invocationID]?.permits[key] = permit
                    cacheInvocations[request.invocationID]?.permitLoads[key] = nil
                }
            }
            let entry = invocation.isPrivate || invocation.configurationRevision != cacheConfigurationRevision ? nil : await ContentCache.shared.metadataEntry(for: key, permit: permit, ttlSeconds: request.ttlSeconds)
            let value = entry.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0.data) }
            let hit = (value.map(Self.safeCacheValue) ?? false) && !(invocation.reload && request.ttlSeconds != nil && !invocation.writtenKeys.contains(key))
            payload = .object(["available": .bool(true), "hit": .bool(hit), "value": value ?? .null, "permit": (try? Self.jsonValue(permit)) ?? .null])
            await invocation.freshness?.record(request.ttlSeconds, date: hit ? entry?.date ?? .now : .now)
            #if DEBUG
            Self.runtimeLogger.debug("Metadata cache \(hit ? "hit" : "miss", privacy: .public)")
            #endif
        case "write":
            guard !invocation.isPrivate, invocation.configurationRevision == cacheConfigurationRevision, let permit = request.permit, invocation.permits[key] == permit,
                  let value = request.value, Self.safeCacheValue(value),
                  let data = try? JSONEncoder().encode(value) else { break }
            await ContentCache.shared.storeMetadata(data, for: key, permit: permit)
            cacheInvocations[request.invocationID]?.writtenKeys.insert(key)
        case "remove":
            await ContentCache.shared.remove(key)
            cacheInvocations[request.invocationID]?.permits[key] = nil
            cacheInvocations[request.invocationID]?.permitLoads[key] = nil
        default: break
        }
        guard activeInvocationIDs.contains(request.invocationID), isValid else { return }
        let object = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))) as? [String: Any] ?? [:]
        try? await resolveRequest(id: request.id, payload: object, error: nil)
    }

    /// Metadata is deliberately distinct from HTTP responses and secure state.
    private static func safeCacheValue(_ value: JSONValue) -> Bool {
        switch value {
        case let .object(object):
            let forbidden: Set<String> = ["password", "authorization", "cookie", "cookies", "credentials", "securestate", "secret", "apikey", "token", "setcookie", "accesstoken", "refreshtoken", "database64", "challenge", "error"]
            guard object.keys.allSatisfy({ !forbidden.contains($0.lowercased().filter { $0.isLetter || $0.isNumber }) }),
                  !(object["status"] != nil && object["headers"] != nil) else { return false }
            return object.values.allSatisfy(safeCacheValue)
        case let .array(values): return values.allSatisfy(safeCacheValue)
        default: return true
        }
    }

    private func resolveRequest(
        id: String, payload: [String: Any]?, error: [String: Any]?
    ) async throws {
        let object: [String: Any] = ["payload": payload.map { $0 as Any } ?? NSNull(),
                                     "error": error.map { $0 as Any } ?? NSNull()]
        let data = try JSONSerialization.data(withJSONObject: object)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        serviceContinuations.removeValue(forKey: id)?.resume(returning: value)
    }


    private func executeWasm(method: String, arguments: JSONValue, owner: UUID) async throws -> JSONValue {
        try await withThrowingTaskGroup(of: JSONValue.self) { group in
            var response = try await dispatchWasm(.object([
                "action": .string("invoke"), "invocationID": .string(owner.uuidString),
                "method": .string(method), "arguments": arguments
            ]), owner: owner)
            var outstanding: Set<String> = []
            var issued: Set<String> = []
            defer { group.cancelAll() }
            while case let .object(object) = response {
                try Task.checkCancellation()
                guard isValid, activeInvocationIDs.contains(owner) else { throw CancellationError() }
                if method == "imagePageContents", case let .array(completed) = object["completed"] {
                    guard completed.count <= 4 else { throw MankoExtensionRuntimeError.invalidPackage }
                    for item in completed {
                        guard case var .object(result) = item else { throw MankoExtensionRuntimeError.invalidPackage }
                        result["invocationID"] = .string(owner.uuidString)
                        receiveImageResult(try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONValue.object(result))))
                    }
                }
                guard let pending = object["pending"] else { return response }
                let requests = try decode([MankoWasmServiceRequest].self, from: pending)
                guard requests.count + outstanding.count <= 64, issued.count + requests.count <= 10_000 else {
                    throw MankoExtensionRuntimeError.invalidPackage
                }
                for request in requests {
                    guard issued.insert(request.id).inserted else { throw MankoExtensionRuntimeError.invalidPackage }
                    outstanding.insert(request.id)
                    group.addTask { [weak self] in
                        guard let self else { throw CancellationError() }
                        return try await self.performService(request, owner: owner)
                    }
                }
                guard !outstanding.isEmpty, let completed = try await group.next(),
                      case let .object(completion) = completed,
                      case let .string(id) = completion["id"], outstanding.remove(id) != nil else {
                    throw MankoExtensionRuntimeError.invalidPackage
                }
                response = try await dispatchWasm(.object([
                    "action": .string("resume"), "invocationID": .string(owner.uuidString),
                    "responses": .array([completed])
                ]), owner: owner)
            }
            throw MankoExtensionRuntimeError.invalidPackage
        }
    }

    private func dispatchWasm(_ value: JSONValue, owner: UUID) async throws -> JSONValue {
#if DEBUG
        let auditStart = ContinuousClock.now
        defer {
            if ProcessInfo.processInfo.environment["MANKO_PERFORMANCE_RUN"] != nil {
                print("SourcePerformanceStage stage=wasm elapsed=\(auditStart.duration(to: .now))")
            }
        }
#endif
        try Task.checkCancellation()
        guard isValid, activeInvocationIDs.contains(owner) else { throw CancellationError() }
        do { return try await wasm.dispatch(value, owner: owner, context: invocationContexts[owner]) }
        catch {
            if !(error is CancellationError) { invalidate(cancelInitialization: false) }
            throw error
        }
    }

    private func performService(_ request: MankoWasmServiceRequest, owner: UUID) async throws -> JSONValue {
        guard !request.id.isEmpty, request.id.utf8.count <= 128,
              isValid, activeInvocationIDs.contains(owner) else { throw CancellationError() }
        do {
            let value = try await serviceValue(request, owner: owner)
            try Task.checkCancellation()
            guard isValid, activeInvocationIDs.contains(owner) else { throw CancellationError() }
            return .object(["id": .string(request.id), "payload": value, "error": .null])
        } catch {
            if error is CancellationError { throw error }
            return .object(["id": .string(request.id), "payload": .null,
                            "error": try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: Self.bridgeErrorDescriptor(for: error)))])
        }
    }

    private func serviceValue(_ request: MankoWasmServiceRequest, owner: UUID) async throws -> JSONValue {
        try Task.checkCancellation()
        guard isValid, activeInvocationIDs.contains(owner) else { throw CancellationError() }
        guard case var .object(arguments) = request.arguments else { throw MankoExtensionRuntimeError.invalidPackage }
        let required: ExtensionPermission? = switch request.service {
        case "http": .network
        case "state", "cache": .state
        case "secureState": .secureState
        case "challenge": .challengeHandoff
        case "log": .redactedLogging
        default: nil
        }
        if let required, !runtimeConfiguration.permissions.values.contains(required) { throw ExtensionSecurityError.approvalRequired }
        if runtimeConfiguration.offlineValidation, !["clock", "log"].contains(request.service) { throw ExtensionSecurityError.approvalRequired }
        switch request.service {
        case "catalogProgress":
            guard let method = invocationMethods[owner], ["search", "discover"].contains(method),
                  let callback = catalogProgressHandlers[owner],
                  case let .array(items) = arguments["items"],
                  !items.isEmpty, items.count <= 100 else {
                throw MankoExtensionRuntimeError.invalidPackage
            }
            try await callback(.array(items))
            return .null
        case "http", "cache":
            let nativeID = UUID().uuidString
            arguments["id"] = .string(nativeID)
            arguments["invocationID"] = .string(owner.uuidString)
            let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONValue.object(arguments)))
            let http = request.service == "http" ? NativeRequest(body: body) : nil
            let cache = request.service == "cache" ? NativeCacheRequest(body: body) : nil
            guard http != nil || cache != nil else { throw MankoExtensionRuntimeError.invalidPackage }
            nativeRequestOwners[nativeID] = owner
            defer {
                nativeRequestOwners[nativeID] = nil
                nativeRequestTasks[nativeID] = nil
            }
            let envelope: JSONValue = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                    guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    serviceContinuations[nativeID] = continuation
                    nativeRequestTasks[nativeID] = Task {
                        if let http { await handleRequest(http) }
                        else if let cache { await handleCacheRequest(cache) }
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.nativeRequestTasks[nativeID]?.cancel()
                    self?.serviceContinuations.removeValue(forKey: nativeID)?.resume(throwing: CancellationError())
                }
            }
            guard case let .object(result) = envelope else { throw MankoExtensionRuntimeError.invalidPackage }
            if let error = result["error"], error != .null {
                let descriptor = try decode(MankoInvocationError.self, from: error)
                throw runtimeError(from: descriptor, invocationID: owner)
            }
            return result["payload"] ?? .null
        case "state", "secureState":
            guard case let .string(operation) = arguments["operation"],
                  case let .string(key) = arguments["key"], !key.isEmpty, key.utf8.count <= 256,
                  !key.hasPrefix("__native_"), !key.hasPrefix("oauth_"), key != "cookie_store_cookies",
                  key != ExtensionBrowserSessionProfile.secureStateKey,
                  key != "__manko_metadata_epoch",
                  key != CloudflareChallengeContext.pendingSecureStateKey else {
                throw MankoExtensionRuntimeError.invalidPackage
            }
            let secure = request.service == "secureState" || key == "cookie_store_cookies"
            if operation == "get" {
                let data: Data?
                if secure { data = try await secureStateStore.values(namespace: runtimeConfiguration.namespace)[key] }
                else { data = try await stateStore.values(namespace: runtimeConfiguration.namespace)[key] }
                return try data.map { try JSONDecoder().decode(JSONValue.self, from: $0) } ?? .null
            }
            guard ["set", "remove", "reset"].contains(operation) else { throw MankoExtensionRuntimeError.invalidPackage }
            let value = operation == "set" ? arguments["value"] : nil
            let data = try value.map { try JSONEncoder().encode($0) }
            guard (data?.count ?? 0) <= 1_024 * 1_024 else { throw MankoExtensionRuntimeError.responseTooLarge }
            if data != nil {
                let values = secure ? try await secureStateStore.values(namespace: runtimeConfiguration.namespace)
                    : try await stateStore.values(namespace: runtimeConfiguration.namespace)
                let other = values.filter { $0.key != key }
                guard other.count < 256, other.values.reduce(0, { $0 + $1.count }) + (data?.count ?? 0) <= 4 * 1_024 * 1_024
                else { throw MankoExtensionRuntimeError.responseTooLarge }
            }
            if operation == "reset", !secure {
                try await stateStore.reset(namespace: runtimeConfiguration.namespace, authorization: storageWriteAuthorization)
            } else if secure {
                try await secureStateStore.setIndexed(data, namespace: runtimeConfiguration.namespace, key: key, authorization: storageWriteAuthorization)
            } else {
                try await stateStore.set(data, key: key, namespace: runtimeConfiguration.namespace, authorization: storageWriteAuthorization)
            }
            if key != "cookie_store_cookies" { cacheConfigurationRevision = UUID(); cacheSettingsIdentity = nil }
            return .null
        case "clock":
            return .object(["now": .string(Date.now.ISO8601Format()),
                            "milliseconds": .number(Date.now.timeIntervalSince1970 * 1_000),
                            "random": .number(Double(UInt32.random(in: 1...UInt32.max)))])
        case "sleep":
            guard case let .number(milliseconds) = arguments["milliseconds"],
                  milliseconds.isFinite, (0...60_000).contains(milliseconds) else {
                throw MankoExtensionRuntimeError.invalidPackage
            }
            try await Task.sleep(for: .milliseconds(milliseconds))
            return .null
        case "challenge":
            guard case let .string(raw) = arguments["url"], let url = validatedHandoffURL(raw) else {
                throw MankoExtensionRuntimeError.invalidPackage
            }
            lastCloudflareHandoffURL = url
            throw MankoExtensionRuntimeError.cloudflareHandoff(cloudflareContext(url: url))
        case "log":
            return .null
        default:
            throw MankoExtensionRuntimeError.operationFailed("Unsupported WASM host service.")
        }
    }

    private static func jsonValue<Value: Encodable>(_ value: Value) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

private struct NativeRequest: Sendable {
    var invocationID: UUID
    var id: String
    var url: String
    var method: String
    var headers: [String: String]
    var cookies: [String: String]
    var bodyBase64: String?
    var authenticated: Bool
    var wantsImageResource: Bool

    init?(body: Any) {
        guard let body = body as? [String: Any],
              let invocationIDValue = body["invocationID"] as? String,
              let invocationID = UUID(uuidString: invocationIDValue),
              let id = body["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
              let url = body["url"] as? String,
              let method = body["method"] as? String
        else { return nil }
        self.authenticated = body["authenticated"] as? Bool ?? false
        self.invocationID = invocationID
        self.id = id
        self.url = url
        self.method = method
        headers = body["headers"] as? [String: String] ?? [:]
        cookies = body["cookies"] as? [String: String] ?? [:]
        bodyBase64 = body["bodyBase64"] as? String
        wantsImageResource = body["imageResource"] as? Bool ?? false
    }
}

private struct NativeCacheRequest: Sendable {
    let id: String
    let invocationID: UUID
    let operation: String
    let key: String
    let ttlSeconds: Double?
    let permit: ContentCache.MetadataPermit?
    let value: JSONValue?
    init?(body: Any) {
        guard let body = body as? [String: Any], let id = body["id"] as? String,
              let owner = body["invocationID"] as? String, let invocationID = UUID(uuidString: owner),
              let operation = body["operation"] as? String, let key = body["key"] as? String,
              !key.isEmpty, key.utf8.count <= 16384,
              ["acquire", "release", "read", "write", "remove"].contains(operation) else { return nil }
        self.id = id; self.invocationID = invocationID; self.operation = operation; self.key = key
        ttlSeconds = body["ttlSeconds"] as? Double
        if operation == "read", body["ttlSeconds"] is NSNull == false, !(ttlSeconds.map { $0.isFinite && $0 > 0 } ?? false) { return nil }
        func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
            guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
        permit = decode(ContentCache.MetadataPermit.self, body["permit"])
        value = decode(JSONValue.self, body["value"])
    }
}
