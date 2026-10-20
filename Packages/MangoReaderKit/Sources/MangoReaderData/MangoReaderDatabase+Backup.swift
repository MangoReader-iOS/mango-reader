import CryptoKit
import Foundation
import GRDB
import MangoReaderDomain

extension MangoReaderDatabase {
    // MARK: - Backup plumbing

    func backupPayload() throws -> DatabaseBackupPayload {
        try pool.read { db in
            try Self.backupPayload(in: db)
        }
    }

    /// Restores selected logical groups through a fully migrated SQLite store
    /// staged beside the live database. The staged store is integrity checked
    /// before the live pool is closed. Only then is the database file replaced
    /// atomically and the actor's pool reopened. Any failure after replacement
    /// restores the previous file before reopening it, so a live GRDB pool is
    /// never pointed at a file that is being replaced.
    ///
    /// This method is deliberately synchronous while isolated to the database
    /// actor. That creates one explicit handoff point: no actor operation can
    /// interleave between taking the current logical snapshot, building the
    /// staged database, closing the pool, swapping files, and reopening.
    @discardableResult
    func restore(
        _ backupPayload: DatabaseBackupPayload,
        selection: BackupRestoreSelection,
        libraryFilesDirectory: URL,
        mode: BackupRestoreMode = .replace
    ) throws -> BackupRestoreReport {
        let currentPayload = try pool.read { db in
            try Self.backupPayload(in: db)
        }
        var report = BackupRestoreReport()
        let mergedPayload = mode == .merge
            ? currentPayload.retainingCurrent(backup: backupPayload, selection: selection,
                libraryFilesDirectory: libraryFilesDirectory, report: &report)
            : currentPayload.merging(
            backup: backupPayload,
            selection: selection,
            libraryFilesDirectory: libraryFilesDirectory
        )

        let stagedURL = databaseURL.deletingLastPathComponent().appending(
            path: ".manko.restore.\(UUID().uuidString).sqlite",
            directoryHint: .notDirectory
        )
        defer { Self.removeSQLiteStore(at: stagedURL) }

        let chapterSources = try pool.read { db in try String.fetchAll(db, sql: "SELECT sourceID FROM extensionChapterSources") }
        try Self.createStagedStore(
            at: stagedURL,
            payload: mergedPayload,
            migrator: migrator,
            chapterSources: chapterSources
        )
        try restoreSwapFailureInjector?(.stagedStoreReady)
        try replaceLiveStore(with: stagedURL)
        return report
    }

    func restoreSnapshot(_ payload: DatabaseBackupPayload) throws {
        let url = databaseURL.deletingLastPathComponent().appendingPathComponent(".manko.restore-rollback.sqlite")
        defer { Self.removeSQLiteStore(at: url) }
        try Self.createStagedStore(at: url, payload: payload, migrator: migrator, chapterSources: payload.chapterIdentity?.sources ?? [])
        try replaceLiveStore(with: url)
    }


