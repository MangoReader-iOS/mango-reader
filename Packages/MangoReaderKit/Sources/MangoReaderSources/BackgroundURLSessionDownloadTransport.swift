import Foundation
import MangoReaderDomain

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor BackgroundURLSessionDownloadTransport: DownloadTransport {
    private let isPrivate: Bool
    private let identifier: String
    private let redirectIdentityLoader: DownloadRedirectIdentityLoader?
    private let stagingDirectory: URL
    private var session: URLSession?
    private var sessionDelegate: BackgroundDownloadDelegate?
    private struct ConstrainedSession {
        let generation: UUID?
        let session: URLSession
    }
    private var constrainedSessions: [ExtensionNetworkPolicy: ConstrainedSession] = [:]
    private var pendingStarts: [UUID: UUID] = [:]
    private var activePolicies: [UUID: ExtensionNetworkPolicy] = [:]
    private var activeTasks: [UUID: URLSessionDownloadTask] = [:]
    /// Secret-bearing identities are process memory only. Task descriptions
    /// carry the non-secret source reference needed for safe recovery.
    private var activeRedirectIdentities: [UUID: HTTPRedirectIdentity] = [:]
    /// Suppression follows the concrete URLSession task rather than the queue
    /// ID, which is intentionally reused by retries.
    private var suppressedTaskIdentifiers: Set<Int> = []
    private var continuations: [UUID: AsyncStream<DownloadTransportEvent>.Continuation] = [:]
    private var backgroundEventsCompletionHandler: (@MainActor @Sendable () -> Void)?
    private var hasPendingBackgroundEventsCompletion = false

    public init(
        identifier: String = "com.k800k.manko.background-downloads",
        redirectIdentityLoader: DownloadRedirectIdentityLoader? = nil,
        stagingDirectory: URL? = nil,
        isPrivate: Bool = false
    ) {
        self.isPrivate = isPrivate
        self.identifier = identifier
        self.redirectIdentityLoader = redirectIdentityLoader
        self.stagingDirectory = stagingDirectory
            ?? DownloadCoordinator.Configuration.defaultOfflineDownloadsDirectory.appendingPathComponent(".Staging", isDirectory: true)
    }

    public func events() -> AsyncStream<DownloadTransportEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: DownloadTransportEvent.self, bufferingPolicy: .bufferingNewest(512))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    public func prepare() async -> Set<UUID> {
        do {
            let session = try ensureSession()
            let tasks = await allTasks(in: session)
            let downloadTasks = tasks.compactMap { $0 as? URLSessionDownloadTask }
            return await registerPreparedTasks(downloadTasks)
        } catch {
            return []
        }
    }

    func registerPreparedTasks(_ downloadTasks: [URLSessionDownloadTask]) async -> Set<UUID> {
        var claimedIDs: Set<UUID> = []
        var restoredTasks: [(task: URLSessionDownloadTask, metadata: DownloadTaskMetadata)] = []
        for task in downloadTasks.sorted(by: { $0.taskIdentifier < $1.taskIdentifier }) {
            guard let metadata = task.downloadMetadata else {
                // A task without authenticated app metadata has no safe
                // endpoint or credential provenance and must not continue as
                // an untracked background request.
                task.cancel()
                continue
            }
            guard metadata.verificationReference == nil, metadata.credentialOrigin == nil else {
                // Pre-policy background tasks must restart through the native broker.
                task.cancel()
                continue
            }
            guard claimedIDs.insert(metadata.id).inserted else {
                // Queue IDs are reused by retries, but two simultaneous OS
                // tasks with one ID are ambiguous. Deterministically keep the
                // lowest taskIdentifier and cancel every duplicate.
                task.cancel()
                continue
            }
            restoredTasks.append((task, metadata))
        }

        for (task, metadata) in restoredTasks {
            let id = metadata.id
            if let existing = activeTasks[id], existing !== task {
                existing.cancel()
                suppressedTaskIdentifiers.insert(Int(bitPattern: ObjectIdentifier(existing)))
                activeRedirectIdentities.removeValue(forKey: id)
                activePolicies.removeValue(forKey: id)
            }
            activeTasks[id] = task
        }
        for (task, metadata) in restoredTasks {
            let id = metadata.id
            if metadata.expectsVerifiedIdentity,
               let requestURL = task.currentRequest?.url ?? task.originalRequest?.url,
               let identity = await loadRedirectIdentity(
                   metadata: metadata,
                   requestURL: requestURL
               )
            {
                guard activeTasks[id] === task else { continue }
                activeRedirectIdentities[id] = identity
            }
        }
        let restoredIDs: [UUID] = restoredTasks.compactMap { entry -> UUID? in
            activeTasks[entry.metadata.id] === entry.task ? entry.metadata.id : nil
        }
        return Set(restoredIDs)
    }

    public func start(_ transfer: DownloadTransfer, resumeData: Data?, wifiOnly: Bool) async throws {
        if activeTasks[transfer.id] != nil || pendingStarts[transfer.id] != nil { return }
        let startToken = UUID()
        pendingStarts[transfer.id] = startToken
        defer { if pendingStarts[transfer.id] == startToken { pendingStarts[transfer.id] = nil } }
        let policy: ExtensionNetworkPolicy? = transfer.verificationReference.map {
            ExtensionNetworkPolicy(hosts: $0.permittedBrowserHosts, serverOrigin: $0.serverOrigin)
        } ?? transfer.credentialOrigin.map { ExtensionNetworkPolicy(hosts: [], serverOrigin: $0) }
        let session: URLSession
        if let policy {
            try policy.validate(transfer.remoteURL)
            let lease = transfer.remoteURL.scheme?.lowercased() == "https"
                ? try await ExtensionNetworkSessions.shared.lease(for: policy) : nil
            try Task.checkCancellation()
            guard pendingStarts[transfer.id] == startToken else { throw CancellationError() }
            if let existing = constrainedSessions[policy], existing.generation == lease?.generation {
                session = existing.session
            }
            else {
                _ = try ensureSession() // Creates the staging directory and native delegate.
                let configuration = Self.makeSessionConfiguration(identifier: identifier, isPrivate: true)
                if let lease { configuration.proxyConfigurations = [lease.configuration] }
                // An in-process broker cannot survive process termination. Constrained
                // transfers restart from the durable queue; never fall back to direct egress.
                session = URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: nil)
                constrainedSessions[policy]?.session.finishTasksAndInvalidate()
                constrainedSessions[policy] = ConstrainedSession(generation: lease?.generation, session: session)
            }
            activePolicies[transfer.id] = policy
        } else { session = try ensureSession() }
        try Task.checkCancellation()
        guard pendingStarts[transfer.id] == startToken else { throw CancellationError() }
        let task: URLSessionDownloadTask
        if policy == nil, let resumeData, !resumeData.isEmpty {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = URLRequest(url: transfer.remoteURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 60
            request.allowsCellularAccess = !wifiOnly
            request.allowsExpensiveNetworkAccess = !wifiOnly
            request.allowsConstrainedNetworkAccess = true
            for (name, value) in transfer.headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            request = request.applyingRedirectIdentity(
                transfer.redirectIdentity,
                for: transfer.remoteURL
            )
            task = session.downloadTask(with: request)
        }
        task.taskDescription = try DownloadTaskMetadata(
            id: transfer.id,
            credentialOrigin: transfer.credentialOrigin,
            credentialHeaderNames: transfer.credentialHeaderNames,
            verificationReference: transfer.verificationReference,
            expectsVerifiedIdentity: transfer.redirectIdentity != nil,
            endpointAccess: transfer.endpointAccess
        ).encodedDescription()
        task.priority = Self.urlSessionPriority(transfer.priority)
        activeTasks[transfer.id] = task
        activeRedirectIdentities[transfer.id] = transfer.redirectIdentity
        task.resume()
    }

    public func pause(_ id: UUID) async -> Data? {
        pendingStarts[id] = nil
        guard let task = activeTasks.removeValue(forKey: id) else { return nil }
        activeRedirectIdentities.removeValue(forKey: id)
        activePolicies.removeValue(forKey: id)
        suppressedTaskIdentifiers.insert(Int(bitPattern: ObjectIdentifier(task)))
        return await withCheckedContinuation { continuation in
            task.cancel { resumeData in
                continuation.resume(returning: resumeData)
            }
        }
    }

    public func cancel(_ id: UUID) {
        pendingStarts[id] = nil
        guard let task = activeTasks.removeValue(forKey: id) else { return }
        activeRedirectIdentities.removeValue(forKey: id)
        activePolicies.removeValue(forKey: id)
        suppressedTaskIdentifiers.insert(Int(bitPattern: ObjectIdentifier(task)))
        task.cancel()
    }

    public func setPriority(_ priority: Int, for id: UUID) {
        activeTasks[id]?.priority = Self.urlSessionPriority(priority)
    }

    /// Mirrors the task registration performed by `prepare()`. Kept internal
    /// so cancellation-vs-rebind behavior can be tested without starting a
    /// network request.
    func registerRestoredTask(_ task: URLSessionDownloadTask, id: UUID) {
        activeTasks[id] = task
    }

    func hasCachedRedirectIdentity(for id: UUID) -> Bool {
        activeRedirectIdentities[id] != nil
    }

    func hasActiveTask(for id: UUID) -> Bool {
        activeTasks[id] != nil
    }

    func activeTaskIdentifier(for id: UUID) -> Int? {
        activeTasks[id].map({ Int(bitPattern: ObjectIdentifier($0)) })
    }

    public func setBackgroundEventsCompletionHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    ) async {
        backgroundEventsCompletionHandler = handler
        guard hasPendingBackgroundEventsCompletion, let handler else { return }
        hasPendingBackgroundEventsCompletion = false
        backgroundEventsCompletionHandler = nil
        await handler()
    }

    private func ensureSession() throws -> URLSession {
        if let session { return session }
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        } catch {
            throw DownloadCoordinatorError.storage(error.localizedDescription)
        }

        let delegate = BackgroundDownloadDelegate(owner: self, stagingDirectory: stagingDirectory, isPrivate: isPrivate)
        let configuration = Self.makeSessionConfiguration(identifier: identifier, isPrivate: isPrivate)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        sessionDelegate = delegate
        self.session = session
        return session
    }

    /// Browser cookies are introduced only by the explicitly rebuilt,
    /// exact-origin identity. Ambient Foundation stores must not silently
    /// broaden that identity boundary.
    static func makeSessionConfiguration(identifier: String, isPrivate: Bool = false) -> URLSessionConfiguration {
        let configuration = isPrivate ? URLSessionConfiguration.ephemeral : URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = !isPrivate
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    private func allTasks(in session: URLSession) async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
    }

    fileprivate func receivedProgress(
        id: UUID,
        taskIdentifier: Int,
        completedBytes: Int64,
        totalBytes: Int64?
    ) {
        guard activeTasks[id].map({ Int(bitPattern: ObjectIdentifier($0)) }) == taskIdentifier else { return }
        emit(.progress(id: id, completedBytes: completedBytes, totalBytes: totalBytes))
    }

    func receivedFinishedFile(
        id: UUID,
        taskIdentifier: Int,
        stagedFile: URL,
        response: DownloadTransportResponse
    ) {
        guard activeTasks[id].map({ Int(bitPattern: ObjectIdentifier($0)) }) == taskIdentifier else {
            try? FileManager.default.removeItem(at: stagedFile)
            return
        }
        activeTasks.removeValue(forKey: id)
        activeRedirectIdentities.removeValue(forKey: id)
        activePolicies.removeValue(forKey: id)
        emit(.finished(id: id, stagedFile: stagedFile, response: response))
    }

    func receivedCompletion(id: UUID, taskIdentifier: Int, error: Error?) {
        if suppressedTaskIdentifiers.remove(taskIdentifier) != nil { return }
        guard activeTasks[id].map({ Int(bitPattern: ObjectIdentifier($0)) }) == taskIdentifier else { return }
        // URLSession delegate callbacks are bridged through independent Tasks,
        // so the nil completion can overtake didFinishDownloadingTo. Successful
        // ownership remains until receivedFinishedFile installs the artifact.
        guard let error else { return }
        activeTasks.removeValue(forKey: id)
        activeRedirectIdentities.removeValue(forKey: id)
        activePolicies.removeValue(forKey: id)

        let nsError = error as NSError
        let resumeData = nsError.userInfo["NSURLSessionDownloadTaskResumeData"] as? Data
        let mapped: DownloadCoordinatorError
        if nsError.domain == NSURLErrorDomain, nsError.code == URLError.cancelled.rawValue {
            mapped = .cancelled
        } else {
            mapped = .network(code: nsError.code, description: nsError.localizedDescription)
        }
        emit(.failed(id: id, error: mapped, resumeData: resumeData))
    }

    func requestForFollowingRedirect(
        id: UUID,
        metadata: DownloadTaskMetadata,
        from source: URL?,
        request: URLRequest,
        expectedTaskIdentifier: Int? = nil
    ) async -> URLRequest? {
        let expectedTask: URLSessionDownloadTask?
        if let expectedTaskIdentifier {
            guard let activeTask = activeTasks[id],
                  Int(bitPattern: ObjectIdentifier(activeTask)) == expectedTaskIdentifier
            else { return nil }
            expectedTask = activeTask
        } else {
            // Unit-level policy calls have no live URLSession task. Production
            // delegate calls always supply an identifier and take the stronger
            // before/after task-identity path below.
            expectedTask = nil
        }
        if let destination = request.url {
            let policy = activePolicies[id] ?? metadata.verificationReference.map {
                ExtensionNetworkPolicy(hosts: $0.permittedBrowserHosts, serverOrigin: $0.serverOrigin)
            } ?? metadata.credentialOrigin.map { ExtensionNetworkPolicy(hosts: [], serverOrigin: $0) }
            if let policy, !policy.allows(destination) { return nil }
        }
        guard let endpointAccess = metadata.endpointAccess,
              let destination = request.url,
              (try? EndpointPolicy().validate(destination, access: endpointAccess)) != nil,
              var followed = DownloadCredentialPolicy.requestForFollowing(
            request,
            from: source,
            credentialOrigin: metadata.credentialOrigin,
            credentialHeaderNames: metadata.credentialHeaderNames
        ), followed.url != nil
        else { return nil }

        var redirectIdentity = activeRedirectIdentities[id]
        if redirectIdentity == nil, metadata.expectsVerifiedIdentity {
            guard let requestURL = source ?? request.url,
                  let rebound = await loadRedirectIdentity(
                      metadata: metadata,
                      requestURL: requestURL
                  )
            else {
                // This task originally carried a verified browser identity.
                // If a relaunch cannot rebuild it from secure state, refusing
                // the redirect is safer than manufacturing a false second
                // challenge and consuming the transfer's bounded retry.
                return nil
            }
            if let expectedTask {
                guard activeTasks[id] === expectedTask else { return nil }
                activeRedirectIdentities[id] = rebound
            }
            redirectIdentity = rebound
        }

        if let expectedTask, activeTasks[id] !== expectedTask {
            return nil
        }

        if let identity = redirectIdentity {
            if !DownloadCredentialPolicy.isSameOrigin(destination, as: identity.origin) {
                // User-Agent is normally safe on redirects, but this value is
                // part of the verified WebKit identity and belongs only to its
                // exact origin.
                followed.setValue(nil, forHTTPHeaderField: "User-Agent")
            }
            return followed.applyingRedirectIdentity(identity, for: destination)
        }

        // After a system relaunch the OS-owned task can still contain the
        // verified request, while this process intentionally has no secret
        // identity map. Never let that UA cross origins; a future fresh retry
        // will rebuild the identity from secure state.
        if metadata.verificationReference != nil,
           let source,
           !DownloadCredentialPolicy.isSameOrigin(destination, as: source)
        {
            followed.setValue(nil, forHTTPHeaderField: "User-Agent")
        }
        return followed
    }

    private func loadRedirectIdentity(
        metadata: DownloadTaskMetadata,
        requestURL: URL
    ) async -> HTTPRedirectIdentity? {
        guard metadata.expectsVerifiedIdentity,
              let reference = metadata.verificationReference,
              let redirectIdentityLoader
        else { return nil }
        do {
            guard let identity = try await redirectIdentityLoader(reference, requestURL),
                  reference.authorizes(identity)
            else { return nil }
            return identity
        } catch {
            return nil
        }
    }

    func receivedBackgroundEventsFinished() async {
        emit(.backgroundEventsFinished)
        guard let handler = backgroundEventsCompletionHandler else {
            // During a system relaunch the background session can finish
            // replaying its delegate events while the app is still restoring
            // the coordinator. Preserve that edge until AppDelegate's
            // completion handler is installed instead of dropping it.
            hasPendingBackgroundEventsCompletion = true
            return
        }
        hasPendingBackgroundEventsCompletion = false
        backgroundEventsCompletionHandler = nil
        await handler()
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func emit(_ event: DownloadTransportEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private static func urlSessionPriority(_ priority: Int) -> Float {
        let normalized = (Double(priority) + 1_000) / 2_000
        return Float(min(1, max(0, normalized)))
    }
}

private final class BackgroundDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let isPrivate: Bool
    private weak var owner: BackgroundURLSessionDownloadTransport?
    private let stagingDirectory: URL

    init(owner: BackgroundURLSessionDownloadTransport, stagingDirectory: URL, isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        self.owner = owner
        self.stagingDirectory = stagingDirectory
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = downloadTask.downloadID else { return }
        let limit = Int64(DownloadValidationLimits.publication.maximumFileBytes)
        guard totalBytesWritten <= limit, totalBytesExpectedToWrite <= limit else {
            downloadTask.cancel()
            return
        }
        let total = totalBytesExpectedToWrite == NSURLSessionTransferSizeUnknown ? nil : totalBytesExpectedToWrite
        let taskIdentifier = Int(bitPattern: ObjectIdentifier(downloadTask))
        Task {
            await owner?.receivedProgress(
                id: id,
                taskIdentifier: taskIdentifier,
                completedBytes: totalBytesWritten,
                totalBytes: total
            )
        }
    }

    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.downloadID else { return }
        let taskIdentifier = Int(bitPattern: ObjectIdentifier(downloadTask))
        let stableLocation = stagingDirectory.appendingPathComponent("\(id.uuidString)-\(UUID().uuidString).download")
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: stableLocation.path) {
                try FileManager.default.removeItem(at: stableLocation)
            }
            try FileManager.default.moveItem(at: location, to: stableLocation)
            if isPrivate {
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: stableLocation.path)
            }

            let http = downloadTask.response as? HTTPURLResponse
            let bodyPrefix = try Self.readChallengePrefix(from: stableLocation)
            let response = DownloadTransportResponse(
                url: http?.url ?? downloadTask.currentRequest?.url ?? downloadTask.originalRequest?.url,
                statusCode: http?.statusCode ?? 0,
                suggestedFilename: http?.suggestedFilename,
                mimeType: http?.mimeType,
                expectedContentLength: http.map { $0.expectedContentLength >= 0 ? $0.expectedContentLength : nil } ?? nil,
                isDefinitiveCloudflareChallenge: downloadTask.downloadMetadata?.verificationReference != nil
                    && DownloadCloudflareChallengePolicy.isDefinitiveChallenge(
                        cfMitigated: http?.value(forHTTPHeaderField: "cf-mitigated"),
                        bodyPrefix: bodyPrefix
                    )
            )
            Task {
                await owner?.receivedFinishedFile(
                    id: id,
                    taskIdentifier: taskIdentifier,
                    stagedFile: stableLocation,
                    response: response
                )
            }
        } catch {
            Task {
                await owner?.receivedCompletion(
                    id: id,
                    taskIdentifier: taskIdentifier,
                    error: DownloadCoordinatorError.storage(error.localizedDescription)
                )
            }
        }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.downloadID else { return }
        let taskIdentifier = Int(bitPattern: ObjectIdentifier(task))
        Task {
            await owner?.receivedCompletion(
                id: id,
                taskIdentifier: taskIdentifier,
                error: error
            )
        }
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Every task created by this transport has a versioned description.
        // If it is absent or corrupt, its credential provenance is unknowable,
        // so refusing the redirect is the only safe recovery behavior.
        guard let metadata = task.downloadMetadata else {
            completionHandler(nil)
            return
        }
        guard let id = task.downloadID, let owner else {
            completionHandler(nil)
            return
        }
        let taskIdentifier = Int(bitPattern: ObjectIdentifier(task))
        Task {
            let followed = await owner.requestForFollowingRedirect(
                id: id,
                metadata: metadata,
                from: response.url,
                request: request,
                expectedTaskIdentifier: taskIdentifier
            )
            completionHandler(followed)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
        Task {
            await owner?.receivedBackgroundEventsFinished()
        }
    }

    private static func readChallengePrefix(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: DownloadCloudflareChallengePolicy.maximumBodyBytes)
            ?? Data()
    }
}

