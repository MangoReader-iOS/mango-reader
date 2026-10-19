import Foundation
import GRDB
import MankoDomain

extension MankoDatabase {
    public func progress(installmentID: InstallmentID) async throws -> ReadingProgress? {
        try await pool.read { db in
            try ReadingProgressRecord
                .filter(Column("installmentID") == installmentID.rawValue.uuidString)
                .fetchOne(db)?.domainValue()
        }
    }

    /// Retain resets so stale sync cannot restore completed progress.
    public func resetProgress(
        workID: WorkID,
        installments: [Installment],
        modifiedAt: Date = .now,
        deviceID: String
    ) async throws -> Set<InstallmentID> {
        try await pool.write { db in
            var resetIDs: Set<InstallmentID> = []
            for installment in installments {
                guard installment.workID == workID else { throw MankoDataError.inconsistentIdentifiers }
                let chapterID = try Self.normalizedChapterID(installment.id, workID: workID, in: db)
                let existing = try ReadingProgressRecord
                    .filter(Column("workID") == workID.rawValue.uuidString)
                    .filter(Column("installmentID") == chapterID.rawValue.uuidString)
                    .fetchOne(db)?.domainValue()
                let reset = ReadingProgress(
                    id: existing?.id ?? UUID(), workID: workID, installmentID: chapterID,
                    locator: .image(page: 0, total: installment.pageCount, offset: 0),
                    currentProgression: 0, highestProgression: 0,
                    modifiedAt: modifiedAt, deviceID: deviceID, resetAt: modifiedAt
                )
                try ReadingProgressRecord(existing.map { $0.merging(reset) } ?? reset).save(db)
                resetIDs.insert(chapterID)
            }
            return resetIDs
        }
    }

    public func progress(workID: WorkID) async throws -> ReadingProgress? {
        try await pool.read { db in
            try ReadingProgressRecord
                .filter(Column("workID") == workID.rawValue.uuidString)
                .order(Column("modifiedAt").desc)
                .fetchOne(db)?
                .domainValue()
        }
    }

    public func progress(workID: WorkID, installmentID: InstallmentID) throws -> ReadingProgress? {
        try pool.read { db in
            try ReadingProgressRecord
                .filter(Column("workID") == workID.rawValue.uuidString)
                .filter(Column("installmentID") == installmentID.rawValue.uuidString)
                .fetchOne(db)?
                .domainValue()
        }
    }

    public func progresses(for workID: WorkID) throws -> [ReadingProgress] {
        try pool.read { db in
            try ReadingProgressRecord
                .filter(Column("workID") == workID.rawValue.uuidString)
                .fetchAll(db)
                .map { try $0.domainValue() }
        }
    }

    public func progresses() throws -> [ReadingProgress] {
        try pool.read { db in
            try ReadingProgressRecord
                .fetchAll(db)
                .map { try $0.domainValue() }
        }
    }

    public func progresses(installmentIDs: Set<InstallmentID>) async throws -> [ReadingProgress] {
        guard !installmentIDs.isEmpty else { return [] }
        let identifiers = installmentIDs.map { $0.rawValue.uuidString }
        return try await pool.read { db in
            try ReadingProgressRecord
                .filter(identifiers.contains(Column("installmentID")))
                .fetchAll(db)
                .map { try $0.domainValue() }
        }
    }

    public func deleteProgress(
        workID: WorkID,
        installmentIDs: Set<InstallmentID>
    ) throws {
        guard !installmentIDs.isEmpty else { return }
        let identifiers = installmentIDs.map { $0.rawValue.uuidString }
        try pool.write { db in
            _ = try ReadingProgressRecord
                .filter(Column("workID") == workID.rawValue.uuidString)
                .filter(identifiers.contains(Column("installmentID")))
                .deleteAll(db)
        }
    }

    public func save(progress: ReadingProgress) async throws {
        var adjustedProgress = progress
        adjustedProgress.highestProgression = max(
            adjustedProgress.currentProgression,
            adjustedProgress.highestProgression
        )
        let proposed = adjustedProgress

        try await pool.write { db in
            var incoming = proposed
            incoming.installmentID = try Self.normalizedChapterID(incoming.installmentID, workID: incoming.workID, in: db)
            if let existingRecord = try ReadingProgressRecord
                .filter(Column("workID") == incoming.workID.rawValue.uuidString)
                .filter(Column("installmentID") == incoming.installmentID.rawValue.uuidString)
                .fetchOne(db)
            {
                let existing = try existingRecord.domainValue()
                var merged = existing.merging(incoming)
                merged.id = existing.id
                merged.highestProgression = max(
                    merged.currentProgression,
                    merged.highestProgression
                )
                try ReadingProgressRecord(merged).save(db)
            } else {
                try ReadingProgressRecord(incoming).insert(db)
            }
        }
    }

