import Foundation
import MankoDomain

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Priority queue and state machine for durable publication downloads.
public actor DownloadCoordinator {
    public struct Configuration: Sendable, Hashable {
        public var isPrivate: Bool
        public var maximumConcurrentDownloads: Int
        public var wifiOnly: Bool
        public var offlineDownloadsDirectory: URL
        public var validationLimits: DownloadValidationLimits

        public init(
            maximumConcurrentDownloads: Int = 3,
            wifiOnly: Bool = false,
            offlineDownloadsDirectory: URL = Self.defaultOfflineDownloadsDirectory,
            validationLimits: DownloadValidationLimits = .publication,
            isPrivate: Bool = false
        ) {
            self.isPrivate = isPrivate
            self.maximumConcurrentDownloads = max(1, maximumConcurrentDownloads)
            self.wifiOnly = wifiOnly
            self.offlineDownloadsDirectory = offlineDownloadsDirectory
            self.validationLimits = validationLimits
        }

        public static var defaultOfflineDownloadsDirectory: URL {
            let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            return applicationSupport.appendingPathComponent("OfflineDownloads", isDirectory: true)
        }
    }

    private let stateStore: any DownloadStateStore
    private let transport: any DownloadTransport
    private let credentialLoader: (any SourceCredentialLoading)?
    private let redirectIdentityLoader: DownloadRedirectIdentityLoader?
    private let endpointPolicy = EndpointPolicy()
    private let publicationValidator: DownloadedPublicationValidator
    private var configuration: Configuration
    private var snapshotsByID: [UUID: DownloadSnapshot] = [:]
    private var activeIDs: Set<UUID> = []
    /// Queue entries being promoted from a challenged pause to their single
    /// durable retry. Actor reentrancy must not expose them to the scheduler
    /// while queue persistence is suspended.
    private var retryPersistenceIDs: Set<UUID> = []
    private var verificationInvalidationNamespaces: Set<String> = []
    /// Identifies the scheduler pass currently preparing each transfer. Any
    /// operation that stops or requeues a transfer removes its token before
    /// awaiting the transport, so a late credential/browser-identity lookup
    /// cannot start an obsolete request.
    private var startTokensByID: [UUID: UUID] = [:]
    /// The smaller interval after the final scheduler revalidation but before
    /// `transport.start` returns. Removal waits for this interval to settle and
    /// cancels again, guaranteeing that secure browser state is not deleted
    /// while a late transport start can still materialize.
    private var transportStartingTokensByID: [UUID: UUID] = [:]
    private var transportStartSettlementWaiters: [
        UUID: [CheckedContinuation<Void, Never>]
    ] = [:]
    private var queuePersistenceIsLocked = false
    private var queuePersistenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuations: [UUID: AsyncStream<DownloadEvent>.Continuation] = [:]
    private var transportTask: Task<Void, Never>?
    private var isPrepared = false
    private var isLocked = false

    public init(
        configuration: Configuration = Configuration(),
        stateStore: any DownloadStateStore = TransientDownloadStateStore(),
        credentialLoader: (any SourceCredentialLoading)? = nil,
        redirectIdentityLoader: DownloadRedirectIdentityLoader? = nil,
        transport: (any DownloadTransport)? = nil
    ) {
        self.configuration = configuration
        self.stateStore = stateStore
        self.credentialLoader = credentialLoader
        self.redirectIdentityLoader = redirectIdentityLoader
        self.publicationValidator = DownloadedPublicationValidator(limits: configuration.validationLimits)
        self.transport = transport ?? BackgroundURLSessionDownloadTransport(
            redirectIdentityLoader: redirectIdentityLoader,
            stagingDirectory: configuration.offlineDownloadsDirectory.appendingPathComponent(".Staging", isDirectory: true),
            isPrivate: configuration.isPrivate
        )
    }

    /// Restores durable queue state and reconnects tasks already owned by the
    /// background session. Call once during application launch.
    public func restore(repair: (@Sendable (DownloadSnapshot) async throws -> DownloadSnapshot)? = nil) async throws {
        try prepareOfflineDirectory()
        await ensureTransportObservation()

        var persisted: [DownloadSnapshot]
        do {
            persisted = try await stateStore.loadDownloads()
        } catch {
            throw DownloadCoordinatorError.persistence(error.localizedDescription)
        }

        if let repair {
            var repaired: [DownloadSnapshot] = []
            for snapshot in persisted { repaired.append(try await repair(snapshot)) }
            // Commit repaired ownership before any background task is resumed.
            try await stateStore.saveDownloads(repaired)
            persisted = repaired
        }

        let existingTransfers = await transport.prepare()
        for snapshot in persisted where snapshot.lastError == .chapterOwnershipMismatch {
            await transport.cancel(snapshot.id)
            try await saveResumeData(nil, for: snapshot.id)
        }
        snapshotsByID.removeAll(keepingCapacity: true)
        for snapshot in persisted {
            snapshotsByID[snapshot.id] = snapshot
        }
        // Remove opaque request blobs written by older builds. Browser and
        // credential identities are rebuilt just-in-time, including for
        // paused/failed items that may never otherwise reach the scheduler.
        for snapshot in persisted where snapshot.transfer.credentialAccount != nil
            || snapshot.transfer.verificationReference != nil
        {
            try await saveResumeData(nil, for: snapshot.id)
        }
        activeIDs.removeAll(keepingCapacity: true)
        retryPersistenceIDs.removeAll(keepingCapacity: true)
        startTokensByID.removeAll(keepingCapacity: true)
        transportStartingTokensByID.removeAll(keepingCapacity: true)

        var restoredActivePriorities: [(id: UUID, priority: Int)] = []
        for id in snapshotsByID.keys {
            guard var snapshot = snapshotsByID[id] else { continue }
            if snapshot.state == .downloading {
                if existingTransfers.contains(id) {
                    activeIDs.insert(id)
                    restoredActivePriorities.append((id, snapshot.transfer.priority))
                } else {
                    snapshot.state = .queued
                    snapshot.modifiedAt = .now
                    snapshotsByID[id] = snapshot
                }
            }
        }

        isPrepared = true
        try await persistQueue()
        for item in restoredActivePriorities.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            await transport.setPriority(item.priority, for: item.id)
        }
        for snapshot in orderedSnapshots() {
            broadcast(DownloadEvent(kind: .restored, snapshot: snapshot))
        }
        await scheduleAvailableDownloads()
    }

    @discardableResult
    public func enqueue(_ transfer: DownloadTransfer) async throws -> UUID {
        guard !isLocked else { throw DownloadCoordinatorError.storage("Library is locked.") }
        try validate(transfer)
        try prepareOfflineDirectory()
        await ensureTransportObservation()
        if !isPrepared {
            _ = await transport.prepare()
            isPrepared = true
        }
        guard snapshotsByID[transfer.id] == nil else {
            throw DownloadCoordinatorError.duplicateDownload(transfer.id)
        }
        if let existing = protectedDuplicate(for: transfer) {
            throw DownloadCoordinatorError.duplicateDownload(existing.id)
        }

        let snapshot = DownloadSnapshot(transfer: transfer)
        snapshotsByID[transfer.id] = snapshot
        do {
            try await persistQueue()
        } catch {
            if snapshotsByID[transfer.id] == snapshot {
                snapshotsByID.removeValue(forKey: transfer.id)
            }
            throw error
        }
        broadcast(DownloadEvent(kind: .enqueued, snapshot: snapshot))
        await scheduleAvailableDownloads()
        return transfer.id
    }

    public func start(_ id: UUID) async throws {
        guard !isLocked else { throw DownloadCoordinatorError.storage("Library is locked.") }
        try ensureVerificationRetryIsNotPersisting(id)
        guard var snapshot = snapshotsByID[id] else { throw DownloadCoordinatorError.unknownDownload(id) }
        guard snapshot.lastError != .chapterOwnershipMismatch else { throw DownloadCoordinatorError.chapterOwnershipMismatch }
        guard snapshot.lastError != .invalidVerificationContext,
              snapshot.transfer.verificationReference.map({
                  !verificationInvalidationNamespaces.contains($0.namespace)
              }) ?? true
        else { throw DownloadCoordinatorError.invalidVerificationContext }
        guard snapshot.state == .paused || snapshot.state == .failed || snapshot.state == .cancelled || snapshot.state == .queued else {
            throw DownloadCoordinatorError.invalidState(expected: "a paused, failed, cancelled, or queued download", actual: snapshot.state)
        }
        if let existing = protectedDuplicate(for: snapshot.transfer, excluding: id) {
            throw DownloadCoordinatorError.duplicateDownload(existing.id)
        }
        guard snapshot.lastError != .verificationRequired else {
            throw DownloadCoordinatorError.verificationRequired
        }
        snapshot.state = .queued
        snapshot.lastError = nil
        snapshot.modifiedAt = .now
        snapshotsByID[id] = snapshot
        try await persistQueue()
        broadcast(DownloadEvent(kind: .stateChanged, snapshot: snapshot))
        await scheduleAvailableDownloads()
    }

    /// Restarts a challenge-paused transfer after its source's visible WebKit
    /// handoff completes. The retry marker is persisted before networking so a
    /// second challenge remains terminal even after a relaunch.
    public func retryAfterVerification(_ id: UUID) async throws {
        guard var snapshot = snapshotsByID[id] else {
            throw DownloadCoordinatorError.unknownDownload(id)
        }
        if retryPersistenceIDs.contains(id) { return }
        guard snapshot.transfer.verificationReference.map({
            !verificationInvalidationNamespaces.contains($0.namespace)
        }) ?? true
        else { throw DownloadCoordinatorError.invalidVerificationContext }
        if (snapshot.verificationRetryCount ?? 0) == 1,
           snapshot.state != .paused
        {
            // Multiple scenes can observe the same durable requirement. The
            // first caller owns the one restart; later coalesced callers are a
            // no-op rather than a second transfer.
            return
        }
        guard snapshot.state == .paused,
              snapshot.lastError == .verificationRequired,
              snapshot.verificationRequirement != nil,
              (snapshot.verificationRetryCount ?? 0) == 0
        else {
            throw DownloadCoordinatorError.invalidState(
                expected: "a download paused for source verification",
                actual: snapshot.state
            )
        }

        let pausedSnapshot = snapshot
        retryPersistenceIDs.insert(id)
        do {
            // Keep the actor-visible snapshot paused across this first await.
            try await saveResumeData(nil, for: id)
        } catch {
            retryPersistenceIDs.remove(id)
            throw error
        }
        snapshot.verificationRetryCount = 1
        snapshot.verificationURL = nil
        snapshot.state = .queued
        snapshot.lastError = nil
        snapshot.completedBytes = 0
        snapshot.totalBytes = nil
        snapshot.modifiedAt = .now

        await acquireQueuePersistenceLock()
        guard snapshotsByID[id] == pausedSnapshot,
              let verificationNamespace = pausedSnapshot.transfer.verificationReference?.namespace,
              !verificationInvalidationNamespaces.contains(verificationNamespace)
        else {
            retryPersistenceIDs.remove(id)
            releaseQueuePersistenceLock()
            throw DownloadCoordinatorError.invalidVerificationContext
        }
        snapshotsByID[id] = snapshot
        do {
            try await persistQueueUnlocked()
        } catch {
            let retryPersistenceError = error
            // No scheduler may observe a queued retry until its one-retry
            // marker is durable. Clearing resume data is harmless for the
            // challenged transfer, whose response already discarded it.
            snapshotsByID[id] = pausedSnapshot
            do {
                // A store can report failure after partially committing. Keep
                // the FIFO persistence lock while durably restoring the pause.
                try await persistQueueUnlocked()
            } catch {
                retryPersistenceIDs.remove(id)
                releaseQueuePersistenceLock()
                throw error
            }
            retryPersistenceIDs.remove(id)
            releaseQueuePersistenceLock()
            throw retryPersistenceError
        }
        retryPersistenceIDs.remove(id)
        releaseQueuePersistenceLock()
        broadcast(DownloadEvent(kind: .stateChanged, snapshot: snapshot))
        await scheduleAvailableDownloads()
    }

    public func rejectVerificationRequirement(_ id: UUID) async {
        guard !retryPersistenceIDs.contains(id) else { return }
        guard var snapshot = snapshotsByID[id],
              snapshot.state == .paused,
              snapshot.lastError == .verificationRequired
        else { return }
        snapshot.state = .failed
        snapshot.lastError = .invalidVerificationContext
        snapshot.verificationURL = nil
        snapshot.modifiedAt = .now
        snapshotsByID[id] = snapshot
        try? await saveResumeData(nil, for: id)
        try? await persistQueue()
        broadcast(DownloadEvent(kind: .failed, snapshot: snapshot))
        await scheduleAvailableDownloads()
    }

    /// Erases every in-flight use of browser identity for removed extension
    /// namespaces before their secure/WebKit state is deleted. Completed files
    /// remain usable; all other affected records become actionable failures.
    public func invalidateVerificationSessions(namespaces: Set<String>) async throws {
        let namespaces = Set(namespaces.filter { !$0.isEmpty })
        guard !namespaces.isEmpty else { return }
        verificationInvalidationNamespaces.formUnion(namespaces)

        let initiallyAffectedIDs: [UUID] = snapshotsByID.values.compactMap { snapshot -> UUID? in
            guard let namespace = snapshot.transfer.verificationReference?.namespace,
                  namespaces.contains(namespace)
            else { return nil }
            return snapshot.id
        }
        for id in initiallyAffectedIDs {
            await cancelActiveTransferAndAwaitPendingStart(id)
        }

        await acquireQueuePersistenceLock()
        let affectedSnapshots = snapshotsByID.values.compactMap { snapshot -> DownloadSnapshot? in
            guard let namespace = snapshot.transfer.verificationReference?.namespace,
                  namespaces.contains(namespace)
            else { return nil }
            return snapshot
        }
        var updatedSnapshots: [DownloadSnapshot] = []
        for original in affectedSnapshots {
            var updated = original
            // Retain the access provenance so retry can never become an unrestricted request.
            updated.transfer.redirectIdentity = nil
            updated.verificationURL = nil
            updated.verificationRetryCount = nil
            updated.verificationWasTransportObserved = nil
            if updated.state != .completed {
                updated.state = .failed
                updated.lastError = .invalidVerificationContext
                updated.completedBytes = 0
                updated.totalBytes = nil
                updated.localRelativePath = nil
            }
            updated.modifiedAt = .now
            snapshotsByID[updated.id] = updated
            updatedSnapshots.append(updated)
        }

        var firstPersistenceError: Error?
        for snapshot in affectedSnapshots {
            do {
                try await saveResumeData(nil, for: snapshot.id)
            } catch {
                if firstPersistenceError == nil { firstPersistenceError = error }
            }
        }
        do {
            try await persistQueueUnlocked()
        } catch {
            if firstPersistenceError == nil { firstPersistenceError = error }
        }
        releaseQueuePersistenceLock()

        if firstPersistenceError == nil {
            verificationInvalidationNamespaces.subtract(namespaces)
        }
        for snapshot in updatedSnapshots {
            broadcast(DownloadEvent(
                kind: snapshot.state == .completed ? .stateChanged : .failed,
                snapshot: snapshot
            ))
        }
        await scheduleAvailableDownloads()
        if let firstPersistenceError { throw firstPersistenceError }
    }

    /// Fence new starts before awaiting any active transfer, then persist pauses.
    public func lock() async throws {
        isLocked = true
        var firstError: (any Error)?
        let pending = snapshotsByID.values.filter { $0.state == .queued || $0.state == .downloading }
        for snapshot in pending {
            do { try await pause(snapshot.id) }
            catch {
                if firstError == nil { firstError = error }
                await cancelActiveTransferAndAwaitPendingStart(snapshot.id)
            }
        }
        if let firstError { throw firstError }
    }

    public func unlock() { isLocked = false }

    public func pause(_ id: UUID) async throws {
        try ensureVerificationRetryIsNotPersisting(id)
        guard var snapshot = snapshotsByID[id] else { throw DownloadCoordinatorError.unknownDownload(id) }
        guard snapshot.state == .queued || snapshot.state == .downloading else {
            throw DownloadCoordinatorError.invalidState(expected: "a queued or active download", actual: snapshot.state)
        }

        let wasDownloading = snapshot.state == .downloading
        let resumeData: Data?
        if wasDownloading {
            resumeData = await pauseActiveTransferAndAwaitPendingStart(id)
        } else {
            resumeData = nil
        }
        guard let current = snapshotsByID[id],
              current.state == snapshot.state,
              current.transfer.verificationReference == snapshot.transfer.verificationReference
        else {
            throw DownloadCoordinatorError.invalidVerificationContext
        }
        snapshot = current
        snapshot.state = .paused
        snapshot.modifiedAt = .now
        snapshotsByID[id] = snapshot
        try await saveResumeData(resumeData, for: id, replacingOnlyWhenPresent: true)
        try await persistQueue()
        broadcast(DownloadEvent(kind: .stateChanged, snapshot: snapshot))
        await scheduleAvailableDownloads()
    }

    public func resume(_ id: UUID) async throws {
        guard !isLocked else { throw DownloadCoordinatorError.storage("Library is locked.") }
        try ensureVerificationRetryIsNotPersisting(id)
        guard let snapshot = snapshotsByID[id] else { throw DownloadCoordinatorError.unknownDownload(id) }
        guard snapshot.state == .paused else {
            throw DownloadCoordinatorError.invalidState(expected: "a paused download", actual: snapshot.state)
        }
        try await start(id)
    }

    public func cancel(_ id: UUID) async throws {
        try ensureVerificationRetryIsNotPersisting(id)
        guard var snapshot = snapshotsByID[id] else { throw DownloadCoordinatorError.unknownDownload(id) }
        guard snapshot.state != .completed && snapshot.state != .cancelled else {
            throw DownloadCoordinatorError.invalidState(expected: "an incomplete download", actual: snapshot.state)
        }

        await cancelActiveTransferAndAwaitPendingStart(id)
        guard let current = snapshotsByID[id] else {
            throw DownloadCoordinatorError.unknownDownload(id)
        }
        guard current.transfer.verificationReference == snapshot.transfer.verificationReference else {
            throw DownloadCoordinatorError.invalidVerificationContext
        }
        guard current.state != .completed && current.state != .cancelled else {
            throw DownloadCoordinatorError.invalidState(
                expected: "an incomplete download",
                actual: current.state
            )
        }
        snapshot = current
        snapshot.state = .cancelled
        if snapshot.lastError != .chapterOwnershipMismatch { snapshot.lastError = .cancelled }
        snapshot.modifiedAt = .now
        snapshotsByID[id] = snapshot
        try await saveResumeData(nil, for: id)
        try await persistQueue()
        broadcast(DownloadEvent(kind: .stateChanged, snapshot: snapshot))
        await scheduleAvailableDownloads()
    }

    public func retry(_ id: UUID) async throws {
        try ensureVerificationRetryIsNotPersisting(id)
        guard let snapshot = snapshotsByID[id] else { throw DownloadCoordinatorError.unknownDownload(id) }
        guard snapshot.state == .failed || snapshot.state == .cancelled else {
            throw DownloadCoordinatorError.invalidState(expected: "a failed or cancelled download", actual: snapshot.state)
        }
        if snapshot.state == .cancelled {
            try await saveResumeData(nil, for: id)
        }
        try await start(id)
    }

    public func remove(_ id: UUID, deleteFile: Bool = true) async throws {
        try ensureVerificationRetryIsNotPersisting(id)
        guard let snapshot = snapshotsByID[id] else { throw DownloadCoordinatorError.unknownDownload(id) }
        await cancelActiveTransferAndAwaitPendingStart(id)

        if deleteFile, let relativePath = snapshot.localRelativePath {
            let file = configuration.offlineDownloadsDirectory.appendingPathComponent(relativePath)
            do {
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
            } catch {
                throw DownloadCoordinatorError.storage(error.localizedDescription)
            }
        }

        snapshotsByID.removeValue(forKey: id)
        try await saveResumeData(nil, for: id)
        try await persistQueue()
        broadcast(DownloadEvent(kind: .removed, snapshot: snapshot))
        await scheduleAvailableDownloads()
    }

    public func setPriority(_ priority: Int, for id: UUID) async throws {
        try ensureVerificationRetryIsNotPersisting(id)
        guard var snapshot = snapshotsByID[id] else { throw DownloadCoordinatorError.unknownDownload(id) }
        snapshot.transfer.priority = priority
        snapshot.modifiedAt = .now
        snapshotsByID[id] = snapshot
        if activeIDs.contains(id) {
            await transport.setPriority(priority, for: id)
        }
        try await persistQueue()
        broadcast(DownloadEvent(kind: .stateChanged, snapshot: snapshot))
    }

    /// Moves a queued, paused, or failed item immediately before another
    /// queue participant. A currently downloading item can be the anchor, but
    /// cannot itself be moved because its transfer is already in progress.
    ///
    /// Ordering is materialized as unique priorities and persisted, so it is
    /// deterministic after process death and restoration.
    public func move(_ id: UUID, before otherID: UUID) async throws {
        try await move(id, relativeTo: otherID, placement: .before)
    }

    /// Moves a queued, paused, or failed item immediately after another queue
    /// participant. See ``move(_:before:)`` for ordering guarantees.
    public func move(_ id: UUID, after otherID: UUID) async throws {
        try await move(id, relativeTo: otherID, placement: .after)
    }

    /// Applying Wi-Fi-only restarts active transfers, ensuring the new
    /// URLRequest policy applies immediately rather than only to future queue
    /// items. Opaque URLSession resume data retains the previous request's
    /// cellular policy, so a policy change intentionally discards that blob.
    public func setWiFiOnly(_ wifiOnly: Bool) async throws {
        guard configuration.wifiOnly != wifiOnly else { return }
        let previousWiFiOnly = configuration.wifiOnly
        let previouslyActive = activeIDs
        let originalActiveSnapshots = Dictionary(uniqueKeysWithValues: previouslyActive.compactMap { id in
            snapshotsByID[id].map { (id, $0) }
        })
        configuration.wifiOnly = wifiOnly

        do {
            for id in previouslyActive {
                guard let original = originalActiveSnapshots[id] else { continue }
                _ = await pauseActiveTransferAndAwaitPendingStart(id)
                try await saveResumeData(nil, for: id)
                guard var current = snapshotsByID[id],
                      current.state == .downloading,
                      current.transfer.verificationReference == original.transfer.verificationReference,
                      current.transfer.verificationReference.map({
                          !verificationInvalidationNamespaces.contains($0.namespace)
                      }) ?? true
                else { continue }
                current.state = .queued
                current.modifiedAt = .now
                snapshotsByID[id] = current
                broadcast(DownloadEvent(kind: .stateChanged, snapshot: current))
            }
            try await persistQueue()
            await scheduleAvailableDownloads()
        } catch {
            // A failed policy change must not leave the coordinator advertising
            // the requested value while its queue still reflects the old one.
            // Resume blobs already discarded are intentionally rebuilt by
            // restarting the affected transfers from their original requests.
            configuration.wifiOnly = previousWiFiOnly
            for id in previouslyActive {
                guard let original = originalActiveSnapshots[id] else { continue }
                if activeIDs.contains(id) || transportStartingTokensByID[id] != nil {
                    _ = await pauseActiveTransferAndAwaitPendingStart(id)
                }
                guard var current = snapshotsByID[id],
                      current.state == .downloading,
                      current.transfer.verificationReference == original.transfer.verificationReference,
                      current.transfer.verificationReference.map({
                          !verificationInvalidationNamespaces.contains($0.namespace)
                      }) ?? true
                else { continue }
                current.state = .queued
                current.modifiedAt = .now
                snapshotsByID[id] = current
                broadcast(DownloadEvent(kind: .stateChanged, snapshot: current))
            }
            try? await persistQueue()
            await scheduleAvailableDownloads()
            throw error
        }
    }

    public func setMaximumConcurrentDownloads(_ count: Int) async {
        configuration.maximumConcurrentDownloads = max(1, count)
        await scheduleAvailableDownloads()
    }

    public func setBackgroundEventsCompletionHandler(_ handler: (@MainActor @Sendable () -> Void)?) async {
        await transport.setBackgroundEventsCompletionHandler(handler)
    }

    public func snapshot(for id: UUID) -> DownloadSnapshot? {
        snapshotsByID[id]
    }

    public func snapshots() -> [DownloadSnapshot] {
        orderedSnapshots()
    }

    public func progress() -> AsyncStream<DownloadEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: DownloadEvent.self, bufferingPolicy: .bufferingNewest(256))
        continuations[id] = continuation
        for snapshot in orderedSnapshots() {
            continuation.yield(DownloadEvent(kind: .restored, snapshot: snapshot))
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    public func localFileURL(for id: UUID) -> URL? {
        guard let relativePath = snapshotsByID[id]?.localRelativePath else { return nil }
        return configuration.offlineDownloadsDirectory.appendingPathComponent(relativePath)
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func ensureTransportObservation() async {
        guard transportTask == nil else { return }
        let transport = self.transport
        let events = await transport.events()
        transportTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { break }
                await self?.handleTransportEvent(event)
            }
        }
    }

    private func handleTransportEvent(_ event: DownloadTransportEvent) async {
        switch event {
        case let .progress(id, completedBytes, totalBytes):
            guard activeIDs.contains(id), var snapshot = snapshotsByID[id] else { return }
            snapshot.completedBytes = max(snapshot.completedBytes, completedBytes)
            snapshot.totalBytes = totalBytes ?? snapshot.totalBytes
            snapshot.modifiedAt = .now
            snapshotsByID[id] = snapshot
            try? await persistQueue()
            broadcast(DownloadEvent(kind: .progress, snapshot: snapshot))

        case let .finished(id, stagedFile, response):
            guard activeIDs.contains(id), var snapshot = snapshotsByID[id] else {
                try? FileManager.default.removeItem(at: stagedFile)
                return
            }
            activeIDs.remove(id)
            startTokensByID.removeValue(forKey: id)
            if response.isDefinitiveCloudflareChallenge,
               snapshot.transfer.verificationReference != nil
            {
                try? FileManager.default.removeItem(at: stagedFile)
                await handleVerificationChallenge(
                    id: id,
                    responseURL: response.url ?? snapshot.transfer.remoteURL
                )
                await scheduleAvailableDownloads()
                return
            }
            guard (200 ..< 300).contains(response.statusCode) else {
                try? FileManager.default.removeItem(at: stagedFile)
                await markFailed(id, error: .httpStatus(response.statusCode), resumeData: nil)
                await scheduleAvailableDownloads()
                return
            }

            do {
                let relativePath = try await install(stagedFile: stagedFile, snapshot: snapshot, response: response)
                guard let current = snapshotsByID[id],
                      current.state == .downloading,
                      current.transfer.verificationReference == snapshot.transfer.verificationReference
                else {
                    let installedFile = configuration.offlineDownloadsDirectory
                        .appendingPathComponent(relativePath)
                    try? FileManager.default.removeItem(at: installedFile)
                    throw DownloadCoordinatorError.invalidVerificationContext
                }
                snapshot = current
                snapshot.state = .completed
                snapshot.completedBytes = max(snapshot.completedBytes, response.expectedContentLength ?? snapshot.totalBytes ?? 0)
                snapshot.totalBytes = response.expectedContentLength ?? snapshot.totalBytes
                snapshot.localRelativePath = relativePath
                snapshot.lastError = nil
                snapshot.modifiedAt = .now
                snapshotsByID[id] = snapshot
                try await saveResumeData(nil, for: id)
                try await persistQueue()
                broadcast(DownloadEvent(kind: .completed, snapshot: snapshot))
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: stagedFile)
                await markFailed(id, error: .cancelled, resumeData: nil)
            } catch let error as DownloadValidationError {
                try? FileManager.default.removeItem(at: stagedFile)
                await markFailed(id, error: .invalidPublication(error.localizedDescription), resumeData: nil)
            } catch let error as DownloadCoordinatorError {
                try? FileManager.default.removeItem(at: stagedFile)
                await markFailed(id, error: error, resumeData: nil)
            } catch {
                try? FileManager.default.removeItem(at: stagedFile)
                await markFailed(id, error: .storage(error.localizedDescription), resumeData: nil)
            }
            await scheduleAvailableDownloads()

        case let .failed(id, error, resumeData):
            guard activeIDs.contains(id) else { return }
            activeIDs.remove(id)
            startTokensByID.removeValue(forKey: id)
            await markFailed(id, error: error, resumeData: resumeData)
            await scheduleAvailableDownloads()

        case .backgroundEventsFinished:
            broadcast(DownloadEvent(kind: .backgroundEventsFinished))
        }
    }

    private func markFailed(_ id: UUID, error: DownloadCoordinatorError, resumeData: Data?) async {
        guard var snapshot = snapshotsByID[id], snapshot.state != .cancelled, snapshot.state != .paused else { return }
        snapshot.state = .failed
        snapshot.lastError = error
        snapshot.modifiedAt = .now
        snapshotsByID[id] = snapshot
        try? await saveResumeData(resumeData, for: id, replacingOnlyWhenPresent: true)
        try? await persistQueue()
        broadcast(DownloadEvent(kind: .failed, snapshot: snapshot))
    }

    private func handleVerificationChallenge(id: UUID, responseURL: URL) async {
        guard var snapshot = snapshotsByID[id],
              snapshot.state != .cancelled,
              snapshot.state != .paused,
              snapshot.transfer.verificationReference?.isValid == true
        else { return }
        guard let sanitizedURL = DownloadVerificationRequirement.sanitizedChallengeURL(
            responseURL
        ) else {
            await markFailed(id, error: .invalidURL, resumeData: nil)
            return
        }

        snapshot.completedBytes = 0
        snapshot.totalBytes = nil
        snapshot.localRelativePath = nil
        snapshot.verificationURL = sanitizedURL
        snapshot.verificationWasTransportObserved = true
        snapshot.modifiedAt = .now

        if (snapshot.verificationRetryCount ?? 0) == 0 {
            snapshot.state = .paused
            snapshot.lastError = .verificationRequired
        } else {
            snapshot.state = .failed
            snapshot.lastError = .browserOnlyProtection
        }
        snapshotsByID[id] = snapshot
        do {
            try await saveResumeData(nil, for: id)
            try await persistQueue()
            guard snapshotsByID[id] == snapshot else { return }
            broadcast(DownloadEvent(
                kind: snapshot.state == .paused ? .verificationRequired : .failed,
                snapshot: snapshot
            ))
        } catch {
            // Source removal or another terminal action may have changed this
            // record while persistence was suspended. Only the exact challenge
            // transition owns this fallback write.
            guard snapshotsByID[id] == snapshot else { return }
            var failed = snapshot
            failed.state = .failed
            failed.lastError = .persistence(error.localizedDescription)
            failed.verificationURL = nil
            snapshotsByID[id] = failed
            try? await persistQueue()
            broadcast(DownloadEvent(kind: .failed, snapshot: failed))
        }
    }

    private func scheduleAvailableDownloads() async {
        guard !isLocked else { return }
        while !isLocked, activeIDs.count < configuration.maximumConcurrentDownloads,
              let next = nextQueuedSnapshot() {
            var starting = next
            let startToken = UUID()
            starting.state = .downloading
            starting.lastError = nil
            starting.modifiedAt = .now
            snapshotsByID[starting.id] = starting
            activeIDs.insert(starting.id)
            startTokensByID[starting.id] = startToken
            do {
                try await persistQueue()
            } catch {
                guard startTokensByID[starting.id] == startToken else { continue }
                startTokensByID.removeValue(forKey: starting.id)
                activeIDs.remove(starting.id)
                await markFailed(
                    starting.id,
                    error: .persistence(error.localizedDescription),
                    resumeData: nil
                )
                continue
            }
            guard startTokensByID[starting.id] == startToken,
                  activeIDs.contains(starting.id),
                  let persistedStarting = snapshotsByID[starting.id],
                  persistedStarting.state == .downloading
            else { continue }
            broadcast(DownloadEvent(
                kind: .stateChanged,
                snapshot: persistedStarting
            ))

            let resumeData: Data?
            do {
                resumeData = try await stateStore.loadResumeData(for: starting.id)
            } catch {
                guard startTokensByID[starting.id] == startToken else { continue }
                startTokensByID.removeValue(forKey: starting.id)
                activeIDs.remove(starting.id)
                await markFailed(starting.id, error: .persistence(error.localizedDescription), resumeData: nil)
                continue
            }

            let carriesRebuiltIdentity = starting.transfer.credentialAccount != nil
                || starting.transfer.verificationReference != nil
            let safeResumeData = carriesRebuiltIdentity ? nil : resumeData
            do {
                let authorizedTransfer = try await authorized(starting.transfer)
                // URLSession resume blobs are opaque and can retain a request
                // produced before the current credential-origin policy. An
                // authenticated transfer therefore restarts from its original
                // URL so stale redirect state can never carry credentials to a
                // different origin.
                if resumeData != nil, safeResumeData == nil {
                    try await saveResumeData(nil, for: starting.id)
                }
                guard !isLocked, activeIDs.contains(starting.id),
                      startTokensByID[starting.id] == startToken,
                      let current = snapshotsByID[starting.id],
                      current.state == .downloading,
                      current.transfer.verificationReference == starting.transfer.verificationReference,
                      current.transfer.verificationReference.map({
                          !verificationInvalidationNamespaces.contains($0.namespace)
                      }) ?? true
                else { continue }
                var currentAuthorizedTransfer = authorizedTransfer
                currentAuthorizedTransfer.priority = current.transfer.priority
                transportStartingTokensByID[starting.id] = startToken
                do {
                    try await transport.start(
                        currentAuthorizedTransfer,
                        resumeData: safeResumeData,
                        wifiOnly: configuration.wifiOnly
                    )
                } catch {
                    finishTransportStart(id: starting.id, token: startToken)
                    throw error
                }
                finishTransportStart(id: starting.id, token: startToken)
                guard startTokensByID[starting.id] == startToken,
                      activeIDs.contains(starting.id)
                else {
                    // A stop/removal can enter while the cross-actor start is
                    // pending. Ensure any task created after its first cancel
                    // is immediately torn down.
                    await transport.cancel(starting.id)
                    continue
                }
                startTokensByID.removeValue(forKey: starting.id)
            } catch let error as DownloadCoordinatorError {
                guard startTokensByID[starting.id] == startToken else { continue }
                startTokensByID.removeValue(forKey: starting.id)
                activeIDs.remove(starting.id)
                await markFailed(starting.id, error: error, resumeData: safeResumeData)
            } catch {
                guard startTokensByID[starting.id] == startToken else { continue }
                startTokensByID.removeValue(forKey: starting.id)
                activeIDs.remove(starting.id)
                await markFailed(starting.id, error: .network(code: 0, description: error.localizedDescription), resumeData: safeResumeData)
            }
        }
    }

    private func nextQueuedSnapshot() -> DownloadSnapshot? {
        snapshotsByID.values
            .filter {
                $0.state == .queued
                    && $0.lastError != .chapterOwnershipMismatch
                    && !activeIDs.contains($0.id)
                    && !retryPersistenceIDs.contains($0.id)
                    && transportStartingTokensByID[$0.id] == nil
                    && ($0.transfer.verificationReference.map {
                        !verificationInvalidationNamespaces.contains($0.namespace)
                    } ?? true)
            }
            .sorted(by: queueComesBefore)
            .first
    }

    private func ensureVerificationRetryIsNotPersisting(_ id: UUID) throws {
        guard !retryPersistenceIDs.contains(id) else {
            let actual = snapshotsByID[id]?.state ?? .paused
            throw DownloadCoordinatorError.invalidState(
                expected: "the verified retry marker to finish saving",
                actual: actual
            )
        }
    }

    /// A work/installment may have at most one usable or in-flight artifact.
    /// Failed and cancelled records remain outside this invariant so callers
    /// can retry them or enqueue a replacement acquisition.
    private func protectedDuplicate(
        for transfer: DownloadTransfer,
        excluding excludedID: UUID? = nil
    ) -> DownloadSnapshot? {
        orderedSnapshots().first {
            $0.id != excludedID
                && $0.transfer.workID == transfer.workID
                && $0.transfer.installmentID == transfer.installmentID
                && Self.protectsInstallmentDownload($0.state)
        }
    }

    private func authorized(_ transfer: DownloadTransfer) async throws -> DownloadTransfer {
        var authorized = transfer
        authorized.credentialOrigin = nil
        authorized.credentialHeaderNames = []
        authorized.redirectIdentity = nil

        if let account = transfer.credentialAccount,
           let credentialOrigin = transfer.credentialOrigin,
           DownloadCredentialPolicy.isSameOrigin(transfer.remoteURL, as: credentialOrigin),
           let credentialLoader,
           let credential = try await credentialLoader.credential(account: account)
        {
            authorized.credentialOrigin = credentialOrigin
            authorized.headers = try SourceRequestSupport.applying(
                credential: credential,
                to: transfer.headers
            )
            authorized.credentialHeaderNames = DownloadCredentialPolicy.credentialHeaderNames(
                for: credential
            )
        }

        if let reference = transfer.verificationReference,
           reference.isValid,
           let redirectIdentityLoader
        {
            let identity = try await redirectIdentityLoader(
                reference,
                transfer.remoteURL
            )
            if let identity, reference.authorizes(identity) {
                authorized.redirectIdentity = identity
            }
        }
        return authorized
    }

    private func orderedSnapshots() -> [DownloadSnapshot] {
        snapshotsByID.values.sorted {
            let lhsIsQueued = Self.participatesInQueueOrdering($0.state)
            let rhsIsQueued = Self.participatesInQueueOrdering($1.state)
            if lhsIsQueued != rhsIsQueued { return lhsIsQueued }
            if lhsIsQueued { return queueComesBefore($0, $1) }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private enum MovePlacement {
        case before
        case after
    }

    private func move(
        _ id: UUID,
        relativeTo otherID: UUID,
        placement: MovePlacement
    ) async throws {
        guard retryPersistenceIDs.isEmpty else {
            throw DownloadCoordinatorError.invalidMove(
                "Wait for the verified download retry marker to finish saving before reordering the queue."
            )
        }
        try ensureVerificationRetryIsNotPersisting(id)
        try ensureVerificationRetryIsNotPersisting(otherID)
        guard let source = snapshotsByID[id] else {
            throw DownloadCoordinatorError.unknownDownload(id)
        }
        guard let target = snapshotsByID[otherID] else {
            throw DownloadCoordinatorError.unknownDownload(otherID)
        }
        guard id != otherID else {
            throw DownloadCoordinatorError.invalidMove("A download cannot be moved relative to itself.")
        }
        guard Self.canMove(source.state) else {
            throw DownloadCoordinatorError.invalidState(
                expected: "a queued, paused, or failed download",
                actual: source.state
            )
        }
        guard Self.participatesInQueueOrdering(target.state) else {
            throw DownloadCoordinatorError.invalidState(
                expected: "a queued, active, paused, or failed target",
                actual: target.state
            )
        }

        var reordered = snapshotsByID.values
            .filter { Self.participatesInQueueOrdering($0.state) }
            .sorted(by: queueComesBefore)
        guard let sourceIndex = reordered.firstIndex(where: { $0.id == id }) else {
            throw DownloadCoordinatorError.invalidMove("The download is not part of the durable queue.")
        }
        let moved = reordered.remove(at: sourceIndex)
        guard let targetIndex = reordered.firstIndex(where: { $0.id == otherID }) else {
            throw DownloadCoordinatorError.invalidMove("The target is not part of the durable queue.")
        }
        let insertionIndex = placement == .before ? targetIndex : targetIndex + 1
        reordered.insert(moved, at: insertionIndex)

        let now = Date.now
        var originalSnapshots: [UUID: DownloadSnapshot] = [:]
        var changedSnapshots: [DownloadSnapshot] = []
        var changedSnapshotsByID: [UUID: DownloadSnapshot] = [:]
        for (index, candidate) in reordered.enumerated() {
            let newPriority = reordered.count - index
            guard candidate.transfer.priority != newPriority else { continue }
            originalSnapshots[candidate.id] = candidate
            var updated = candidate
            updated.transfer.priority = newPriority
            updated.modifiedAt = now
            snapshotsByID[updated.id] = updated
            changedSnapshots.append(updated)
            changedSnapshotsByID[updated.id] = updated
        }

        guard !changedSnapshots.isEmpty else { return }
        do {
            try await persistQueue()
        } catch {
            for (changedID, original) in originalSnapshots {
                if snapshotsByID[changedID] == changedSnapshotsByID[changedID] {
                    snapshotsByID[changedID] = original
                }
            }
            throw error
        }

        for changed in changedSnapshots where activeIDs.contains(changed.id) {
            guard let current = snapshotsByID[changed.id],
                  current.transfer.priority == changed.transfer.priority,
                  current.transfer.verificationReference == changed.transfer.verificationReference
            else { continue }
            await transport.setPriority(current.transfer.priority, for: current.id)
        }
        for changed in changedSnapshots.sorted(by: queueComesBefore) {
            guard let current = snapshotsByID[changed.id],
                  current.transfer.priority == changed.transfer.priority,
                  current.transfer.verificationReference == changed.transfer.verificationReference
            else { continue }
            broadcast(DownloadEvent(kind: .stateChanged, snapshot: current))
        }
        await scheduleAvailableDownloads()
    }

    private func queueComesBefore(_ lhs: DownloadSnapshot, _ rhs: DownloadSnapshot) -> Bool {
        if lhs.transfer.priority != rhs.transfer.priority {
            return lhs.transfer.priority > rhs.transfer.priority
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func canMove(_ state: DownloadState) -> Bool {
        switch state {
        case .queued, .paused, .failed:
            true
        case .downloading, .completed, .cancelled:
            false
        }
    }

    private static func participatesInQueueOrdering(_ state: DownloadState) -> Bool {
        switch state {
        case .downloading, .queued, .paused, .failed:
            true
        case .completed, .cancelled:
            false
        }
    }

    private static func protectsInstallmentDownload(_ state: DownloadState) -> Bool {
        switch state {
        case .queued, .downloading, .paused, .completed:
            true
        case .failed, .cancelled:
            false
        }
    }

    /// Stops a transfer and closes the reentrant gap where the scheduler has
    /// already invoked `transport.start`, but that cross-actor call has not
    /// returned yet. The second cancellation is intentionally unconditional:
    /// the first can arrive before the transport has created its task.
    private func cancelActiveTransferAndAwaitPendingStart(_ id: UUID) async {
        let pendingStartToken = transportStartingTokensByID[id]
        startTokensByID.removeValue(forKey: id)
        let wasActive = activeIDs.remove(id) != nil
        if wasActive || pendingStartToken != nil {
            await transport.cancel(id)
        }
        if let pendingStartToken {
            await waitForTransportStartSettlement(id: id, token: pendingStartToken)
            await transport.cancel(id)
        }
    }

    /// Pausing uses the same settlement fence as cancellation. If a late start
    /// wins the first transport hop, pause it a second time and prefer the
    /// resulting resume data.
    private func pauseActiveTransferAndAwaitPendingStart(_ id: UUID) async -> Data? {
        let pendingStartToken = transportStartingTokensByID[id]
        startTokensByID.removeValue(forKey: id)
        let wasActive = activeIDs.remove(id) != nil
        var resumeData: Data?
        if wasActive || pendingStartToken != nil {
            resumeData = await transport.pause(id)
        } else {
            resumeData = nil
        }
        if let pendingStartToken {
            await waitForTransportStartSettlement(id: id, token: pendingStartToken)
            if let lateResumeData = await transport.pause(id) {
                resumeData = lateResumeData
            }
        }
        return resumeData
    }

    private func waitForTransportStartSettlement(id: UUID, token: UUID) async {
        guard transportStartingTokensByID[id] == token else { return }
        await withCheckedContinuation { continuation in
            transportStartSettlementWaiters[token, default: []].append(continuation)
        }
    }

    private func finishTransportStart(id: UUID, token: UUID) {
        if transportStartingTokensByID[id] == token {
            transportStartingTokensByID.removeValue(forKey: id)
        }
        let waiters = transportStartSettlementWaiters.removeValue(forKey: token) ?? []
        for waiter in waiters { waiter.resume() }
    }

    private func persistQueue() async throws {
        await acquireQueuePersistenceLock()
        defer { releaseQueuePersistenceLock() }
        try await persistQueueUnlocked()
    }

    private func persistQueueUnlocked() async throws {
        do {
            try await stateStore.saveDownloads(orderedSnapshots())
        } catch let error as DownloadCoordinatorError {
            throw error
        } catch {
            throw DownloadCoordinatorError.persistence(error.localizedDescription)
        }
    }

    private func acquireQueuePersistenceLock() async {
        guard queuePersistenceIsLocked else {
            queuePersistenceIsLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            queuePersistenceWaiters.append(continuation)
        }
    }

    private func releaseQueuePersistenceLock() {
        guard !queuePersistenceWaiters.isEmpty else {
            queuePersistenceIsLocked = false
            return
        }
        let continuation = queuePersistenceWaiters.removeFirst()
        continuation.resume()
    }

    private func saveResumeData(_ data: Data?, for id: UUID, replacingOnlyWhenPresent: Bool = false) async throws {
        let carriesRebuiltIdentity = snapshotsByID[id].map {
            $0.transfer.credentialAccount != nil
                || $0.transfer.verificationReference != nil
        } ?? false
        if replacingOnlyWhenPresent, data == nil, !carriesRebuiltIdentity { return }
        // Opaque URLSession resume data can embed the original request. A
        // credential-bearing or WebKit-verified transfer always restarts from
        // its public URL with freshly rebuilt identity, so no such blob is ever
        // written to durable storage—even if this call resumes after removal.
        let sanitizedData = carriesRebuiltIdentity ? nil : data
        do {
            try await stateStore.saveResumeData(sanitizedData, for: id)
        } catch {
            throw DownloadCoordinatorError.persistence(error.localizedDescription)
        }
    }

    private func validate(_ transfer: DownloadTransfer) throws {
        if let reference = transfer.verificationReference, !reference.isValid {
            throw DownloadCoordinatorError.invalidURL
        }
        if let namespace = transfer.verificationReference?.namespace,
           verificationInvalidationNamespaces.contains(namespace)
        {
            throw DownloadCoordinatorError.invalidVerificationContext
        }
        do {
            try endpointPolicy.validate(transfer.remoteURL, access: transfer.endpointAccess)
        } catch HTTPClientError.invalidURL {
            throw DownloadCoordinatorError.invalidURL
        } catch HTTPClientError.insecurePublicEndpoint {
            throw DownloadCoordinatorError.insecureEndpoint
        } catch let HTTPClientError.unsupportedScheme(scheme) {
            throw DownloadCoordinatorError.unsupportedScheme(scheme)
        } catch {
            throw DownloadCoordinatorError.invalidURL
        }
    }

    private func prepareOfflineDirectory() throws {
        do {
            let directory = configuration.offlineDownloadsDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var mutableDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try mutableDirectory.setResourceValues(values)
        } catch {
            throw DownloadCoordinatorError.storage(error.localizedDescription)
        }
    }

    private func install(stagedFile: URL, snapshot: DownloadSnapshot, response: DownloadTransportResponse) async throws -> String {
        guard FileManager.default.fileExists(atPath: stagedFile.path) else {
            throw DownloadCoordinatorError.missingDownloadedFile
        }

        if let expectedFormat = expectedFormat(for: snapshot.transfer) {
            _ = try await publicationValidator.validate(stagedFile, expectedFormat: expectedFormat)
        }
        try Task.checkCancellation()

        let workDirectory = configuration.offlineDownloadsDirectory
            .appendingPathComponent(snapshot.transfer.workID.rawValue.uuidString, isDirectory: true)
        let installmentDirectory = workDirectory
            .appendingPathComponent(snapshot.transfer.installmentID.rawValue.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: installmentDirectory, withIntermediateDirectories: true)
        } catch {
            throw DownloadCoordinatorError.storage(error.localizedDescription)
        }

        let candidateName = response.suggestedFilename ?? snapshot.transfer.suggestedFilename
        let filename = safeFilename(candidateName, fallbackExtensionFrom: snapshot.transfer.remoteURL)
        let uniqueFilename = "\(snapshot.id.uuidString)-\(filename)"
        let destination = installmentDirectory.appendingPathComponent(uniqueFilename, isDirectory: false)
        let temporaryDestination = installmentDirectory.appendingPathComponent(".\(snapshot.id.uuidString).installing", isDirectory: false)

        do {
            if FileManager.default.fileExists(atPath: temporaryDestination.path) {
                try FileManager.default.removeItem(at: temporaryDestination)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: stagedFile, to: temporaryDestination)
            try FileManager.default.setAttributes(
                [.protectionKey: configuration.isPrivate ? FileProtectionType.complete : .completeUntilFirstUserAuthentication],
                ofItemAtPath: temporaryDestination.path
            )
            try FileManager.default.moveItem(at: temporaryDestination, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporaryDestination)
            throw DownloadCoordinatorError.storage(error.localizedDescription)
        }

        return destination.path.replacingOccurrences(
            of: configuration.offlineDownloadsDirectory.path + "/",
            with: "",
            options: [.anchored]
        )
    }

    private func expectedFormat(for transfer: DownloadTransfer) -> PublicationFormat? {
        if let expectedFormat = transfer.expectedFormat {
            return expectedFormat
        }

        // Suwayomi's compiled-in acquisition route always materializes a CBZ.
        // Keeping this narrow avoids guessing formats from arbitrary URLs.
        let components = transfer.remoteURL.pathComponents.map { $0.lowercased() }
        guard
            components.count >= 3,
            components[components.count - 3] == "chapter",
            components.last == "download"
        else {
            return nil
        }
        return .cbz
    }

    private func safeFilename(_ proposed: String, fallbackExtensionFrom url: URL) -> String {
        let decoded = proposed.removingPercentEncoding ?? proposed
        let invalid = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        let scalars = decoded.unicodeScalars.map { invalid.contains($0) ? "_" : String($0) }
        var result = scalars.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix(".") { result.removeFirst() }
        if result.isEmpty { result = "publication" }
        if (result as NSString).pathExtension.isEmpty {
            let fallbackExtension = url.pathExtension.lowercased()
            if !fallbackExtension.isEmpty {
                result += ".\(fallbackExtension)"
            }
        }
        return String(result.prefix(180))
    }

    private func broadcast(_ event: DownloadEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }
}

/// A background-session transport. The delegate moves the ephemeral download
/// callback file into a stable staging directory before returning, because the
/// system removes the original callback URL immediately afterwards.
