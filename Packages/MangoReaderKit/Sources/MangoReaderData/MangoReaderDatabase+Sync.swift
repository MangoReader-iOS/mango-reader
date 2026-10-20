import Foundation
import GRDB
import MangoReaderDomain

public struct CloudSyncInventory: Equatable, Sendable {
    public var workIDs: [WorkID]
    public var readingContentWorkIDs: [WorkID]
    public var progressWorkIDs: [WorkID]
    public var progressInstallmentIDs: [InstallmentID]
    public var sessionIDs: [UUID]
    public var categoryIDs: [UUID]
    public var bookmarkIDs: [UUID]
    public var annotationIDs: [UUID]
    public var titleStateWorkIDs: [WorkID]
    public var importedOriginalInstallmentIDs: [InstallmentID]
    public var hasSyncedAppSettings: Bool
    public var tombstoneIDs: [UUID]

    public init(
        workIDs: [WorkID],
        readingContentWorkIDs: [WorkID],
        progressWorkIDs: [WorkID],
        sessionIDs: [UUID],
        categoryIDs: [UUID],
        bookmarkIDs: [UUID],
        annotationIDs: [UUID],
        titleStateWorkIDs: [WorkID],
        importedOriginalInstallmentIDs: [InstallmentID],
        hasSyncedAppSettings: Bool,
        tombstoneIDs: [UUID],
        progressInstallmentIDs: [InstallmentID] = []
    ) {
        self.workIDs = workIDs
        self.readingContentWorkIDs = readingContentWorkIDs
        self.progressWorkIDs = progressWorkIDs
        self.progressInstallmentIDs = progressInstallmentIDs
        self.sessionIDs = sessionIDs
        self.categoryIDs = categoryIDs
        self.bookmarkIDs = bookmarkIDs
        self.annotationIDs = annotationIDs
        self.titleStateWorkIDs = titleStateWorkIDs
        self.importedOriginalInstallmentIDs = importedOriginalInstallmentIDs
        self.hasSyncedAppSettings = hasSyncedAppSettings
        self.tombstoneIDs = tombstoneIDs
    }
}

