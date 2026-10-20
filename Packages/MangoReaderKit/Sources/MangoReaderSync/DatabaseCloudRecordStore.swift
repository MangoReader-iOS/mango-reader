import CloudKit
import Foundation
import MangoReaderData
import MangoReaderDomain

public enum CloudSyncRecordID {
    public static func work(_ id: WorkID) -> String {
        "work:\(id.rawValue.uuidString)"
    }

    public static func readingContent(_ id: WorkID) -> String {
        "readingContent:\(id.rawValue.uuidString)"
    }

    public static func progress(workID: WorkID) -> String {
        "progress:\(workID.rawValue.uuidString)"
    }

    public static func chapterProgress(_ id: InstallmentID) -> String {
        "chapterProgress:\(id.rawValue.uuidString)"
    }

    public static func session(_ id: UUID) -> String {
        "session:\(id.uuidString)"
    }

    public static func category(_ id: UUID) -> String {
        "category:\(id.uuidString)"
    }

    public static func bookmark(_ id: UUID) -> String {
        "bookmark:\(id.uuidString)"
    }

    public static func annotation(_ id: UUID) -> String {
        "annotation:\(id.uuidString)"
    }

    public static func titleState(workID: WorkID) -> String {
        "titleState:\(workID.rawValue.uuidString)"
    }

    public static func importedOriginal(_ id: InstallmentID) -> String {
        "importedOriginal:\(id.rawValue.uuidString)"
    }

    public static func settings() -> String {
        "settings:\(SyncedAppSettings.singletonID)"
    }

    public static func tombstone(_ id: UUID) -> String {
        "tombstone:\(id.uuidString)"
    }

    fileprivate static func components(_ recordName: String) -> (kind: String, identifier: String)? {
        guard let separator = recordName.firstIndex(of: ":") else { return nil }
        let kind = String(recordName[..<separator])
        let identifier = String(recordName[recordName.index(after: separator)...])
        guard !kind.isEmpty, !identifier.isEmpty else { return nil }
        return (kind, identifier)
    }
}

public struct SyncedLibraryWork: Codable, Hashable, Sendable {
    public var work: Work
    public var entry: LibraryEntry
    public var installments: [Installment]
    public var categoryIDs: Set<UUID>

    public init(
        work: Work,
        entry: LibraryEntry,
        installments: [Installment],
        categoryIDs: Set<UUID>
    ) {
        self.work = work
        self.entry = entry
        self.installments = installments
        self.categoryIDs = categoryIDs
    }
}

public struct SyncedReadingContent: Codable, Hashable, Sendable {
    public var work: Work
    public var installments: [Installment]

    public init(work: Work, installments: [Installment]) {
        self.work = work
        self.installments = installments
    }
}

public struct SyncedCategory: Codable, Hashable, Sendable {
    public var category: MangoReaderDomain.Category
    public var workIDs: Set<WorkID>

    public init(category: MangoReaderDomain.Category, workIDs: Set<WorkID>) {
        self.category = category
        self.workIDs = workIDs
    }
}

