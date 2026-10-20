import Foundation
import GRDB
import MangoReaderDomain

extension MangoReaderDatabase {
    // MARK: - LibraryRepository

    public func library(sort: LibrarySort) async throws -> [Work] {
        let orderClause = Self.libraryOrderClause(for: sort)

        return try await pool.read { db in
            let records = try WorkRecord.fetchAll(db, sql: """
                SELECT works.*
                FROM works
                JOIN libraryEntries ON libraryEntries.workID = works.id
                WHERE libraryEntries.isHidden = 0
                ORDER BY libraryEntries.isPinned DESC, \(orderClause)
                """)
            return try records.map { try $0.domainValue() }
        }
    }

    /// Returns visible Library works that have no category memberships.
    public func uncategorizedLibrary(sort: LibrarySort) async throws -> [Work] {
        let orderClause = Self.libraryOrderClause(for: sort)

        return try await pool.read { db in
            let records = try WorkRecord.fetchAll(db, sql: """
                SELECT works.*
                FROM works
                JOIN libraryEntries ON libraryEntries.workID = works.id
                WHERE libraryEntries.isHidden = 0
                  AND NOT EXISTS (
                    SELECT 1
                    FROM categoryMemberships
                    WHERE categoryMemberships.workID = works.id
                  )
                ORDER BY libraryEntries.isPinned DESC, \(orderClause)
                """)
            return try records.map { try $0.domainValue() }
        }
    }

    private static func libraryOrderClause(for sort: LibrarySort) -> String {
        switch sort {
        case .title:
            "works.title COLLATE NOCASE ASC"
        case .recentlyAdded:
            "libraryEntries.addedAt DESC, works.title COLLATE NOCASE ASC"
        case .recentlyRead:
            "libraryEntries.lastOpenedAt IS NULL, libraryEntries.lastOpenedAt DESC, works.title COLLATE NOCASE ASC"
        case .unread:
            "libraryEntries.unreadCount DESC, works.title COLLATE NOCASE ASC"
        case .lastUpdated:
            "works.modifiedAt DESC, works.title COLLATE NOCASE ASC"
        }
    }

    /// Resolves a saved filter against the current library using the same
    /// deterministic predicate for presets and smart lists.
    public func library(matching filter: SavedFilter) async throws -> [Work] {
        let works = try await library(sort: filter.sort)
        let normalizedQuery = filter.query.mangoReaderSearchNormalized
        let queryTokens = normalizedQuery.split(separator: " ").map(String.init)

        let memberships: [WorkID: Set<UUID>]
        if filter.categoryIDs.isEmpty {
            memberships = [:]
        } else {
            memberships = try await pool.read { db in
                let records = try CategoryMembershipRecord.fetchAll(db)
                var result: [WorkID: Set<UUID>] = [:]
                for record in records {
                    guard
                        let workUUID = UUID(uuidString: record.workID),
                        let categoryUUID = UUID(uuidString: record.categoryID)
                    else { continue }
                    result[WorkID(rawValue: workUUID), default: []].insert(categoryUUID)
                }
                return result
            }
        }

        return works.filter { work in
            if !filter.kinds.isEmpty, !filter.kinds.contains(work.kind) { return false }
            if !filter.categoryIDs.isEmpty,
               !filter.categoryIDs.isSubset(of: memberships[work.id, default: []]) {
                return false
            }
            guard !queryTokens.isEmpty else { return true }
            let searchableText = ([work.title, work.summary]
                + work.alternativeTitles
                + work.authors
                + work.tags)
                .joined(separator: " ")
                .mangoReaderSearchNormalized
            return queryTokens.allSatisfy(searchableText.contains)
        }
    }

    public func work(id: WorkID) async throws -> Work? {
        try await pool.read { db in
            try WorkRecord
                .fetchOne(db, key: id.rawValue.uuidString)?
                .domainValue()
        }
    }

