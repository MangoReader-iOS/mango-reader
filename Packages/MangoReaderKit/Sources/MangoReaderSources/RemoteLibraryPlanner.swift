import Foundation
import MangoReaderDomain

public enum RemoteLibraryPlannerError: Error, Equatable, Sendable, LocalizedError {
    case missingRemoteWorkID
    case paginationCycle(page: Int)
    case duplicateRemoteInstallmentID(String)

    public var errorDescription: String? {
        switch self {
        case .missingRemoteWorkID:
            "The publication does not have a remote source identifier."
        case let .paginationCycle(page):
            "The source repeated installment page \(page)."
        case let .duplicateRemoteInstallmentID(identifier):
            "The source returned duplicate installment identifier \(identifier)."
        }
    }
}

public struct RemoteLibrarySnapshot: Codable, Hashable, Sendable {
    public var work: Work
    public var installments: [Installment]

    public init(work: Work, installments: [Installment]) {
        self.work = work
        self.installments = installments
    }
}

public struct ChangedRemoteInstallment: Hashable, Sendable {
    public var previous: Installment
    public var proposed: Installment

    public init(previous: Installment, proposed: Installment) {
        self.previous = previous
        self.proposed = proposed
    }
}

/// A non-destructive preview of the latest state reported by one source.
/// `proposedInstallments` retains local-only and remotely removed installments;
/// `removedInstallments` reports the latter for review without deleting them.
public struct RemoteLibraryUpdatePlan: Hashable, Sendable {
    public var proposedWork: Work
    public var proposedInstallments: [Installment]
    public var newlyAvailableInstallments: [Installment]
    public var changedInstallments: [ChangedRemoteInstallment]
    public var removedInstallments: [Installment]
    public var workMetadataChanged: Bool

    public init(
        proposedWork: Work,
        proposedInstallments: [Installment],
        newlyAvailableInstallments: [Installment],
        changedInstallments: [ChangedRemoteInstallment],
        removedInstallments: [Installment],
        workMetadataChanged: Bool
    ) {
        self.proposedWork = proposedWork
        self.proposedInstallments = proposedInstallments
        self.newlyAvailableInstallments = newlyAvailableInstallments
        self.changedInstallments = changedInstallments
        self.removedInstallments = removedInstallments
        self.workMetadataChanged = workMetadataChanged
    }
}

public enum InstallmentMigrationMatchBasis: String, Hashable, Sendable {
    case remoteID
    case volumeNumberAndTitle
}

public struct InstallmentMigrationMatch: Hashable, Sendable {
    public var existing: Installment
    public var target: Installment
    public var proposed: Installment
    public var basis: InstallmentMigrationMatchBasis

    public init(
        existing: Installment,
        target: Installment,
        proposed: Installment,
        basis: InstallmentMigrationMatchBasis
    ) {
        self.existing = existing
        self.target = target
        self.proposed = proposed
        self.basis = basis
    }
}

public struct AmbiguousInstallmentMigration: Hashable, Sendable {
    public var existing: Installment
    public var candidates: [Installment]
    public var basis: InstallmentMigrationMatchBasis

    public init(
        existing: Installment,
        candidates: [Installment],
        basis: InstallmentMigrationMatchBasis
    ) {
        self.existing = existing
        self.candidates = candidates
        self.basis = basis
    }
}

/// A conservative source-migration preview. Ambiguous and unmatched entries
/// require explicit caller/user resolution and are never silently paired.
public struct SourceMigrationPlan: Hashable, Sendable {
    public var proposedWork: Work
    public var proposedInstallments: [Installment]
    public var matches: [InstallmentMigrationMatch]
    public var ambiguousMatches: [AmbiguousInstallmentMigration]
    public var unmatchedExistingInstallments: [Installment]
    public var unmatchedTargetInstallments: [Installment]

    public init(
        proposedWork: Work,
        proposedInstallments: [Installment],
        matches: [InstallmentMigrationMatch],
        ambiguousMatches: [AmbiguousInstallmentMigration],
        unmatchedExistingInstallments: [Installment],
        unmatchedTargetInstallments: [Installment]
    ) {
        self.proposedWork = proposedWork
        self.proposedInstallments = proposedInstallments
        self.matches = matches
        self.ambiguousMatches = ambiguousMatches
        self.unmatchedExistingInstallments = unmatchedExistingInstallments
        self.unmatchedTargetInstallments = unmatchedTargetInstallments
    }
}

