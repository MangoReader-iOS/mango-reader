import Foundation
import GRDB
import MangoReaderDomain

extension MangoReaderDatabase {
    public func save(category: MangoReaderDomain.Category) throws {
        try pool.write { db in
            try CategoryRecord(category).save(db)
        }
    }

    public func save(categories: [MangoReaderDomain.Category]) throws {
        let records = categories.map(CategoryRecord.init)
        try pool.write { db in
            for record in records {
                try record.save(db)
            }
        }
    }

    @discardableResult
    public func deleteCategory(id: UUID, deviceID: String) async throws -> Tombstone {
        try await pool.write { db in
            var tombstone = Tombstone(
                entityType: "category",
                entityID: id.uuidString,
                deviceID: deviceID
            )
            var tombstoneRecord = TombstoneRecord(tombstone)
            if let existing = try TombstoneRecord
                .filter(Column("entityType") == tombstoneRecord.entityType)
                .filter(Column("entityID") == tombstoneRecord.entityID)
                .fetchOne(db)
            {
                tombstone.id = UUID(uuidString: existing.id) ?? tombstone.id
                tombstoneRecord.id = existing.id
            }

            try Self.removeCategoryFromSavedFilters(id, in: db)

            _ = try CategoryRecord.deleteOne(db, key: id.uuidString)
            try tombstoneRecord.save(db)
            return try tombstoneRecord.domainValue()
        }
    }

    public func category(id: UUID) throws -> MangoReaderDomain.Category? {
        try pool.read { db in
            try CategoryRecord.fetchOne(db, key: id.uuidString)?.domainValue()
        }
    }

    public func categories() throws -> [MangoReaderDomain.Category] {
        try pool.read { db in
            let records = try CategoryRecord
                .order(Column("sortIndex"), Column("name").collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
            return try records.map { try $0.domainValue() }
        }
    }

    public func setCategories(_ categoryIDs: Set<UUID>, for workID: WorkID) throws {
        let workIDString = workID.rawValue.uuidString
        let sortedIDs = categoryIDs.map(\.uuidString).sorted()
        let modifiedAt = Date.now.timeIntervalSince1970
        try pool.write { db in
            try CategoryMembershipRecord
                .filter(Column("workID") == workIDString)
                .deleteAll(db)
            for categoryID in sortedIDs {
                try CategoryMembershipRecord(
                    categoryID: categoryID,
                    workID: workIDString
                ).insert(db)
            }
            try db.execute(
                sql: "UPDATE works SET modifiedAt = ? WHERE id = ?",
                arguments: [modifiedAt, workIDString]
            )
        }
    }

    public func addCategories(_ categoryIDs: Set<UUID>, to workIDs: Set<WorkID>) throws {
        guard !categoryIDs.isEmpty, !workIDs.isEmpty else { return }
        let sortedCategoryIDs = categoryIDs.map(\.uuidString).sorted()
        let sortedWorkIDs = workIDs.map { $0.rawValue.uuidString }.sorted()
        let modifiedAt = Date.now.timeIntervalSince1970
        try pool.write { db in
            for workID in sortedWorkIDs {
                for categoryID in sortedCategoryIDs {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO categoryMemberships (categoryID, workID) VALUES (?, ?)",
                        arguments: [categoryID, workID]
                    )
                }
                try db.execute(
                    sql: "UPDATE works SET modifiedAt = ? WHERE id = ?",
                    arguments: [modifiedAt, workID]
                )
            }
        }
    }

    public func categoryIDs(for workID: WorkID) throws -> Set<UUID> {
        try pool.read { db in
            let ids = try String.fetchAll(
                db,
                sql: "SELECT categoryID FROM categoryMemberships WHERE workID = ?",
                arguments: [workID.rawValue.uuidString]
            )
            return Set(ids.compactMap(UUID.init(uuidString:)))
        }
    }

    public func workIDs(forCategoryID categoryID: UUID) throws -> Set<WorkID> {
        try pool.read { db in
            let ids = try String.fetchAll(
                db,
                sql: "SELECT workID FROM categoryMemberships WHERE categoryID = ?",
                arguments: [categoryID.uuidString]
            )
            return Set(ids.compactMap(UUID.init(uuidString:)).map(WorkID.init(rawValue:)))
        }
    }

    /// Applies a cloud membership snapshot without failing when related records
    /// are delivered in a later CloudKit batch.
    public func setAvailableSyncedCategories(
        _ categoryIDs: Set<UUID>,
        for workID: WorkID
    ) async throws {
        let workIDString = workID.rawValue.uuidString
        try await pool.write { db in
            try CategoryMembershipRecord
                .filter(Column("workID") == workIDString)
                .deleteAll(db)
            for categoryID in categoryIDs {
                guard try CategoryRecord.fetchOne(db, key: categoryID.uuidString) != nil else { continue }
                try CategoryMembershipRecord(
                    categoryID: categoryID.uuidString,
                    workID: workIDString
                ).insert(db)
            }
        }
    }

    /// Completes memberships when a category arrives after its works in a
    /// different CloudKit change batch.
    public func addSyncedCategory(_ categoryID: UUID, toAvailable workIDs: Set<WorkID>) async throws {
        try await pool.write { db in
            guard try CategoryRecord.fetchOne(db, key: categoryID.uuidString) != nil else { return }
            for workID in workIDs {
                let workIDString = workID.rawValue.uuidString
                guard try WorkRecord.fetchOne(db, key: workIDString) != nil else { continue }
                try db.execute(
                    sql: "INSERT OR IGNORE INTO categoryMemberships (categoryID, workID) VALUES (?, ?)",
                    arguments: [categoryID.uuidString, workIDString]
                )
            }
        }
    }

    public func save(filter: SavedFilter) throws {
        let record = try SavedFilterRecord(filter)
        try pool.write { db in try record.save(db) }
    }

    public func savedFilters() throws -> [SavedFilter] {
        try pool.read { db in
            let records = try SavedFilterRecord
                .order(Column("name").collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
            return try records.map { try $0.domainValue() }
        }
    }

    public func deleteSavedFilter(id: UUID) throws {
        try pool.write { db in
            _ = try SavedFilterRecord.deleteOne(db, key: id.uuidString)
        }
    }

    static func removeCategoryFromSavedFilters(_ categoryID: UUID, in db: Database) throws {
        for record in try SavedFilterRecord.fetchAll(db) {
            var filter = try record.domainValue()
            guard filter.categoryIDs.remove(categoryID) != nil else { continue }
            try SavedFilterRecord(filter).save(db)
        }
    }
}
