import Foundation
import GRDB
import MangoReaderDomain

extension MangoReaderDatabase {
    /// Only descriptors explicitly identified as extensions participate. Native
    /// connectors and imported publications keep their existing identifiers.
    public func repairExtensionChapters(sourceIDs: Set<SourceID>) async throws -> Set<WorkID> {
        try await pool.write { db in
            for sourceID in sourceIDs {
                try db.execute(sql: "INSERT OR IGNORE INTO extensionChapterSources VALUES (?)", arguments: [sourceID.rawValue])
            }
            return try Self.repairExtensionChapters(in: db)
        }
    }

    static func repairExtensionChapters(in db: Database) throws -> Set<WorkID> {
        let works = try WorkRecord.fetchAll(db, sql: "SELECT works.* FROM works JOIN extensionChapterSources ON works.sourceID = extensionChapterSources.sourceID")
        var changed = Set<WorkID>()
        let tables = ["readingProgress", "readingSessions", "bookmarks", "annotations", "downloads"]
        let oldChapters = try InstallmentRecord.fetchAll(db)
        for record in oldChapters {
            guard let remote = record.remoteID, let owner = works.first(where: { $0.id == record.workID }) else { continue }
            let work = try owner.domainValue()
            let oldID = record.id
            let scopedOwner = ExtensionChapterIdentity.id(sourceID: work.sourceID, workID: work.id, remoteID: remote)
            if oldID == scopedOwner.description {
                let legacy = ExtensionChapterIdentity.legacyID(sourceID: work.sourceID, remoteID: remote)
                try db.execute(sql: "INSERT OR IGNORE INTO extensionChapterAliases VALUES (?, ?, ?)", arguments: [record.workID, legacy.description, oldID])
                continue
            }
            let legacyID = ExtensionChapterIdentity.legacyID(sourceID: work.sourceID, remoteID: remote).description
            // References can outlive metadata displaced by the former upsert.
            var owners = Set([record.workID])
            for table in tables {
                owners.formUnion(try String.fetchAll(db, sql: "SELECT DISTINCT workID FROM \(table) WHERE installmentID = ?", arguments: [oldID]))
            }
            for parent in owners {
                guard let parentRecord = works.first(where: { $0.id == parent }), parentRecord.sourceID == owner.sourceID else { continue }
                let parentWork = try parentRecord.domainValue()
                let scopedID = ExtensionChapterIdentity.id(sourceID: parentWork.sourceID, workID: parentWork.id, remoteID: remote)
                for alias in Set([oldID, legacyID]) where alias != scopedID.description {
                    try db.execute(sql: "INSERT OR REPLACE INTO extensionChapterAliases(workID, legacyID, scopedID) VALUES (?, ?, ?)", arguments: [parent, alias, scopedID.description])
                }
                guard oldID != scopedID.description else { continue }
                var chapter = try record.domainValue()
                chapter.id = scopedID
                chapter.workID = parentWork.id
                let displaced = parent != record.workID
                if chapter.acquisitionURL?.isFileURL == true {
                    let verified = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM downloads WHERE installmentID = ? AND workID = ? AND state = 'completed' AND localRelativePath IS NOT NULL", arguments: [oldID, parent]) ?? 0
                    if verified == 0 {
                        try db.execute(sql: "INSERT OR IGNORE INTO extensionChapterRecovery VALUES (?, ?, ?, ?)", arguments: [oldID, parent, oldID, chapter.acquisitionURL?.absoluteString])
                        chapter.acquisitionURL = nil
                    }
                }
                // Never copy content or title metadata from a different owner.
                if displaced {
                    chapter = Installment(id: scopedID, workID: parentWork.id, remoteID: remote,
                                          title: "Chapter — refresh required", format: chapter.format)
                    try db.execute(sql: "INSERT OR IGNORE INTO extensionChapterRecovery VALUES (?, ?, ?, NULL)",
                                   arguments: [scopedID.description, parent, oldID])
                }
                if try InstallmentRecord.fetchOne(db, key: scopedID.description) == nil {
                    try InstallmentRecord(chapter).insert(db)
                }
                for table in tables {
                    if table == "downloads", displaced {
                        // Keep the file path and original association for recovery,
                        // but fail the job and detach the unverified serving path.
                        try db.execute(sql: "INSERT OR IGNORE INTO extensionChapterRecovery SELECT id, workID, installmentID, localRelativePath FROM downloads WHERE workID = ? AND installmentID = ?", arguments: [parent, oldID])
                        try db.execute(sql: "UPDATE downloads SET state = 'failed', localRelativePath = NULL, lastError = 'Chapter ownership could not be verified. Refresh and retry; the original file is retained for recovery.' WHERE workID = ? AND installmentID = ?", arguments: [parent, oldID])
                    }
                    try db.execute(sql: "UPDATE \(table) SET installmentID = ? WHERE workID = ? AND installmentID = ?", arguments: [scopedID.description, parent, oldID])
                }
                changed.insert(parentWork.id)
                try db.execute(sql: "INSERT OR IGNORE INTO extensionChapterRepairQueue VALUES (?)", arguments: [parent])
            }
            if oldID != ExtensionChapterIdentity.id(sourceID: work.sourceID, workID: work.id, remoteID: remote).description {
                // References from unknown/native sources cannot be guessed away.
                let references = try tables.reduce(0) { count, table in count + (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE installmentID = ?", arguments: [oldID]) ?? 0) }
                if references == 0 { try InstallmentRecord.deleteOne(db, key: oldID) }
                else { try db.execute(sql: "UPDATE installments SET acquisitionURL = NULL WHERE id = ?", arguments: [oldID]) }
            }
        }
        try DatabaseSchema.createChapterOwnershipGuards(in: db)
        return changed
    }

    static func normalizedChapter(_ proposed: Installment, in db: Database) throws -> Installment {
        var chapter = proposed
        guard let work = try WorkRecord.fetchOne(db, key: chapter.workID.description),
              try String.fetchOne(db, sql: "SELECT sourceID FROM extensionChapterSources WHERE sourceID = ?", arguments: [work.sourceID]) != nil,
              let remoteID = chapter.remoteID else { return chapter }
        chapter.id = ExtensionChapterIdentity.id(sourceID: SourceID(rawValue: work.sourceID), workID: chapter.workID, remoteID: remoteID)
        if proposed.id != chapter.id {
            try db.execute(sql: "INSERT OR IGNORE INTO extensionChapterRepairQueue VALUES (?)", arguments: [chapter.workID.description])
            try db.execute(sql: "INSERT OR REPLACE INTO extensionChapterAliases VALUES (?, ?, ?)", arguments: [chapter.workID.description, proposed.id.description, chapter.id.description])
        }
        let legacy = ExtensionChapterIdentity.legacyID(sourceID: SourceID(rawValue: work.sourceID), remoteID: remoteID)
        try db.execute(sql: "INSERT OR REPLACE INTO extensionChapterAliases VALUES (?, ?, ?)", arguments: [chapter.workID.description, legacy.description, chapter.id.description])
        return chapter
    }

    static func normalizedChapterID(_ id: InstallmentID, workID: WorkID, in db: Database) throws -> InstallmentID {
        var raw = try String.fetchOne(db, sql: "SELECT scopedID FROM extensionChapterAliases WHERE workID = ? AND legacyID = ?", arguments: [workID.description, id.description]) ?? id.description
        if try InstallmentRecord.fetchOne(db, key: raw)?.workID != workID.description,
           let parent = try WorkRecord.fetchOne(db, key: workID.description),
           try String.fetchOne(db, sql: "SELECT sourceID FROM extensionChapterSources WHERE sourceID = ?", arguments: [parent.sourceID]) != nil {
            let sourceID = SourceID(rawValue: parent.sourceID)
            let candidates = try InstallmentRecord.fetchAll(db, sql: "SELECT installments.* FROM installments JOIN works ON works.id = installments.workID WHERE works.sourceID = ?", arguments: [sourceID.rawValue])
            if let displaced = candidates.first(where: { chapter in
                chapter.remoteID.map { ExtensionChapterIdentity.legacyID(sourceID: sourceID, remoteID: $0) == id } ?? false
            }), let remote = displaced.remoteID {
                let scoped = ExtensionChapterIdentity.id(sourceID: sourceID, workID: workID, remoteID: remote)
                let placeholder = Installment(id: scoped, workID: workID, remoteID: remote, title: "Chapter — refresh required", format: try displaced.domainValue().format)
                try InstallmentRecord(placeholder).save(db)
                try db.execute(sql: "INSERT OR IGNORE INTO extensionChapterRecovery VALUES (?, ?, ?, NULL)",
                               arguments: [scoped.description, workID.description, id.description])
                raw = scoped.description
                try db.execute(sql: "INSERT OR REPLACE INTO extensionChapterAliases VALUES (?, ?, ?)", arguments: [workID.description, id.description, raw])
                try db.execute(sql: "INSERT OR IGNORE INTO extensionChapterRepairQueue VALUES (?)", arguments: [workID.description])
            }
        }
        guard let uuid = UUID(uuidString: raw),
              let chapter = try InstallmentRecord.fetchOne(db, key: raw), chapter.workID == workID.description else {
            throw MangoReaderDataError.inconsistentIdentifiers
        }
        if raw != id.description { try db.execute(sql: "INSERT OR IGNORE INTO extensionChapterRepairQueue VALUES (?)", arguments: [workID.description]) }
        return InstallmentID(rawValue: uuid)
    }

    static func saveChapter(_ proposed: Installment, in db: Database) throws {
        let chapter = try normalizedChapter(proposed, in: db)
        if let old = try InstallmentRecord.fetchOne(db, key: chapter.id.description), old.workID != chapter.workID.description {
            throw MangoReaderDataError.inconsistentIdentifiers
        }
        try InstallmentRecord(chapter).save(db)
    }

    public func canResolveChapter(_ id: InstallmentID, workID: WorkID) throws -> Bool {
        try pool.write { db in (try? Self.normalizedChapterID(id, workID: workID, in: db)) != nil }
    }

    /// Reconcile the separate durable acquisition queue before it reconnects
    /// background tasks. Never authorize an old URL by guessing its parent.
    public func normalizedDownloadForRestoration(_ proposed: DownloadJob) throws -> (job: DownloadJob, requiresRefresh: Bool) {
        try pool.write { db in
            guard let parent = try WorkRecord.fetchOne(db, key: proposed.workID.description),
                  try String.fetchOne(db, sql: "SELECT sourceID FROM extensionChapterSources WHERE sourceID = ?", arguments: [parent.sourceID]) != nil else {
                return (proposed, false)
            }
            var job = proposed
            let canonical = try? Self.normalizedChapterID(proposed.installmentID, workID: proposed.workID, in: db)
            if let canonical { job.installmentID = canonical }
            let old = try DownloadJobRecord.fetchOne(db, key: proposed.id.uuidString)?.domainValue()
            let recoveredJob = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM extensionChapterRecovery WHERE id = ? AND workID = ?", arguments: [proposed.id.uuidString, parent.id]) ?? 0
            let displacementCount = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM extensionChapterRecovery WHERE id = ? AND workID = ?",
                arguments: [job.installmentID.description, parent.id]) ?? 0
            let displaced = canonical != proposed.installmentID && displacementCount > 0
            let verifiedFile = old?.workID == proposed.workID && old?.installmentID == canonical
                && old?.state == .completed && old?.localRelativePath == proposed.localRelativePath
            let ambiguous = canonical == nil || recoveredJob > 0 || displaced
                || (proposed.localRelativePath != nil && !verifiedFile)
            if ambiguous {
                try db.execute(sql: "INSERT OR IGNORE INTO extensionChapterRecovery VALUES (?, ?, ?, ?)",
                    arguments: [proposed.id.uuidString, parent.id, proposed.installmentID.description, proposed.localRelativePath])
                job.state = .failed
                job.localRelativePath = nil
                job.lastError = "Chapter ownership could not be verified. Refresh the source and queue this chapter again. The original file is retained for recovery."
            }
            if canonical != nil { try DownloadJobRecord(job).save(db) }
            return (job, ambiguous)
        }
    }
    public func deferCloudChapterRecord(name: String, data: Data) throws {
        try pool.write { db in try db.execute(sql: "INSERT OR REPLACE INTO deferredChapterRecords VALUES (?, ?)", arguments: [name, data]) }
    }
    public func deferredCloudChapterRecords() throws -> [Data] {
        try pool.read { db in try Data.fetchAll(db, sql: "SELECT payload FROM deferredChapterRecords") }
    }
    public func removeDeferredCloudChapterRecord(name: String) throws {
        try pool.write { db in try db.execute(sql: "DELETE FROM deferredChapterRecords WHERE name = ?", arguments: [name]) }
    }
    public func chapterRepairQueue() throws -> Set<WorkID> {
        try pool.read { db in Set(try String.fetchAll(db, sql: "SELECT workID FROM extensionChapterRepairQueue").compactMap { UUID(uuidString: $0).map { WorkID(rawValue: $0) } }) }
    }
    public func acknowledgeChapterRepairs() throws {
        try pool.write { db in try db.execute(sql: "DELETE FROM extensionChapterRepairQueue") }
    }
}

struct ChapterIdentityBackup: Codable, Sendable {
    var sources: [String]
    var aliases: [ChapterAliasRecord]
    var recovery: [ChapterRecoveryRecord]
    static func read(in db: Database) throws -> Self {
        Self(sources: try String.fetchAll(db, sql: "SELECT sourceID FROM extensionChapterSources"), aliases: try ChapterAliasRecord.fetchAll(db), recovery: try ChapterRecoveryRecord.fetchAll(db))
    }
    func restore(in db: Database) throws {
        for source in sources { try db.execute(sql: "INSERT OR IGNORE INTO extensionChapterSources VALUES (?)", arguments: [source]) }
        for alias in aliases { try alias.save(db) }
        for row in recovery { try row.save(db) }
    }
}
struct ChapterAliasRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "extensionChapterAliases"
    var workID: String
    var legacyID: String
    var scopedID: String
}
struct ChapterRecoveryRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "extensionChapterRecovery"
    var id: String
    var workID: String
    var installmentID: String
    var localRelativePath: String?
}
