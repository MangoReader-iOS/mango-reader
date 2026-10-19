import CloudKit
import Foundation

public protocol CloudRecordBackingStore: Sendable {
    func record(for id: CKRecord.ID) async -> CKRecord?
    func apply(records: [CKRecord], deletions: [CKRecord.ID]) async throws
    func didSave(records: [CKRecord]) async throws
    func didDelete(recordIDs: [CKRecord.ID]) async throws
    func resetCloudAccountState() async throws
}

public actor CloudSyncStateStore {
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.fileURL = root
                .appendingPathComponent("manko", isDirectory: true)
                .appendingPathComponent("CloudSync", isDirectory: true)
                .appendingPathComponent("state.json", isDirectory: false)
        }
    }

    public func load() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    public func save(_ state: CKSyncEngine.State.Serialization) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

public enum CloudSyncAvailability: Equatable, Sendable {
    case stopped
    case available
    case signedOut
    case switchedAccount
    case unavailable(String)
    case failed(String)
}

/// A private-zone CKSyncEngine coordinator. Failure never blocks the local store.
public actor CloudSyncEngine: CKSyncEngineDelegate {
    public static let zoneName = "MankoLibrary"

    private let container: CKContainer
    private let database: CKDatabase
    private let backingStore: any CloudRecordBackingStore
    private let stateStore: CloudSyncStateStore
    private let zoneID: CKRecordZone.ID
    private var engine: CKSyncEngine?
    private var availability: CloudSyncAvailability = .stopped
    private var statusContinuations: [UUID: AsyncStream<CloudSyncAvailability>.Continuation] = [:]
    private var remoteChangeRevision = 0
    private var remoteChangeContinuations: [UUID: AsyncStream<Int>.Continuation] = [:]

    public init(
        container: CKContainer = .default(),
        backingStore: any CloudRecordBackingStore,
        stateStore: CloudSyncStateStore = CloudSyncStateStore()
    ) {
        self.container = container
        self.database = container.privateCloudDatabase
        self.backingStore = backingStore
        self.stateStore = stateStore
        self.zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    public func start() async {
        guard engine == nil else { return }
        do {
            switch try await container.accountStatus() {
            case .available:
                break
            case .noAccount:
                do {
                    try await backingStore.resetCloudAccountState()
                    setAvailability(.signedOut)
                } catch {
                    setAvailability(.failed("Manko couldn’t reset iCloud account state."))
                }
                return
            case .restricted:
                setAvailability(.unavailable("iCloud access is restricted on this device."))
                return
            case .couldNotDetermine:
                setAvailability(.unavailable("Manko couldn’t determine iCloud account availability."))
                return
            case .temporarilyUnavailable:
                setAvailability(.unavailable("iCloud is temporarily unavailable."))
                return
            @unknown default:
                setAvailability(.unavailable("iCloud account availability is unknown."))
                return
            }
        } catch {
            setAvailability(.failed(error.localizedDescription))
            return
        }

        let persistedState = await stateStore.load()
        let configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: persistedState,
            delegate: self
        )
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        setAvailability(.available)
        if persistedState == nil {
            let zone = CKRecordZone(zoneID: zoneID)
            engine.state.add(pendingDatabaseChanges: [.saveZone(zone)])
        }
    }

    public func stop() async {
        await engine?.cancelOperations()
        engine = nil
        setAvailability(.stopped)
    }

    /// Completes the explicit local-data cleanup handshake required after
    /// CKSyncEngine reports an account switch. The engine has already reset its
    /// account-scoped state; manko rechecks account availability, creates
    /// its private zone for the present account, then lets the app reseed all
    /// current local records.
    @discardableResult
    public func resumeAfterAccountChange() async -> Bool {
        do {
            switch try await container.accountStatus() {
            case .available:
                guard let engine else {
                    setAvailability(.failed("iCloud sync must be restarted after the account change."))
                    return false
                }
                let zone = CKRecordZone(zoneID: zoneID)
                engine.state.add(pendingDatabaseChanges: [.saveZone(zone)])
                setAvailability(.available)
                return true
            case .noAccount:
                setAvailability(.signedOut)
            case .restricted:
                setAvailability(.unavailable("iCloud access is restricted on this device."))
            case .couldNotDetermine:
                setAvailability(.unavailable("Manko couldn’t determine iCloud account availability."))
            case .temporarilyUnavailable:
                setAvailability(.unavailable("iCloud is temporarily unavailable."))
            @unknown default:
                setAvailability(.unavailable("iCloud account availability is unknown."))
            }
        } catch {
            setAvailability(.failed(error.localizedDescription))
        }
        return false
    }

    public func status() -> CloudSyncAvailability {
        availability
    }

    public func statusUpdates() -> AsyncStream<CloudSyncAvailability> {
        let identifier = UUID()
        let (stream, continuation) = AsyncStream<CloudSyncAvailability>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        statusContinuations[identifier] = continuation
        continuation.yield(availability)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStatusContinuation(identifier) }
        }
        return stream
    }

    public func remoteChangeUpdates() -> AsyncStream<Int> {
        let identifier = UUID()
        let (stream, continuation) = AsyncStream<Int>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        remoteChangeContinuations[identifier] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeRemoteChangeContinuation(identifier) }
        }
        return stream
    }

    public func queueSave(recordName: String) {
        guard let engine else { return }
        let id = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
    }

    public func queueSaves(recordNames: [String]) {
        guard let engine, !recordNames.isEmpty else { return }
        let changes = recordNames.map { recordName in
            CKSyncEngine.PendingRecordZoneChange.saveRecord(
                CKRecord.ID(recordName: recordName, zoneID: zoneID)
            )
        }
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    public func queueDelete(recordName: String) {
        guard let engine else { return }
        let id = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(id)])
    }

    public func synchronize() async {
        guard await fetchRemoteChanges() else { return }
        await sendPendingChanges()
    }

    /// Completes an explicit fetch before the app enqueues a first-launch or
    /// account-change seed. CKSyncEngine automatically syncs by default, so
    /// this ordering keeps freshly discovered local records from racing an
    /// established private-zone winner.
    @discardableResult
    public func fetchRemoteChanges() async -> Bool {
        guard let engine else { return false }
        setAvailability(.available)
        do {
            try await engine.fetchChanges()
            return availability == .available
        } catch {
            setAvailability(.failed(error.localizedDescription))
            return false
        }
    }

    public func sendPendingChanges() async {
        guard let engine else { return }
        setAvailability(.available)
        do {
            try await engine.sendChanges()
        } catch {
            setAvailability(.failed(error.localizedDescription))
        }
    }

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case let .stateUpdate(update):
            try? await stateStore.save(update.stateSerialization)
        case let .accountChange(change):
            switch change.changeType {
            case .signIn:
                let zone = CKRecordZone(zoneID: zoneID)
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(zone)])
                setAvailability(.available)
            case .signOut:
                do {
                    try await backingStore.resetCloudAccountState()
                    setAvailability(.signedOut)
                } catch {
                    setAvailability(.failed("Manko couldn’t reset iCloud account state."))
                }
            case .switchAccounts:
                do {
                    try await backingStore.resetCloudAccountState()
                    setAvailability(.switchedAccount)
                } catch {
                    setAvailability(.failed("Manko couldn’t reset iCloud account state."))
                }
            @unknown default:
                setAvailability(.failed("The iCloud account changed in an unsupported way."))
            }
        case let .fetchedRecordZoneChanges(changes):
            do {
                let records = changes.modifications.map(\.record)
                let deletions = changes.deletions.map(\.recordID)
                try await backingStore.apply(
                    records: records,
                    deletions: deletions
                )
                try await backingStore.didSave(records: records)
                try await backingStore.didDelete(recordIDs: deletions)
                notifyRemoteChanges()
            } catch {
                setAvailability(.failed("Manko couldn’t apply iCloud library changes."))
            }
        case let .sentRecordZoneChanges(changes):
            await handleSentRecordZoneChanges(changes, syncEngine: syncEngine)
        default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [backingStore] id in
            await backingStore.record(for: id)
        }
    }

    private func setAvailability(_ value: CloudSyncAvailability) {
        guard availability != value else { return }
        availability = value
        for continuation in statusContinuations.values {
            continuation.yield(value)
        }
    }

    private func removeStatusContinuation(_ identifier: UUID) {
        statusContinuations.removeValue(forKey: identifier)
    }

    private func notifyRemoteChanges() {
        remoteChangeRevision += 1
        for continuation in remoteChangeContinuations.values {
            continuation.yield(remoteChangeRevision)
        }
    }

    private func removeRemoteChangeContinuation(_ identifier: UUID) {
        remoteChangeContinuations.removeValue(forKey: identifier)
    }

    private func handleSentRecordZoneChanges(
        _ changes: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) async {
        do {
            try await backingStore.didSave(records: changes.savedRecords)
            try await backingStore.didDelete(recordIDs: changes.deletedRecordIDs)

            var hasPermanentFailure = false
            var mergedRemoteWinner = false

            for failure in changes.failedRecordSaves {
                switch Self.failurePolicy(for: failure.error) {
                case .automaticRetry:
                    break
                case .mergeServerRecord:
                    guard
                        let serverRecord = failure.error.serverRecord,
                        serverRecord.recordID == failure.record.recordID
                    else {
                        hasPermanentFailure = true
                        continue
                    }
                    try await backingStore.apply(records: [serverRecord], deletions: [])
                    try await backingStore.didSave(records: [serverRecord])
                    syncEngine.state.add(
                        pendingRecordZoneChanges: [.saveRecord(serverRecord.recordID)]
                    )
                    mergedRemoteWinner = true
                case .recreateZone:
                    try await backingStore.didDelete(recordIDs: [failure.record.recordID])
                    let zone = CKRecordZone(zoneID: failure.record.recordID.zoneID)
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(zone)])
                    syncEngine.state.add(
                        pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)]
                    )
                case .permanentFailure:
                    hasPermanentFailure = true
                }
            }

            for (recordID, error) in changes.failedRecordDeletes {
                if error.code == .unknownItem {
                    try await backingStore.didDelete(recordIDs: [recordID])
                    continue
                }
                switch Self.failurePolicy(for: error) {
                case .automaticRetry:
                    break
                case .recreateZone:
                    try await backingStore.didDelete(recordIDs: [recordID])
                    let zone = CKRecordZone(zoneID: recordID.zoneID)
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(zone)])
                    syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
                case .mergeServerRecord, .permanentFailure:
                    hasPermanentFailure = true
                }
            }

            if mergedRemoteWinner {
                notifyRemoteChanges()
            }
            setAvailability(
                hasPermanentFailure
                    ? .failed("iCloud couldn’t save one or more library changes.")
                    : .available
            )
        } catch {
            setAvailability(.failed("Manko couldn’t preserve iCloud synchronization state."))
        }
    }

    static func failurePolicy(for error: CKError) -> CloudRecordFailurePolicy {
        switch error.code {
        case .notAuthenticated,
             .accountTemporarilyUnavailable,
             .networkFailure,
             .networkUnavailable,
             .requestRateLimited,
             .serviceUnavailable,
             .zoneBusy:
            .automaticRetry
        case .serverRecordChanged:
            .mergeServerRecord
        case .zoneNotFound:
            .recreateZone
        default:
            .permanentFailure
        }
    }
}

enum CloudRecordFailurePolicy: Equatable, Sendable {
    case automaticRetry
    case mergeServerRecord
    case recreateZone
    case permanentFailure
}

public enum CloudRecordCodec {
    public static let payloadKey = "payload"
    public static let modifiedAtKey = "modifiedAt"
    public static let deviceIDKey = "deviceID"

    public static func record<Value: Encodable>(
        type: String,
        id: String,
        zoneID: CKRecordZone.ID,
        value: Value,
        modifiedAt: Date,
        deviceID: String
    ) throws -> CKRecord {
        let record = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: id, zoneID: zoneID))
        record[payloadKey] = try JSONEncoder().encode(value) as CKRecordValue
        record[modifiedAtKey] = modifiedAt as CKRecordValue
        record[deviceIDKey] = deviceID as CKRecordValue
        return record
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from record: CKRecord) throws -> Value {
        guard let data = record[payloadKey] as? Data else {
            throw CocoaError(.coderReadCorrupt)
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