    public func libraryEntry(for workID: WorkID) throws -> LibraryEntry? {
        try pool.read { db in
            try LibraryEntryRecord
                .filter(Column("workID") == workID.rawValue.uuidString)
                .fetchOne(db)?
                .domainValue()
        }
    }

    public func libraryEntries() throws -> [WorkID: LibraryEntry] {
        try pool.read { db in
            let entries = try LibraryEntryRecord.fetchAll(db).map { try $0.domainValue() }
            return Dictionary(uniqueKeysWithValues: entries.map { ($0.workID, $0) })
        }
    }

    /// Recomputes the two library badges from their durable sources of truth.
    /// An installment is unread until its highest-ever progression reaches 1,
    /// and it is offline when its acquisition URL is a managed local file URL.
    @discardableResult
    public func refreshLibraryCounts(for workID: WorkID) throws -> LibraryEntry? {
        try pool.write { db in
            let identifier = workID.rawValue.uuidString
            try db.execute(
                sql: """
                    UPDATE libraryEntries
                    SET unreadCount = (
                            SELECT COUNT(*)
                            FROM installments AS installment
                            LEFT JOIN readingProgress AS progress
                                ON progress.workID = installment.workID
                                AND progress.installmentID = installment.id
                            WHERE installment.workID = ?
                                AND COALESCE(progress.highestProgression, 0) < 1
                        ),
                        downloadedCount = (
                            SELECT COUNT(*)
                            FROM installments AS installment
                            WHERE installment.workID = ?
                                AND installment.acquisitionURL LIKE 'file:%'
                        )
                    WHERE workID = ?
                    """,
                arguments: [identifier, identifier, identifier]
            )
            return try LibraryEntryRecord
                .filter(Column("workID") == identifier)
                .fetchOne(db)?
                .domainValue()
        }
    }

    public func pinnedWorkIDs() throws -> Set<WorkID> {
        try pool.read { db in
            let ids = try String.fetchAll(
                db,
                sql: "SELECT workID FROM libraryEntries WHERE isPinned = 1"
            )
            return Set(ids.compactMap(UUID.init(uuidString:)).map(WorkID.init(rawValue:)))
        }
    }

    public func setPinned(_ isPinned: Bool, for workIDs: Set<WorkID>) throws {
        guard !workIDs.isEmpty else { return }
        let modifiedAt = Date.now.timeIntervalSince1970
        try pool.write { db in
            for workID in workIDs {
                try db.execute(
                    sql: "UPDATE libraryEntries SET isPinned = ? WHERE workID = ?",
                    arguments: [isPinned, workID.rawValue.uuidString]
                )
                try db.execute(
                    sql: "UPDATE works SET modifiedAt = ? WHERE id = ?",
                    arguments: [modifiedAt, workID.rawValue.uuidString]
                )
            }
        }
    }

    public func save(work: Work, entry: LibraryEntry) async throws {
        guard work.id == entry.workID else {
            throw MangoReaderDataError.inconsistentIdentifiers
        }
        let workRecord = try WorkRecord(work)
        let proposedEntryRecord = LibraryEntryRecord(entry)

        try await pool.write { db in
            var entryRecord = proposedEntryRecord
            try workRecord.save(db)
            if let existing = try LibraryEntryRecord
                .filter(Column("workID") == entryRecord.workID)
                .fetchOne(db)
            {
                entryRecord.id = existing.id
            }
            try entryRecord.save(db)
        }
    }

    /// Atomically replaces the persisted metadata for a library work and
    /// upserts the supplied installments. Existing installments omitted from
    /// the call are intentionally retained, which keeps source updates and
    /// migrations non-destructive.
    public func save(
        work: Work,
        entry: LibraryEntry,
        installments: [Installment]
    ) async throws {
        guard work.id == entry.workID,
              installments.allSatisfy({ $0.workID == work.id })
        else {
            throw MangoReaderDataError.inconsistentIdentifiers
        }

        let workRecord = try WorkRecord(work)
        let proposedEntryRecord = LibraryEntryRecord(entry)
        let installmentRecords = installments.map(InstallmentRecord.init)

        try await pool.write { db in
            var entryRecord = proposedEntryRecord
            try workRecord.save(db)
            if let existing = try LibraryEntryRecord
                .filter(Column("workID") == entryRecord.workID)
                .fetchOne(db)
            {
                entryRecord.id = existing.id
            }
            try entryRecord.save(db)
            for record in installmentRecords {
                try Self.saveChapter(try record.domainValue(), in: db)
            }
        }
    }