    public func sessions(limit: Int) async throws -> [ReadingSession] {
        guard limit > 0 else { return [] }
        let boundedLimit = min(limit, 10_000)
        return try await pool.read { db in
            let records = try ReadingSessionRecord
                .order(Column("startedAt").desc)
                .limit(boundedLimit)
                .fetchAll(db)
            return try records.map { try $0.domainValue() }
        }
    }

    /// Returns every session whose start date is inside the half-open interval.
    /// A nil interval intentionally means all time and is not subject to the
    /// bounded History limit.
    public func sessions(in interval: DateInterval?) async throws -> [ReadingSession] {
        try await pool.read { db in
            var request = ReadingSessionRecord.order(Column("startedAt").desc)
            if let interval {
                request = request
                    .filter(Column("startedAt") >= interval.start.timeIntervalSince1970)
                    .filter(Column("startedAt") < interval.end.timeIntervalSince1970)
            }
            return try request.fetchAll(db).map { try $0.domainValue() }
        }
    }

    public func sessions(for workID: WorkID) async throws -> [ReadingSession] {
        try await pool.read { db in
            try ReadingSessionRecord
                .filter(Column("workID") == workID.rawValue.uuidString)
                .order(Column("startedAt").desc)
                .fetchAll(db)
                .map { try $0.domainValue() }
        }
    }

    @discardableResult
    public func deleteReadingSessions() async throws -> [UUID] {
        try await pool.write { db in
            let identifiers = try String.fetchAll(
                db,
                sql: "SELECT id FROM readingSessions ORDER BY id"
            ).compactMap(UUID.init(uuidString:))
            _ = try ReadingSessionRecord.deleteAll(db)
            return identifiers
        }
    }

    // MARK: - Reader state

    /// Persists an in-progress reader session and advances the owning Library
    /// entry's recent-reading timestamp in one transaction. Reading content
    /// without Library membership intentionally remains history-only.
    @discardableResult
    public func beginReadingSession(
        _ session: ReadingSession,
        openedAt: Date
    ) throws -> LibraryEntry? {
        try pool.write { db in
            let sessionRecord = ReadingSessionRecord(session)
            let existingSession = try ReadingSessionRecord
                .fetchOne(db, key: sessionRecord.id)?
                .domainValue()

            // A delayed start task must never replace a session that dismissal
            // has already finalized.
            if existingSession?.endedAt == nil {
                try sessionRecord.save(db)
            }

            let workID = session.workID.rawValue.uuidString
            let timestamp = openedAt.timeIntervalSince1970
            try db.execute(
                sql: """
                    UPDATE libraryEntries
                    SET lastOpenedAt = CASE
                        WHEN lastOpenedAt IS NULL OR lastOpenedAt < ? THEN ?
                        ELSE lastOpenedAt
                    END
                    WHERE workID = ?
                    """,
                arguments: [timestamp, timestamp, workID]
            )
            return try LibraryEntryRecord
                .filter(Column("workID") == workID)
                .fetchOne(db)?
                .domainValue()
        }
    }

    public func save(session: ReadingSession) throws {
        try pool.write { db in
            var incoming = session
            incoming.installmentID = try Self.normalizedChapterID(incoming.installmentID, workID: incoming.workID, in: db)
            if incoming.readingUnitCount == nil {
                incoming.readingUnitCount = try ReadingSessionRecord.fetchOne(db, key: incoming.id.uuidString)?.readingUnitCount
            }
            try ReadingSessionRecord(incoming).save(db)
        }
    }

    public func session(id: UUID) throws -> ReadingSession? {
        try pool.read { db in
            try ReadingSessionRecord.fetchOne(db, key: id.uuidString)?.domainValue()
        }
    }

    public struct UserTitleStateSaveResult: Sendable, Equatable {
        public var didSave: Bool
        public var supersededTombstoneID: UUID?