/// Matches the explicit Cloudflare mitigation signal and the same bounded,
/// managed-challenge markup used by the extension HTTP broker. A bare 403 or
/// 503 is deliberately not evidence of Cloudflare.
enum DownloadCloudflareChallengePolicy {
    static let maximumBodyBytes = 256 * 1_024

    static func isDefinitiveChallenge(
        cfMitigated: String?,
        bodyPrefix: Data
    ) -> Bool {
        if cfMitigated?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("challenge") == .orderedSame
        {
            return true
        }
        let html = String(decoding: bodyPrefix.prefix(maximumBodyBytes), as: UTF8.self)
            .lowercased()
        let hasManagedChallengeForm = html.range(
            of: #"<form\b[^>]*(?:id\s*=\s*['\"]challenge-form['\"]|action\s*=\s*['\"][^'\"]*(?:__cf_chl|/cdn-cgi/challenge-platform))"#,
            options: .regularExpression
        ) != nil
        let hasManagedChallengeTitle = html.range(
            of: #"<title\b[^>]*>\s*just a moment(?:\.\.\.)?\s*</title>"#,
            options: .regularExpression
        ) != nil
        return hasManagedChallengeForm || hasManagedChallengeTitle
    }
}

struct DownloadTaskMetadata: Sendable, Equatable {
    static let currentPrefix = "manko-download-v2:"
    static let legacyPrefix = "manko-download-v1:"

