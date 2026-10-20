import Foundation
import Synchronization

/// Bridges the synchronous cancellation handler to the main-actor settlement.
/// The flag must be visible even before the queued actor callback can run.
private final class MangoReaderOperationCancellation: Sendable {
    private let requested = Mutex(false)
    func cancel() { requested.withLock { $0 = true } }
    var isCancelled: Bool { requested.withLock { $0 } }
}

@MainActor
final class MangoReaderOperationRace {
    private let sleep: @MainActor @Sendable (Duration) async throws -> Void

    init(sleep: @escaping @MainActor @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    // Each call owns its settlement, so late completions cannot settle a later
    // call even when a transport does not promptly cooperate with cancellation.
    @MainActor
    private final class Attempt {
        let cancellation = MangoReaderOperationCancellation()
        var continuation: CheckedContinuation<String, Error>?
        var operationTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        let onTimeout: @MainActor () -> Void
        let onCancellation: @MainActor @Sendable () -> Void

        init(onTimeout: @escaping @MainActor () -> Void,
             onCancellation: @escaping @MainActor @Sendable () -> Void) {
            self.onTimeout = onTimeout
            self.onCancellation = onCancellation
        }

        func finish(_ result: Result<String, Error>, timedOut: Bool = false) {
            guard let continuation else { return }
            self.continuation = nil
            operationTask?.cancel()
            timeoutTask?.cancel()
            operationTask = nil
            timeoutTask = nil
            if cancellation.isCancelled {
                onCancellation()
                continuation.resume(throwing: CancellationError())
            } else {
                if timedOut { onTimeout() }
                continuation.resume(with: result)
            }
        }
    }

    func run(
        timeout: Duration,
        timeoutError: MangoReaderExtensionRuntimeError = .operationTimedOut,
        operation: @escaping @MainActor () async throws -> String,
        onTimeout: @escaping @MainActor () -> Void,
        onCancellation: @escaping @MainActor @Sendable () -> Void = {}
    ) async throws -> String {
        try Task.checkCancellation()
        let attempt = Attempt(onTimeout: onTimeout, onCancellation: onCancellation)
        let cancellation = attempt.cancellation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                attempt.continuation = continuation
                guard !cancellation.isCancelled else {
                    attempt.finish(.failure(CancellationError()))
                    return
                }
                attempt.operationTask = Task { @MainActor in
                    do {
                        let value = try await operation()
                        attempt.finish(.success(value))
                    } catch {
                        attempt.finish(.failure(error))
                    }
                }
                attempt.timeoutTask = Task { @MainActor in
                    do {
                        try await sleep(timeout)
                        guard !Task.isCancelled else { return }
                        attempt.finish(.failure(timeoutError), timedOut: true)
                    } catch {
                        // Cancellation means another outcome won.
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor in attempt.finish(.failure(CancellationError())) }
        }
    }
}