        public init(didSave: Bool, supersededTombstoneID: UUID? = nil) {
            self.didSave = didSave
            self.supersededTombstoneID = supersededTombstoneID
        }
    }

    @discardableResult
    public func save(titleState: UserTitleState) throws -> UserTitleStateSaveResult {
        guard !titleState.isEmpty,
              titleState.startDate?.isValid != false,
              titleState.finishDate?.isValid != false,
              TrackerDate.areOrdered(start: titleState.startDate, finish: titleState.finishDate),
              !titleState.deviceID.isEmpty,
              titleState.deviceID.count <= 128
        else {
            throw MankoDataError.invalidRecord(
                table: UserTitleStateRecord.databaseTableName,
                id: titleState.workID.rawValue.uuidString
            )
        }
        return try pool.write { db in
            var supersededTombstoneID: UUID?
            if let tombstone = try TombstoneRecord
                .filter(Column("entityType") == "titleState")
                .filter(Column("entityID") == titleState.workID.rawValue.uuidString)
                .fetchOne(db)
            {
                guard tombstone.deletedAt < titleState.modifiedAt.timeIntervalSince1970 else {
                    return UserTitleStateSaveResult(didSave: false)
                }
                supersededTombstoneID = UUID(uuidString: tombstone.id)
                _ = try TombstoneRecord.deleteOne(db, key: tombstone.id)
            }
            try UserTitleStateRecord(titleState).save(db)
            return UserTitleStateSaveResult(
                didSave: true,
                supersededTombstoneID: supersededTombstoneID
            )
        }
    }

    public func titleState(for workID: WorkID) throws -> UserTitleState? {
        try pool.read { db in
            try UserTitleStateRecord
                .fetchOne(db, key: workID.rawValue.uuidString)?
                .domainValue()
        }
    }

    public func titleStates(workIDs: Set<WorkID>) throws -> [UserTitleState] {
        guard !workIDs.isEmpty else { return [] }
        let identifiers = workIDs.map { $0.rawValue.uuidString }
        return try pool.read { db in
            try UserTitleStateRecord
                .filter(identifiers.contains(Column("workID")))
                .fetchAll(db)
                .map { try $0.domainValue() }
        }
    }

    @discardableResult
    public func deleteTitleState(workID: WorkID, deviceID: String) async throws -> Tombstone {
        let identifier = workID.rawValue.uuidString
        return try await pool.write { db in
            var tombstone = Tombstone(
                entityType: "titleState",
                entityID: identifier,
                deviceID: deviceID
            )
            var record = TombstoneRecord(tombstone)
            if let existing = try TombstoneRecord
                .filter(Column("entityType") == "titleState")
                .filter(Column("entityID") == identifier)
                .fetchOne(db)
            {
                tombstone.id = UUID(uuidString: existing.id) ?? tombstone.id
                record.id = existing.id
            }
            _ = try UserTitleStateRecord.deleteOne(db, key: identifier)
            try record.save(db)
            // Return the same timestamp representation callers will observe
            // when the tombstone is read back from SQLite.
            return try record.domainValue()
        }
    }

    // Tracker links are device-local operational state. They are deliberately
    // absent from CloudKit inventory and logical backup payloads.
    public func save(trackerLink: TrackerLink) throws {
        let record = try TrackerLinkRecord(trackerLink)
        try pool.write { db in try record.save(db) }
    }

    public func trackerLinks(for workID: WorkID) throws -> [TrackerLink] {
        try pool.read { db in
            try TrackerLinkRecord
                .filter(Column("workID") == workID.rawValue.uuidString)
                .fetchAll(db)
                .map { try $0.domainValue() }
        }
    }

    public func trackerLinks(trackerID: TrackerID? = nil) throws -> [TrackerLink] {
        try pool.read { db in
            var request = TrackerLinkRecord.all()
            if let trackerID {
                request = request.filter(Column("trackerID") == trackerID.rawValue)
            }
            return try request.fetchAll(db).map { try $0.domainValue() }
        }
    }

    public func deleteTrackerLink(workID: WorkID, trackerID: TrackerID) throws {
        try pool.write { db in
            _ = try TrackerLinkRecord
                .filter(Column("workID") == workID.rawValue.uuidString)
                .filter(Column("trackerID") == trackerID.rawValue)
                .deleteAll(db)
        }
    }

