import Foundation
import GRDB
import MankoDomain

private struct SourceMigrationDestinationIdentity: Hashable, Sendable {
    let sourceID: SourceID
    let remoteID: String
}

extension MankoDatabase {
    /// Applies a validated metadata patch to every available work in one GRDB
    /// transaction. Missing identifiers are reported rather than inserted, and
    /// related library, reader, installment, and file records are not touched.
    public func applyBulkMetadataPatch(
        _ patch: BulkWorkMetadataPatch,
        to workIDs: Set<WorkID>
    ) async throws -> BulkMetadataUpdateResult {
        guard !workIDs.isEmpty else {
            throw MankoDataError.emptyBulkMetadataSelection
        }

        let orderedIDs = workIDs.sorted {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }
        let modifiedAt = Date.now
        let failureInjector = bulkMetadataUpdateFailureInjector

        return try await pool.write { db in
            var assignments: [String] = []
            var baseArguments: StatementArguments = []
            if case let .set(value) = patch.contentKind {
                assignments.append("kind = ?")
                baseArguments += [value.rawValue]
            }
            if case let .set(value) = patch.workStatus {
                assignments.append("status = ?")
                baseArguments += [value.rawValue]
            }
            if case let .set(value) = patch.authors {
                assignments.append("authors = ?")
                assignments.append("normalizedAuthors = ?")
                baseArguments += [
                    try DataCoding.encode(value),
                    value.map(\.mankoSearchNormalized).joined(separator: " "),
                ]
            }
            if case let .set(value) = patch.tags {
                assignments.append("tags = ?")
                assignments.append("normalizedTags = ?")
                baseArguments += [
                    try DataCoding.encode(value),
                    value.map(\.mankoSearchNormalized).joined(separator: " "),
                ]
            }
            assignments.append("modifiedAt = ?")
            baseArguments += [modifiedAt.timeIntervalSince1970]

            let updateStatement = try db.makeStatement(sql: """
                UPDATE works
                SET \(assignments.joined(separator: ", "))
                WHERE id = ?
                """)
            let existenceStatement = try db.makeStatement(
                sql: "SELECT 1 FROM works WHERE id = ? LIMIT 1"
            )
            var updatedIDs: [WorkID] = []
            var missingIDs: [WorkID] = []
            updatedIDs.reserveCapacity(orderedIDs.count)

            for workID in orderedIDs {
                let identifier = workID.rawValue.uuidString
                guard try Int.fetchOne(
                    existenceStatement,
                    arguments: [identifier]
                ) == 1 else {
                    missingIDs.append(workID)
                    continue
                }
                try failureInjector?(.beforeUpdate(index: updatedIDs.count, workID: workID))
                var arguments = baseArguments
                arguments += [identifier]
                try updateStatement.execute(arguments: arguments)
                updatedIDs.append(workID)
            }

            return BulkMetadataUpdateResult(
                updatedIDs: updatedIDs,
                missingIDs: missingIDs
            )
        }
    }