    var id: UUID
    var credentialOrigin: URL?
    /// `nil` means a decoded v1 task whose credential-header provenance is
    /// unavailable. Newly encoded v2 tasks always carry a (possibly empty)
    /// exact set of non-secret header names.
    var credentialHeaderNames: Set<String>?
    var verificationReference: DownloadVerificationReference?
    /// Non-secret indication that the original request carried a verified
    /// identity and therefore must fail redirects closed if relaunch rebinding
    /// cannot reconstruct it.
    var expectsVerifiedIdentity: Bool
    /// Nil represents an older task that predates redirect endpoint
    /// provenance; those tasks fail closed at their next redirect.
    var endpointAccess: EndpointAccess?

    init(
        id: UUID,
        credentialOrigin: URL?,
        credentialHeaderNames: Set<String>,
        verificationReference: DownloadVerificationReference? = nil,
        expectsVerifiedIdentity: Bool = false,
        endpointAccess: EndpointAccess? = nil
    ) {
        self.id = id
        self.credentialOrigin = credentialOrigin
        self.credentialHeaderNames = credentialHeaderNames
        self.verificationReference = verificationReference
        self.expectsVerifiedIdentity = expectsVerifiedIdentity
        self.endpointAccess = endpointAccess
    }

    func encodedDescription() throws -> String {
        guard let credentialHeaderNames else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "Legacy download metadata cannot be promoted without credential-header provenance."
                )
            )
        }
        guard verificationReference?.isValid != false else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "Invalid extension download verification provenance."
                )
            )
        }
        let payload = CurrentPayload(
            id: id,
            credentialOrigin: credentialOrigin,
            credentialHeaderNames: credentialHeaderNames.sorted(),
            verificationReference: verificationReference,
            expectsVerifiedIdentity: expectsVerifiedIdentity,
            endpointAccess: endpointAccess
        )
        let data = try JSONEncoder().encode(payload)
        return Self.currentPrefix + data.base64EncodedString()
    }

    static func decode(_ description: String) -> DownloadTaskMetadata? {
        if description.hasPrefix(currentPrefix) {
            guard let data = Data(
                base64Encoded: String(description.dropFirst(currentPrefix.count))
            ), let payload = try? JSONDecoder().decode(CurrentPayload.self, from: data)
            else {
                return nil
            }
            return DownloadTaskMetadata(
                id: payload.id,
                credentialOrigin: payload.credentialOrigin,
                credentialHeaderNames: Set(payload.credentialHeaderNames),
                verificationReference: payload.verificationReference,
                expectsVerifiedIdentity: payload.expectsVerifiedIdentity ?? false,
                endpointAccess: payload.endpointAccess
            )
        }

        guard
            description.hasPrefix(legacyPrefix),
            let data = Data(base64Encoded: String(description.dropFirst(legacyPrefix.count))),
            let payload = try? JSONDecoder().decode(LegacyPayload.self, from: data)
        else {
            return nil
        }
        return DownloadTaskMetadata(
            id: payload.id,
            credentialOrigin: payload.credentialOrigin,
            credentialHeaderNames: nil,
            verificationReference: nil,
            expectsVerifiedIdentity: false,
            endpointAccess: nil
        )
    }

    private init(
        id: UUID,
        credentialOrigin: URL?,
        credentialHeaderNames: Set<String>?,
        verificationReference: DownloadVerificationReference?,
        expectsVerifiedIdentity: Bool,
        endpointAccess: EndpointAccess?
    ) {
        self.id = id
        self.credentialOrigin = credentialOrigin
        self.credentialHeaderNames = credentialHeaderNames
        self.verificationReference = verificationReference
        self.expectsVerifiedIdentity = expectsVerifiedIdentity
        self.endpointAccess = endpointAccess
    }

    private struct CurrentPayload: Codable {
        var id: UUID
        var credentialOrigin: URL?
        var credentialHeaderNames: [String]
        var verificationReference: DownloadVerificationReference?
        var expectsVerifiedIdentity: Bool?
        var endpointAccess: EndpointAccess?
    }

    private struct LegacyPayload: Codable {
        var id: UUID
        var credentialOrigin: URL?
    }
}

private extension URLSessionTask {
    var downloadMetadata: DownloadTaskMetadata? {
        taskDescription.flatMap(DownloadTaskMetadata.decode)
    }

    var downloadID: UUID? { downloadMetadata?.id }
}