    public func deleteTrackerLinks(trackerID: TrackerID) throws {
        try pool.write { db in
            _ = try TrackerLinkRecord
                .filter(Column("trackerID") == trackerID.rawValue)
                .deleteAll(db)
        }
    }

    public func save(bookmark: Bookmark) throws {
        try pool.write { db in
            var incoming = bookmark
            incoming.installmentID = try Self.normalizedChapterID(incoming.installmentID, workID: incoming.workID, in: db)
            try BookmarkRecord(incoming).save(db)
        }
    }

    public func bookmark(id: UUID) throws -> Bookmark? {
        try pool.read { db in
            try BookmarkRecord.fetchOne(db, key: id.uuidString)?.domainValue()
        }
    }

    public func bookmarks(for installmentID: InstallmentID) throws -> [Bookmark] {
        try pool.read { db in
            let records = try BookmarkRecord
                .filter(Column("installmentID") == installmentID.rawValue.uuidString)
                .order(Column("modifiedAt").desc)
                .fetchAll(db)
            return try records.map { try $0.domainValue() }
        }
    }

    /// Deletes a bookmark and records its logical deletion in the same SQLite
    /// transaction. The stable tombstone prevents an older CloudKit record
    /// from resurrecting the bookmark on another device.
    @discardableResult
    public func deleteBookmark(id: UUID, deviceID: String) async throws -> Tombstone {
        try await deleteReaderRecord(
            id: id,
            entityType: "bookmark",
            deviceID: deviceID,
            delete: { db, identifier in
                _ = try BookmarkRecord.deleteOne(db, key: identifier)
            }
        )
    }

    public func save(annotation: Annotation) throws {
        try pool.write { db in
            var incoming = annotation
            incoming.installmentID = try Self.normalizedChapterID(incoming.installmentID, workID: incoming.workID, in: db)
            try AnnotationRecord(incoming).save(db)
        }
    }

    public func annotation(id: UUID) throws -> Annotation? {
        try pool.read { db in
            try AnnotationRecord.fetchOne(db, key: id.uuidString)?.domainValue()
        }
    }

    public func annotations(for installmentID: InstallmentID) throws -> [Annotation] {
        try pool.read { db in
            let records = try AnnotationRecord
                .filter(Column("installmentID") == installmentID.rawValue.uuidString)
                .order(Column("modifiedAt").desc)
                .fetchAll(db)
            return try records.map { try $0.domainValue() }
        }
    }

    /// Deletes an annotation and records its logical deletion atomically so
    /// sync retries can never expose a half-applied local mutation.
    @discardableResult
    public func deleteAnnotation(id: UUID, deviceID: String) async throws -> Tombstone {
        try await deleteReaderRecord(
            id: id,
            entityType: "annotation",
            deviceID: deviceID,
            delete: { db, identifier in
                _ = try AnnotationRecord.deleteOne(db, key: identifier)
            }
        )
    }

    private func deleteReaderRecord(
        id: UUID,
        entityType: String,
        deviceID: String,
        delete: @escaping @Sendable (Database, String) throws -> Void
    ) async throws -> Tombstone {
        try await pool.write { db in
            var tombstone = Tombstone(
                entityType: entityType,
                entityID: id.uuidString,
                deviceID: deviceID
            )
            var record = TombstoneRecord(tombstone)
            if let existing = try TombstoneRecord
                .filter(Column("entityType") == entityType)
                .filter(Column("entityID") == id.uuidString)
                .fetchOne(db)
            {
                tombstone.id = UUID(uuidString: existing.id) ?? tombstone.id
                record.id = existing.id
            }

            try delete(db, id.uuidString)
            try record.save(db)
            return tombstone
        }
    }
}


public enum TrackerImportError: Error, LocalizedError {
    case changed
    public var errorDescription: String? { "Progress changed since this review. Review the latest values before applying." }
}