    private func replaceLiveStore(with stagedURL: URL) throws {
        let fileManager = FileManager.default
        let parent = databaseURL.deletingLastPathComponent()
        let rollbackName = ".manko.rollback.\(UUID().uuidString).sqlite"
        let rollbackURL = parent.appending(path: rollbackName, directoryHint: .notDirectory)
        let failedRestoreName = ".manko.failed-restore.\(UUID().uuidString).sqlite"
        let failedRestoreURL = parent.appending(
            path: failedRestoreName,
            directoryHint: .notDirectory
        )
        var liveStoreIsOpen = true
        var liveStoreWasReplaced = false
        var preservesRollbackArtifact = false

        defer {
            if !preservesRollbackArtifact {
                Self.removeSQLiteStore(at: rollbackURL)
            }
            Self.removeSQLiteStore(at: failedRestoreURL)
        }

        do {
            // Drain and close read-only connections before truncating the WAL.
            // This waits for any pool access that began during actor reentrancy,
            // rather than failing the checkpoint because a reader still holds
            // a snapshot.
            pool.releaseMemory()
            try pool.writeWithoutTransaction { db in
                let busy = try Int.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)") ?? 1
                guard busy == 0 else {
                    throw MangoReaderDataError.databaseRestoreFailed(
                        "The live database could not finish its WAL checkpoint."
                    )
                }
            }
            try pool.close()
            liveStoreIsOpen = false
            try restoreSwapFailureInjector?(.liveStoreClosed)

            Self.removeSQLiteSidecars(for: databaseURL)
            _ = try fileManager.replaceItemAt(
                databaseURL,
                withItemAt: stagedURL,
                backupItemName: rollbackName,
                options: [.withoutDeletingBackupItem]
            )
            liveStoreWasReplaced = true
            try restoreSwapFailureInjector?(.liveStoreReplaced)

            pool = try Self.openPool(at: databaseURL, migrator: migrator)
            liveStoreIsOpen = true
            try restoreSwapFailureInjector?(.restoredStoreOpened)
        } catch {
            let primaryError = error
            // A completed Foundation replacement always creates the rollback
            // item. Checking it also covers a defensive edge case where the
            // API reports an error after the atomic rename has occurred.
            liveStoreWasReplaced = liveStoreWasReplaced
                || fileManager.fileExists(atPath: rollbackURL.path)

            var recoveryFailures: [String] = []
            if liveStoreIsOpen, liveStoreWasReplaced {
                do {
                    try pool.close()
                    liveStoreIsOpen = false
                } catch {
                    recoveryFailures.append(
                        "the restored database could not be closed: \(error.localizedDescription)"
                    )
                }
            }

            if liveStoreWasReplaced, !liveStoreIsOpen {
                do {
                    Self.removeSQLiteSidecars(for: databaseURL)
                    guard fileManager.fileExists(atPath: rollbackURL.path) else {
                        throw MangoReaderDataError.databaseRestoreFailed(
                            "The rollback database is missing."
                        )
                    }
                    _ = try fileManager.replaceItemAt(
                        databaseURL,
                        withItemAt: rollbackURL,
                        backupItemName: failedRestoreName,
                        options: []
                    )
                    liveStoreWasReplaced = false
                } catch {
                    recoveryFailures.append(
                        "the previous database could not be restored: \(error.localizedDescription)"
                    )
                }
            }

            if !liveStoreIsOpen, !liveStoreWasReplaced {
                do {
                    pool = try Self.openPool(at: databaseURL, migrator: migrator)
                    liveStoreIsOpen = true
                } catch {
                    recoveryFailures.append(
                        "the previous database could not be reopened: \(error.localizedDescription)"
                    )
                }
            }

            let primaryDescription = primaryError.localizedDescription
            guard recoveryFailures.isEmpty else {
                preservesRollbackArtifact = liveStoreWasReplaced
                throw MangoReaderDataError.databaseRestoreFailed(
                    ([primaryDescription] + recoveryFailures).joined(separator: " ")
                )
            }
            if let dataError = primaryError as? MangoReaderDataError,
               case .databaseRestoreFailed = dataError {
                throw dataError
            }
            throw MangoReaderDataError.databaseRestoreFailed(primaryDescription)
        }
    }

    private nonisolated static func createStagedStore(
        at stagedURL: URL,
        payload: DatabaseBackupPayload,
        migrator: DatabaseMigrator,
        chapterSources: [String]
    ) throws {
        removeSQLiteStore(at: stagedURL)
        let queue = try DatabaseQueue(
            path: stagedURL.path,
            configuration: databaseConfiguration()
        )
        do {
            try migrator.migrate(queue)
            try queue.write { db in
                // Import the old relationships before enforcing repaired ownership.
                for table in ["readingProgress", "readingSessions", "bookmarks", "annotations", "downloads"] {
                    for action in ["INSERT", "UPDATE"] { try db.execute(sql: "DROP TRIGGER IF EXISTS \(table)_owner_\(action)") }
                }
                for source in chapterSources { try db.execute(sql: "INSERT OR IGNORE INTO extensionChapterSources VALUES (?)", arguments: [source]) }
                try replaceDatabaseContents(with: payload, in: db)
                _ = try repairExtensionChapters(in: db)
                try DatabaseSchema.createChapterOwnershipGuards(in: db)
            }
            try queue.read { db in
                let integrityMessages = try String.fetchAll(db, sql: "PRAGMA integrity_check")
                guard integrityMessages == ["ok"] else {
                    throw MangoReaderDataError.databaseRestoreFailed(
                        "The staged database failed its integrity check."
                    )
                }
                guard try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
                    throw MangoReaderDataError.databaseRestoreFailed(
                        "The staged database contains invalid relationships."
                    )
                }
            }
            try queue.close()
            removeSQLiteSidecars(for: stagedURL)
            try StoragePaths.applyStandardProtection(to: stagedURL)
        } catch {
            try? queue.close()
            removeSQLiteStore(at: stagedURL)
            throw error
        }
    }

    private nonisolated static func removeSQLiteSidecars(for databaseURL: URL) {
        let fileManager = FileManager.default
        for suffix in ["-wal", "-shm", "-journal"] {
            try? fileManager.removeItem(atPath: databaseURL.path + suffix)
        }
    }

    private nonisolated static func removeSQLiteStore(at databaseURL: URL) {
        try? FileManager.default.removeItem(at: databaseURL)
        removeSQLiteSidecars(for: databaseURL)
    }

    private static func backupPayload(in db: Database) throws -> DatabaseBackupPayload {
        let works = try WorkRecord.fetchAll(db).map { try $0.domainValue() }
        let installments = try InstallmentRecord.fetchAll(db).map { try $0.domainValue() }
        let libraryEntries = try LibraryEntryRecord.fetchAll(db).map { try $0.domainValue() }
        let categories = try CategoryRecord.fetchAll(db).map { try $0.domainValue() }
        let categoryMemberships = try CategoryMembershipRecord.fetchAll(db).map {
            BackupCategoryMembership(categoryID: $0.categoryID, workID: $0.workID)
        }
        let progress = try ReadingProgressRecord.fetchAll(db).map { try $0.domainValue() }
        let sessions = try ReadingSessionRecord.fetchAll(db).map { try $0.domainValue() }
        let bookmarks = try BookmarkRecord.fetchAll(db).map { try $0.domainValue() }
        let annotations = try AnnotationRecord.fetchAll(db).map { try $0.domainValue() }
        let titleStates = try UserTitleStateRecord.fetchAll(db).map { try $0.domainValue() }
        let downloads = try DownloadJobRecord.fetchAll(db).map { try $0.domainValue() }
        let savedFilters = try SavedFilterRecord.fetchAll(db).map { try $0.domainValue() }
        let importedOriginalReferences = try ImportedOriginalReferenceRecord.fetchAll(db)
            .map { try $0.domainValue() }
        let tombstones = try TombstoneRecord.fetchAll(db).map { try $0.domainValue() }
        var payload = DatabaseBackupPayload(
            chapterIdentity: try ChapterIdentityBackup.read(in: db),
            works: works,
            installments: installments,
            libraryEntries: libraryEntries,
            categories: categories,
            categoryMemberships: categoryMemberships,
            progress: progress,
            sessions: sessions,
            bookmarks: bookmarks,
            annotations: annotations,
            titleStates: titleStates,
            downloads: downloads,
            savedFilters: savedFilters,
            importedOriginalReferences: importedOriginalReferences,
            tombstones: tombstones
        )
        payload.localState = BackupLocalState(
            trackers: try TrackerLinkRecord.fetchAll(db),
            settings: try SyncedAppSettingsRecord.fetchAll(db),
            visits: try Row.fetchAll(db, sql: "SELECT * FROM chapterVisits").map {
                .init(workID: $0["workID"], sourceID: $0["sourceID"], knownIDs: $0["knownIDs"])
            },
            deferred: try Row.fetchAll(db, sql: "SELECT * FROM deferredChapterRecords").map {
                .init(name: $0["name"], payload: $0["payload"])
            }
        )
        return payload
    }

    private static func replaceDatabaseContents(
        with payload: DatabaseBackupPayload,
        in db: Database
    ) throws {
        let workRecords = try payload.works.map(WorkRecord.init)
        let installmentRecords = payload.installments.map(InstallmentRecord.init)
        let libraryEntryRecords = payload.libraryEntries.map(LibraryEntryRecord.init)
        let categoryRecords = payload.categories.map(CategoryRecord.init)
        let progressRecords = try payload.progress.map(ReadingProgressRecord.init)
        let sessionRecords = payload.sessions.map(ReadingSessionRecord.init)
        let bookmarkRecords = try payload.bookmarks.map(BookmarkRecord.init)
        let annotationRecords = try payload.annotations.map(AnnotationRecord.init)
        let titleStateRecords = try payload.titleStates.map(UserTitleStateRecord.init)
        let downloadRecords = payload.downloads.map(DownloadJobRecord.init)
        let savedFilterRecords = try payload.savedFilters.map(SavedFilterRecord.init)
        let importedOriginalReferenceRecords = payload.importedOriginalReferences
            .map(ImportedOriginalReferenceRecord.init)
        let tombstoneRecords = payload.tombstones.map(TombstoneRecord.init)

        try db.execute(sql: "DELETE FROM works")
        try db.execute(sql: "DELETE FROM categories")
        try db.execute(sql: "DELETE FROM savedFilters")
        try db.execute(sql: "DELETE FROM tombstones")

        try payload.chapterIdentity?.restore(in: db)
        for record in workRecords { try record.insert(db) }
        for record in installmentRecords { try record.insert(db) }
        for record in libraryEntryRecords { try record.insert(db) }
        for record in categoryRecords { try record.insert(db) }
        for membership in payload.categoryMemberships {
            try CategoryMembershipRecord(
                categoryID: membership.categoryID,
                workID: membership.workID
            ).insert(db)
        }
        for record in progressRecords { try record.insert(db) }
        for record in sessionRecords { try record.insert(db) }
        for record in bookmarkRecords { try record.insert(db) }
        for record in annotationRecords { try record.insert(db) }
        for record in titleStateRecords { try record.insert(db) }
        for record in downloadRecords { try record.insert(db) }
        for record in savedFilterRecords { try record.insert(db) }
        for record in importedOriginalReferenceRecords { try record.insert(db) }
        for record in tombstoneRecords { try record.insert(db) }
        if let local = payload.localState {
            let works = Set(payload.works.map { $0.id.description })
            for record in local.trackers where works.contains(record.workID) { try record.save(db) }
            for record in local.settings { try record.save(db) }
            for visit in local.visits where works.contains(visit.workID) {
                try db.execute(sql: "INSERT OR REPLACE INTO chapterVisits VALUES (?, ?, ?)", arguments: [visit.workID, visit.sourceID, visit.knownIDs])
            }
            for record in local.deferred {
                try db.execute(sql: "INSERT OR REPLACE INTO deferredChapterRecords VALUES (?, ?)", arguments: [record.name, record.payload])
            }
        }
    }
}