extension MangoReaderDatabase {
    public func cloudSyncInventory() async throws -> CloudSyncInventory {
        try await pool.read { db in
            let workIDs = try String.fetchAll(
                db,
                sql: "SELECT works.id FROM works JOIN libraryEntries ON libraryEntries.workID = works.id"
            )
            let readingContentWorkIDs = try String.fetchAll(
                db,
                sql: """
                    SELECT works.id
                    FROM works
                    LEFT JOIN libraryEntries ON libraryEntries.workID = works.id
                    WHERE libraryEntries.workID IS NULL
                    """
            )
            let progressWorkIDs = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT workID FROM readingProgress"
            )
            let progressInstallmentIDs = try String.fetchAll(db, sql: "SELECT installmentID FROM readingProgress")
            let sessionIDs = try String.fetchAll(db, sql: "SELECT id FROM readingSessions")
            let categoryIDs = try String.fetchAll(db, sql: "SELECT id FROM categories")
            let bookmarkIDs = try String.fetchAll(db, sql: "SELECT id FROM bookmarks")
            let annotationIDs = try String.fetchAll(db, sql: "SELECT id FROM annotations")
            let titleStateWorkIDs = try String.fetchAll(
                db,
                sql: "SELECT workID FROM userTitleStates"
            )
            let importedOriginalInstallmentIDs = try String.fetchAll(
                db,
                sql: "SELECT installmentID FROM importedOriginalReferences"
            )
            let hasSyncedAppSettings = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM syncedAppSettings WHERE id = ?)",
                arguments: [SyncedAppSettings.singletonID]
            ) ?? false
            let tombstoneIDs = try String.fetchAll(db, sql: "SELECT id FROM tombstones")

            return CloudSyncInventory(
                workIDs: workIDs.compactMap(UUID.init(uuidString:)).map(WorkID.init(rawValue:)),
                readingContentWorkIDs: readingContentWorkIDs
                    .compactMap(UUID.init(uuidString:))
                    .map(WorkID.init(rawValue:)),
                progressWorkIDs: progressWorkIDs.compactMap(UUID.init(uuidString:)).map(WorkID.init(rawValue:)),
                sessionIDs: sessionIDs.compactMap(UUID.init(uuidString:)),
                categoryIDs: categoryIDs.compactMap(UUID.init(uuidString:)),
                bookmarkIDs: bookmarkIDs.compactMap(UUID.init(uuidString:)),
                annotationIDs: annotationIDs.compactMap(UUID.init(uuidString:)),
                titleStateWorkIDs: titleStateWorkIDs
                    .compactMap(UUID.init(uuidString:))
                    .map(WorkID.init(rawValue:)),
                importedOriginalInstallmentIDs: importedOriginalInstallmentIDs
                    .compactMap(UUID.init(uuidString:))
                    .map(InstallmentID.init(rawValue:)),
                hasSyncedAppSettings: hasSyncedAppSettings,
                tombstoneIDs: tombstoneIDs.compactMap(UUID.init(uuidString:)),
                progressInstallmentIDs: progressInstallmentIDs.compactMap(UUID.init(uuidString:)).map(InstallmentID.init(rawValue:))
            )
        }
    }

    // MARK: - Non-sensitive synchronized settings

    /// Saves preferences produced by this device. Callers stamp a fresh
    /// modified date and this device's stable tie-break identifier first.
    public func save(syncedAppSettings settings: SyncedAppSettings) async throws {
        guard settings.isValidForCloudSync else {
            throw MangoReaderDataError.invalidSyncedAppSettings
        }
        try await pool.write { db in
            try SyncedAppSettingsRecord(settings).save(db)
        }
    }

    /// Atomically suppresses duplicate scene/UserDefaults echoes against the
    /// durable winner. When a real local change follows a slightly future
    /// device clock, its timestamp is advanced monotonically so the user's edit
    /// is not discarded by the subsequent LWW comparison.
    @discardableResult
    public func saveSyncedAppSettingsIfPreferencesChanged(
        _ proposed: SyncedAppSettings,
        forceMetadataRefresh: Bool = false
    ) async throws -> SyncedAppSettings? {
        guard proposed.isValidForCloudSync else {
            throw MangoReaderDataError.invalidSyncedAppSettings
        }
        return try await pool.write { db in
            let existing = try SyncedAppSettingsRecord
                .fetchOne(db, key: SyncedAppSettings.singletonID)?
                .domainValue()
            if !forceMetadataRefresh,
               let existing,
               proposed.hasSamePreferences(as: existing)
            {
                return nil
            }

            let settings: SyncedAppSettings
            if let existing, proposed.modifiedAt <= existing.modifiedAt {
                settings = proposed.replacingMetadata(
                    modifiedAt: existing.modifiedAt.addingTimeInterval(0.001),
                    deviceID: proposed.deviceID
                )
            } else {
                settings = proposed
            }
            guard settings.isValidForCloudSync else {
                throw MangoReaderDataError.invalidSyncedAppSettings
            }
            try SyncedAppSettingsRecord(settings).save(db)
            return settings
        }
    }

    /// Applies a remote value with deterministic latest-modified/device-ID
    /// resolution. The return value says whether the durable local value
    /// changed, which lets UI coordinators avoid unnecessary refreshes.
    @discardableResult
    public func mergeSyncedAppSettings(_ incoming: SyncedAppSettings) async throws -> Bool {
        guard incoming.isValidForCloudSync else {
            throw MangoReaderDataError.invalidSyncedAppSettings
        }
        return try await pool.write { db in
            let existing = try SyncedAppSettingsRecord
                .fetchOne(db, key: SyncedAppSettings.singletonID)?
                .domainValue()
            guard let existing else {
                try SyncedAppSettingsRecord(incoming).insert(db)
                return true
            }
            let winner = existing.merging(incoming)
            guard winner != existing else { return false }
            try SyncedAppSettingsRecord(winner).save(db)
            return true
        }
    }

    public func syncedAppSettings() async throws -> SyncedAppSettings? {
        try await pool.read { db in
            try SyncedAppSettingsRecord
                .fetchOne(db, key: SyncedAppSettings.singletonID)?
                .domainValue()
        }
    }

    @discardableResult
    public func deleteSyncedAppSettings() async throws -> Bool {
        try await pool.write { db in
            try SyncedAppSettingsRecord.deleteOne(db, key: SyncedAppSettings.singletonID)
        }
    }

    public func tombstones(limit: Int = 1_000) throws -> [Tombstone] {
        guard limit > 0 else { return [] }
        return try pool.read { db in
            let records = try TombstoneRecord
                .order(Column("deletedAt"))
                .limit(min(limit, 10_000))
                .fetchAll(db)
            return try records.map { try $0.domainValue() }
        }
    }

    public func tombstone(id: UUID) throws -> Tombstone? {
        try pool.read { db in
            try TombstoneRecord.fetchOne(db, key: id.uuidString)?.domainValue()
        }
    }

    /// Applies a logical deletion received through CloudKit. Keeping the
    /// tombstone locally prevents an older record from resurrecting the entity.
    public func apply(tombstone: Tombstone) async throws {
        try await pool.write { db in
            var record = TombstoneRecord(tombstone)
            if let existing = try TombstoneRecord
                .filter(Column("entityType") == record.entityType)
                .filter(Column("entityID") == record.entityID)
                .fetchOne(db)
            {
                guard existing.deletedAt <= record.deletedAt else { return }
                record.id = existing.id
            }
            if tombstone.entityType == "titleState",
               let titleState = try UserTitleStateRecord.fetchOne(db, key: tombstone.entityID),
               titleState.modifiedAt > tombstone.deletedAt.timeIntervalSince1970
            {
                return
            }
            try record.save(db)

            switch tombstone.entityType {
            case "work":
                _ = try WorkRecord.deleteOne(db, key: tombstone.entityID)
            case "category":
                _ = try CategoryRecord.deleteOne(db, key: tombstone.entityID)
                if let categoryID = UUID(uuidString: tombstone.entityID) {
                    try Self.removeCategoryFromSavedFilters(categoryID, in: db)
                }
            case "bookmark":
                _ = try BookmarkRecord.deleteOne(db, key: tombstone.entityID)
            case "annotation":
                _ = try AnnotationRecord.deleteOne(db, key: tombstone.entityID)
            case "titleState":
                _ = try UserTitleStateRecord.deleteOne(db, key: tombstone.entityID)
            default:
                break
            }
        }
    }

    /// Removes a CloudKit record representation without manufacturing another
    /// logical deletion. User deletions should travel as `Tombstone` records.
    public func applyCloudRecordDeletion(kind: String, identifier: String) async throws {
        try await pool.write { db in
            switch kind {
            case "work":
                // A LibraryWork record disappearing means the title was
                // unsaved. Preserve its cached work graph and reader state;
                // permanent deletion is represented by a work tombstone.
                _ = try LibraryEntryRecord
                    .filter(Column("workID") == identifier)
                    .deleteAll(db)
            case "chapterProgress":
                _ = try ReadingProgressRecord
                    .filter(Column("installmentID") == identifier)
                    .deleteAll(db)
            case "progress":
                _ = try ReadingProgressRecord
                    .filter(Column("workID") == identifier)
                    .deleteAll(db)
            case "category":
                _ = try CategoryRecord.deleteOne(db, key: identifier)
                if let categoryID = UUID(uuidString: identifier) {
                    try Self.removeCategoryFromSavedFilters(categoryID, in: db)
                }
            case "bookmark":
                _ = try BookmarkRecord.deleteOne(db, key: identifier)
            case "annotation":
                _ = try AnnotationRecord.deleteOne(db, key: identifier)
            case "titleState":
                _ = try UserTitleStateRecord.deleteOne(db, key: identifier)
            case "session":
                _ = try ReadingSessionRecord.deleteOne(db, key: identifier)
            case "readingContent":
                // ReadingContent is redundant after promotion to Library. Its
                // CloudKit deletion must never delete local membership, files,
                // or reader state, including when change batches are reordered.
                break
            case "importedOriginal":
                _ = try ImportedOriginalReferenceRecord.deleteOne(db, key: identifier)
            case "settings" where identifier == SyncedAppSettings.singletonID:
                _ = try SyncedAppSettingsRecord.deleteOne(db, key: identifier)
            case "tombstone":
                _ = try TombstoneRecord.deleteOne(db, key: identifier)
            default:
                break
            }
        }
    }
}