extension MankoDatabase {
    /// One transaction validates and applies the reviewed snapshot. No reader locator is fabricated over an existing one.
    public func applyTrackerImport(_ preview: TrackerImportPreview, deviceID: String,
                                   now: Date = .now) async throws -> Set<InstallmentID> {
        try await pool.write { db in
            guard let record = try TrackerLinkRecord
                .filter(Column("workID") == preview.link.workID.description)
                .filter(Column("trackerID") == preview.link.trackerID.rawValue).fetchOne(db),
                  try record.domainValue() == preview.link,
                  preview.link.lastRemote.map(TrackerSyncSnapshot.init) == preview.remote else { throw TrackerImportError.changed }
            let chapters = try InstallmentRecord.filter(Column("workID") == preview.link.workID.description)
                .fetchAll(db).map { try $0.domainValue() }
            let progresses = try ReadingProgressRecord.filter(Column("workID") == preview.link.workID.description)
                .fetchAll(db).map { try $0.domainValue() }
            guard ReaderChapterPolicy.ordered(chapters) == ReaderChapterPolicy.ordered(preview.chapters),
                  Set(progresses) == Set(preview.progresses),
                  Set(try ReadingSessionRecord.filter(Column("workID") == preview.link.workID.description)
                    .fetchAll(db).map { try $0.domainValue() }) == Set(preview.sessions) else { throw TrackerImportError.changed }
            let mapped: [Installment]
            if let chapter = preview.remote.chapter,
               let matches = TrackerChapterMapping.importChapters(boundary: chapter, chapters: chapters) {
                mapped = matches
            } else if preview.remote.chapter == nil, let volume = preview.remote.volume,
                      volume.isFinite, volume >= 0, TrackerChapterMapping.issue(in: chapters) == nil,
                      chapters.allSatisfy({ $0.volume.map { $0.isFinite && $0 >= 0 } == true }) {
                mapped = chapters.filter { $0.volume! <= volume }
            } else { throw TrackerImportError.changed }
            let completeIDs = Set(progresses.filter { $0.highestProgression >= 1 }.map(\.installmentID))
            guard Set(mapped.map(\.id)).subtracting(completeIDs) == preview.affectedIDs else { throw TrackerImportError.changed }
            var changed: Set<InstallmentID> = []
            for chapter in chapters where preview.affectedIDs.contains(chapter.id) {
                let existing = progresses.first { $0.installmentID == chapter.id }
                guard (existing?.highestProgression ?? 0) < 1 else { continue }
                var progress = existing ?? ReadingProgress(workID: chapter.workID, installmentID: chapter.id,
                    locator: .image(page: 0, total: chapter.pageCount, offset: 0),
                    currentProgression: 0, highestProgression: 0, deviceID: deviceID)
                progress.highestProgression = 1
                progress.modifiedAt = now
                progress.deviceID = deviceID
                try ReadingProgressRecord(progress).save(db)
                changed.insert(chapter.id)
            }
            var link = preview.link
            for field: TrackerSyncField in [.chapter, .volume] {
                link.lastSynced.copy(field, from: preview.remote)
            }
            link.conflicts.removeAll { $0.field == .chapter || $0.field == .volume }
            try TrackerLinkRecord(link).save(db)
            return changed
        }
    }

    /// Local presentation acknowledgement, independent of progress and CloudKit.
    public func acknowledgedChapters(workID: WorkID, sourceID: SourceID) throws -> Set<InstallmentID>? {
        try pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT sourceID, knownIDs FROM chapterVisits WHERE workID = ?",
                                            arguments: [workID.description]),
                  row["sourceID"] as String == sourceID.rawValue else { return nil }
            let known = try DataCoding.decode(Set<InstallmentID>.self, from: row["knownIDs"])
            return try Set(known.map { id in
                let canonical = try String.fetchOne(db, sql: "SELECT scopedID FROM extensionChapterAliases WHERE workID = ? AND legacyID = ?", arguments: [workID.description, id.description])
                return canonical.flatMap(UUID.init(uuidString:)).map(InstallmentID.init(rawValue:)) ?? id
            })
        }
    }

    public func acknowledgeChapters(workID: WorkID, sourceID: SourceID, ids: Set<InstallmentID>) throws {
        try pool.write { db in
            guard try WorkRecord.fetchOne(db, key: workID.description) != nil else { return }
            var known = try Set(ids.map { id in
                let canonical = try String.fetchOne(db, sql: "SELECT scopedID FROM extensionChapterAliases WHERE workID = ? AND legacyID = ?", arguments: [workID.description, id.description])
                return canonical.flatMap(UUID.init(uuidString:)).map(InstallmentID.init(rawValue:)) ?? id
            })
            if let row = try Row.fetchOne(db, sql: "SELECT sourceID, knownIDs FROM chapterVisits WHERE workID = ?",
                                         arguments: [workID.description]), row["sourceID"] as String == sourceID.rawValue {
                known.formUnion(try DataCoding.decode(Set<InstallmentID>.self, from: row["knownIDs"]))
            }
            try db.execute(sql: "INSERT OR REPLACE INTO chapterVisits(workID, sourceID, knownIDs) VALUES (?, ?, ?)",
                           arguments: [workID.description, sourceID.rawValue, try DataCoding.encode(known)])
        }
    }
}