    /// Atomically caches the parent metadata required by reader state without
    /// creating Library membership. If the title was promoted concurrently,
    /// the existing library work remains authoritative while useful installment
    /// metadata is merged without replacing device-local acquisition URLs.
    public func saveReadingContent(
        work: Work,
        installments: [Installment]
    ) async throws {
        guard installments.allSatisfy({ $0.workID == work.id }) else {
            throw MangoReaderDataError.inconsistentIdentifiers
        }

        let proposedWorkRecord = try WorkRecord(work)
        let proposedInstallmentRecords = installments.map(InstallmentRecord.init)
        try await pool.write { db in
            let identifier = work.id.rawValue.uuidString
            let isInLibrary = try LibraryEntryRecord
                .filter(Column("workID") == identifier)
                .fetchCount(db) > 0
            if !isInLibrary {
                var cachedWork = work
                if let existing = try WorkRecord.fetchOne(db, key: identifier)?.domainValue() {
                    cachedWork.customCoverPath = existing.customCoverPath
                    if existing.coverURL?.isFileURL == true {
                        cachedWork.coverURL = existing.coverURL
                    }
                    if existing.modifiedAt > cachedWork.modifiedAt {
                        cachedWork = existing
                    }
                }
                try WorkRecord(cachedWork).save(db)
            } else if try WorkRecord.fetchOne(db, key: identifier) == nil {
                try proposedWorkRecord.save(db)
            }

            for record in proposedInstallmentRecords {
                var incoming = try Self.normalizedChapter(record.domainValue(), in: db)
                if let existing = try InstallmentRecord.fetchOne(db, key: incoming.id.description)?.domainValue(),
                   existing.workID == incoming.workID, existing.acquisitionURL != nil
                {
                    incoming.acquisitionURL = existing.acquisitionURL
                }
                try Self.saveChapter(incoming, in: db)
            }
        }
    }

    /// Atomically promotes cached reader content to Library membership while
    /// preserving this device's custom cover and downloaded acquisition URLs.
    public func promoteReadingContentToLibrary(
        work: Work,
        entry: LibraryEntry,
        installments: [Installment]
    ) async throws {
        guard work.id == entry.workID,
              installments.allSatisfy({ $0.workID == work.id })
        else {
            throw MangoReaderDataError.inconsistentIdentifiers
        }

        let proposedEntryRecord = LibraryEntryRecord(entry)
        try await pool.write { db in
            let identifier = work.id.rawValue.uuidString
            var promotedWork = work
            if let existing = try WorkRecord.fetchOne(db, key: identifier)?.domainValue() {
                if existing.customCoverPath != nil {
                    promotedWork.customCoverPath = existing.customCoverPath
                }
                if existing.coverURL?.isFileURL == true {
                    promotedWork.coverURL = existing.coverURL
                }
            }
            try WorkRecord(promotedWork).save(db)

            var entryRecord = proposedEntryRecord
            if let existing = try LibraryEntryRecord
                .filter(Column("workID") == identifier)
                .fetchOne(db)
            {
                entryRecord.id = existing.id
            }
            try entryRecord.save(db)

            for installment in installments {
                var promoted = try Self.normalizedChapter(installment, in: db)
                if let existing = try InstallmentRecord.fetchOne(
                    db,
                    key: promoted.id.rawValue.uuidString
                )?.domainValue(), existing.acquisitionURL != nil
                {
                    promoted.acquisitionURL = existing.acquisitionURL
                }
                try Self.saveChapter(promoted, in: db)
            }
        }
    }