struct BackupCategoryMembership: Codable, Hashable, Sendable {
    var categoryID: String
    var workID: String
}

/// Local operational state is retained during restore, but never encoded in an archive.
struct BackupLocalState: Sendable {
    struct Visit: Sendable { var workID: String; var sourceID: String; var knownIDs: Data }
    struct Deferred: Sendable { var name: String; var payload: Data }
    var trackers: [TrackerLinkRecord]
    var settings: [SyncedAppSettingsRecord]
    var visits: [Visit]
    var deferred: [Deferred]
}

struct DatabaseBackupPayload: Codable, Sendable {
    var localState: BackupLocalState? = nil
    var chapterIdentity: ChapterIdentityBackup?
    var works: [Work]
    var installments: [Installment]
    var libraryEntries: [LibraryEntry]
    var categories: [MangoReaderDomain.Category]
    var categoryMemberships: [BackupCategoryMembership]
    var progress: [ReadingProgress]
    var sessions: [ReadingSession]
    var bookmarks: [Bookmark]
    var annotations: [Annotation]
    var titleStates: [UserTitleState]
    var downloads: [DownloadJob]
    var savedFilters: [SavedFilter]
    var importedOriginalReferences: [ImportedOriginalReference]
    var tombstones: [Tombstone]

    init(
        chapterIdentity: ChapterIdentityBackup? = nil,
        works: [Work],
        installments: [Installment],
        libraryEntries: [LibraryEntry],
        categories: [MangoReaderDomain.Category],
        categoryMemberships: [BackupCategoryMembership],
        progress: [ReadingProgress],
        sessions: [ReadingSession],
        bookmarks: [Bookmark],
        annotations: [Annotation],
        titleStates: [UserTitleState],
        downloads: [DownloadJob],
        savedFilters: [SavedFilter],
        importedOriginalReferences: [ImportedOriginalReference],
        tombstones: [Tombstone]
    ) {
        self.chapterIdentity = chapterIdentity
        self.works = works
        self.installments = installments
        self.libraryEntries = libraryEntries
        self.categories = categories
        self.categoryMemberships = categoryMemberships
        self.progress = progress
        self.sessions = sessions
        self.bookmarks = bookmarks
        self.annotations = annotations
        self.titleStates = titleStates
        self.downloads = downloads
        self.savedFilters = savedFilters
        self.importedOriginalReferences = importedOriginalReferences
        self.tombstones = tombstones
    }

