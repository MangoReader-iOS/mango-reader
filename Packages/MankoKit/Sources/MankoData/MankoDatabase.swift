import Foundation
import GRDB
import MankoDomain

public struct DatabaseSchemaInformation: Equatable, Sendable {
    public let tables: Set<String>
    public let appliedMigrations: [String]
    public let foreignKeysEnabled: Bool
    public let journalMode: String

    public init(
        tables: Set<String>,
        appliedMigrations: [String],
        foreignKeysEnabled: Bool,
        journalMode: String
    ) {
        self.tables = tables
        self.appliedMigrations = appliedMigrations
        self.foreignKeysEnabled = foreignKeysEnabled
        self.journalMode = journalMode
    }
}

enum DatabaseRestoreSwapPhase: Equatable, Sendable {
    case stagedStoreReady
    case liveStoreClosed
    case liveStoreReplaced
    case restoredStoreOpened
}

typealias DatabaseRestoreSwapFailureInjector = @Sendable (DatabaseRestoreSwapPhase) throws -> Void

enum BulkMetadataUpdatePhase: Equatable, Sendable {
    case beforeUpdate(index: Int, workID: WorkID)
}

typealias BulkMetadataUpdateFailureInjector = @Sendable (BulkMetadataUpdatePhase) throws -> Void

enum BulkSourceMigrationUpdatePhase: Equatable, Sendable {
    case beforeUpdate(index: Int, workID: WorkID)
}

typealias BulkSourceMigrationUpdateFailureInjector = @Sendable (
    BulkSourceMigrationUpdatePhase
) throws -> Void

/// The single isolation domain for manko's local SQLite database.
public actor MankoDatabase: LibraryRepository {
    public nonisolated let databaseURL: URL

    // Shared only by actor-isolated database extensions; the pool has one owner.
    var pool: DatabasePool
    let migrator: DatabaseMigrator
    let restoreSwapFailureInjector: DatabaseRestoreSwapFailureInjector?
    let bulkMetadataUpdateFailureInjector: BulkMetadataUpdateFailureInjector?
    let bulkSourceMigrationUpdateFailureInjector: BulkSourceMigrationUpdateFailureInjector?

    /// Preferred app entry point: database opening and migrations do not block MainActor.
    @concurrent
    public static func open(storagePaths: StoragePaths) async throws -> MankoDatabase {
        try MankoDatabase(storagePaths: storagePaths)
    }

    public init(storagePaths: StoragePaths) throws {
        try storagePaths.prepare()
        databaseURL = storagePaths.databaseURL
        let migrator = DatabaseSchema.makeMigrator()
        self.migrator = migrator
        restoreSwapFailureInjector = nil
        bulkMetadataUpdateFailureInjector = nil
        bulkSourceMigrationUpdateFailureInjector = nil
        pool = try Self.openPool(at: storagePaths.databaseURL, migrator: migrator)
    }

    public init(databaseURL: URL) throws {
        let parent = databaseURL.deletingLastPathComponent()
        let paths = StoragePaths(
            applicationSupportDirectory: parent,
            cachesDirectory: parent.appending(path: "Caches", directoryHint: .isDirectory)
        )
        try paths.prepare()
        self.databaseURL = databaseURL
        let migrator = DatabaseSchema.makeMigrator()
        self.migrator = migrator
        restoreSwapFailureInjector = nil
        bulkMetadataUpdateFailureInjector = nil
        bulkSourceMigrationUpdateFailureInjector = nil
        pool = try Self.openPool(at: databaseURL, migrator: migrator)
    }

    init(
        storagePaths: StoragePaths,
        restoreSwapFailureInjector: @escaping DatabaseRestoreSwapFailureInjector
    ) throws {
        try storagePaths.prepare()
        databaseURL = storagePaths.databaseURL
        let migrator = DatabaseSchema.makeMigrator()
        self.migrator = migrator
        self.restoreSwapFailureInjector = restoreSwapFailureInjector
        bulkMetadataUpdateFailureInjector = nil
        bulkSourceMigrationUpdateFailureInjector = nil
        pool = try Self.openPool(at: storagePaths.databaseURL, migrator: migrator)
    }

    init(
        storagePaths: StoragePaths,
        bulkMetadataUpdateFailureInjector: @escaping BulkMetadataUpdateFailureInjector
    ) throws {
        try storagePaths.prepare()
        databaseURL = storagePaths.databaseURL
        let migrator = DatabaseSchema.makeMigrator()
        self.migrator = migrator
        restoreSwapFailureInjector = nil
        self.bulkMetadataUpdateFailureInjector = bulkMetadataUpdateFailureInjector
        bulkSourceMigrationUpdateFailureInjector = nil
        pool = try Self.openPool(at: storagePaths.databaseURL, migrator: migrator)
    }

    init(
        storagePaths: StoragePaths,
        bulkSourceMigrationUpdateFailureInjector: @escaping BulkSourceMigrationUpdateFailureInjector
    ) throws {
        try storagePaths.prepare()
        databaseURL = storagePaths.databaseURL
        let migrator = DatabaseSchema.makeMigrator()
        self.migrator = migrator
        restoreSwapFailureInjector = nil
        bulkMetadataUpdateFailureInjector = nil
        self.bulkSourceMigrationUpdateFailureInjector = bulkSourceMigrationUpdateFailureInjector
        pool = try Self.openPool(at: storagePaths.databaseURL, migrator: migrator)
    }

    nonisolated static func databaseConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }
        return configuration
    }

    nonisolated static func openPool(
        at databaseURL: URL,
        migrator: DatabaseMigrator
    ) throws -> DatabasePool {
        let pool = try DatabasePool(
            path: databaseURL.path,
            configuration: databaseConfiguration()
        )
        do {
            try migrator.migrate(pool)
            try pool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA optimize")
            }
            return pool
        } catch {
            try? pool.close()
            throw error
        }
    }

    public func close() throws { try pool.close() }

    public func schemaInformation() throws -> DatabaseSchemaInformation {
        try pool.read { db in
            let tables = try Set(String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'view')"
            ))
            let migrations = try migrator.appliedMigrations(db)
            let foreignKeys = try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1
            let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "unknown"
            return DatabaseSchemaInformation(
                tables: tables,
                appliedMigrations: migrations,
                foreignKeysEnabled: foreignKeys,
                journalMode: journalMode.lowercased()
            )
        }
    }
}
