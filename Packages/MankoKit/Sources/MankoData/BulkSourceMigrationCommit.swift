import Foundation
import MankoDomain

public enum BulkSourceMigrationCommitLimits {
    public static let maximumWorks = 50
}

/// A source-migration preview reduced to the values the data layer needs for
/// an optimistic, transaction-safe commit.
public struct LibrarySourceMigrationCommit: Hashable, Sendable {
    public let expectedSourceID: SourceID
    public let expectedModifiedAt: Date
    public let proposedWork: Work
    public let proposedInstallments: [Installment]

    public init(
        expectedSourceID: SourceID,
        expectedModifiedAt: Date,
        proposedWork: Work,
        proposedInstallments: [Installment]
    ) {
        self.expectedSourceID = expectedSourceID
        self.expectedModifiedAt = expectedModifiedAt
        self.proposedWork = proposedWork
        self.proposedInstallments = proposedInstallments
    }
}

public struct BulkSourceMigrationCommitResult: Equatable, Sendable {
    public let updatedIDs: [WorkID]

    public init(updatedIDs: [WorkID]) {
        self.updatedIDs = updatedIDs
    }
}