    var recordCounts: [String: Int] {
        [
            "works": works.count,
            "installments": installments.count,
            "libraryEntries": libraryEntries.count,
            "categories": categories.count,
            "categoryMemberships": categoryMemberships.count,
            "readingProgress": progress.count,
            "readingSessions": sessions.count,
            "bookmarks": bookmarks.count,
            "annotations": annotations.count,
            "userTitleStates": titleStates.count,
            "downloads": downloads.count,
            "savedFilters": savedFilters.count,
            "importedOriginalReferences": importedOriginalReferences.count,
            "tombstones": tombstones.count,
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case chapterIdentity
        case works
        case installments
        case libraryEntries
        case categories
        case categoryMemberships
        case progress
        case sessions
        case bookmarks
        case annotations
        case titleStates
        case downloads
        case savedFilters
        case importedOriginalReferences
        case tombstones
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chapterIdentity = try container.decodeIfPresent(ChapterIdentityBackup.self, forKey: .chapterIdentity)
        works = try container.decode([Work].self, forKey: .works)
        installments = try container.decode([Installment].self, forKey: .installments)
        libraryEntries = try container.decode([LibraryEntry].self, forKey: .libraryEntries)
        categories = try container.decode([MangoReaderDomain.Category].self, forKey: .categories)
        categoryMemberships = try container.decode(
            [BackupCategoryMembership].self,
            forKey: .categoryMemberships
        )
        progress = try container.decode([ReadingProgress].self, forKey: .progress)
        sessions = try container.decode([ReadingSession].self, forKey: .sessions)
        bookmarks = try container.decode([Bookmark].self, forKey: .bookmarks)
        annotations = try container.decode([Annotation].self, forKey: .annotations)
        titleStates = try container.decodeIfPresent(
            [UserTitleState].self,
            forKey: .titleStates
        ) ?? []
        downloads = try container.decode([DownloadJob].self, forKey: .downloads)
        savedFilters = try container.decode([SavedFilter].self, forKey: .savedFilters)
        importedOriginalReferences = try container.decode(
            [ImportedOriginalReference].self,
            forKey: .importedOriginalReferences
        )
        tombstones = try container.decode([Tombstone].self, forKey: .tombstones)
    }
}

extension DatabaseBackupPayload {
    func merging(
        backup: Self,
        selection: BackupRestoreSelection,
        libraryFilesDirectory: URL
    ) -> Self {
        var result = self
        if let incoming = backup.chapterIdentity {
            var identity = chapterIdentity ?? ChapterIdentityBackup(sources: [], aliases: [], recovery: [])
            identity.sources = Array(Set(identity.sources + incoming.sources))
            identity.aliases += incoming.aliases
            identity.recovery += incoming.recovery
            result.chapterIdentity = identity
        }

        if selection.contains(.library) {
            let currentLocalWorkIDs = Set(works.filter { $0.sourceID == .local }.map(\.id))
            let restoresImportedMedia = selection.contains(.importedMedia)

            if restoresImportedMedia {
                let backupLocalWorkIDs = Set(backup.works.filter { $0.sourceID == .local }.map(\.id))
                result.works = backup.works.map(Self.sanitizedRestoredWork)
                result.installments = backup.installments.map { installment in
                    Self.sanitizedRestoredInstallment(
                        installment,
                        localWorkIDs: backupLocalWorkIDs,
                        libraryFilesDirectory: libraryFilesDirectory
                    )
                }
                result.libraryEntries = backup.libraryEntries.map { entry in
                    Self.sanitizedRestoredLibraryEntry(entry, localWorkIDs: backupLocalWorkIDs)
                }
                result.importedOriginalReferences = backup.importedOriginalReferences
            } else {
                let restoredRemoteWorks = backup.works
                    .filter { $0.sourceID != .local }
                    .map(Self.sanitizedRestoredWork)
                let restoredRemoteWorkIDs = Set(restoredRemoteWorks.map(\.id))
                result.works = restoredRemoteWorks
                    + works.filter { currentLocalWorkIDs.contains($0.id) }
                result.installments = backup.installments
                    .filter { restoredRemoteWorkIDs.contains($0.workID) }
                    .map { installment in
                        Self.sanitizedRestoredInstallment(
                            installment,
                            localWorkIDs: [],
                            libraryFilesDirectory: libraryFilesDirectory
                        )
                    }
                    + installments.filter { currentLocalWorkIDs.contains($0.workID) }
                result.libraryEntries = backup.libraryEntries
                    .filter { restoredRemoteWorkIDs.contains($0.workID) }
                    .map { entry in
                        Self.sanitizedRestoredLibraryEntry(entry, localWorkIDs: [])
                    }
                    + libraryEntries.filter { currentLocalWorkIDs.contains($0.workID) }
            }
        }

        if selection.contains(.readingActivity) {
            result.progress = backup.progress
            let currentSessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
            result.sessions = backup.sessions.map { session in
                var restored = session
                if restored.readingUnitCount == nil, let current = currentSessions[session.id],
                   current.workID == session.workID, current.installmentID == session.installmentID {
                    restored.readingUnitCount = current.readingUnitCount
                }
                return restored
            }
        }
        if selection.contains(.organization) {
            result.categories = backup.categories
            result.categoryMemberships = backup.categoryMemberships
            result.savedFilters = backup.savedFilters
        }
        if selection.contains(.bookmarksAndAnnotations) {
            result.bookmarks = backup.bookmarks
            result.annotations = backup.annotations
            result.titleStates = backup.titleStates
        }
        if selection.contains(.downloadMetadata) {
            result.downloads = backup.downloads.map(Self.sanitizedDownloadMetadata)
        }

        result.tombstones = Self.mergedTombstones(
            current: tombstones,
            backup: backup.tombstones,
            selection: selection
        )
        result.normalizeExtensionChapterReferences()
        result.pruneBrokenRelationships()
        return result
    }