/// Fetches and plans remote library changes without mutating persistence.
/// The injected `ContentSource` owns transport/authentication behavior while
/// this Sendable value owns deterministic pagination and reconciliation logic.
public struct RemoteLibraryPlanner: Sendable {
    private let source: any ContentSource

    public init(source: any ContentSource) {
        self.source = source
    }

    public func fetchLatest(for work: Work) async throws -> RemoteLibrarySnapshot {
        try Task.checkCancellation()
        guard let remoteID = Self.nonemptyRemoteID(work.remoteID) else {
            throw RemoteLibraryPlannerError.missingRemoteWorkID
        }

        let details = try await source.details(for: remoteID)
        try Task.checkCancellation()

        var page = 1
        var visitedPages: Set<Int> = []
        var installments: [Installment] = []
        while true {
            try Task.checkCancellation()
            guard visitedPages.insert(page).inserted else {
                throw RemoteLibraryPlannerError.paginationCycle(page: page)
            }
            let response = try await source.installments(for: details, page: page)
            try Task.checkCancellation()
            installments.append(contentsOf: response.items)
            guard let nextPage = response.nextPage else { break }
            page = nextPage
        }

        try Self.validateUniqueRemoteIDs(installments)
        return RemoteLibrarySnapshot(work: details, installments: installments)
    }

    public func planUpdate(
        existingWork: Work,
        existingInstallments: [Installment]
    ) async throws -> RemoteLibraryUpdatePlan {
        let snapshot = try await fetchLatest(for: existingWork)
        try Task.checkCancellation()
        try Self.validateUniqueRemoteIDs(existingInstallments)

        let proposedWork = Self.proposedWork(from: snapshot.work, preserving: existingWork)
        let existingByRemoteID = Dictionary(
            uniqueKeysWithValues: existingInstallments.compactMap { installment in
                Self.nonemptyRemoteID(installment.remoteID).map { ($0, installment) }
            }
        )
        let remoteIDs = Set(snapshot.installments.compactMap { Self.nonemptyRemoteID($0.remoteID) })

        var updatesByExistingID: [InstallmentID: Installment] = [:]
        var newlyAvailable: [Installment] = []
        var changed: [ChangedRemoteInstallment] = []
        for remote in snapshot.installments {
            try Task.checkCancellation()
            if
                let remoteID = Self.nonemptyRemoteID(remote.remoteID),
                let existing = existingByRemoteID[remoteID]
            {
                let proposed = Self.proposedInstallment(
                    from: remote,
                    preserving: existing,
                    workID: existingWork.id
                )
                updatesByExistingID[existing.id] = proposed
                if Self.remoteMetadataDiffers(existing, remote) {
                    changed.append(ChangedRemoteInstallment(previous: existing, proposed: proposed))
                }
            } else {
                var proposed = remote
                proposed.workID = existingWork.id
                newlyAvailable.append(proposed)
            }
        }

        let proposedInstallments = existingInstallments.map { existing in
            updatesByExistingID[existing.id] ?? existing
        } + newlyAvailable

        let removed = existingInstallments.filter { installment in
            guard let remoteID = Self.nonemptyRemoteID(installment.remoteID) else { return false }
            return !remoteIDs.contains(remoteID)
        }

        return RemoteLibraryUpdatePlan(
            proposedWork: proposedWork,
            proposedInstallments: proposedInstallments,
            newlyAvailableInstallments: newlyAvailable,
            changedInstallments: changed,
            removedInstallments: removed,
            workMetadataChanged: Self.remoteWorkMetadataDiffers(existingWork, snapshot.work)
        )
    }

    public func planMigration(
        existingWork: Work,
        existingInstallments: [Installment],
        targetWork: Work
    ) async throws -> SourceMigrationPlan {
        let snapshot = try await fetchLatest(for: targetWork)
        try Task.checkCancellation()

        let result = try Self.matchForMigration(
            existing: existingInstallments,
            targets: snapshot.installments,
            destinationWorkID: existingWork.id
        )
        let proposedWork = Self.proposedWork(from: snapshot.work, preserving: existingWork)
        let proposedByTargetID = Dictionary(
            uniqueKeysWithValues: result.matches.map { ($0.target.id, $0.proposed) }
        )
        let proposedInstallments = snapshot.installments.map { target in
            if let matched = proposedByTargetID[target.id] { return matched }
            var proposed = target
            proposed.workID = existingWork.id
            return proposed
        }

        return SourceMigrationPlan(
            proposedWork: proposedWork,
            proposedInstallments: proposedInstallments,
            matches: result.matches,
            ambiguousMatches: result.ambiguous,
            unmatchedExistingInstallments: result.unmatchedExisting,
            unmatchedTargetInstallments: result.unmatchedTargets
        )
    }

