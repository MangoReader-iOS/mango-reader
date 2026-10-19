import CryptoKit
import Foundation
import Nuke

/// Disposable source content only. Library records and explicit downloads never
/// enter this store. Nuke supplies atomic asynchronous writes and LRU eviction.
public actor ContentCache {
    public static let shared = ContentCache()
    public static let defaultLimit = 1_024 * 1_024 * 1_024
    public static let freshness: TimeInterval = 30 * 60

    public struct Entry: Codable, Sendable {
        public let data: Data
        public let date: Date
        public let mediaType: String?
        public let ttlSeconds: TimeInterval?
        public init(data: Data, date: Date, mediaType: String?, ttlSeconds: TimeInterval? = nil) {
            self.data = data; self.date = date; self.mediaType = mediaType; self.ttlSeconds = ttlSeconds
        }
        public func isFresh(at now: Date = .now, lifetime: TimeInterval = ContentCache.freshness) -> Bool {
            now.timeIntervalSince(date) >= 0 && now.timeIntervalSince(date) < min(lifetime, ttlSeconds ?? lifetime)
        }
        public func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
            try JSONDecoder().decode(type, from: data)
        }
    }

    private let disk: DataCache?
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Entry, Error>]
    }
    private var flights: [String: Flight] = [:]
    var waitingCount: Int { flights.values.reduce(0) { $0 + $1.waiters.count } }
    private var generation = UUID()
    private var keyGenerations: [String: UUID] = [:]
    public static let maximumMetadataBytes = 16 * 1_024 * 1_024
    public struct MetadataPermit: Codable, Sendable, Equatable {
        public let generation: UUID
        public let resourceGeneration: UUID
    }
    public func metadataPermit(for key: String, replacing: Bool, invocationGeneration: UUID) -> MetadataPermit {
        if replacing || keyGenerations[key] == nil { keyGenerations[key] = UUID() }
        if keyGenerations.count > 10_000, let evicted = keyGenerations.keys.first(where: { $0 != key }) { keyGenerations[evicted] = nil }
        return MetadataPermit(generation: invocationGeneration, resourceGeneration: keyGenerations[key]!)
    }
    public func metadataEntry(for key: String, permit: MetadataPermit, ttlSeconds: Double?, at now: Date = .now) -> Entry? {
        guard enabled, permit.generation == generation, permit.resourceGeneration == keyGenerations[key],
              let entry = entry(for: key), entry.data.count <= Self.maximumMetadataBytes,
              ttlSeconds == nil || entry.isFresh(at: now, lifetime: ttlSeconds!) else { return nil }
        return entry
    }
    public func storeMetadata(_ data: Data, for key: String, permit: MetadataPermit) {
        guard data.count <= Self.maximumMetadataBytes, permit.resourceGeneration == keyGenerations[key] else { return }
        store(data, for: key, token: permit.generation)
    }
    private var enabled = true
    private var bytesSinceSweep = 0
    public func writeToken() -> UUID { generation }
    public func setPrivacyMode(_ isPrivate: Bool) {
        guard enabled == isPrivate else { return }
        enabled = !isPrivate; generation = UUID()
        keyGenerations.removeAll()
        cancelFlights()
    }

    public init(directory: URL? = nil, byteLimit: Int = ContentCache.defaultLimit, memoryOnly: Bool = false) {
        disk = memoryOnly ? nil : try? directory.map { try DataCache(path: $0) } ?? DataCache(name: "com.k800k.manko.content")
        disk?.sizeLimit = max(0, byteLimit)
        if !memoryOnly, directory == nil, let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            // Previous readers used disposable UUID keys in this separate pool.
            try? FileManager.default.removeItem(at: caches.appendingPathComponent("com.k800k.manko.reader-pages"))
        }
    }

    public nonisolated static func key(_ components: [String]) -> String {
        let encoded = (try? JSONEncoder().encode(components)) ?? Data()
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }

    public func entry(for key: String) -> Entry? {
        guard enabled else { return nil }
        guard let data = disk?.cachedData(for: key) else { return nil }
        guard let entry = try? PropertyListDecoder().decode(Entry.self, from: data) else {
            disk?.removeData(for: key); return nil
        }
        return entry
    }

    public func store(_ data: Data, for key: String, mediaType: String? = nil, date: Date = .now, token: UUID? = nil, ttlSeconds: TimeInterval? = nil) {
        guard enabled, token == nil || token == generation, let disk, data.count <= disk.sizeLimit else { return }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        guard let encoded = try? encoder.encode(Entry(data: data, date: date, mediaType: mediaType, ttlSeconds: ttlSeconds)) else { return }
        disk.storeData(encoded, for: key)
        bytesSinceSweep += encoded.count
        if bytesSinceSweep >= min(16 * 1_024 * 1_024, max(1_024, disk.sizeLimit / 8)) {
            disk.flush(); disk.sweep(); bytesSinceSweep = 0
        }
    }

    public func store<Value: Encodable & Sendable>(_ value: Value, for key: String, date: Date = .now) {
        if let data = try? JSONEncoder().encode(value) { store(data, for: key, date: date) }
    }

    /// Every waiter shares one refresh; cancellation of one screen cannot
    /// cancel a request another screen is using. Clear fences late responses.
    public func refresh(_ key: String, replacing: Bool = false,
                        freshness: (@Sendable () async -> TimeInterval?)? = nil,
                        loader: @escaping @Sendable () async throws -> Data) async throws -> Entry {
        if replacing, let old = flights.removeValue(forKey: key) {
            old.task.cancel()
            for waiter in old.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if flights[key] != nil { flights[key]?.waiters[waiterID] = continuation; return }
                let id = UUID(), token = generation
                let task = Task { [weak self] in
                    let result: Result<Entry, Error>
                    do {
                        let data = try await loader()
                        try Task.checkCancellation()
                        result = .success(Entry(data: data, date: .now, mediaType: nil, ttlSeconds: await freshness?()))
                    } catch { result = .failure(error) }
                    await self?.complete(result, key: key, id: id, generation: token)
                }
                flights[key] = Flight(id: id, task: task, waiters: [waiterID: continuation])
            }
        } onCancel: { Task { await self.cancelWaiter(waiterID, key: key) } }
    }

    private func cancelWaiter(_ id: UUID, key: String) {
        guard let waiter = flights[key]?.waiters.removeValue(forKey: id) else { return }
        waiter.resume(throwing: CancellationError())
        if flights[key]?.waiters.isEmpty == true { flights.removeValue(forKey: key)?.task.cancel() }
    }
    private func complete(_ result: Result<Entry, Error>, key: String, id: UUID, generation token: UUID) {
        guard generation == token, flights[key]?.id == id, let flight = flights.removeValue(forKey: key) else { return }
        if case let .success(entry) = result { store(entry.data, for: key, date: entry.date, ttlSeconds: entry.ttlSeconds) }
        for waiter in flight.waiters.values { waiter.resume(with: result) }
    }
    private func cancelFlights() {
        let current = flights.values; flights.removeAll()
        for flight in current {
            flight.task.cancel()
            for waiter in flight.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
    }

    public func remove(_ key: String) {
        keyGenerations[key] = UUID()
        if let flight = flights.removeValue(forKey: key) {
            flight.task.cancel()
            for waiter in flight.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
        disk?.removeData(for: key)
    }
    public func clear() {
        generation = UUID()
        keyGenerations.removeAll()
        cancelFlights()
        disk?.removeAll()
    }
    public func setLimit(_ bytes: Int) {
        disk?.sizeLimit = max(0, bytes); disk?.flush(); disk?.sweep()
    }
    public func usage() -> Int { disk?.totalAllocatedSize ?? 0 }
    public func flush() { disk?.flush() }
}

/// Inherited by structured source work, captured when the runtime invocation starts.
public enum SourceCachePolicy {
    @TaskLocal public static var searchCoordinator: SourceSearchRequestCoordinator? = nil
    @TaskLocal public static var reload = false
    @TaskLocal public static var isPrivate = false
    @TaskLocal public static var scope: String? = nil
    @TaskLocal public static var freshness: SourceCacheFreshness? = nil
}

/// Mutable metadata dependencies cap the freshness of their derived app result.
/// Immutable resources impose no limit; older extensions retain the host default.
public actor SourceCacheFreshness {
    private var expiresAt: Date?
    public init() {}
    public func record(_ ttlSeconds: TimeInterval?, date: Date = .now) {
        guard let ttlSeconds, ttlSeconds.isFinite, ttlSeconds > 0 else { return }
        let deadline = date.addingTimeInterval(ttlSeconds)
        expiresAt = min(expiresAt ?? deadline, deadline)
    }
    public func lifetime(at now: Date = .now) -> TimeInterval? {
        expiresAt.map { max(0, $0.timeIntervalSince(now)) }
    }
}
