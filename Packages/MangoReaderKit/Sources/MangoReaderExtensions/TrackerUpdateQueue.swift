import CryptoKit
import Foundation
import MangoReaderDomain

public enum TrackerUpdateDeliveryState: String, Codable, Hashable, Sendable {
    case ready
    case awaitingReauthentication
    case awaitingReview
    case permanentlyFailed
}

public enum TrackerDeliveryFailure: String, Codable, Hashable, Sendable, LocalizedError {
    case missingCredential
    case unauthorized
    case rateLimited
    case transient
    case permanent

    public var errorDescription: String? {
        switch self {
        case .missingCredential: "Tracker sign-in is required."
        case .unauthorized: "The tracker session expired."
        case .rateLimited: "The tracker requested a delivery pause."
        case .transient: "The tracker update failed temporarily."
        case .permanent: "The tracker rejected the update."
        }
    }
}

public struct QueuedTrackerUpdate: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var progress: TrackerProgress
    public var attempts: Int
    public var nextAttemptAt: Date
    public var deliveryState: TrackerUpdateDeliveryState
    public var lastFailure: TrackerDeliveryFailure?
    public var expectedBaseline: TrackerSyncSnapshot?
    public var linkGeneration: UUID?

    public var lastError: String? { lastFailure?.errorDescription }

    public init(
        id: UUID = UUID(),
        progress: TrackerProgress,
        attempts: Int = 0,
        nextAttemptAt: Date = .now,
        deliveryState: TrackerUpdateDeliveryState = .ready,
        lastFailure: TrackerDeliveryFailure? = nil,
        expectedBaseline: TrackerSyncSnapshot? = nil,
        linkGeneration: UUID? = nil
    ) {
        self.id = id
        self.progress = progress
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.deliveryState = deliveryState
        self.lastFailure = lastFailure
        self.expectedBaseline = expectedBaseline
        self.linkGeneration = linkGeneration
    }

    public var idempotencyKey: String {
        TrackerUpdateIdempotency.key(for: progress)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case progress
        case attempts
        case nextAttemptAt
        case deliveryState
        case lastFailure
        case expectedBaseline
        case linkGeneration
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        progress = try container.decode(TrackerProgress.self, forKey: .progress)
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        nextAttemptAt = try container.decodeIfPresent(Date.self, forKey: .nextAttemptAt) ?? .now
        deliveryState = try container.decodeIfPresent(
            TrackerUpdateDeliveryState.self,
            forKey: .deliveryState
        ) ?? .ready
        lastFailure = try container.decodeIfPresent(TrackerDeliveryFailure.self, forKey: .lastFailure)
        expectedBaseline = try container.decodeIfPresent(TrackerSyncSnapshot.self, forKey: .expectedBaseline)
        linkGeneration = try container.decodeIfPresent(UUID.self, forKey: .linkGeneration)
        if expectedBaseline == nil { deliveryState = .awaitingReview }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(progress, forKey: .progress)
        try container.encode(attempts, forKey: .attempts)
        try container.encode(nextAttemptAt, forKey: .nextAttemptAt)
        try container.encode(deliveryState, forKey: .deliveryState)
        try container.encodeIfPresent(lastFailure, forKey: .lastFailure)
        try container.encodeIfPresent(expectedBaseline, forKey: .expectedBaseline)
        try container.encodeIfPresent(linkGeneration, forKey: .linkGeneration)
    }
}