    mutating func normalizeExtensionChapterReferences() {
        let known = Set(chapterIdentity?.sources ?? [])
        var chapters = installments
        var aliases = chapterIdentity?.aliases ?? []
        func resolve(_ workID: WorkID, _ id: InstallmentID) -> InstallmentID {
            if chapters.contains(where: { $0.id == id && $0.workID == workID }) { return id }
            guard let work = works.first(where: { $0.id == workID }), known.contains(work.sourceID.rawValue) else { return id }
            if let alias = aliases.last(where: { $0.workID == workID.description && $0.legacyID == id.description }),
               let uuid = UUID(uuidString: alias.scopedID), chapters.contains(where: { $0.id.rawValue == uuid && $0.workID == workID }) { return InstallmentID(rawValue: uuid) }
            guard let original = chapters.first(where: { chapter in
                guard let remote = chapter.remoteID, let owner = works.first(where: { $0.id == chapter.workID }), owner.sourceID == work.sourceID else { return false }
                return chapter.id == id || ExtensionChapterIdentity.legacyID(sourceID: work.sourceID, remoteID: remote) == id
            }), let remote = original.remoteID else { return id }
            if original.id == id { return id } // staged repair preserves displaced state
            let scoped = ExtensionChapterIdentity.id(sourceID: work.sourceID, workID: workID, remoteID: remote)
            if !chapters.contains(where: { $0.id == scoped }) {
                chapters.append(Installment(id: scoped, workID: workID, remoteID: remote, title: "Chapter — refresh required", format: original.format))
            }
            aliases.append(ChapterAliasRecord(workID: workID.description, legacyID: id.description, scopedID: scoped.description))
            return scoped
        }
        for index in progress.indices { progress[index].installmentID = resolve(progress[index].workID, progress[index].installmentID) }
        for index in sessions.indices { sessions[index].installmentID = resolve(sessions[index].workID, sessions[index].installmentID) }
        for index in bookmarks.indices { bookmarks[index].installmentID = resolve(bookmarks[index].workID, bookmarks[index].installmentID) }
        for index in annotations.indices { annotations[index].installmentID = resolve(annotations[index].workID, annotations[index].installmentID) }
        for index in downloads.indices { downloads[index].installmentID = resolve(downloads[index].workID, downloads[index].installmentID) }
        installments = chapters
        if chapterIdentity != nil { chapterIdentity?.aliases = aliases }
    }

    mutating func pruneBrokenRelationships() {
        let validWorkIDs = Set(works.map(\.id))
        installments.removeAll { !validWorkIDs.contains($0.workID) }

        var installmentOwners: [InstallmentID: WorkID] = [:]
        for installment in installments {
            installmentOwners[installment.id] = installment.workID
        }
        func isValidPair(workID: WorkID, installmentID: InstallmentID) -> Bool {
            guard validWorkIDs.contains(workID) else { return false }
            if installmentOwners[installmentID] == workID { return true }
            // Retain known legacy extension references for the staged repair.
            if let parent = works.first(where: { $0.id == workID }),
               chapterIdentity?.sources.contains(parent.sourceID.rawValue) == true,
               let chapter = installments.first(where: { $0.id == installmentID }),
               let owner = works.first(where: { $0.id == chapter.workID }) {
                return parent.sourceID == owner.sourceID && chapter.remoteID != nil
            }
            return false
        }

        libraryEntries.removeAll { !validWorkIDs.contains($0.workID) }
        progress.removeAll { !isValidPair(workID: $0.workID, installmentID: $0.installmentID) }
        sessions.removeAll { !isValidPair(workID: $0.workID, installmentID: $0.installmentID) }
        bookmarks.removeAll { !isValidPair(workID: $0.workID, installmentID: $0.installmentID) }
        annotations.removeAll { !isValidPair(workID: $0.workID, installmentID: $0.installmentID) }
        titleStates.removeAll { !validWorkIDs.contains($0.workID) }
        downloads.removeAll { !isValidPair(workID: $0.workID, installmentID: $0.installmentID) }
        importedOriginalReferences.removeAll { reference in
            !reference.isValidForCloudSync
                || !isValidPair(
                    workID: reference.workID,
                    installmentID: reference.installmentID
                )
        }

        let validCategoryIDs = Set(categories.map(\.id))
        categoryMemberships.removeAll { membership in
            guard let categoryID = UUID(uuidString: membership.categoryID),
                  let workID = UUID(uuidString: membership.workID)
            else { return true }
            return !validCategoryIDs.contains(categoryID)
                || !validWorkIDs.contains(WorkID(rawValue: workID))
        }
        savedFilters = savedFilters.map { filter in
            var sanitized = filter
            sanitized.categoryIDs.formIntersection(validCategoryIDs)
            return sanitized
        }

        let progressWorkIDs = Set(progress.map { $0.workID.rawValue.uuidString })
        let categoryIDStrings = Set(categories.map { $0.id.uuidString })
        let bookmarkIDStrings = Set(bookmarks.map { $0.id.uuidString })
        let annotationIDStrings = Set(annotations.map { $0.id.uuidString })
        let titleStateWorkIDStrings = Set(titleStates.map { $0.workID.rawValue.uuidString })
        let workIDStrings = Set(works.map { $0.id.rawValue.uuidString })
        tombstones.removeAll { tombstone in
            switch tombstone.entityType {
            case "work": workIDStrings.contains(tombstone.entityID)
            case "progress": progressWorkIDs.contains(tombstone.entityID)
            case "category": categoryIDStrings.contains(tombstone.entityID)
            case "bookmark": bookmarkIDStrings.contains(tombstone.entityID)
            case "annotation": annotationIDStrings.contains(tombstone.entityID)
            case "titleState": titleStateWorkIDStrings.contains(tombstone.entityID)
            default: false
            }
        }
    }

