import Foundation

/// One active search operation and one latest pending operation per source.
/// Identical callers share a result; cancellation removes only that consumer.
@MainActor
public final class SourceSearchRequestCoordinator {
    private final class Flight {
        let key: String
        let operation: @MainActor () async throws -> Data
        var waiters: [UUID: CheckedContinuation<Data, Error>] = [:]
        var task: Task<Void, Never>?
        init(key: String, operation: @escaping @MainActor () async throws -> Data) {
            self.key = key; self.operation = operation
        }
    }
    private var active: Flight?
    private var pending: Flight?
    private var nextStart: TimeInterval = 0
    private var cooldown: TimeInterval = 0
    var pendingRequestKey: String? { pending?.key }
    var activeConsumerCount: Int { active?.waiters.count ?? 0 }
    private let now: @MainActor () -> TimeInterval
    private let sleep: @MainActor (Duration) async throws -> Void

    public init(now: @escaping @MainActor () -> TimeInterval = { Date.timeIntervalSinceReferenceDate },
                sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.now = now; self.sleep = sleep
    }

    public func run<Value: Codable & Sendable>(key: String,
        operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let id = UUID()
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if let flight = [active, pending].compactMap({ $0 }).first(where: { $0.key == key }) {
                    flight.waiters[id] = continuation
                    return
                }
                let flight = Flight(key: key) { try JSONEncoder().encode(await operation()) }
                flight.waiters[id] = continuation
                if active == nil { start(flight) }
                else {
                    if let pending { finish(pending, result: .failure(CancellationError())) }
                    pending = flight
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel(id) } }
        try Task.checkCancellation()
        return try JSONDecoder().decode(Value.self, from: data)
    }

    public func reportRateLimit(retryAfter: String?, at date: Date = .now) {
        let parsed = HTTPClient.retryDelay(from: retryAfter, now: date)
        let delay = parsed.flatMap { $0.isFinite ? $0 : nil } ?? 5
        cooldown = max(cooldown, now() + max(0, delay))
    }

    /// A fallback within a suggestion invocation spends another request slot.
    public func waitForTransport(isFallback: Bool) async throws {
        try await wait(until: { isFallback ? max(self.nextStart, self.cooldown) : self.cooldown })
        if isFallback { nextStart = now() + 1 }
    }

    public func invalidate() {
        if let pending { self.pending = nil; finish(pending, result: .failure(CancellationError())) }
        if let active { active.task?.cancel(); finish(active, result: .failure(CancellationError())) }
    }

    private func wait(until deadline: @MainActor () -> TimeInterval) async throws {
        while deadline() > now() {
            try await sleep(.seconds(min(60, deadline() - now())))
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
    }
    private func start(_ flight: Flight) {
        active = flight
        flight.task = Task { [weak self] in
            guard let self else { return }
            let result: Result<Data, Error>
            do {
                try await wait(until: { max(self.nextStart, self.cooldown) })
                nextStart = now() + 1
                let data = try await SourceCachePolicy.$searchCoordinator.withValue(self) { try await flight.operation() }
                try Task.checkCancellation()
                result = .success(data)
            } catch { result = .failure(error) }
            finish(flight, result: result)
            if active === flight {
                active = nil
                if let pending { self.pending = nil; start(pending) }
            }
        }
    }
    private func finish(_ flight: Flight, result: Result<Data, Error>) {
        let waiters = flight.waiters.values
        flight.waiters.removeAll()
        for waiter in waiters { waiter.resume(with: result) }
    }
    private func cancel(_ id: UUID) {
        for flight in [active, pending].compactMap({ $0 }) {
            guard let waiter = flight.waiters.removeValue(forKey: id) else { continue }
            waiter.resume(throwing: CancellationError())
            if flight.waiters.isEmpty {
                if pending === flight { pending = nil }
                else { flight.task?.cancel() }
            }
        }
    }
}