    private static func matchForMigration(
        existing: [Installment],
        targets: [Installment],
        destinationWorkID: WorkID
    ) throws -> (
        matches: [InstallmentMigrationMatch],
        ambiguous: [AmbiguousInstallmentMigration],
        unmatchedExisting: [Installment],
        unmatchedTargets: [Installment]
    ) {
        var matchedExisting: Set<InstallmentID> = []
        var matchedTargets: Set<InstallmentID> = []
        var ambiguousExisting: Set<InstallmentID> = []
        var ambiguousTargets: Set<InstallmentID> = []
        var matches: [InstallmentMigrationMatch] = []
        var ambiguities: [AmbiguousInstallmentMigration] = []

        var existingRemoteGroups: [String: [Installment]] = [:]
        for installment in existing {
            if let remoteID = Self.nonemptyRemoteID(installment.remoteID) {
                existingRemoteGroups[remoteID, default: []].append(installment)
            }
        }
        var targetRemoteGroups: [String: [Installment]] = [:]
        for installment in targets {
            if let remoteID = Self.nonemptyRemoteID(installment.remoteID) {
                targetRemoteGroups[remoteID, default: []].append(installment)
            }
        }
        for remoteID in existingRemoteGroups.keys.sorted() {
            try Task.checkCancellation()
            guard
                let existingGroup = existingRemoteGroups[remoteID],
                let targetGroup = targetRemoteGroups[remoteID],
                !targetGroup.isEmpty
            else { continue }

            if existingGroup.count == 1, targetGroup.count == 1,
               let existingItem = existingGroup.first,
               let targetItem = targetGroup.first
            {
                let proposed = Self.proposedInstallment(
                    from: targetItem,
                    preserving: existingItem,
                    workID: destinationWorkID
                )
                matches.append(InstallmentMigrationMatch(
                    existing: existingItem,
                    target: targetItem,
                    proposed: proposed,
                    basis: .remoteID
                ))
                matchedExisting.insert(existingItem.id)
                matchedTargets.insert(targetItem.id)
            } else {
                for existingItem in existingGroup {
                    ambiguities.append(AmbiguousInstallmentMigration(
                        existing: existingItem,
                        candidates: targetGroup,
                        basis: .remoteID
                    ))
                    ambiguousExisting.insert(existingItem.id)
                }
                ambiguousTargets.formUnion(targetGroup.map(\.id))
            }
        }

        let remainingExisting = existing.filter {
            !matchedExisting.contains($0.id) && !ambiguousExisting.contains($0.id)
        }
        let remainingTargets = targets.filter {
            !matchedTargets.contains($0.id) && !ambiguousTargets.contains($0.id)
        }
        var existingSignatureGroups: [MigrationSignature: [Installment]] = [:]
        for installment in remainingExisting {
            if let signature = MigrationSignature(installment: installment) {
                existingSignatureGroups[signature, default: []].append(installment)
            }
        }
        var targetSignatureGroups: [MigrationSignature: [Installment]] = [:]
        for installment in remainingTargets {
            if let signature = MigrationSignature(installment: installment) {
                targetSignatureGroups[signature, default: []].append(installment)
            }
        }

        for signature in existingSignatureGroups.keys.sorted() {
            try Task.checkCancellation()
            guard
                let existingGroup = existingSignatureGroups[signature],
                let targetGroup = targetSignatureGroups[signature],
                !targetGroup.isEmpty
            else { continue }

            if existingGroup.count == 1, targetGroup.count == 1,
               let existingItem = existingGroup.first,
               let targetItem = targetGroup.first
            {
                let proposed = Self.proposedInstallment(
                    from: targetItem,
                    preserving: existingItem,
                    workID: destinationWorkID
                )
                matches.append(InstallmentMigrationMatch(
                    existing: existingItem,
                    target: targetItem,
                    proposed: proposed,
                    basis: .volumeNumberAndTitle
                ))
                matchedExisting.insert(existingItem.id)
                matchedTargets.insert(targetItem.id)
            } else {
                for existingItem in existingGroup {
                    ambiguities.append(AmbiguousInstallmentMigration(
                        existing: existingItem,
                        candidates: targetGroup,
                        basis: .volumeNumberAndTitle
                    ))
                    ambiguousExisting.insert(existingItem.id)
                }
                ambiguousTargets.formUnion(targetGroup.map(\.id))
            }
        }

        return (
            matches: existing.compactMap { item in
                matches.first { $0.existing.id == item.id }
            },
            ambiguous: existing.compactMap { item in
                ambiguities.first { $0.existing.id == item.id }
            },
            unmatchedExisting: existing.filter {
                !matchedExisting.contains($0.id) && !ambiguousExisting.contains($0.id)
            },
            unmatchedTargets: targets.filter { target in
                !matchedTargets.contains(target.id)
                    && !ambiguousTargets.contains(target.id)
            }
        )
    }

