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

struct ExtensionContentRefresh: Sendable {
    var work: Work
    var installments: [Installment]
    var selectedInstallment: Installment
}

enum WorkDetailLoadError: LocalizedError {
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            "Library storage is still starting. Try again in a moment."
        }
    }
}

/// Transient source responses only; progress and library membership always come from storage.
typealias WorkDetailMetadataHandler = @MainActor @Sendable (Work) -> Void

@MainActor
final class SourceWorkDetailCache {
    struct Key: Hashable {
        let sourceID: SourceID
        let workID: WorkID
        let remoteID: String?
        let revision: Int
    }

    private struct Flight {
        let id: UUID
        let task: Task<RemoteLibrarySnapshot, Error>
        var metadata: Work?
        var waiters: [UUID: Waiter]
    }
    private struct Waiter {
        let continuation: CheckedContinuation<RemoteLibrarySnapshot, Error>
        let onMetadata: WorkDetailMetadataHandler?
    }
    private let limit: Int
    private var entries: [Key: RemoteLibrarySnapshot] = [:]
    private var order: [Key] = []
    private var flights: [Key: Flight] = [:]

    init(limit: Int = 100) { self.limit = max(1, limit) }

    func cached(_ key: Key) -> RemoteLibrarySnapshot? {
        guard let value = entries[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return value
    }

    func invalidate(sourceID: SourceID) {
        for key in order where key.sourceID == sourceID { entries[key] = nil }
        order.removeAll { $0.sourceID == sourceID }
        for key in Array(flights.keys) where key.sourceID == sourceID {
            guard let flight = flights.removeValue(forKey: key) else { continue }
            flight.task.cancel()
            for waiter in flight.waiters.values { waiter.continuation.resume(throwing: CancellationError()) }
        }
    }

    func refresh(
        _ key: Key,
        replacing: Bool = false,
        loader: @escaping @MainActor () async throws -> RemoteLibrarySnapshot
    ) async throws -> RemoteLibrarySnapshot {
        try await refresh(key, replacing: replacing, onMetadata: nil) { _ in try await loader() }
    }

    func refresh(
        _ key: Key,
        replacing: Bool = false,
        onMetadata: WorkDetailMetadataHandler?,
        loader: @escaping @MainActor (@escaping WorkDetailMetadataHandler) async throws -> RemoteLibrarySnapshot
    ) async throws -> RemoteLibrarySnapshot {
        try Task.checkCancellation()
        if replacing, let old = flights.removeValue(forKey: key) {
            old.task.cancel()
            for waiter in old.waiters.values { waiter.continuation.resume(throwing: CancellationError()) }
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if flights[key] != nil {
                    flights[key]?.waiters[waiterID] = Waiter(continuation: continuation, onMetadata: onMetadata)
                    if let metadata = flights[key]?.metadata { onMetadata?(metadata) }
                    return
                }
                let id = UUID()
                let task = Task { [weak self] in
                    try await loader { [weak self] metadata in
                        self?.publish(metadata, key: key, id: id)
                    }
                }
                flights[key] = Flight(id: id, task: task, waiters: [waiterID: Waiter(continuation: continuation, onMetadata: onMetadata)])
                Task { [weak self] in
                    let result = await task.result
                    self?.complete(result, key: key, id: id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let waiter = flights[key]?.waiters.removeValue(forKey: waiterID) else { return }
                if flights[key]?.waiters.isEmpty == true {
                    flights.removeValue(forKey: key)?.task.cancel()
                }
                waiter.continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func publish(_ metadata: Work, key: Key, id: UUID) {
        guard let flight = flights[key], flight.id == id, metadata.sourceID == key.sourceID,
              metadata.id == key.workID, metadata.remoteID == key.remoteID else { return }
        flights[key]?.metadata = metadata
        for waiter in flight.waiters.values {
            waiter.onMetadata?(metadata)
        }
    }

    private func complete(_ result: Result<RemoteLibrarySnapshot, Error>, key: Key, id: UUID) {
        guard flights[key]?.id == id, let flight = flights.removeValue(forKey: key) else { return }
        if case let .success(value) = result {
            entries[key] = value
            order.removeAll { $0 == key }
            order.append(key)
            while order.count > limit { entries[order.removeFirst()] = nil }
        }
        for waiter in flight.waiters.values { waiter.continuation.resume(with: result) }
    }
}