    /// Removes Library membership from remote works while retaining the cached
    /// work graph used by History, reader state, downloads, and later promotion.
    /// Local imports use the explicit deletion path because their managed
    /// originals are owned by the Library.
    @discardableResult
    public func demoteLibraryWorksToReadingContent(
        workIDs: Set<WorkID>
    ) async throws -> Set<WorkID> {
        guard !workIDs.isEmpty else { return [] }

        return try await pool.write { db in
            var demoted: Set<WorkID> = []
            for workID in workIDs {
                let identifier = workID.rawValue.uuidString
                guard
                    let work = try WorkRecord.fetchOne(db, key: identifier)?.domainValue(),
                    work.sourceID != .local
                else { continue }

                let deletedCount = try LibraryEntryRecord
                    .filter(Column("workID") == identifier)
                    .deleteAll(db)
                if deletedCount > 0 {
                    demoted.insert(workID)
                }
            }
            return demoted
        }
    }

    /// Returns non-Library content used as the parent of synchronized reader
    /// state. Library works use their richer `LibraryWork` record instead.
    public func readingContentBundle(
        workID: WorkID
    ) async throws -> (work: Work, installments: [Installment])? {
        try await pool.read { db in
            let identifier = workID.rawValue.uuidString
            guard
                try LibraryEntryRecord
                    .filter(Column("workID") == identifier)
                    .fetchCount(db) == 0,
                let workRecord = try WorkRecord.fetchOne(db, key: identifier)
            else { return nil }

            let installmentRecords = try InstallmentRecord
                .filter(Column("workID") == identifier)
                .fetchAll(db)
            return (
                try workRecord.domainValue(),
                try installmentRecords.map { try $0.domainValue() }
            )
        }
    }

    /// Applies history-only metadata without changing membership or replacing
    /// cover/file state that is meaningful only on this device.
    public func mergeSyncedReadingContent(
        work: Work,
        installments: [Installment]
    ) async throws {
        try await saveReadingContent(work: work, installments: installments)
    }

    /// Returns the local library state needed to construct a CloudKit record.
    /// Installment acquisition URLs are intentionally stripped by the sync layer,
    /// because local files, authenticated links, and offline downloads are device-local.
    public func libraryBundle(
        workID: WorkID
    ) async throws -> (work: Work, entry: LibraryEntry, installments: [Installment])? {
        try await pool.read { db in
            guard
                let workRecord = try WorkRecord.fetchOne(db, key: workID.rawValue.uuidString),
                let entryRecord = try LibraryEntryRecord
                    .filter(Column("workID") == workID.rawValue.uuidString)
                    .fetchOne(db)
            else { return nil }

            let installmentRecords = try InstallmentRecord
                .filter(Column("workID") == workID.rawValue.uuidString)
                .fetchAll(db)
            return (
                try workRecord.domainValue(),
                try entryRecord.domainValue(),
                try installmentRecords.map { try $0.domainValue() }
            )
        }
    }

    /// Applies remotely sourced installment metadata while preserving a usable
    /// device-local acquisition URL when the cloud payload omits it.
    public func mergeSyncedInstallments(_ installments: [Installment]) async throws {
        try await pool.write { db in
            for installment in installments {
                var merged = try Self.normalizedChapter(installment, in: db)
                if merged.acquisitionURL == nil,
                   let existing = try InstallmentRecord.fetchOne(
                       db,
                       key: merged.id.rawValue.uuidString
                   )?.domainValue()
                {
                    merged.acquisitionURL = existing.acquisitionURL
                }
                try Self.saveChapter(merged, in: db)
            }
        }
    }

    public func remove(workID: WorkID, deviceID: String) async throws {
        try await remove(workIDs: [workID], deviceID: deviceID)
    }