/// Translates Mango Reader's durable database records into private-zone CloudKit
/// records. Credentials, remote downloads, and local file URLs never enter this
/// store. Reading sessions use their own records so clearing History can delete
/// them without disturbing progress, bookmarks, annotations, or title metadata.
public actor DatabaseCloudRecordStore: CloudRecordBackingStore {
    private let database: MangoReaderDatabase
    private let deviceID: String
    private let systemFieldsStore: CloudRecordSystemFieldsStore
    private let zoneID = CKRecordZone.ID(
        zoneName: CloudSyncEngine.zoneName,
        ownerName: CKCurrentUserDefaultName
    )

    public init(
        database: MangoReaderDatabase,
        deviceID: String,
        systemFieldsStore: CloudRecordSystemFieldsStore = CloudRecordSystemFieldsStore()
    ) {
        self.database = database
        self.deviceID = deviceID
        self.systemFieldsStore = systemFieldsStore
    }

    public func recordNames() async throws -> [String] {
        let inventory = try await database.cloudSyncInventory()
        return inventory.workIDs.map { CloudSyncRecordID.work($0) }
            + inventory.readingContentWorkIDs.map { CloudSyncRecordID.readingContent($0) }
            + inventory.progressWorkIDs.map { CloudSyncRecordID.progress(workID: $0) }
            + inventory.progressInstallmentIDs.map(CloudSyncRecordID.chapterProgress)
            + inventory.sessionIDs.map(CloudSyncRecordID.session)
            + inventory.categoryIDs.map { CloudSyncRecordID.category($0) }
            + inventory.bookmarkIDs.map { CloudSyncRecordID.bookmark($0) }
            + inventory.annotationIDs.map { CloudSyncRecordID.annotation($0) }
            + inventory.titleStateWorkIDs.map { CloudSyncRecordID.titleState(workID: $0) }
            + inventory.importedOriginalInstallmentIDs.map(CloudSyncRecordID.importedOriginal)
            + (inventory.hasSyncedAppSettings ? [CloudSyncRecordID.settings()] : [])
            + inventory.tombstoneIDs.map { CloudSyncRecordID.tombstone($0) }
    }

    public func record(for id: CKRecord.ID) async -> CKRecord? {
        guard
            id.zoneID == zoneID,
            let components = CloudSyncRecordID.components(id.recordName)
        else { return nil }

        do {
            switch components.kind {
            case "work":
                guard
                    let uuid = UUID(uuidString: components.identifier),
                    let bundle = try await database.libraryBundle(workID: WorkID(rawValue: uuid))
                else { return nil }
                let sanitizedInstallments = bundle.installments.map { installment in
                    var sanitized = installment
                    sanitized.acquisitionURL = nil
                    return sanitized
                }
                var sanitizedWork = bundle.work
                // Custom covers are managed device-local files. Never sync a
                // sandbox-relative filename without its image payload.
                sanitizedWork.customCoverPath = nil
                if sanitizedWork.coverURL?.isFileURL == true {
                    sanitizedWork.coverURL = nil
                }
                let categoryIDs = try await database.categoryIDs(for: bundle.work.id)
                let payload = SyncedLibraryWork(
                    work: sanitizedWork,
                    entry: bundle.entry,
                    installments: sanitizedInstallments,
                    categoryIDs: categoryIDs
                )
                return try await makeRecord(
                    type: "LibraryWork",
                    id: id,
                    value: payload,
                    modifiedAt: bundle.work.modifiedAt
                )

            case "readingContent":
                guard
                    let uuid = UUID(uuidString: components.identifier),
                    let bundle = try await database.readingContentBundle(
                        workID: WorkID(rawValue: uuid)
                    )
                else { return nil }
                var sanitizedWork = bundle.work
                sanitizedWork.customCoverPath = nil
                if sanitizedWork.coverURL?.isFileURL == true {
                    sanitizedWork.coverURL = nil
                }
                let sanitizedInstallments = bundle.installments.map { installment in
                    var sanitized = installment
                    sanitized.acquisitionURL = nil
                    return sanitized
                }
                return try await makeRecord(
                    type: "ReadingContent",
                    id: id,
                    value: SyncedReadingContent(
                        work: sanitizedWork,
                        installments: sanitizedInstallments
                    ),
                    modifiedAt: sanitizedWork.modifiedAt
                )

            case "progress":
                guard
                    let uuid = UUID(uuidString: components.identifier),
                    let progress = try await database.progress(workID: WorkID(rawValue: uuid))
                else { return nil }
                return try await makeRecord(
                    type: "ReadingProgress",
                    id: id,
                    value: progress,
                    modifiedAt: progress.modifiedAt
                )

            case "chapterProgress":
                guard let uuid = UUID(uuidString: components.identifier),
                      let progress = try await database.progress(installmentID: InstallmentID(rawValue: uuid))
                else { return nil }
                return try await makeRecord(type: "ReadingProgress", id: id, value: progress, modifiedAt: progress.modifiedAt)

            case "session":
                guard
                    let uuid = UUID(uuidString: components.identifier),
                    let session = try await database.session(id: uuid)
                else { return nil }
                return try await makeRecord(
                    type: "ReadingSession",
                    id: id,
                    value: session,
                    modifiedAt: session.endedAt ?? session.startedAt
                )

            case "category":
                guard
                    let uuid = UUID(uuidString: components.identifier),
                    let category = try await database.category(id: uuid)
                else { return nil }
                let payload = SyncedCategory(
                    category: category,
                    workIDs: try await database.workIDs(forCategoryID: uuid)
                )
                return try await makeRecord(
                    type: "Category",
                    id: id,
                    value: payload,
                    modifiedAt: category.modifiedAt
                )

            case "bookmark":
                guard
                    let uuid = UUID(uuidString: components.identifier),
                    let bookmark = try await database.bookmark(id: uuid)
                else { return nil }
                return try await makeRecord(
                    type: "Bookmark",
                    id: id,
                    value: bookmark,
                    modifiedAt: bookmark.modifiedAt
                )

            case "annotation":
                guard
                    let uuid = UUID(uuidString: components.identifier),
                    let annotation = try await database.annotation(id: uuid)
                else { return nil }
                return try await makeRecord(
                    type: "Annotation",
                    id: id,
                    value: annotation,
                    modifiedAt: annotation.modifiedAt
                )

            case "titleState":
                guard
                    let uuid = UUID(uuidString: components.identifier),
                    let titleState = try await database.titleState(
                        for: WorkID(rawValue: uuid)
                    )
                else { return nil }
                return try await makeRecord(
                    type: "UserTitleState",
                    id: id,
                    value: titleState,
                    modifiedAt: titleState.modifiedAt,
                    recordDeviceID: titleState.deviceID
                )

            case "importedOriginal":
                guard
                    let uuid = UUID(uuidString: components.identifier),
                    let reference = try await database.importedOriginalReference(
                        installmentID: InstallmentID(rawValue: uuid)
                    ),
                    reference.installmentID.rawValue == uuid,
                    reference.isValidForCloudSync
                else { return nil }
                return try await makeRecord(
                    type: "ImportedOriginalReference",
                    id: id,
                    value: reference,
                    modifiedAt: reference.modifiedAt
                )

            case "settings":
                guard
                    components.identifier == SyncedAppSettings.singletonID,
                    let settings = try await database.syncedAppSettings(),
                    settings.isValidForCloudSync
                else { return nil }
                return try await makeRecord(
                    type: "AppSettings",
                    id: id,
                    value: settings,
                    modifiedAt: settings.modifiedAt,
                    recordDeviceID: settings.deviceID
                )

            case "tombstone":
                guard
                    let uuid = UUID(uuidString: components.identifier),
                    let tombstone = try await database.tombstone(id: uuid)
                else { return nil }
                return try await makeRecord(
                    type: "Tombstone",
                    id: id,
                    value: tombstone,
                    modifiedAt: tombstone.deletedAt
                )

            default:
                return nil
            }
        } catch {
            // CKSyncEngine will keep a missing record pending and retry after the
            // local store becomes available; local reading remains unaffected.
            return nil
        }
    }

    public func apply(records: [CKRecord], deletions: [CKRecord.ID]) async throws {
        let deferred = try await database.deferredCloudChapterRecords().compactMap {
            try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: $0)
        }
        var byName = Dictionary(deferred.map { ($0.recordID.recordName, $0) }, uniquingKeysWith: { _, last in last })
        for record in records { byName[record.recordID.recordName] = record }
        let ordered = byName.values.sorted { recordPriority($0) < recordPriority($1) }
        for record in ordered {
            try await apply(record)
        }

        for deletion in deletions {
            guard
                deletion.zoneID == zoneID,
                let components = CloudSyncRecordID.components(deletion.recordName)
            else { continue }
            try await database.applyCloudRecordDeletion(
                kind: components.kind,
                identifier: components.identifier
            )
        }
    }

    public func didSave(records: [CKRecord]) async throws {
        for record in records where isSupported(record) {
            try await systemFieldsStore.saveSystemFields(for: record)
        }
    }

    public func didDelete(recordIDs: [CKRecord.ID]) async throws {
        for recordID in recordIDs where recordID.zoneID == zoneID {
            try await systemFieldsStore.remove(for: recordID)
        }
    }

    public func resetCloudAccountState() async throws {
        try await systemFieldsStore.removeAll()
    }

    private func apply(_ record: CKRecord) async throws {
        guard let components = CloudSyncRecordID.components(record.recordID.recordName) else { return }
        guard let expectedType = expectedRecordType(for: components.kind) else { return }
        guard record.recordID.zoneID == zoneID, record.recordType == expectedType else {
            throw CocoaError(.coderReadCorrupt)
        }

        switch components.kind {
        case "work":
            var incoming = try CloudRecordCodec.decode(SyncedLibraryWork.self, from: record)
            guard
                UUID(uuidString: components.identifier) == incoming.work.id.rawValue,
                incoming.entry.workID == incoming.work.id,
                incoming.installments.allSatisfy({ $0.workID == incoming.work.id }),
                incoming.work.customCoverPath == nil,
                incoming.work.coverURL?.isFileURL != true
            else {
                throw CocoaError(.coderReadCorrupt)
            }
            if let local = try await database.libraryBundle(workID: incoming.work.id),
               local.work.modifiedAt > incoming.work.modifiedAt
            {
                return
            }
            if let local = try await database.work(id: incoming.work.id) {
                incoming.work.customCoverPath = local.customCoverPath
                if local.coverURL?.isFileURL == true {
                    incoming.work.coverURL = local.coverURL
                }
            }
            try await database.save(work: incoming.work, entry: incoming.entry)
            try await database.mergeSyncedInstallments(incoming.installments)
            try await database.setAvailableSyncedCategories(
                incoming.categoryIDs,
                for: incoming.work.id
            )

        case "readingContent":
            let incoming = try CloudRecordCodec.decode(SyncedReadingContent.self, from: record)
            guard
                UUID(uuidString: components.identifier) == incoming.work.id.rawValue,
                incoming.installments.allSatisfy({ $0.workID == incoming.work.id }),
                incoming.work.customCoverPath == nil,
                incoming.work.coverURL?.isFileURL != true,
                incoming.installments.allSatisfy({ $0.acquisitionURL == nil })
            else {
                throw CocoaError(.coderReadCorrupt)
            }
            try await database.mergeSyncedReadingContent(
                work: incoming.work,
                installments: incoming.installments
            )

        case "progress", "chapterProgress":
            let incoming = try CloudRecordCodec.decode(ReadingProgress.self, from: record)
            let expectedID = components.kind == "chapterProgress" ? incoming.installmentID.rawValue : incoming.workID.rawValue
            guard UUID(uuidString: components.identifier) == expectedID else { throw CocoaError(.coderReadCorrupt) }
            guard try await database.canResolveChapter(incoming.installmentID, workID: incoming.workID) else {
                let data = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
                try await database.deferCloudChapterRecord(name: record.recordID.recordName, data: data)
                return
            }

            try await database.save(progress: incoming)
            try await database.removeDeferredCloudChapterRecord(name: record.recordID.recordName)

        case "session":
            let incoming = try CloudRecordCodec.decode(ReadingSession.self, from: record)
            guard UUID(uuidString: components.identifier) == incoming.id else { throw CocoaError(.coderReadCorrupt) }
            guard try await database.canResolveChapter(incoming.installmentID, workID: incoming.workID) else {
                let data = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
                try await database.deferCloudChapterRecord(name: record.recordID.recordName, data: data)
                return
            }

            if let local = try await database.session(id: incoming.id),
               (local.endedAt ?? local.startedAt) > (incoming.endedAt ?? incoming.startedAt)
            {
                return
            }
            try await database.save(session: incoming)
            try await database.removeDeferredCloudChapterRecord(name: record.recordID.recordName)

        case "category":
            let incoming = try CloudRecordCodec.decode(SyncedCategory.self, from: record)
            guard UUID(uuidString: components.identifier) == incoming.category.id else {
                throw CocoaError(.coderReadCorrupt)
            }
            if let local = try await database.category(id: incoming.category.id),
               local.modifiedAt > incoming.category.modifiedAt
            {
                return
            }
            try await database.save(category: incoming.category)
            try await database.addSyncedCategory(
                incoming.category.id,
                toAvailable: incoming.workIDs
            )

        case "bookmark":
            let incoming = try CloudRecordCodec.decode(Bookmark.self, from: record)
            guard UUID(uuidString: components.identifier) == incoming.id else { throw CocoaError(.coderReadCorrupt) }
            guard try await database.canResolveChapter(incoming.installmentID, workID: incoming.workID) else {
                let data = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
                try await database.deferCloudChapterRecord(name: record.recordID.recordName, data: data)
                return
            }

            if let local = try await database.bookmark(id: incoming.id),
               local.modifiedAt > incoming.modifiedAt
            {
                return
            }
            try await database.save(bookmark: incoming)
            try await database.removeDeferredCloudChapterRecord(name: record.recordID.recordName)

        case "annotation":
            let incoming = try CloudRecordCodec.decode(Annotation.self, from: record)
            guard UUID(uuidString: components.identifier) == incoming.id else { throw CocoaError(.coderReadCorrupt) }
            guard try await database.canResolveChapter(incoming.installmentID, workID: incoming.workID) else {
                let data = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
                try await database.deferCloudChapterRecord(name: record.recordID.recordName, data: data)
                return
            }

            if let local = try await database.annotation(id: incoming.id),
               local.modifiedAt > incoming.modifiedAt
            {
                return
            }
            try await database.save(annotation: incoming)
            try await database.removeDeferredCloudChapterRecord(name: record.recordID.recordName)

        case "titleState":
            guard
                let payload = record[CloudRecordCodec.payloadKey] as? Data,
                payload.count <= 524_288,
                let recordModifiedAt = record[CloudRecordCodec.modifiedAtKey] as? Date,
                let recordDeviceID = record[CloudRecordCodec.deviceIDKey] as? String
            else {
                throw CocoaError(.coderReadCorrupt)
            }
            var incoming = try JSONDecoder().decode(UserTitleState.self, from: payload)
            // Older clients omit dates. Only explicit null in a new payload clears them.
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
            if let local = try await database.titleState(for: incoming.workID) {
                if object?["startDate"] == nil { incoming.startDate = local.startDate }
                if object?["finishDate"] == nil { incoming.finishDate = local.finishDate }
            }
            guard
                UUID(uuidString: components.identifier) == incoming.workID.rawValue,
                !incoming.isEmpty,
                incoming.deviceID == recordDeviceID,
                incoming.deviceID.count <= 128,
                abs(incoming.modifiedAt.timeIntervalSince(recordModifiedAt)) < 0.000_001
            else {
                throw CocoaError(.coderReadCorrupt)
            }
            if let local = try await database.titleState(for: incoming.workID),
               local.modifiedAt > incoming.modifiedAt
                    || (local.modifiedAt == incoming.modifiedAt && local.deviceID > incoming.deviceID)
            {
                return
            }
            _ = try await database.save(titleState: incoming)

        case "importedOriginal":
            guard
                let expectedID = UUID(uuidString: components.identifier),
                let payload = record[CloudRecordCodec.payloadKey] as? Data,
                payload.count <= 16_384
            else {
                throw CocoaError(.coderReadCorrupt)
            }
            let incoming = try JSONDecoder().decode(ImportedOriginalReference.self, from: payload)
            guard
                incoming.installmentID.rawValue == expectedID,
                incoming.isValidForCloudSync
            else {
                throw MangoReaderDataError.invalidImportedOriginalReference
            }
            try await database.mergeSyncedImportedOriginalReference(incoming)

        case "settings":
            guard
                components.identifier == SyncedAppSettings.singletonID,
                record.recordType == "AppSettings",
                let payload = record[CloudRecordCodec.payloadKey] as? Data,
                !payload.isEmpty,
                payload.count <= 65_536,
                let recordModifiedAt = record[CloudRecordCodec.modifiedAtKey] as? Date,
                let recordDeviceID = record[CloudRecordCodec.deviceIDKey] as? String
            else {
                throw MangoReaderDataError.invalidSyncedAppSettings
            }
            let incoming = try JSONDecoder().decode(SyncedAppSettings.self, from: payload)
            guard
                incoming.isValidForCloudSync,
                incoming.deviceID == recordDeviceID,
                abs(incoming.modifiedAt.timeIntervalSince(recordModifiedAt)) < 0.000_001
            else {
                throw MangoReaderDataError.invalidSyncedAppSettings
            }
            try await database.mergeSyncedAppSettings(incoming)

        case "tombstone":
            let incoming = try CloudRecordCodec.decode(Tombstone.self, from: record)
            guard UUID(uuidString: components.identifier) == incoming.id else {
                throw CocoaError(.coderReadCorrupt)
            }
            try await database.apply(tombstone: incoming)

        default:
            break
        }
    }

    private func makeRecord<Value: Encodable>(
        type: String,
        id: CKRecord.ID,
        value: Value,
        modifiedAt: Date,
        recordDeviceID: String? = nil
    ) async throws -> CKRecord {
        let record = try await systemFieldsStore.record(for: id, expectedType: type)
            ?? CKRecord(recordType: type, recordID: id)
        for key in record.allKeys() {
            record[key] = nil
        }
        record[CloudRecordCodec.payloadKey] = try JSONEncoder().encode(value) as CKRecordValue
        record[CloudRecordCodec.modifiedAtKey] = modifiedAt as CKRecordValue
        record[CloudRecordCodec.deviceIDKey] = (recordDeviceID ?? deviceID) as CKRecordValue
        return record
    }

    private func isSupported(_ record: CKRecord) -> Bool {
        guard
            record.recordID.zoneID == zoneID,
            let components = CloudSyncRecordID.components(record.recordID.recordName),
            let expectedType = expectedRecordType(for: components.kind)
        else { return false }
        return record.recordType == expectedType
    }

    private func expectedRecordType(for kind: String) -> String? {
        switch kind {
        case "work": "LibraryWork"
        case "readingContent": "ReadingContent"
        case "progress", "chapterProgress": "ReadingProgress"
        case "session": "ReadingSession"
        case "category": "Category"
        case "bookmark": "Bookmark"
        case "annotation": "Annotation"
        case "titleState": "UserTitleState"
        case "importedOriginal": "ImportedOriginalReference"
        case "settings": "AppSettings"
        case "tombstone": "Tombstone"
        default: nil
        }
    }

    private func recordPriority(_ record: CKRecord) -> Int {
        switch CloudSyncRecordID.components(record.recordID.recordName)?.kind {
        case "settings": 0
        case "category": 1
        case "work", "readingContent": 2
        case "importedOriginal": 3
        case "progress", "chapterProgress", "session", "bookmark", "annotation", "titleState": 4
        case "tombstone": 5
        default: 6
        }
    }
}