    private static func proposedWork(from remote: Work, preserving existing: Work) -> Work {
        var proposed = remote
        proposed.id = existing.id
        proposed.customCoverPath = existing.customCoverPath
        proposed.createdAt = existing.createdAt
        return proposed
    }

    private static func proposedInstallment(
        from remote: Installment,
        preserving existing: Installment,
        workID: WorkID
    ) -> Installment {
        var proposed = remote
        proposed.id = existing.id
        proposed.workID = workID
        if existing.acquisitionURL?.isFileURL == true || proposed.acquisitionURL == nil {
            proposed.acquisitionURL = existing.acquisitionURL
        }
        return proposed
    }

    private static func remoteMetadataDiffers(_ existing: Installment, _ remote: Installment) -> Bool {
        existing.remoteID != remote.remoteID
            || existing.title != remote.title
            || existing.volume != remote.volume
            || existing.number != remote.number
            || existing.publishedAt != remote.publishedAt
            || existing.languageCode != remote.languageCode
            || existing.format != remote.format
            || existing.pageCount != remote.pageCount
    }

    private static func remoteWorkMetadataDiffers(_ existing: Work, _ remote: Work) -> Bool {
        existing.sourceID != remote.sourceID
            || existing.remoteID != remote.remoteID
            || existing.title != remote.title
            || existing.alternativeTitles != remote.alternativeTitles
            || existing.authors != remote.authors
            || existing.summary != remote.summary
            || existing.tags != remote.tags
            || existing.searchFacets != remote.searchFacets
            || existing.languageCode != remote.languageCode
            || existing.kind != remote.kind
            || existing.status != remote.status
            || existing.coverURL != remote.coverURL
    }

    private static func validateUniqueRemoteIDs(_ installments: [Installment]) throws {
        var identifiers: Set<String> = []
        for installment in installments {
            guard let remoteID = nonemptyRemoteID(installment.remoteID) else { continue }
            guard identifiers.insert(remoteID).inserted else {
                throw RemoteLibraryPlannerError.duplicateRemoteInstallmentID(remoteID)
            }
        }
    }

    private static func nonemptyRemoteID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct MigrationSignature: Hashable, Comparable, Sendable {
    let volume: Double?
    let number: Double?
    let normalizedTitle: String

    init?(installment: Installment) {
        let normalizedTitle = Self.normalizeTitle(installment.title)
        guard
            !normalizedTitle.isEmpty,
            installment.volume != nil || installment.number != nil
        else { return nil }
        volume = installment.volume.map { $0 == 0 ? 0 : $0 }
        number = installment.number.map { $0 == 0 ? 0 : $0 }
        self.normalizedTitle = normalizedTitle
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let lhsValue = "\(lhs.volume.map { String($0) } ?? "-")|\(lhs.number.map { String($0) } ?? "-")|\(lhs.normalizedTitle)"
        let rhsValue = "\(rhs.volume.map { String($0) } ?? "-")|\(rhs.number.map { String($0) } ?? "-")|\(rhs.normalizedTitle)"
        return lhsValue < rhsValue
    }

    private static func normalizeTitle(_ title: String) -> String {
        let normalized = title.mangoReaderSearchNormalized
        return normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
