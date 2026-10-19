import Foundation
import MankoDomain

public actor MankoExtensionTrackerAdapter: TrackerProvider, TrackerAuthenticationProviding, TrackerCollectionProviding {
    public typealias RuntimeFactory = @MainActor @Sendable () throws -> MankoExtensionRuntime
    public typealias AuthenticationPreparation = @Sendable (TrackerAuthenticationDescriptor) async throws -> Bool

    public let installedExtension: InstalledMankoExtension
    public let id: TrackerID
    public let displayName: String
    private let runtimeFactory: RuntimeFactory
    private let authenticationPreparation: AuthenticationPreparation?
    private var runtime: MankoExtensionRuntime?
    private var runtimeInitialization: Task<MankoExtensionRuntime, Error>?
    private var runtimeInitializationID: UUID?

    public init(
        installedExtension: InstalledMankoExtension,
        authenticationPreparation: AuthenticationPreparation? = nil,
        runtimeFactory: @escaping RuntimeFactory
    ) {
        self.installedExtension = installedExtension
        id = TrackerID(rawValue: "repository.\(installedExtension.repositoryID).\(installedExtension.sourceID)")
        displayName = installedExtension.descriptor.name
        self.runtimeFactory = runtimeFactory
        self.authenticationPreparation = authenticationPreparation
    }

    public func search(title: String, kind: ContentKind) async throws -> [TrackerMatch] {
        let value = try await authenticatedOperation(
            "trackerSearch",
            arguments: .object(["title": .string(title), "kind": .string(kind.rawValue)])
        )
        return try decode([TrackerMatch].self, value: value)
    }

    public func progress(remoteWorkID: String) async throws -> TrackerProgress? {
        let value = try await authenticatedOperation(
            "progress",
            arguments: .object(["remoteWorkID": .string(remoteWorkID)])
        )
        guard value != .null else { return nil }
        let payload = try decode(TrackerProgressPayload.self, value: value)
        return payload.progress(trackerID: id)
    }

    public func progressBatch(remoteWorkIDs: [String]) async throws -> [String: TrackerProgress] {
        let boundedIDs = Array(remoteWorkIDs.prefix(50))
        do {
            let value = try await authenticatedOperation(
                "progressBatch",
                arguments: .object(["remoteWorkIDs": .array(boundedIDs.map(JSONValue.string))])
            )
            let payloads = try decode([TrackerProgressPayload].self, value: value)
            return Dictionary(uniqueKeysWithValues: payloads.map { payload in
                (payload.remoteWorkID, payload.progress(trackerID: id))
            })
        } catch {
            // Batch snapshots are optional; retain bounded per-title fallback.
            var result: [String: TrackerProgress] = [:]
            for remoteWorkID in boundedIDs {
                try Task.checkCancellation()
                if let item = try await progress(remoteWorkID: remoteWorkID) {
                    result[remoteWorkID] = item
                }
            }
            return result
        }
    }

    public func update(_ progress: TrackerProgress) async throws {
        guard progress.trackerID == id else { throw SourceError.unsupportedResponse }
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(progress))
        _ = try await authenticatedOperation("update", arguments: .object(["progress": value]))
    }

    public func trackingCapabilities() async throws -> TrackerCapabilities {
        do {
            let runtime = try await activeRuntime()
            let value = try await runtime.trackerOperation("trackingCapabilities")
            return try decode(TrackerCapabilities.self, value: value)
        } catch let MankoExtensionRuntimeError.operationFailed(message)
            where message.localizedCaseInsensitiveContains("unsupported") {
            return .init()
        }
    }

    public func authentication() async throws -> TrackerAuthenticationDescriptor {
        guard let policy = installedExtension.accountPolicy else { throw ExtensionSecurityError.invalidPolicy }
        return policy.authentication
    }

    public func collections(cursor: SourceCursor?) async throws -> SourcePage<TrackerCollection> {
        let cursorValue: JSONValue
        if let cursor,
           let data = cursor.value.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
            cursorValue = decoded
        } else {
            cursorValue = .null
        }
        let value = try await authenticatedOperation("collections", arguments: .object(["cursor": cursorValue]))
        return try decode(SourcePage<TrackerCollection>.self, value: value)
    }

    public func resetRuntime() async {
        runtimeInitialization?.cancel()
        runtimeInitialization = nil
        runtimeInitializationID = nil
        if let runtime { await runtime.invalidate() }
        runtime = nil
    }

    private func activeRuntime() async throws -> MankoExtensionRuntime {
        if let runtime, await runtime.isValid { return runtime }
        if let runtimeInitialization, let runtimeInitializationID {
            return try await finishRuntimeInitialization(runtimeInitialization, id: runtimeInitializationID)
        }
        let id = UUID()
        let runtimeFactory = runtimeFactory
        let task = Task { @MainActor in
            let created = try runtimeFactory()
            do {
                try await created.initialize()
                return created
            } catch {
                created.invalidate()
                throw error
            }
        }
        runtimeInitialization = task
        runtimeInitializationID = id
        return try await finishRuntimeInitialization(task, id: id)
    }

    private func finishRuntimeInitialization(
        _ task: Task<MankoExtensionRuntime, Error>,
        id: UUID
    ) async throws -> MankoExtensionRuntime {
        do {
            let created = try await task.value
            if let runtime, runtime === created { return created }
            guard runtimeInitializationID == id else {
                await created.invalidate()
                throw CancellationError()
            }
            runtime = created
            runtimeInitialization = nil
            runtimeInitializationID = nil
            return created
        } catch {
            if runtimeInitializationID == id {
                runtimeInitialization = nil
                runtimeInitializationID = nil
            }
            throw error
        }
    }

    private func authenticatedOperation(
        _ operation: String,
        arguments: JSONValue = .object([:])
    ) async throws -> JSONValue {
        var runtime = try await activeRuntime()
        if let authenticationPreparation {
            let descriptor = try await authentication()
            if try await authenticationPreparation(descriptor) {
                await resetRuntime()
                runtime = try await activeRuntime()
            }
        }
        do {
            return try await runtime.trackerOperation(operation, arguments: arguments)
        } catch let MankoExtensionRuntimeError.operationFailed(message)
            where message.localizedCaseInsensitiveContains("authentication required")
                || message.localizedCaseInsensitiveContains("unauthorized")
                || message.contains("401")
                || message.contains("403")
        {
            throw SourceError.unauthorized
        }
    }

    private func decode<Value: Decodable & Sendable>(_ type: Value.Type, value: JSONValue) throws -> Value {
        return try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }
}

