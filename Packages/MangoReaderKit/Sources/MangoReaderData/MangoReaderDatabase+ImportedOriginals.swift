import Foundation
import GRDB
import MangoReaderDomain

extension MangoReaderDatabase {
    // MARK: - Imported-original cloud references

    /// App updates can move the sandbox while preserving its files and database.
    /// Rebind only verified content-addressed originals owned by this app.
    @discardableResult
    public func reconcileManagedImportedFileURLs(libraryFilesDirectory: URL) async throws -> Int {
        let root = libraryFilesDirectory.standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath()
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
        else { return 0 }
        let originals: [Installment] = try await pool.read { db in
            try InstallmentRecord.fetchAll(db, sql: """
                SELECT installments.* FROM installments
                JOIN works ON works.id = installments.workID
                JOIN libraryEntries ON libraryEntries.workID = works.id
                WHERE works.sourceID = ? AND installments.acquisitionURL IS NOT NULL
                  AND installments.format IN ('epub', 'pdf', 'cbz')
                """, arguments: [SourceID.local.rawValue]).compactMap { try? $0.domainValue() }
        }
        guard !originals.isEmpty else { return 0 }
        let references: [String: ImportedOriginalReference?] = try await pool.read { db in
            guard try db.tableExists("importedOriginalReferences") else { return [:] }
            var result: [String: ImportedOriginalReference?] = [:]
            for record in try ImportedOriginalReferenceRecord.fetchAll(db) {
                result.updateValue(try? record.domainValue(), forKey: record.installmentID)
            }
            return result
        }
        var repairedCount = 0
        var verifiedFiles: Set<String> = []
        for original in originals {
            try Task.checkCancellation()
            guard let previousURL = original.acquisitionURL, previousURL.isFileURL,
                  let ext = original.format.importedOriginalFileExtension,
                  previousURL.pathExtension == ext
            else { continue }
            let filename = previousURL.lastPathComponent
            let digest = previousURL.deletingPathExtension().lastPathComponent
            guard digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  Array(previousURL.pathComponents.suffix(5)) == [
                    "Library", "Application Support", "com.k800k.manko", "LibraryFiles", filename,
                  ]
            else { continue }
            let candidate = root.appendingPathComponent(filename)
            guard previousURL.standardizedFileURL != candidate,
                  candidate.resolvingSymlinksInPath().deletingLastPathComponent() == resolvedRoot,
                  let values = try? candidate.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                  ]),
                  values.isRegularFile == true, values.isSymbolicLink == false
            else { continue }
            if let storedReference = references[original.id.rawValue.uuidString] {
                guard let reference = storedReference, reference.isValidForCloudSync,
                      reference.workID == original.workID,
                      reference.format == original.format,
                      reference.canonicalRelativePath == filename,
                      values.fileSize.map(Int64.init) == reference.byteCount
                else { continue }
            }
            if !verifiedFiles.contains(filename) {
                guard (try? LocalPublicationImporter.sha256Hex(of: candidate)) == digest else { continue }
                verifiedFiles.insert(filename)
            }
            try Task.checkCancellation()
            repairedCount += try await pool.write { db in
                try db.execute(sql: """
                    UPDATE installments SET acquisitionURL = ?
                    WHERE id = ? AND workID = ? AND acquisitionURL = ?
                      AND EXISTS (SELECT 1 FROM works WHERE id = installments.workID AND sourceID = ?)
                    """, arguments: [
                        candidate.absoluteString, original.id.rawValue.uuidString,
                        original.workID.rawValue.uuidString, previousURL.absoluteString,
                        SourceID.local.rawValue,
                    ])
                return db.changesCount
            }
        }
        return repairedCount
    }

    /// Returns app-managed local publications that can be uploaded when their
    /// effective policy permits it. The absolute acquisition URL never leaves
    /// this database boundary; only its final content-addressed component is
    /// exposed to the transfer service.
    public func managedImportedOriginals() async throws -> [ManagedImportedOriginal] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    works.id AS workID,
                    installments.id AS installmentID,
                    works.sourceID AS sourceID,
                    installments.format AS format,
                    installments.acquisitionURL AS acquisitionURL,
                    libraryEntries.cloudFilePolicy AS cloudFilePolicy
                FROM installments
                JOIN works ON works.id = installments.workID
                JOIN libraryEntries ON libraryEntries.workID = works.id
                WHERE works.sourceID = ?
                  AND installments.format IN (?, ?, ?)
                  AND installments.acquisitionURL IS NOT NULL
                ORDER BY works.id, installments.id
                """, arguments: [
                    SourceID.local.rawValue,
                    PublicationFormat.cbz.rawValue,
                    PublicationFormat.epub.rawValue,
                    PublicationFormat.pdf.rawValue,
                ])

            return rows.compactMap { row in
                guard
                    let workUUID = UUID(uuidString: row["workID"] as String),
                    let installmentUUID = UUID(uuidString: row["installmentID"] as String),
                    let format = PublicationFormat(rawValue: row["format"] as String),
                    let policy = CloudFilePolicy(rawValue: row["cloudFilePolicy"] as String),
                    let acquisitionURLString = row["acquisitionURL"] as String?,
                    let acquisitionURL = URL(string: acquisitionURLString),
                    acquisitionURL.isFileURL
                else {
                    return nil
                }
                return ManagedImportedOriginal(
                    workID: WorkID(rawValue: workUUID),
                    installmentID: InstallmentID(rawValue: installmentUUID),
                    sourceID: SourceID(rawValue: row["sourceID"] as String),
                    format: format,
                    localRelativePath: acquisitionURL.lastPathComponent,
                    cloudFilePolicy: policy
                )
            }
        }
    }

    /// Saves a reference produced by a verified local upload. Unlike remotely
    /// fetched references, this path requires the related local work and
    /// installment to exist and match before committing.
    public func save(importedOriginalReference reference: ImportedOriginalReference) async throws {
        guard reference.isValidForCloudSync else {
            throw MangoReaderDataError.invalidImportedOriginalReference
        }
        try await pool.write { db in
            guard try Self.hasMatchingLocalImportedOriginal(reference, in: db) else {
                throw MangoReaderDataError.missingImportedOriginalRelationship
            }
            try Self.merge(reference, in: db)
        }
    }

    /// Persists a validated CloudKit reference even if its owning work arrives
    /// in a later change batch. Reconciliation queries keep such rows dormant
    /// until the complete local relationship exists.
    public func mergeSyncedImportedOriginalReference(
        _ reference: ImportedOriginalReference
    ) async throws {
        guard reference.isValidForCloudSync else {
            throw MangoReaderDataError.invalidImportedOriginalReference
        }
        try await pool.write { db in
            try Self.merge(reference, in: db)
        }
    }

    public func importedOriginalReference(
        installmentID: InstallmentID
    ) async throws -> ImportedOriginalReference? {
        try await pool.read { db in
            try ImportedOriginalReferenceRecord
                .fetchOne(db, key: installmentID.rawValue.uuidString)?
                .domainValue()
        }
    }

    public func importedOriginalReferences() async throws -> [ImportedOriginalReference] {
        try await pool.read { db in
            let records = try ImportedOriginalReferenceRecord
                .order(Column("workID"), Column("installmentID"))
                .fetchAll(db)
            return try records.map { try $0.domainValue() }
        }
    }

    public func importedOriginalReferences(
        for workIDs: Set<WorkID>
    ) async throws -> [ImportedOriginalReference] {
        guard !workIDs.isEmpty else { return [] }
        let identifiers = Set(workIDs.map { $0.rawValue.uuidString })
        return try await importedOriginalReferences().filter { reference in
            identifiers.contains(reference.workID.rawValue.uuidString)
        }
    }

    @discardableResult
    public func deleteImportedOriginalReference(
        installmentID: InstallmentID
    ) async throws -> Bool {
        try await pool.write { db in
            try ImportedOriginalReferenceRecord.deleteOne(
                db,
                key: installmentID.rawValue.uuidString
            )
        }
    }

    /// Drops account-scoped CloudKit descriptors while preserving every work,
    /// installment, managed original, and download. This is used only at the
    /// explicit CKSyncEngine account-switch boundary so old-account metadata
    /// can never be interpreted against a new iCloud Drive container.
    @discardableResult
    public func deleteAllImportedOriginalReferences() async throws -> [InstallmentID] {
        try await pool.write { db in
            let identifiers = try String.fetchAll(
                db,
                sql: "SELECT installmentID FROM importedOriginalReferences ORDER BY installmentID"
            ).compactMap(UUID.init(uuidString:)).map(InstallmentID.init(rawValue:))
            try db.execute(sql: "DELETE FROM importedOriginalReferences")
            return identifiers
        }
    }

    /// Returns only references whose current work, installment, source, and
    /// format still match. Orphaned cross-batch metadata remains durable but can
    /// never cause a file write until its relationship is complete.
    public func importedOriginalDownloadCandidates() async throws -> [ImportedOriginalDownloadCandidate] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    importedOriginalReferences.*,
                    libraryEntries.cloudFilePolicy AS cloudFilePolicy
                FROM importedOriginalReferences
                JOIN works
                  ON works.id = importedOriginalReferences.workID
                 AND works.sourceID = importedOriginalReferences.sourceID
                JOIN installments
                  ON installments.id = importedOriginalReferences.installmentID
                 AND installments.workID = importedOriginalReferences.workID
                 AND installments.format = importedOriginalReferences.format
                JOIN libraryEntries ON libraryEntries.workID = works.id
                WHERE works.sourceID = ?
                ORDER BY importedOriginalReferences.workID,
                         importedOriginalReferences.installmentID
                """, arguments: [SourceID.local.rawValue])

            return try rows.map { row in
                let reference = try ImportedOriginalReferenceRecord(row: row).domainValue()
                guard let policy = CloudFilePolicy(rawValue: row["cloudFilePolicy"] as String) else {
                    throw MangoReaderDataError.invalidRecord(
                        table: LibraryEntryRecord.databaseTableName,
                        id: reference.workID.rawValue.uuidString
                    )
                }
                return ImportedOriginalDownloadCandidate(
                    reference: reference,
                    cloudFilePolicy: policy
                )
            }
        }
    }

    /// Attaches a verified downloaded original to its existing local
    /// installment. This intentionally updates one acquisition URL only; remote
    /// download rows, source requests, and credentials are never read or written.
    @discardableResult
    public func attachManagedImportedOriginal(
        _ reference: ImportedOriginalReference,
        fileURL: URL
    ) async throws -> Bool {
        guard
            reference.isValidForCloudSync,
            fileURL.isFileURL,
            fileURL.standardizedFileURL.lastPathComponent == reference.canonicalRelativePath
        else {
            throw MangoReaderDataError.unsafeManagedFileURL
        }
        return try await pool.write { db in
            guard try Self.hasMatchingLocalImportedOriginal(reference, in: db) else {
                throw MangoReaderDataError.missingImportedOriginalRelationship
            }
            try db.execute(
                sql: """
                    UPDATE installments
                    SET acquisitionURL = ?
                    WHERE id = ? AND workID = ? AND format = ?
                    """,
                arguments: [
                    fileURL.standardizedFileURL.absoluteString,
                    reference.installmentID.rawValue.uuidString,
                    reference.workID.rawValue.uuidString,
                    reference.format.rawValue,
                ]
            )
            return db.changesCount == 1
        }
    }

    private static func hasMatchingLocalImportedOriginal(
        _ reference: ImportedOriginalReference,
        in db: Database
    ) throws -> Bool {
        try Int.fetchOne(db, sql: """
            SELECT 1
            FROM installments
            JOIN works ON works.id = installments.workID
            JOIN libraryEntries ON libraryEntries.workID = works.id
            WHERE installments.id = ?
              AND installments.workID = ?
              AND installments.format = ?
              AND works.sourceID = ?
            LIMIT 1
            """, arguments: [
                reference.installmentID.rawValue.uuidString,
                reference.workID.rawValue.uuidString,
                reference.format.rawValue,
                SourceID.local.rawValue,
            ]) == 1
    }

    private static func merge(
        _ reference: ImportedOriginalReference,
        in db: Database
    ) throws {
        let merged: ImportedOriginalReference
        if let existing = try ImportedOriginalReferenceRecord
            .fetchOne(db, key: reference.installmentID.rawValue.uuidString)?
            .domainValue()
        {
            merged = existing.merging(reference)
        } else {
            merged = reference
        }
        try ImportedOriginalReferenceRecord(merged).save(db)
    }
}