    public func remove(workIDs: Set<WorkID>, deviceID: String) async throws {
        guard !workIDs.isEmpty else { return }
        let entityIDs = workIDs.map { $0.rawValue.uuidString }

        try await pool.write { db in
            for entityID in entityIDs {
                var tombstoneRecord = TombstoneRecord(
                    Tombstone(entityType: "work", entityID: entityID, deviceID: deviceID)
                )
                if let existing = try TombstoneRecord
                    .filter(Column("entityType") == tombstoneRecord.entityType)
                    .filter(Column("entityID") == tombstoneRecord.entityID)
                    .fetchOne(db)
                {
                    tombstoneRecord.id = existing.id
                }
                try tombstoneRecord.save(db)
                _ = try WorkRecord.deleteOne(db, key: entityID)
            }
        }
    }

    public func search(_ query: String, limit: Int) async throws -> [Work] {
        let normalized = query.mangoReaderSearchNormalized
        guard
            !normalized.isEmpty,
            let pattern = FTS5Pattern(matchingAllPrefixesIn: normalized)
        else {
            return []
        }
        let boundedLimit = min(max(limit, 1), 500)

        return try await pool.read { db in
            let records = try WorkRecord.fetchAll(db, sql: """
                SELECT works.*
                FROM worksFTS
                JOIN works ON works.rowid = worksFTS.rowid
                JOIN libraryEntries ON libraryEntries.workID = works.id
                WHERE libraryEntries.isHidden = 0
                    AND worksFTS MATCH ?
                ORDER BY bm25(worksFTS, 10.0, 6.0, 4.0, 1.0, 2.0), works.title COLLATE NOCASE
                LIMIT ?
                """, arguments: [pattern, boundedLimit])
            return try records.map { try $0.domainValue() }
        }
    }

    public func works(ids: Set<WorkID>) async throws -> [Work] {
        guard !ids.isEmpty else { return [] }
        let rawIDs = ids.map { $0.rawValue.uuidString }
        return try await pool.read { db in
            let records = try WorkRecord
                .filter(rawIDs.contains(Column("id")))
                .fetchAll(db)
            return try records.map { try $0.domainValue() }
        }
    }

    public func installments(ids: Set<InstallmentID>) async throws -> [Installment] {
        guard !ids.isEmpty else { return [] }
        let rawIDs = ids.map { $0.rawValue.uuidString }
        return try await pool.read { db in
            let records = try InstallmentRecord
                .filter(rawIDs.contains(Column("id")))
                .fetchAll(db)
            return try records.map { try $0.domainValue() }
        }
    }

    // MARK: - Installments and library metadata

    public func save(installments: [Installment]) throws {
        let records = installments.map(InstallmentRecord.init)
        try pool.write { db in
            for record in records {
                try Self.saveChapter(try record.domainValue(), in: db)
            }
        }
    }

    public func installments(for workID: WorkID) throws -> [Installment] {
        try pool.read { db in
            let records = try InstallmentRecord
                .filter(Column("workID") == workID.rawValue.uuidString)
                .order(
                    Column("volume").ascNullsLast,
                    Column("number").ascNullsLast,
                    Column("publishedAt").ascNullsLast,
                    Column("title").collating(.localizedCaseInsensitiveCompare).asc
                )
                .fetchAll(db)
            return try records.map { try $0.domainValue() }
        }
    }

    // MARK: - Download metadata

    public func save(download: DownloadJob) throws {
        try pool.write { db in
            var normalized = download
            normalized.installmentID = try Self.normalizedChapterID(download.installmentID, workID: download.workID, in: db)
            var record = DownloadJobRecord(normalized)
            if let existing = try DownloadJobRecord
                .filter(Column("installmentID") == record.installmentID)
                .fetchOne(db)
            {
                record.id = existing.id
            }
            try record.save(db)
        }
    }

    public func downloads(states: Set<DownloadState> = []) throws -> [DownloadJob] {
        try pool.read { db in
            var request = DownloadJobRecord.all()
            if !states.isEmpty {
                request = request.filter(states.map(\.rawValue).contains(Column("state")))
            }
            let records = try request
                .order(Column("priority").desc, Column("createdAt"))
                .fetchAll(db)
            return try records.map { try $0.domainValue() }
        }
    }
}