    static func sanitizedRestoredWork(_ work: Work) -> Work {
        var restored = work
        // Custom-cover media lives outside LibraryFiles and is not part of the
        // current backup format, so never retain a dangling device-local path.
        restored.customCoverPath = nil
        return restored
    }

    static func sanitizedRestoredInstallment(
        _ installment: Installment,
        localWorkIDs: Set<WorkID>,
        libraryFilesDirectory: URL
    ) -> Installment {
        var restored = installment
        if localWorkIDs.contains(restored.workID),
           let originalURL = restored.acquisitionURL,
           originalURL.isFileURL {
            restored.acquisitionURL = libraryFilesDirectory.appending(
                path: originalURL.lastPathComponent,
                directoryHint: .notDirectory
            )
        } else if restored.acquisitionURL?.isFileURL == true {
            // Offline downloads are intentionally excluded from backups.
            restored.acquisitionURL = nil
        }
        return restored
    }

    static func sanitizedRestoredLibraryEntry(
        _ entry: LibraryEntry,
        localWorkIDs: Set<WorkID>
    ) -> LibraryEntry {
        guard !localWorkIDs.contains(entry.workID) else { return entry }
        var restored = entry
        restored.downloadedCount = 0
        return restored
    }

    static func sanitizedDownloadMetadata(_ download: DownloadJob) -> DownloadJob {
        var restored = download
        restored.localRelativePath = nil
        restored.completedBytes = 0
        if restored.state == .downloading || restored.state == .completed {
            restored.state = .paused
        }
        if restored.state != .failed {
            restored.lastError = nil
        }
        return restored
    }

    static func mergedTombstones(
        current: [Tombstone],
        backup: [Tombstone],
        selection: BackupRestoreSelection
    ) -> [Tombstone] {
        var restoredEntityTypes: Set<String> = []
        if selection.contains(.library) { restoredEntityTypes.insert("work") }
        if selection.contains(.readingActivity) { restoredEntityTypes.insert("progress") }
        if selection.contains(.organization) { restoredEntityTypes.insert("category") }
        if selection.contains(.bookmarksAndAnnotations) {
            restoredEntityTypes.formUnion(["bookmark", "annotation", "titleState"])
        }

        var byEntityKey: [String: Tombstone] = [:]
        for tombstone in current where !restoredEntityTypes.contains(tombstone.entityType) {
            byEntityKey["\(tombstone.entityType):\(tombstone.entityID)"] = tombstone
        }
        for tombstone in backup where restoredEntityTypes.contains(tombstone.entityType) {
            byEntityKey["\(tombstone.entityType):\(tombstone.entityID)"] = tombstone
        }
        return Array(byEntityKey.values)
    }
}


extension DatabaseBackupPayload {
    func selected(_ selection: BackupRestoreSelection) throws -> Self {
        var result = self
        result.localState = nil
        if !selection.contains(.library) {
            result.works = []; result.installments = []; result.libraryEntries = []
            result.importedOriginalReferences = []; result.chapterIdentity = nil
        }
        if !selection.contains(.readingActivity) { result.progress = []; result.sessions = [] }
        if !selection.contains(.organization) { result.categories = []; result.categoryMemberships = []; result.savedFilters = [] }
        if !selection.contains(.bookmarksAndAnnotations) { result.bookmarks = []; result.annotations = []; result.titleStates = [] }
        if !selection.contains(.downloadMetadata) { result.downloads = [] }
        result.downloads = result.downloads.map { var value = Self.sanitizedDownloadMetadata($0); value.lastError = nil; return value }
        result.tombstones = Self.mergedTombstones(current: [], backup: tombstones, selection: selection)
        let workIDs = Set(result.works.map { $0.id.description })
        result.chapterIdentity?.aliases.removeAll { !workIDs.contains($0.workID) }
        result.chapterIdentity?.recovery = [] // Recovery contains device-local offline paths.
        result.chapterIdentity?.sources = Array(Set(result.works.map { $0.sourceID.rawValue }).intersection(chapterIdentity?.sources ?? []))
        for index in result.works.indices {
            result.works[index].coverURL = BackupPrivacy.publicURL(result.works[index].coverURL)
            result.works[index].coverPreviewURL = BackupPrivacy.publicURL(result.works[index].coverPreviewURL)
            result.works[index].shareURL = BackupPrivacy.publicURL(result.works[index].shareURL)
            result.works[index].customCoverPath = nil
        }
        let localIDs = Set(result.works.filter { $0.sourceID == .local }.map(\.id))
        for index in result.installments.indices {
            let url = result.installments[index].acquisitionURL
            if localIDs.contains(result.installments[index].workID), let url, url.isFileURL {
                result.installments[index].acquisitionURL = URL(fileURLWithPath: "/" + url.lastPathComponent)
            } else {
                result.installments[index].acquisitionURL = BackupPrivacy.publicURL(url)
            }
        }
        return result
    }