extension MankoDatabase {
    public func applyTrackerMetadata(_ remote: TrackerSyncSnapshot, fields: Set<TrackerSyncField>,
        expected: TrackerSyncSnapshot, workID: WorkID, deviceID: String, now: Date = .now
    ) async throws -> (state: UserTitleState?, tombstoneID: UUID?, supersededTombstoneID: UUID?) {
        try await pool.write { db in
            let existing = try UserTitleStateRecord.fetchOne(db, key: workID.description)?.domainValue()
            let current = TrackerSyncSnapshot(status: existing?.status, score: existing?.rating.map { Double($0.rawValue) },
                startDate: existing?.startDate, finishDate: existing?.finishDate)
            guard fields.allSatisfy({ current.value(for: $0) == expected.value(for: $0) }) else { throw TrackerImportError.changed }
            var state = existing ?? UserTitleState(workID: workID, deviceID: deviceID)
            if fields.contains(.rating) {
                if let score = remote.score {
                    guard score.isFinite, score.rounded() == score, (1...10).contains(score) else { throw TrackerImportError.changed }
                    state.rating = TenPointRating(rawValue: Int(score))
                } else { state.rating = nil }
            }
            if fields.contains(.status) { state.status = remote.status }
            if fields.contains(.startDate) { state.startDate = remote.startDate }
            if fields.contains(.finishDate) { state.finishDate = remote.finishDate }
            guard state.startDate?.isValid != false, state.finishDate?.isValid != false,
                  TrackerDate.areOrdered(start: state.startDate, finish: state.finishDate) else { throw TrackerImportError.changed }
            state.modifiedAt = now; state.deviceID = deviceID
            let oldTombstone = try TombstoneRecord.filter(Column("entityType") == "titleState")
                .filter(Column("entityID") == workID.description).fetchOne(db)
            if state.isEmpty {
                var tombstone = Tombstone(entityType: "titleState", entityID: workID.description, deletedAt: now, deviceID: deviceID)
                if let id = oldTombstone.flatMap({ UUID(uuidString: $0.id) }) { tombstone.id = id }
                try TombstoneRecord(tombstone).save(db)
                _ = try UserTitleStateRecord.deleteOne(db, key: workID.description)
                return (nil, tombstone.id, nil)
            }
            if let oldTombstone {
                guard oldTombstone.deletedAt < now.timeIntervalSince1970 else { throw TrackerImportError.changed }
                _ = try TombstoneRecord.deleteOne(db, key: oldTombstone.id)
            }
            try UserTitleStateRecord(state).save(db)
            return (state, nil, oldTombstone.flatMap { UUID(uuidString: $0.id) })
        }
    }

    public func completeInstallmentsPreservingPositions(workID: WorkID, installments: [Installment],
        deviceID: String, now: Date = .now) async throws -> Set<InstallmentID> {
        try await pool.write { db in
            var changed: Set<InstallmentID> = []
            for chapter in installments {
                guard chapter.workID == workID else { throw MankoDataError.inconsistentIdentifiers }
                let id = try Self.normalizedChapterID(chapter.id, workID: workID, in: db)
                let record = try ReadingProgressRecord.filter(Column("workID") == workID.description)
                    .filter(Column("installmentID") == id.description).fetchOne(db)
                var progress = try record?.domainValue() ?? ReadingProgress(workID: workID, installmentID: id,
                    locator: .image(page: 0, total: chapter.pageCount, offset: 0), currentProgression: 0,
                    highestProgression: 0, deviceID: deviceID)
                guard progress.highestProgression < 1 else { continue }
                progress.highestProgression = 1; progress.modifiedAt = now; progress.deviceID = deviceID
                try ReadingProgressRecord(progress).save(db)
                changed.insert(id)
            }
            return changed
        }
    }
}