public enum TrackerUpdateIdempotency {
    /// A stable, header-safe key derived only from non-credential update state.
    public static func key(for progress: TrackerProgress) -> String {
        let timestampBits = progress.modifiedAt.timeIntervalSinceReferenceDate.bitPattern
        let input = "\(progress.trackerID.rawValue)\u{1F}\(progress.remoteWorkID)\u{1F}\(timestampBits)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return "mr-" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

public actor TrackerUpdateQueue {
    public typealias Delivery = @Sendable (QueuedTrackerUpdate, any TrackerProvider) async throws -> Set<TrackerSyncField>

    private enum ErrorDisposition {
        case cancelled
        case authentication(TrackerDeliveryFailure)
        case rateLimited(Date?)
        case transient
        case permanent

        var isTransient: Bool {
            if case .transient = self { return true }
            return false
        }
    }

    private let isPrivate: Bool
    private let fileURL: URL
    private var updates: [QueuedTrackerUpdate]
    private var isFlushing = false

    public init(fileURL: URL? = nil, isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.fileURL = fileURL ?? root
            .appendingPathComponent("manko", isDirectory: true)
            .appendingPathComponent("Tracking", isDirectory: true)
            .appendingPathComponent("queue.json")
        if let data = try? Data(contentsOf: self.fileURL),
           let saved = try? JSONDecoder().decode([QueuedTrackerUpdate].self, from: data) {
            updates = saved
            // Re-encode immediately to remove legacy free-form `lastError`
            // values, which may have captured credential-bearing text.
            try? Self.persist(saved, to: self.fileURL, isPrivate: isPrivate)
        } else {
            updates = []
        }
    }

    public func enqueue(_ progress: TrackerProgress, now: Date = .now,
                        expectedBaseline: TrackerSyncSnapshot? = nil, linkGeneration: UUID? = nil) throws {
        let previous = updates
        var item = QueuedTrackerUpdate(progress: progress, nextAttemptAt: now,
            deliveryState: expectedBaseline == nil ? .awaitingReview : .ready,
            expectedBaseline: expectedBaseline, linkGeneration: linkGeneration)
        if let authenticationBlock = updates.first(where: {
            $0.progress.trackerID == progress.trackerID
                && $0.deliveryState == .awaitingReauthentication
        }) {
            item.deliveryState = .awaitingReauthentication
            item.lastFailure = authenticationBlock.lastFailure
            item.nextAttemptAt = authenticationBlock.nextAttemptAt
        } else if let trackerDelay = updates
            .filter({
                $0.progress.trackerID == progress.trackerID
                    && $0.deliveryState == .ready
                    && $0.nextAttemptAt > now
            })
            .map(\.nextAttemptAt)
            .max()
        {
            item.nextAttemptAt = trackerDelay
        }

        if let index = updates.firstIndex(where: {
            $0.progress.trackerID == progress.trackerID && $0.progress.remoteWorkID == progress.remoteWorkID
        }) {
            guard updates[index].progress.modifiedAt < progress.modifiedAt else { return }
            let existing = updates[index]
            // Different authorizations must never inherit another link/account's edits.
            let sameAuthorization = existing.linkGeneration == linkGeneration && existing.expectedBaseline != nil
            if sameAuthorization, let newFields = item.progress.fieldsToUpdate {
                let previousFields = existing.progress.updateFields
                let retained = previousFields.subtracting(newFields)
                if retained.contains(.chapter) { item.progress.chapter = existing.progress.chapter }
                if retained.contains(.volume) { item.progress.volume = existing.progress.volume }
                if retained.contains(.status) { item.progress.status = existing.progress.status }
                if retained.contains(.rating) { item.progress.score = existing.progress.score }
                item.progress.fieldsToUpdate = newFields.union(previousFields)
                for field in retained { item.expectedBaseline?.copy(field, from: existing.expectedBaseline!) }

            }
            if sameAuthorization, let previousDates = existing.progress.dateUpdates {
                var dates = item.progress.dateUpdates ?? previousDates
                if !dates.fields.contains(.startDate), previousDates.fields.contains(.startDate) {
                    dates.startDate = previousDates.startDate
                    dates.fields.insert(.startDate)
                }
                if !dates.fields.contains(.finishDate), previousDates.fields.contains(.finishDate) {
                    dates.finishDate = previousDates.finishDate
                    dates.fields.insert(.finishDate)
                }
                item.progress.dateUpdates = dates
            }
            if sameAuthorization, existing.deliveryState == .awaitingReauthentication {
                item.deliveryState = existing.deliveryState
                item.lastFailure = existing.lastFailure
                item.nextAttemptAt = existing.nextAttemptAt
                item.attempts = existing.attempts
            } else if existing.deliveryState == .ready && existing.nextAttemptAt > item.nextAttemptAt {
                item.lastFailure = existing.lastFailure
                item.nextAttemptAt = existing.nextAttemptAt
                item.attempts = existing.attempts
            }
            updates[index] = item
        } else {
            updates.append(item)
        }
        do {
            try persist()
        } catch {
            updates = previous
            throw error
        }
    }

    public func isCurrent(_ item: QueuedTrackerUpdate) -> Bool {
        updates.contains { $0.id == item.id && $0.deliveryState == .ready }
    }

    public func pending() -> [QueuedTrackerUpdate] {
        updates.sorted { $0.nextAttemptAt < $1.nextAttemptAt }
    }

    /// A newer edit may arrive while a write awaits its provider. Carry only
    /// successfully written fields into that edit's expected baseline.
    public func acknowledgeDelivery(of delivered: QueuedTrackerUpdate, fields: Set<TrackerSyncField>,
                                    snapshot: TrackerSyncSnapshot) throws {
        guard !fields.isEmpty, let index = updates.firstIndex(where: {
            $0.id != delivered.id && $0.progress.trackerID == delivered.progress.trackerID
                && $0.progress.remoteWorkID == delivered.progress.remoteWorkID
                && $0.linkGeneration == delivered.linkGeneration
        }), let expected = updates[index].expectedBaseline, let previousExpected = delivered.expectedBaseline else { return }
        let previous = updates
        for field in fields where expected.value(for: field) == previousExpected.value(for: field) {
            updates[index].expectedBaseline?.copy(field, from: snapshot)
        }
        do { try persist() } catch { updates = previous; throw error }
    }

    /// A queued edit must not overwrite a field that now needs user resolution.
    public func excludeFields(_ fields: Set<TrackerSyncField>, trackerID: TrackerID, remoteWorkID: String) throws {
        guard !fields.isEmpty, let index = updates.firstIndex(where: {
            $0.progress.trackerID == trackerID && $0.progress.remoteWorkID == remoteWorkID
        }) else { return }
        let previous = updates
        var item = updates[index]
        item.progress.fieldsToUpdate = item.progress.updateFields.subtracting(fields)
        if fields.contains(.chapter) { item.progress.chapter = nil }
        if fields.contains(.volume) { item.progress.volume = nil }
        if fields.contains(.status) { item.progress.status = nil }
        if fields.contains(.rating) { item.progress.score = nil }
        if var dates = item.progress.dateUpdates {
            dates.fields.subtract(fields)
            item.progress.dateUpdates = dates.fields.isEmpty ? nil : dates
        }
        if item.progress.fieldsToUpdate?.isEmpty == true && item.progress.dateUpdates == nil {
            updates.remove(at: index)
        } else {
            item.id = UUID()
            updates[index] = item
        }
        do { try persist() } catch { updates = previous; throw error }
    }

    public func discardUpdates(for trackerIDs: Set<TrackerID>) throws {
        guard updates.contains(where: { trackerIDs.contains($0.progress.trackerID) }) else { return }
        let previous = updates
        updates.removeAll { trackerIDs.contains($0.progress.trackerID) }
        do {
            try persist()
        } catch {
            updates = previous
            throw error
        }
    }

    public func discardUpdate(for trackerID: TrackerID, remoteWorkID: String) throws {
        guard updates.contains(where: {
            $0.progress.trackerID == trackerID && $0.progress.remoteWorkID == remoteWorkID
        }) else { return }
        let previous = updates
        updates.removeAll {
            $0.progress.trackerID == trackerID && $0.progress.remoteWorkID == remoteWorkID
        }
        do {
            try persist()
        } catch {
            updates = previous
            throw error
        }
    }

    public func resumeAfterReauthentication(for trackerID: TrackerID, now: Date = .now) throws {
        let previous = updates
        for index in updates.indices where
            updates[index].progress.trackerID == trackerID
                && updates[index].deliveryState == .awaitingReauthentication
        {
            updates[index].deliveryState = .ready
            updates[index].nextAttemptAt = now
            updates[index].lastFailure = nil
        }
        do {
            try persist()
        } catch {
            updates = previous
            throw error
        }
    }

    public func flush(using providers: [TrackerID: any TrackerProvider], now: Date = .now,
                      delivery: Delivery? = nil) async {
        try? await flush(
            using: providers,
            now: now,
            reportsCloudflareChallenges: false, delivery: delivery
        )
    }

    /// Flushes updates while leaving a Cloudflare-challenged item untouched and
    /// surfacing its handoff context to the app-level recovery coordinator.
    /// Every other failure keeps the queue's existing authentication, rate-limit,
    /// retry, and permanent-failure semantics.
    public func flushReportingCloudflareChallenges(
        using providers: [TrackerID: any TrackerProvider],
        now: Date = .now,
        delivery: Delivery? = nil
    ) async throws {
        try await flush(
            using: providers,
            now: now,
            reportsCloudflareChallenges: true, delivery: delivery
        )
    }

    private func flush(
        using providers: [TrackerID: any TrackerProvider],
        now: Date,
        reportsCloudflareChallenges: Bool,
        delivery: Delivery?
    ) async throws {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        let deliverable = updates.filter {
            $0.deliveryState == .ready && $0.nextAttemptAt <= now
        }
        deliveryLoop: for item in deliverable {
            guard updates.contains(where: {
                $0.id == item.id && $0.deliveryState == .ready && $0.nextAttemptAt <= now
            }) else {
                continue
            }
            guard let provider = providers[item.progress.trackerID] else { continue }
            do {
                let blocked: Set<TrackerSyncField>
                if let delivery {
                    blocked = try await delivery(item, provider)
                } else {
                    let remoteProgress = try await provider.progress(remoteWorkID: item.progress.remoteWorkID)
                    let remote = remoteProgress.map(TrackerSyncSnapshot.init) ?? .init()
                    var decision = TrackerDeliveryDecision.reconcile(update: item.progress,
                        baseline: item.expectedBaseline, remote: remote)
                    if remoteProgress == nil, item.expectedBaseline != .init() {
                        decision.fieldsToSend = []; decision.conflicts = item.progress.updateFields
                    }
                    guard isCurrent(item) else { continue }
                    if !decision.fieldsToSend.isEmpty {
                        try await provider.update(item.progress.updatingOnly(decision.fieldsToSend))
                        var written = remote
                        for field in decision.fieldsToSend { written.copy(field, from: TrackerSyncSnapshot(item.progress)) }
                        try acknowledgeDelivery(of: item, fields: decision.fieldsToSend, snapshot: written)
                    }
                    blocked = decision.conflicts
                }
                guard commitMutation({ updates in
                    guard let index = updates.firstIndex(where: { $0.id == item.id }) else { return }
                    if blocked.isEmpty { updates.remove(at: index) }
                    else {
                        updates[index].progress = item.progress.updatingOnly(blocked)
                        updates[index].deliveryState = .awaitingReview
                    }
                }) else {
                    return
                }
            } catch {
                if reportsCloudflareChallenges,
                   let runtimeError = error as? MangoReaderExtensionRuntimeError,
                   case .cloudflareHandoff = runtimeError
                {
                    throw runtimeError
                }
                let disposition = Self.disposition(for: error, now: now)
                switch disposition {
                case .cancelled:
                    break deliveryLoop
                case let .authentication(failure):
                    guard commitMutation({ updates in
                        Self.blockForReauthentication(
                            &updates,
                            trackerID: item.progress.trackerID,
                            attemptedItemID: item.id,
                            failure: failure
                        )
                    }) else { return }
                case let .rateLimited(retryAt):
                    guard commitMutation({ updates in
                        Self.applyRateLimit(
                            &updates,
                            trackerID: item.progress.trackerID,
                            attemptedItemID: item.id,
                            retryAt: retryAt,
                            now: now
                        )
                    }) else { return }
                case .transient, .permanent:
                    let committed = commitMutation { updates in
                        let index = updates.firstIndex(where: { $0.id == item.id })
                            ?? updates.firstIndex(where: {
                                disposition.isTransient
                                    && $0.progress.trackerID == item.progress.trackerID
                                    && $0.progress.remoteWorkID == item.progress.remoteWorkID
                                    && $0.progress.modifiedAt > item.progress.modifiedAt
                            })
                        guard let index else { return }
                        updates[index].attempts += 1
                        Self.apply(disposition: disposition, to: &updates[index], now: now)
                    }
                    guard committed else { return }
                }
            }
        }
    }

    private static func blockForReauthentication(
        _ updates: inout [QueuedTrackerUpdate],
        trackerID: TrackerID,
        attemptedItemID: UUID,
        failure: TrackerDeliveryFailure
    ) {
        for index in updates.indices where updates[index].progress.trackerID == trackerID {
            if updates[index].id == attemptedItemID {
                updates[index].attempts += 1
            }
            updates[index].deliveryState = .awaitingReauthentication
            updates[index].lastFailure = failure
        }
    }

    private static func applyRateLimit(
        _ updates: inout [QueuedTrackerUpdate],
        trackerID: TrackerID,
        attemptedItemID: UUID,
        retryAt: Date?,
        now: Date
    ) {
        for index in updates.indices where updates[index].progress.trackerID == trackerID {
            if updates[index].id == attemptedItemID {
                updates[index].attempts += 1
            }
            let attempts = max(1, updates[index].attempts)
            let fallbackDate = now.addingTimeInterval(backoffDelay(attempts: attempts))
            let requestedDate = retryAt.map { max($0, now) } ?? fallbackDate
            updates[index].nextAttemptAt = max(updates[index].nextAttemptAt, requestedDate)
            updates[index].lastFailure = .rateLimited
        }
    }

    private static func disposition(for error: any Error, now: Date) -> ErrorDisposition {
        if error is CancellationError {
            return .cancelled
        }
        if let sourceError = error as? SourceError {
            switch sourceError {
            case .cancelled:
                return .cancelled
            case .unauthorized:
                return .authentication(.unauthorized)
            case let .rateLimited(retryAfterSeconds):
                return .rateLimited(retryAfterSeconds.map { now.addingTimeInterval(max(0, $0)) })
            case let .server(statusCode) where statusCode == 429:
                return .rateLimited(nil)
            case .transport:
                return .transient
            case let .server(statusCode) where isTransient(statusCode: statusCode):
                return .transient
            case .invalidURL, .insecurePublicEndpoint, .unsafeResourceURL, .forbidden,
                 .notFound, .resourceLimitExceeded, .unsupportedResponse, .server:
                return .permanent
            }
        }
        if let runtimeError = error as? MangoReaderExtensionRuntimeError {
            switch runtimeError {
            case .invalidPackage, .undeclaredHost, .responseTooLarge,
                 .webExecutionDenied, .webExecutionResultTooLarge:
                return .permanent
            case .sourceUnavailable, .initializationFailed, .operationFailed, .operationTimedOut, .executionBudgetExceeded,
                 .heartbeatLost, .runtimeTerminated, .webExecutionTimedOut, .cloudflareHandoff:
                return .transient
            }
        }
        return .transient
    }

    private static func apply(
        disposition: ErrorDisposition,
        to update: inout QueuedTrackerUpdate,
        now: Date
    ) {
        switch disposition {
        case let .authentication(failure):
            update.deliveryState = .awaitingReauthentication
            update.lastFailure = failure
        case let .rateLimited(retryAt):
            let fallbackDate = now.addingTimeInterval(backoffDelay(attempts: update.attempts))
            update.nextAttemptAt = retryAt.map { max($0, now) } ?? fallbackDate
            update.lastFailure = .rateLimited
        case .transient:
            update.nextAttemptAt = now.addingTimeInterval(backoffDelay(attempts: update.attempts))
            update.lastFailure = .transient
        case .permanent:
            update.deliveryState = .permanentlyFailed
            update.lastFailure = .permanent
        case .cancelled:
            break
        }
    }

    private static func backoffDelay(attempts: Int) -> TimeInterval {
        let exponent = max(0, min(attempts - 1, 10))
        return min(3_600, 5 * pow(2, Double(exponent)))
    }

    private static func isTransient(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 425 || (500...599).contains(statusCode)
    }

    private func persist() throws {
        try Self.persist(updates, to: fileURL, isPrivate: isPrivate)
    }

    private func commitMutation(_ mutation: (inout [QueuedTrackerUpdate]) -> Void) -> Bool {
        let previous = updates
        mutation(&updates)
        do {
            try persist()
            return true
        } catch {
            updates = previous
            return false
        }
    }

    private static func persist(_ updates: [QueuedTrackerUpdate], to fileURL: URL, isPrivate: Bool) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(updates)
        try data.write(to: fileURL, options: [.atomic, isPrivate ? .completeFileProtection : .completeFileProtectionUntilFirstUserAuthentication])
    }
}