    /// Atomically applies a reviewed batch of remote source migrations.
    ///
    /// Every current work and library entry is preflighted before the first
    /// mutation. The expected source ID protects against applying a stale
    /// preview, while omitted installments are intentionally retained so local
    /// files and unmatched history remain available.
    public func applySourceMigrations(
        _ commits: [LibrarySourceMigrationCommit]
    ) async throws -> BulkSourceMigrationCommitResult {
        guard !commits.isEmpty else {
            throw MankoDataError.emptySourceMigrationBatch
        }
        guard commits.count <= BulkSourceMigrationCommitLimits.maximumWorks else {
            throw MankoDataError.sourceMigrationBatchTooLarge(
                maximum: BulkSourceMigrationCommitLimits.maximumWorks
            )
        }

        let orderedCommits = commits.sorted {
            $0.proposedWork.id.rawValue.uuidString < $1.proposedWork.id.rawValue.uuidString
        }
        guard Set(orderedCommits.map(\.proposedWork.id)).count == orderedCommits.count else {
            throw MankoDataError.duplicateSourceMigrationWork
        }

        var proposedInstallmentIDs: Set<InstallmentID> = []
        var proposedDestinationIdentities: Set<SourceMigrationDestinationIdentity> = []
        proposedInstallmentIDs.reserveCapacity(
            orderedCommits.reduce(into: 0) { $0 += $1.proposedInstallments.count }
        )
        proposedDestinationIdentities.reserveCapacity(orderedCommits.count)
        for commit in orderedCommits {
            let proposedWork = commit.proposedWork
            let proposedSource = proposedWork.sourceID.rawValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let proposedRemoteID = proposedWork.remoteID?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let expectedSource = commit.expectedSourceID.rawValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard
                !expectedSource.isEmpty,
                commit.expectedSourceID != .local,
                commit.expectedModifiedAt.timeIntervalSinceReferenceDate.isFinite,
                !proposedSource.isEmpty,
                proposedWork.sourceID != .local,
                proposedWork.sourceID != commit.expectedSourceID,
                let proposedRemoteID,
                !proposedRemoteID.isEmpty,
                commit.proposedInstallments.allSatisfy({ $0.workID == proposedWork.id })
            else {
                throw MankoDataError.invalidSourceMigration
            }
            guard proposedDestinationIdentities.insert(
                SourceMigrationDestinationIdentity(
                    sourceID: proposedWork.sourceID,
                    remoteID: proposedRemoteID
                )
            ).inserted else {
                throw MankoDataError.invalidSourceMigration
            }
            for installment in commit.proposedInstallments {
                guard proposedInstallmentIDs.insert(installment.id).inserted else {
                    throw MankoDataError.invalidSourceMigration
                }
            }
        }

        let preparedCommits = try orderedCommits.map { commit in
            (
                commit: commit,
                workRecord: try WorkRecord(commit.proposedWork),
                installmentRecords: commit.proposedInstallments.map(InstallmentRecord.init)
            )
        }
        let failureInjector = bulkSourceMigrationUpdateFailureInjector
        let batchWorkIdentifiers = Set(
            preparedCommits.map { $0.commit.proposedWork.id.rawValue.uuidString }
        )

        return try await pool.write { db in
            // Preflight the whole batch before the first write. This makes a
            // stale item fail the batch without relying on transaction rollback.
            for prepared in preparedCommits {
                let commit = prepared.commit
                let identifier = commit.proposedWork.id.rawValue.uuidString
                guard
                    let currentWork = try WorkRecord.fetchOne(db, key: identifier),
                    try LibraryEntryRecord
                        .filter(Column("workID") == identifier)
                        .fetchOne(db) != nil
                else {
                    throw MankoDataError.missingSourceMigrationWork
                }
                guard
                    currentWork.sourceID == commit.expectedSourceID.rawValue,
                    currentWork.modifiedAt == commit.expectedModifiedAt.timeIntervalSince1970
                else {
                    throw MankoDataError.staleSourceMigrationPreview
                }

                guard let destinationRemoteID = commit.proposedWork.remoteID?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ) else {
                    throw MankoDataError.invalidSourceMigration
                }
                let destinationOwners = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT works.id, works.remoteID
                        FROM works
                        JOIN libraryEntries ON libraryEntries.workID = works.id
                        WHERE works.sourceID = ? AND works.remoteID IS NOT NULL
                        """,
                    arguments: [commit.proposedWork.sourceID.rawValue]
                )
                for owner in destinationOwners {
                    let ownerID: String = owner["id"]
                    let ownerRemoteID: String = owner["remoteID"]
                    if ownerRemoteID.trimmingCharacters(in: .whitespacesAndNewlines)
                        == destinationRemoteID,
                       ownerID != identifier,
                       !batchWorkIdentifiers.contains(ownerID) {
                        throw MankoDataError.invalidSourceMigration
                    }
                }

                for installmentRecord in prepared.installmentRecords {
                    if let existing = try InstallmentRecord.fetchOne(db, key: installmentRecord.id),
                       existing.workID != installmentRecord.workID {
                        throw MankoDataError.invalidSourceMigration
                    }
                }
            }

            for (index, prepared) in preparedCommits.enumerated() {
                let workID = prepared.commit.proposedWork.id
                try failureInjector?(.beforeUpdate(index: index, workID: workID))
                try prepared.workRecord.save(db)
                for installmentRecord in prepared.installmentRecords {
                    try installmentRecord.save(db)
                }
            }

            return BulkSourceMigrationCommitResult(
                updatedIDs: preparedCommits.map { $0.commit.proposedWork.id }
            )
        }
    }
}
