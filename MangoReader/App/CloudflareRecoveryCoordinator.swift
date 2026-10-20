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

enum CloudflareRecoveryMode: Sendable {
    case foreground
    case background
}

enum CloudflareHandoffEnqueueSource: Equatable {
    case legacyError
    case recovery
}

struct CloudflareVerificationCancelledError: LocalizedError, Sendable {
    var errorDescription: String? {
        "Source verification was cancelled. Try the operation again when you’re ready to verify."
    }
}

struct CloudflareVerificationRequiredError: LocalizedError, Sendable {
    var context: CloudflareChallengeContext

    var errorDescription: String? {
        "Verification required for this source. Open Mango Reader to complete it before background work resumes."
    }
}

struct CloudflareVerificationPersistenceError: LocalizedError, Sendable {
    var context: CloudflareChallengeContext
    var reason: String

    var errorDescription: String? {
        "Verification is required, but Mango Reader couldn’t save it for foreground recovery: \(reason)"
    }
}

struct CloudflareBrowserOnlyProtectionError: LocalizedError, Sendable {
    var errorDescription: String? {
        "This source still requires browser-only protection after verification. Try another source; Mango Reader won’t loop or automate around stronger protection."
    }
}

/// Coalesces one visible verification session per extension namespace. Every
/// caller retains its own operation and retries it once after the shared
/// session completes. Background callers persist a verification requirement
/// and return promptly; the next foreground scene owns the visible verifier.
@MainActor
final class CloudflareRecoveryCoordinator {
    static let shared = CloudflareRecoveryCoordinator()

    typealias Presenter = @MainActor @Sendable (CloudflareChallengeContext) async throws -> Void
    typealias Abandoner = @MainActor @Sendable (String) -> Void

    private struct Waiter {
        var continuation: CheckedContinuation<Void, Error>
    }

    private struct Session {
        var context: CloudflareChallengeContext
        var waiters: [UUID: Waiter] = [:]
        var isPresenting = false
        var presentationTask: Task<Void, Never>? = nil
        var abandon: Abandoner? = nil
    }

    private var sessions: [String: Session] = [:]
    private var backgroundRequirements: [String: CloudflareChallengeContext] = [:]
    private var boundedRetryNamespaces: Set<String> = []

    var namespacesRequiringVerification: Set<String> {
        Set(sessions.keys).union(backgroundRequirements.keys)
    }

    func waiterCount(for namespace: String) -> Int {
        sessions[namespace]?.waiters.count ?? 0
    }

    func perform<Value: Sendable>(
        mode: CloudflareRecoveryMode,
        operation: @escaping @Sendable () async throws -> Value,
        present: @escaping Presenter,
        abandon: Abandoner? = nil
    ) async throws -> Value {
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard let context = Self.challengeContext(from: error) else { throw error }
            if boundedRetryNamespaces.contains(context.namespace) {
                throw CloudflareBrowserOnlyProtectionError()
            }
            if mode == .background {
                let existing = backgroundRequirements[context.namespace] ?? context
                backgroundRequirements[context.namespace] = Self.merging(existing, context)
                throw CloudflareVerificationRequiredError(context: context)
            }
            try await waitForVerification(
                context,
                mode: mode,
                present: present,
                abandon: abandon
            )
        }

