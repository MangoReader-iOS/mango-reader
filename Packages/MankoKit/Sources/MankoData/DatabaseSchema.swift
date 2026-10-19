import GRDB

enum DatabaseSchema {
    static let migrationIdentifier = "current_schema"
    static let removeTitleRatingsMigrationIdentifier = "remove_title_ratings"
    static let addSearchFacetsMigrationIdentifier = "add_search_facets"
    static let addUserTitleStatesMigrationIdentifier = "add_user_title_states"
    static let addTrackerLinksMigrationIdentifier = "add_tracker_links"
    static let ensureSyncSupportTablesMigrationIdentifier = "ensure_sync_support_tables"

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(migrationIdentifier) { db in
            try createCoreTables(in: db)
            try createIndexes(in: db)
            try createSearchIndex(in: db)
            try createImportedOriginalReferences(in: db)
            try createSyncedAppSettings(in: db)
        }
        migrator.registerMigration(removeTitleRatingsMigrationIdentifier) { db in
            if try db.columns(in: "works").contains(where: { $0.name == "rating" }) {
                try db.execute(sql: "ALTER TABLE works DROP COLUMN rating")
            }
            if try db.columns(in: "savedFilters").contains(where: { $0.name == "ratings" }) {
                try db.execute(sql: "ALTER TABLE savedFilters DROP COLUMN ratings")
            }
        }
        migrator.registerMigration(addSearchFacetsMigrationIdentifier) { db in
            if try !db.columns(in: "works").contains(where: { $0.name == "searchFacets" }) {
                try db.execute(
                    sql: "ALTER TABLE works ADD COLUMN searchFacets BLOB NOT NULL DEFAULT X'5B5D'"
                )
            }
        }
        migrator.registerMigration(addUserTitleStatesMigrationIdentifier) { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS userTitleStates (
                    workID TEXT PRIMARY KEY NOT NULL REFERENCES works(id) ON DELETE CASCADE,
                    rating INTEGER CHECK (
                        rating IS NULL
                        OR rating BETWEEN 1 AND 10
                    ),
                    status TEXT CHECK (
                        status IS NULL
                        OR status IN ('planning', 'reading', 'completed', 'paused', 'dropped', 'rereading')
                    ),
                    modifiedAt REAL NOT NULL,
                    deviceID TEXT NOT NULL CHECK (length(deviceID) BETWEEN 1 AND 128)
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS user_title_states_modified
                ON userTitleStates(modifiedAt DESC)
                """)
        }
        migrator.registerMigration(addTrackerLinksMigrationIdentifier) { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS trackerLinks (
                    workID TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
                    trackerID TEXT NOT NULL,
                    remoteWorkID TEXT NOT NULL,
                    remoteTitle TEXT NOT NULL,
                    lastSynced BLOB NOT NULL,
                    lastPulledAt REAL,
                    conflicts BLOB NOT NULL,
                    PRIMARY KEY (workID, trackerID)
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS tracker_links_tracker
                ON trackerLinks(trackerID, lastPulledAt)
                """)
        }
        migrator.registerMigration(ensureSyncSupportTablesMigrationIdentifier) { db in
            // Older databases already applied current_schema before these
            // optional sync tables were added to its fresh-install definition.
            try createImportedOriginalReferences(in: db)
            try createSyncedAppSettings(in: db)
        }
        migrator.registerMigration("reader_source_metadata") { db in
            try db.execute(sql: "ALTER TABLE works ADD COLUMN readingMode TEXT")
            try db.execute(sql: "ALTER TABLE installments ADD COLUMN scanlators BLOB")
        }
        migrator.registerMigration("extension_chapter_ownership_v2") { db in
            try db.execute(sql: "CREATE TABLE extensionChapterSources (sourceID TEXT PRIMARY KEY NOT NULL) STRICT")
            try db.execute(sql: "CREATE TABLE extensionChapterAliases (workID TEXT NOT NULL, legacyID TEXT NOT NULL, scopedID TEXT NOT NULL, PRIMARY KEY(workID, legacyID)) STRICT")
            try db.execute(sql: "CREATE TABLE extensionChapterRecovery (id TEXT PRIMARY KEY NOT NULL, workID TEXT NOT NULL, installmentID TEXT NOT NULL, localRelativePath TEXT) STRICT")
            try db.execute(sql: "CREATE TABLE extensionChapterRepairQueue (workID TEXT PRIMARY KEY NOT NULL) STRICT")
            try db.execute(sql: "CREATE TABLE deferredChapterRecords (name TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL) STRICT")
            try createChapterOwnershipGuards(in: db)
        }
        migrator.registerMigration("reading_session_unit_count") { db in
            try db.execute(sql: "ALTER TABLE readingSessions ADD COLUMN readingUnitCount INTEGER CHECK (readingUnitCount IS NULL OR readingUnitCount > 0)")
        }
        migrator.registerMigration("work_share_url") { db in
            try db.execute(sql: "ALTER TABLE works ADD COLUMN shareURL TEXT")
        }
        migrator.registerMigration("reading_progress_reset") { db in
            try db.execute(sql: "ALTER TABLE readingProgress ADD COLUMN resetAt REAL")
        }
        migrator.registerMigration("tracker_reading_dates") { db in
            try db.execute(sql: "ALTER TABLE userTitleStates ADD COLUMN startDate BLOB")
            try db.execute(sql: "ALTER TABLE userTitleStates ADD COLUMN finishDate BLOB")
            try db.execute(sql: "ALTER TABLE trackerLinks ADD COLUMN lastRemote BLOB")
            try db.execute(sql: "ALTER TABLE trackerLinks ADD COLUMN supportsDateUpdates INTEGER")
        }
        migrator.registerMigration("tracker_delivery_authorization_and_chapter_visits") { db in
            try db.execute(sql: "ALTER TABLE trackerLinks ADD COLUMN generation TEXT")
            try db.execute(sql: """
                CREATE TABLE chapterVisits (
                    workID TEXT PRIMARY KEY NOT NULL REFERENCES works(id) ON DELETE CASCADE,
                    sourceID TEXT NOT NULL,
                    knownIDs BLOB NOT NULL
                ) STRICT
                """)
        }
        return migrator
    }

    static func createChapterOwnershipGuards(in db: Database) throws {
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS installment_owner_guard BEFORE UPDATE OF workID ON installments
                WHEN new.workID != old.workID BEGIN
                    SELECT RAISE(ABORT, 'Chapter ownership mismatch');
                END
                """)
            for table in ["readingProgress", "readingSessions", "bookmarks", "annotations", "downloads"] {
                for action in ["INSERT", "UPDATE"] {
                    try db.execute(sql: """
                        CREATE TRIGGER IF NOT EXISTS \(table)_owner_\(action) BEFORE \(action) ON \(table)
                        WHEN NOT EXISTS (SELECT 1 FROM installments WHERE id = new.installmentID AND workID = new.workID) BEGIN
                            SELECT RAISE(ABORT, 'Chapter ownership mismatch');
                        END
                        """)
                }
            }
    }

    /// One bounded singleton contains only the allowlisted preference payload.
    /// Keeping it separate from UserDefaults gives CKSyncEngine a durable,
    /// transactionally merged source of truth without admitting secrets or
    /// device-local operational state into CloudKit.
    private static func createSyncedAppSettings(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS syncedAppSettings (
                id TEXT PRIMARY KEY NOT NULL CHECK (id = 'preferences'),
                version INTEGER NOT NULL CHECK (version = 1),
                payload BLOB NOT NULL CHECK (length(payload) BETWEEN 1 AND 65536),
                modifiedAt REAL NOT NULL CHECK (modifiedAt >= 0 AND modifiedAt <= 4102444800),
                deviceID TEXT NOT NULL CHECK (length(deviceID) BETWEEN 1 AND 128)
            ) STRICT
            """)
    }

    /// Descriptor rows intentionally do not declare foreign keys. CloudKit can
    /// deliver a descriptor in a different change batch from its owning work,
    /// so the non-secret metadata must be durable until the library records
    /// arrive. Cleanup triggers provide the ordinary local-delete behavior,
    /// while reconciliation queries only expose rows whose relationships match.
    private static func createImportedOriginalReferences(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS importedOriginalReferences (
                installmentID TEXT PRIMARY KEY NOT NULL,
                workID TEXT NOT NULL,
                sourceID TEXT NOT NULL CHECK (sourceID = 'local'),
                format TEXT NOT NULL CHECK (format IN ('cbz', 'epub', 'pdf')),
                sha256Hex TEXT NOT NULL CHECK (length(sha256Hex) = 64),
                byteCount INTEGER NOT NULL CHECK (byteCount > 0 AND byteCount <= 8589934592),
                modifiedAt REAL NOT NULL,
                deviceID TEXT NOT NULL CHECK (length(deviceID) BETWEEN 1 AND 128)
            ) STRICT
            """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS imported_original_references_work
            ON importedOriginalReferences(workID)
            """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS imported_original_references_digest
            ON importedOriginalReferences(sha256Hex, format)
            """)
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS works_delete_imported_original_references
            AFTER DELETE ON works BEGIN
                DELETE FROM importedOriginalReferences WHERE workID = old.id;
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS installments_delete_imported_original_reference
            AFTER DELETE ON installments BEGIN
                DELETE FROM importedOriginalReferences WHERE installmentID = old.id;
            END
            """)
    }

    private static func createCoreTables(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS works (
                id TEXT PRIMARY KEY NOT NULL,
                sourceID TEXT NOT NULL,
                remoteID TEXT,
                title TEXT NOT NULL,
                alternativeTitles BLOB NOT NULL,
                authors BLOB NOT NULL,
                summary TEXT NOT NULL,
                tags BLOB NOT NULL,
                searchFacets BLOB NOT NULL DEFAULT X'5B5D',
                normalizedTitle TEXT NOT NULL,
                normalizedAlternativeTitles TEXT NOT NULL,
                normalizedAuthors TEXT NOT NULL,
                normalizedSummary TEXT NOT NULL,
                normalizedTags TEXT NOT NULL,
                languageCode TEXT,
                kind TEXT NOT NULL,
                status TEXT NOT NULL,
                coverURL TEXT,
                customCoverPath TEXT,
                createdAt REAL NOT NULL,
                modifiedAt REAL NOT NULL
            ) STRICT
            """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS installments (
                id TEXT PRIMARY KEY NOT NULL,
                workID TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
                remoteID TEXT,
                title TEXT NOT NULL,
                volume REAL,
                number REAL,
                publishedAt REAL,
                languageCode TEXT,
                format TEXT NOT NULL,
                acquisitionURL TEXT,
                pageCount INTEGER CHECK (pageCount IS NULL OR pageCount >= 0)
            ) STRICT
            """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS libraryEntries (
                id TEXT PRIMARY KEY NOT NULL,
                workID TEXT NOT NULL UNIQUE REFERENCES works(id) ON DELETE CASCADE,
                addedAt REAL NOT NULL,
                lastOpenedAt REAL,
                isPinned INTEGER NOT NULL CHECK (isPinned IN (0, 1)),
                isHidden INTEGER NOT NULL CHECK (isHidden IN (0, 1)),
                unreadCount INTEGER NOT NULL CHECK (unreadCount >= 0),
                downloadedCount INTEGER NOT NULL CHECK (downloadedCount >= 0),
                cloudFilePolicy TEXT NOT NULL
            ) STRICT
            """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS categories (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL COLLATE NOCASE UNIQUE,
                sortIndex INTEGER NOT NULL,
                createdAt REAL NOT NULL,
                modifiedAt REAL NOT NULL
            ) STRICT
            """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS categoryMemberships (
                categoryID TEXT NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
                workID TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
                PRIMARY KEY (categoryID, workID)
            ) STRICT, WITHOUT ROWID
            """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS readingProgress (
                id TEXT PRIMARY KEY NOT NULL,
                workID TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
                installmentID TEXT NOT NULL REFERENCES installments(id) ON DELETE CASCADE,
                locator BLOB NOT NULL,
                currentProgression REAL NOT NULL CHECK (currentProgression BETWEEN 0 AND 1),
                highestProgression REAL NOT NULL CHECK (highestProgression BETWEEN 0 AND 1),
                modifiedAt REAL NOT NULL,
                deviceID TEXT NOT NULL,
                UNIQUE (workID, installmentID)
            ) STRICT
            """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS readingSessions (
                id TEXT PRIMARY KEY NOT NULL,
                workID TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
                installmentID TEXT NOT NULL REFERENCES installments(id) ON DELETE CASCADE,
                startedAt REAL NOT NULL,
                endedAt REAL,
                secondsRead REAL NOT NULL CHECK (secondsRead >= 0),
                startProgression REAL NOT NULL CHECK (startProgression BETWEEN 0 AND 1),
                endProgression REAL NOT NULL CHECK (endProgression BETWEEN 0 AND 1)
            ) STRICT
            """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS bookmarks (
                id TEXT PRIMARY KEY NOT NULL,
                workID TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
                installmentID TEXT NOT NULL REFERENCES installments(id) ON DELETE CASCADE,
                locator BLOB NOT NULL,
                title TEXT NOT NULL,
                createdAt REAL NOT NULL,
                modifiedAt REAL NOT NULL
            ) STRICT
            """)

        try createAnnotations(in: db)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS downloads (
                id TEXT PRIMARY KEY NOT NULL,
                workID TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
                installmentID TEXT NOT NULL REFERENCES installments(id) ON DELETE CASCADE,
                state TEXT NOT NULL,
                priority INTEGER NOT NULL,
                completedBytes INTEGER NOT NULL CHECK (completedBytes >= 0),
                totalBytes INTEGER CHECK (totalBytes IS NULL OR totalBytes >= 0),
                localRelativePath TEXT,
                lastError TEXT,
                createdAt REAL NOT NULL,
                modifiedAt REAL NOT NULL,
                UNIQUE (installmentID)
            ) STRICT
            """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS savedFilters (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                query TEXT NOT NULL,
                kinds BLOB NOT NULL,
                categoryIDs BLOB NOT NULL,
                sort TEXT NOT NULL,
                isSmart INTEGER NOT NULL CHECK (isSmart IN (0, 1))
            ) STRICT
            """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS tombstones (
                id TEXT PRIMARY KEY NOT NULL,
                entityType TEXT NOT NULL,
                entityID TEXT NOT NULL,
                deletedAt REAL NOT NULL,
                deviceID TEXT NOT NULL,
                UNIQUE (entityType, entityID)
            ) STRICT
            """)
    }

    private static func createAnnotations(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS annotations (
                id TEXT PRIMARY KEY NOT NULL,
                workID TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
                installmentID TEXT NOT NULL REFERENCES installments(id) ON DELETE CASCADE,
                locator BLOB NOT NULL,
                selectedText TEXT,
                note TEXT NOT NULL,
                highlightColor TEXT NOT NULL CHECK (highlightColor IN ('yellow', 'green', 'orange', 'pink')),
                createdAt REAL NOT NULL,
                modifiedAt REAL NOT NULL
            ) STRICT
            """)
    }

    private static func createIndexes(in db: Database) throws {
        try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS works_source_remote ON works(sourceID, remoteID) WHERE remoteID IS NOT NULL")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS works_modified ON works(modifiedAt DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS installments_work_sort ON installments(workID, volume, number, publishedAt)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS library_entries_pinned_added ON libraryEntries(isPinned DESC, addedAt DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS category_memberships_work ON categoryMemberships(workID)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS progress_work_modified ON readingProgress(workID, modifiedAt DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS sessions_started ON readingSessions(startedAt DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS bookmarks_installment ON bookmarks(installmentID, modifiedAt DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS annotations_installment ON annotations(installmentID, modifiedAt DESC)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS downloads_state_priority ON downloads(state, priority DESC, createdAt)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS tombstones_deleted ON tombstones(deletedAt)")
    }

    private static func createSearchIndex(in db: Database) throws {
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS worksFTS USING fts5(
                normalizedTitle,
                normalizedAlternativeTitles,
                normalizedAuthors,
                normalizedSummary,
                normalizedTags,
                content='works',
                content_rowid='rowid',
                tokenize='unicode61 remove_diacritics 2',
                prefix='2 3'
            )
            """)

        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS works_fts_insert AFTER INSERT ON works BEGIN
                INSERT INTO worksFTS(
                    rowid,
                    normalizedTitle,
                    normalizedAlternativeTitles,
                    normalizedAuthors,
                    normalizedSummary,
                    normalizedTags
                ) VALUES (
                    new.rowid,
                    new.normalizedTitle,
                    new.normalizedAlternativeTitles,
                    new.normalizedAuthors,
                    new.normalizedSummary,
                    new.normalizedTags
                );
            END
            """)

        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS works_fts_delete AFTER DELETE ON works BEGIN
                INSERT INTO worksFTS(
                    worksFTS,
                    rowid,
                    normalizedTitle,
                    normalizedAlternativeTitles,
                    normalizedAuthors,
                    normalizedSummary,
                    normalizedTags
                ) VALUES (
                    'delete',
                    old.rowid,
                    old.normalizedTitle,
                    old.normalizedAlternativeTitles,
                    old.normalizedAuthors,
                    old.normalizedSummary,
                    old.normalizedTags
                );
            END
            """)

        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS works_fts_update AFTER UPDATE ON works BEGIN
                INSERT INTO worksFTS(
                    worksFTS,
                    rowid,
                    normalizedTitle,
                    normalizedAlternativeTitles,
                    normalizedAuthors,
                    normalizedSummary,
                    normalizedTags
                ) VALUES (
                    'delete',
                    old.rowid,
                    old.normalizedTitle,
                    old.normalizedAlternativeTitles,
                    old.normalizedAuthors,
                    old.normalizedSummary,
                    old.normalizedTags
                );
                INSERT INTO worksFTS(
                    rowid,
                    normalizedTitle,
                    normalizedAlternativeTitles,
                    normalizedAuthors,
                    normalizedSummary,
                    normalizedTags
                ) VALUES (
                    new.rowid,
                    new.normalizedTitle,
                    new.normalizedAlternativeTitles,
                    new.normalizedAuthors,
                    new.normalizedSummary,
                    new.normalizedTags
                );
            END
            """)
    }
}