struct TrackerProgressPayload: Decodable, Sendable {
    var remoteWorkID: String
    var chapter: Double?
    var volume: Double?
    var status: TrackerReadingStatus?
    var score: Double?
    var modifiedAt: Date?
    var startDate: TrackerDate?
    var finishDate: TrackerDate?
    var totalChapters: Int?
    var totalVolumes: Int?

    func progress(trackerID: TrackerID) -> TrackerProgress {
        TrackerProgress(
            trackerID: trackerID,
            remoteWorkID: remoteWorkID,
            chapter: chapter,
            volume: volume,
            status: status,
            score: score,
            modifiedAt: modifiedAt ?? .now,
            startDate: startDate, finishDate: finishDate,
            totalChapters: totalChapters, totalVolumes: totalVolumes
        )
    }

    private enum CodingKeys: String, CodingKey {
        case remoteWorkID, chapter, volume, status, score, modifiedAt
        case startDate, finishDate, totalChapters, totalVolumes
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        remoteWorkID = try values.decode(String.self, forKey: .remoteWorkID)
        chapter = try values.decodeIfPresent(Double.self, forKey: .chapter)
        volume = try values.decodeIfPresent(Double.self, forKey: .volume)
        status = try values.decodeIfPresent(TrackerReadingStatus.self, forKey: .status)
        score = try values.decodeIfPresent(Double.self, forKey: .score)
        startDate = try values.decodeIfPresent(TrackerDate.self, forKey: .startDate)
        finishDate = try values.decodeIfPresent(TrackerDate.self, forKey: .finishDate)
        totalChapters = try values.decodeIfPresent(Int.self, forKey: .totalChapters)
        totalVolumes = try values.decodeIfPresent(Int.self, forKey: .totalVolumes)
        if let timestamp = try? values.decode(String.self, forKey: .modifiedAt) {
            let formatter = ISO8601DateFormatter()
            var date = formatter.date(from: timestamp)
            if date == nil {
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                date = formatter.date(from: timestamp)
            }
            guard let date else {
                throw DecodingError.dataCorruptedError(forKey: .modifiedAt, in: values,
                    debugDescription: "Expected an ISO-8601 tracker timestamp")
            }
            modifiedAt = date
        } else {
            // Preserve the numeric Date representation used by older native fixtures.
            modifiedAt = try values.decodeIfPresent(Date.self, forKey: .modifiedAt)
        }
    }
}