    mutating func remapSources(_ mapping: [String: String]) {
        for index in works.indices {
            if let id = mapping[works[index].sourceID.rawValue] { works[index].sourceID = SourceID(rawValue: id) }
        }
        let sources = chapterIdentity?.sources.map { mapping[$0] ?? $0 } ?? []
        chapterIdentity?.sources = sources
    }

    func retainingCurrent(backup: Self, selection: BackupRestoreSelection, libraryFilesDirectory: URL,
                          report: inout BackupRestoreReport) -> Self {
        var incoming = backup
        var result = self
        var workMap: [WorkID: WorkID] = [:]
        let deleted = Set(tombstones.map { "\($0.entityType):\($0.entityID)" })
        func removed(_ type: String, _ id: String) -> Bool { deleted.contains("\(type):\(id)") }
        // Apply deletion markers before remapping IDs, so an independently re-added title
        // or category cannot pull records back through an older deleted identity.
        incoming.works.removeAll { removed("work", $0.id.description) }
        incoming.categories.removeAll { removed("category", $0.id.uuidString) }
        incoming.progress.removeAll { removed("progress", $0.workID.description) }
        incoming.titleStates.removeAll { removed("titleState", $0.workID.description) }
        incoming.pruneBrokenRelationships()

        let currentWorkIDs = Set(works.map(\.id))
        let workByRemote = Dictionary(works.compactMap { value in
            value.remoteID.map { ([value.sourceID.rawValue, $0], value.id) }
        }, uniquingKeysWith: { first, _ in first })
        for value in incoming.works {
            if currentWorkIDs.contains(value.id) { workMap[value.id] = value.id }
            else if let remote = value.remoteID, let id = workByRemote[[value.sourceID.rawValue, remote]] { workMap[value.id] = id }
        }
        var chapterMap: [InstallmentID: InstallmentID] = [:]
        let currentChapterOwners = Dictionary(installments.map { ($0.id, $0.workID) }, uniquingKeysWith: { first, _ in first })
        let chapterByRemote = Dictionary(installments.compactMap { value in
            value.remoteID.map { ([value.workID.description, $0], value.id) }
        }, uniquingKeysWith: { first, _ in first })
        for value in incoming.installments {
            let owner = workMap[value.workID] ?? value.workID
            if currentChapterOwners[value.id] == owner { chapterMap[value.id] = value.id }
            else if let remote = value.remoteID, let id = chapterByRemote[[owner.description, remote]] { chapterMap[value.id] = id }
        }
        func work(_ id: WorkID) -> WorkID { workMap[id] ?? id }
        func chapter(_ id: InstallmentID) -> InstallmentID { chapterMap[id] ?? id }
        for i in incoming.works.indices { incoming.works[i].id = work(incoming.works[i].id) }
        for i in incoming.installments.indices { incoming.installments[i].workID = work(incoming.installments[i].workID); incoming.installments[i].id = chapter(incoming.installments[i].id) }
        for i in incoming.libraryEntries.indices { incoming.libraryEntries[i].workID = work(incoming.libraryEntries[i].workID) }
        for i in incoming.categoryMemberships.indices {
            if let id = UUID(uuidString: incoming.categoryMemberships[i].workID) { incoming.categoryMemberships[i].workID = work(WorkID(rawValue: id)).description }
        }
        var categoryMap: [UUID: UUID] = [:]
        for value in incoming.categories {
            if let existing = categories.first(where: { $0.id == value.id || $0.name.caseInsensitiveCompare(value.name) == .orderedSame }) {
                categoryMap[value.id] = existing.id
            }
        }
        for i in incoming.categories.indices { incoming.categories[i].id = categoryMap[incoming.categories[i].id] ?? incoming.categories[i].id }
        for i in incoming.categoryMemberships.indices {
            if let id = UUID(uuidString: incoming.categoryMemberships[i].categoryID) { incoming.categoryMemberships[i].categoryID = (categoryMap[id] ?? id).uuidString }
        }
        for i in incoming.savedFilters.indices { incoming.savedFilters[i].categoryIDs = Set(incoming.savedFilters[i].categoryIDs.map { categoryMap[$0] ?? $0 }) }
        for i in incoming.progress.indices { incoming.progress[i].workID = work(incoming.progress[i].workID); incoming.progress[i].installmentID = chapter(incoming.progress[i].installmentID) }
        for i in incoming.sessions.indices { incoming.sessions[i].workID = work(incoming.sessions[i].workID); incoming.sessions[i].installmentID = chapter(incoming.sessions[i].installmentID) }
        for i in incoming.bookmarks.indices { incoming.bookmarks[i].workID = work(incoming.bookmarks[i].workID); incoming.bookmarks[i].installmentID = chapter(incoming.bookmarks[i].installmentID) }
        for i in incoming.annotations.indices { incoming.annotations[i].workID = work(incoming.annotations[i].workID); incoming.annotations[i].installmentID = chapter(incoming.annotations[i].installmentID) }
        for i in incoming.downloads.indices { incoming.downloads[i].workID = work(incoming.downloads[i].workID); incoming.downloads[i].installmentID = chapter(incoming.downloads[i].installmentID) }
        for i in incoming.titleStates.indices { incoming.titleStates[i].workID = work(incoming.titleStates[i].workID) }
        for i in incoming.importedOriginalReferences.indices { incoming.importedOriginalReferences[i].workID = work(incoming.importedOriginalReferences[i].workID); incoming.importedOriginalReferences[i].installmentID = chapter(incoming.importedOriginalReferences[i].installmentID) }
        // IDs remapped above are resolved before any foreign-key records are merged.
        func union<T, Key: Hashable>(_ current: [T], _ values: [T], key: (T) -> Key, allowed: (T) -> Bool = { _ in true }) -> [T] {
            var seen = Set(current.map(key)); var added: [T] = []
            for value in values {
                guard allowed(value), seen.insert(key(value)).inserted else { report.skippedConflicts += 1; continue }
                added.append(value); report.addedRecords += 1
            }
            return current + added
        }
        if selection.contains(.library) {
            let localIDs = Set(incoming.works.filter { $0.sourceID == .local }.map(\.id))
            result.works = union(works, incoming.works.map(Self.sanitizedRestoredWork), key: \.id) {
                !removed("work", $0.id.description) && ($0.sourceID != .local || selection.contains(.importedMedia))
            }
            let valid = Set(result.works.map(\.id))
            result.installments = union(installments, incoming.installments.map { Self.sanitizedRestoredInstallment($0, localWorkIDs: localIDs, libraryFilesDirectory: libraryFilesDirectory) }, key: \.id) { valid.contains($0.workID) }
            result.libraryEntries = union(libraryEntries, incoming.libraryEntries.map { Self.sanitizedRestoredLibraryEntry($0, localWorkIDs: localIDs) }, key: \.workID) { valid.contains($0.workID) }
            if selection.contains(.importedMedia) { result.importedOriginalReferences = union(importedOriginalReferences, incoming.importedOriginalReferences, key: \.installmentID) }
        }
        if selection.contains(.readingActivity) {
            result.progress = union(progress, incoming.progress, key: \.installmentID) { !removed("progress", $0.workID.description) }
            result.sessions = union(sessions, incoming.sessions, key: \.id)
        }
        if selection.contains(.organization) {
            result.categories = union(categories, incoming.categories, key: \.id) { !removed("category", $0.id.uuidString) }
            result.categoryMemberships = union(categoryMemberships, incoming.categoryMemberships, key: { $0 })
            result.savedFilters = union(savedFilters, incoming.savedFilters, key: \.id)
        }
        if selection.contains(.bookmarksAndAnnotations) {
            result.bookmarks = union(bookmarks, incoming.bookmarks, key: \.id) { !removed("bookmark", $0.id.uuidString) }
            result.annotations = union(annotations, incoming.annotations, key: \.id) { !removed("annotation", $0.id.uuidString) }
            result.titleStates = union(titleStates, incoming.titleStates, key: \.workID) { !removed("titleState", $0.workID.description) }
        }
        if selection.contains(.downloadMetadata) { result.downloads = union(downloads, incoming.downloads.map(Self.sanitizedDownloadMetadata), key: \.installmentID) }
        if selection.contains(.library), let identity = incoming.chapterIdentity {
            var current = result.chapterIdentity ?? ChapterIdentityBackup(sources: [], aliases: [], recovery: [])
            current.sources = Array(Set(current.sources + identity.sources))
            // Current aliases win; only unchanged work/chapter identities can reuse incoming aliases.
            let known = Set(current.aliases.map { "\($0.workID):\($0.legacyID)" })
            current.aliases += identity.aliases.filter { alias in
                !known.contains("\(alias.workID):\(alias.legacyID)") && workMap.keys.allSatisfy { $0.description != alias.workID || workMap[$0] == $0 }
            }
            result.chapterIdentity = current
        }
        result.normalizeExtensionChapterReferences()
        result.pruneBrokenRelationships()
        result.tombstones = tombstones
        return result
    }
}

/// Backup URLs never carry userinfo, fragments or unknown query parameters.
/// Required endpoints fail closed instead of exporting a silently broken connection.
public enum BackupPrivacy {
    public static func publicURL(_ url: URL?) -> URL? {
        guard let url, !url.isFileURL, var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else { return nil }
        let allowed = Set(["page", "offset", "limit", "lang", "language", "sort", "order", "id"])
        guard (components.queryItems ?? []).allSatisfy({ allowed.contains($0.name.lowercased()) }) else { return nil }
        components.fragment = nil
        return components.url
    }

    static func validatePublicURLs(in data: Data) throws {
        func validate(_ value: Any) throws {
            if let object = value as? [String: Any] { for value in object.values { try validate(value) } }
            else if let array = value as? [Any] { for value in array { try validate(value) } }
            else if let raw = value as? String, raw.hasPrefix("https://") || raw.hasPrefix("http://") {
                guard publicURL(URL(string: raw)) != nil else {
                    throw MangoReaderDataError.corruptBackup("Selected reading data contains an address with authentication or private URL parameters. Exclude that reading data before sharing a backup.")
                }
            }
        }
        try validate(JSONSerialization.jsonObject(with: data))
    }

    public static func requiredURL(_ url: URL) throws -> URL {
        guard let safe = publicURL(url), safe == url else {
            throw MangoReaderDataError.corruptBackup("A server or repository address contains authentication or private URL parameters. Remove those details before exporting or importing it.")
        }
        return safe
    }
}