        try Task.checkCancellation()
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Self.challengeContext(from: error) != nil {
                throw CloudflareBrowserOnlyProtectionError()
            }
            throw error
        }
    }

    /// Handles a definitive challenge reported asynchronously by a download.
    /// The transfer is already paused, so foreground recovery waits for the
    /// coalesced session and invokes only the bounded restart operation.
    func recoverDownload<Value: Sendable>(
        context: CloudflareChallengeContext,
        mode: CloudflareRecoveryMode,
        retry: @escaping @Sendable () async throws -> Value,
        present: @escaping Presenter,
        abandon: Abandoner? = nil
    ) async throws -> Value {
        if mode == .background {
            let existing = backgroundRequirements[context.namespace] ?? context
            backgroundRequirements[context.namespace] = Self.merging(existing, context)
            throw CloudflareVerificationRequiredError(context: context)
        }
        try await waitForVerification(
            context,
            mode: mode,
            present: present,
            abandon: abandon
        )
        try Task.checkCancellation()
        return try await retry()
    }

    @discardableResult
    func complete(namespace: String) -> Bool {
        let resumesBackgroundWork = backgroundRequirements.removeValue(forKey: namespace) != nil
        if resumesBackgroundWork {
            boundedRetryNamespaces.insert(namespace)
        }
        resolve(namespace: namespace, result: .success(()))
        return resumesBackgroundWork
    }

    func cancel(namespace: String) {
        resolve(
            namespace: namespace,
            result: .failure(CloudflareVerificationCancelledError())
        )
    }

    func cancel(namespaces: Set<String>) {
        for namespace in namespaces {
            cancel(namespace: namespace)
            backgroundRequirements.removeValue(forKey: namespace)
            boundedRetryNamespaces.remove(namespace)
        }
    }

    func recordBackgroundRequirement(_ context: CloudflareChallengeContext) {
        let existing = backgroundRequirements[context.namespace] ?? context
        backgroundRequirements[context.namespace] = Self.merging(existing, context)
    }

    func backgroundRequirementContexts() -> [CloudflareChallengeContext] {
        backgroundRequirements.values.sorted { $0.namespace < $1.namespace }
    }

    func finishBoundedBackgroundRetry(namespace: String) {
        boundedRetryNamespaces.remove(namespace)
    }

    private func waitForVerification(
        _ context: CloudflareChallengeContext,
        mode: CloudflareRecoveryMode,
        present: @escaping Presenter,
        abandon: Abandoner?
    ) async throws {
        try Task.checkCancellation()
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                var session = sessions[context.namespace]
                    ?? Session(context: context)
                session.context = Self.merging(session.context, context)
                if session.abandon == nil { session.abandon = abandon }
                session.waiters[waiterID] = Waiter(continuation: continuation)
                let shouldPresent = mode == .foreground && !session.isPresenting
                if shouldPresent {
                    session.isPresenting = true
                }
                sessions[context.namespace] = session

                if shouldPresent {
                    let presentationTask = Task { @MainActor [weak self] in
                        guard let self,
                              let presentedContext = self.sessions[context.namespace]?.context
                        else { return }
                        do {
                            try await present(presentedContext)
                        } catch {
                            self.resolve(
                                namespace: context.namespace,
                                result: .failure(error)
                            )
                        }
                    }
                    sessions[context.namespace]?.presentationTask = presentationTask
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(waiterID: waiterID, namespace: context.namespace)
            }
        }
    }

    private func cancel(waiterID: UUID, namespace: String) {
        guard var session = sessions[namespace],
              let waiter = session.waiters.removeValue(forKey: waiterID)
        else { return }
        waiter.continuation.resume(throwing: CancellationError())
        if session.waiters.isEmpty {
            session.presentationTask?.cancel()
            sessions.removeValue(forKey: namespace)
            session.abandon?(namespace)
        } else {
            sessions[namespace] = session
        }
    }

    private func resolve(namespace: String, result: Result<Void, Error>) {
        guard let session = sessions.removeValue(forKey: namespace) else { return }
        session.presentationTask?.cancel()
        for waiter in session.waiters.values {
            waiter.continuation.resume(with: result)
        }
    }

    private static func challengeContext(from error: Error) -> CloudflareChallengeContext? {
        guard case let MangoReaderExtensionRuntimeError.cloudflareHandoff(context) = error else {
            return nil
        }
        return context
    }

    private static func merging(
        _ existing: CloudflareChallengeContext,
        _ incoming: CloudflareChallengeContext
    ) -> CloudflareChallengeContext {
        existing.merging(incoming)
    }
}
