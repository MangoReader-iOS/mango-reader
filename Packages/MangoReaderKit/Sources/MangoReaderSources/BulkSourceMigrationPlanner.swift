import Foundation
import MangoReaderDomain

public struct BulkSourceMigrationRequest: Hashable, Sendable {
    public var existingWork: Work
    public var existingInstallments: [Installment]

    public init(existingWork: Work, existingInstallments: [Installment]) {
        self.existingWork = existingWork
        self.existingInstallments = existingInstallments
    }
}

public enum BulkSourceMigrationOutcome: Hashable, Sendable {
    case ready(targetWork: Work, plan: SourceMigrationPlan)
    case localSourceUnsupported
    case alreadyUsesDestination
    case noExactMatch
    case multipleExactMatches(Int)
    case duplicateDestinationMatch(Int)
    case ambiguousInstallments(Int)
    case failed
}

public struct BulkSourceMigrationPreviewItem: Hashable, Sendable, Identifiable {
    public var id: WorkID { existingWork.id }
    public var existingWork: Work
    public var outcome: BulkSourceMigrationOutcome

    public init(existingWork: Work, outcome: BulkSourceMigrationOutcome) {
        self.existingWork = existingWork
        self.outcome = outcome
    }
}

public struct BulkSourceMigrationPreview: Hashable, Sendable {
    public var destinationSourceID: SourceID
    public var items: [BulkSourceMigrationPreviewItem]

    public init(destinationSourceID: SourceID, items: [BulkSourceMigrationPreviewItem]) {
        self.destinationSourceID = destinationSourceID
        self.items = items
    }

    public var readyItems: [BulkSourceMigrationPreviewItem] {
        items.filter { item in
            if case .ready = item.outcome { return true }
            return false
        }
    }

    public var readyPlans: [SourceMigrationPlan] {
        items.compactMap { item in
            guard case let .ready(_, plan) = item.outcome else { return nil }
            return plan
        }
    }

    public var readyCount: Int { readyItems.count }
    public var skippedCount: Int { items.count - readyCount }
}

public enum BulkSourceMigrationPlanningError: Error, Equatable, Sendable, LocalizedError {
    case emptySelection
    case tooManyTitles(maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            "Select at least one title to migrate."
        case let .tooManyTitles(maximum):
            "Select no more than \(maximum) titles at once."
        }
    }
}

/// Builds a non-destructive, conservative migration preview for several titles.
///
/// Only a unique exact title or alternate-title match is eligible. The planner
/// bounds both concurrent source requests and pagination, and it reports every
/// uncertain title for per-title review instead of guessing.
public struct BulkSourceMigrationPlanner: Sendable {
    private let source: any ContentSource
    private let maximumConcurrentRequests: Int
    private let maximumSearchPages: Int
    private let maximumTitles: Int

    public init(
        source: any ContentSource,
        maximumConcurrentRequests: Int = 3,
        maximumSearchPages: Int = 3,
        maximumTitles: Int = 50
    ) {
        self.source = source
        self.maximumConcurrentRequests = max(1, maximumConcurrentRequests)
        self.maximumSearchPages = max(1, maximumSearchPages)
        self.maximumTitles = min(50, max(1, maximumTitles))
    }

    public func plan(
        _ requests: [BulkSourceMigrationRequest]
    ) async throws -> BulkSourceMigrationPreview {
        guard !requests.isEmpty else {
            throw BulkSourceMigrationPlanningError.emptySelection
        }
        guard requests.count <= maximumTitles else {
            throw BulkSourceMigrationPlanningError.tooManyTitles(maximum: maximumTitles)
        }

        try Task.checkCancellation()
        let destination = await source.descriptor
        try Task.checkCancellation()

        let items = try await withThrowingTaskGroup(
            of: (Int, BulkSourceMigrationPreviewItem).self,
            returning: [BulkSourceMigrationPreviewItem].self
        ) { group in
            var nextIndex = 0
            var results = Array<BulkSourceMigrationPreviewItem?>(
                repeating: nil,
                count: requests.count
            )

            while nextIndex < min(maximumConcurrentRequests, requests.count) {
                let index = nextIndex
                let request = requests[index]
                nextIndex += 1
                group.addTask { [source, destination, maximumSearchPages] in
                    let outcome = try await Self.planOne(
                        request,
                        destination: destination,
                        source: source,
                        maximumSearchPages: maximumSearchPages
                    )
                    return (
                        index,
                        BulkSourceMigrationPreviewItem(
                            existingWork: request.existingWork,
                            outcome: outcome
                        )
                    )
                }
            }

            while let (index, item) = try await group.next() {
                results[index] = item
                if nextIndex < requests.count {
                    let index = nextIndex
                    let request = requests[index]
                    nextIndex += 1
                    group.addTask { [source, destination, maximumSearchPages] in
                        let outcome = try await Self.planOne(
                            request,
                            destination: destination,
                            source: source,
                            maximumSearchPages: maximumSearchPages
                        )
                        return (
                            index,
                            BulkSourceMigrationPreviewItem(
                                existingWork: request.existingWork,
                                outcome: outcome
                            )
                        )
                    }
                }
            }

            return results.compactMap { $0 }
        }

        try Task.checkCancellation()
        let collisionSafeItems = Self.markDuplicateDestinationMatches(in: items)
        return BulkSourceMigrationPreview(
            destinationSourceID: destination.id,
            items: collisionSafeItems
        )
    }

    /// A batch must never migrate two local library identities onto the same
    /// remote publication. Mark every participant in such a collision so the
    /// caller can direct them to explicit per-title review.
    private static func markDuplicateDestinationMatches(
        in items: [BulkSourceMigrationPreviewItem]
    ) -> [BulkSourceMigrationPreviewItem] {
        var indexesByDestination: [DestinationPublicationIdentity: [Int]] = [:]
        for (index, item) in items.enumerated() {
            guard
                case let .ready(_, plan) = item.outcome,
                let remoteID = nonemptyRemoteID(plan.proposedWork.remoteID)
            else { continue }

            let identity = DestinationPublicationIdentity(
                sourceID: plan.proposedWork.sourceID,
                remoteID: remoteID
            )
            indexesByDestination[identity, default: []].append(index)
        }

        var result = items
        for indexes in indexesByDestination.values where indexes.count > 1 {
            for index in indexes {
                result[index].outcome = .duplicateDestinationMatch(indexes.count)
            }
        }
        return result
    }

    private static func planOne(
        _ request: BulkSourceMigrationRequest,
        destination: SourceDescriptor,
        source: any ContentSource,
        maximumSearchPages: Int
    ) async throws -> BulkSourceMigrationOutcome {
        try Task.checkCancellation()
        let existing = request.existingWork

        guard existing.sourceID != .local, destination.kind != .local else {
            return .localSourceUnsupported
        }
        guard existing.sourceID != destination.id else {
            return .alreadyUsesDestination
        }

        do {
            let candidates = try await exactCandidates(
                for: existing,
                destinationSourceID: destination.id,
                source: source,
                maximumSearchPages: maximumSearchPages
            )
            try Task.checkCancellation()

            guard !candidates.isEmpty else { return .noExactMatch }
            guard candidates.count == 1, let target = candidates.first else {
                return .multipleExactMatches(candidates.count)
            }

            let plan = try await RemoteLibraryPlanner(source: source).planMigration(
                existingWork: existing,
                existingInstallments: request.existingInstallments,
                targetWork: target
            )
            try Task.checkCancellation()

            guard
                plan.proposedWork.sourceID == destination.id,
                plan.proposedWork.kind == existing.kind,
                nonemptyRemoteID(plan.proposedWork.remoteID) != nil
            else { return .failed }

            guard plan.ambiguousMatches.isEmpty else {
                return .ambiguousInstallments(plan.ambiguousMatches.count)
            }
            return .ready(targetWork: target, plan: plan)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return .failed
        }
    }

    private static func exactCandidates(
        for existing: Work,
        destinationSourceID: SourceID,
        source: any ContentSource,
        maximumSearchPages: Int
    ) async throws -> [Work] {
        var candidates: [Work] = []
        var candidateKeys: Set<String> = []
        var visitedPages: Set<Int> = []
        var page = 1
        var fetchedPages = 0
        let existingTitles = normalizedTitles(of: existing)

        while fetchedPages < maximumSearchPages {
            try Task.checkCancellation()
            guard page > 0, visitedPages.insert(page).inserted else {
                throw BulkSourceMigrationSearchError.paginationCycle
            }

            let response = try await source.search(SourceQuery(
                text: existing.title,
                page: page,
                pageSize: 40,
                kinds: [existing.kind]
            ))
            try Task.checkCancellation()
            fetchedPages += 1

            for candidate in response.items {
                guard
                    candidate.sourceID == destinationSourceID,
                    candidate.kind == existing.kind,
                    let remoteID = nonemptyRemoteID(candidate.remoteID),
                    !normalizedTitles(of: candidate).isDisjoint(with: existingTitles)
                else { continue }

                let key = "\(candidate.sourceID.rawValue)|\(remoteID)"
                if candidateKeys.insert(key).inserted {
                    candidates.append(candidate)
                }
            }

            guard let nextPage = response.nextPage else { break }
            guard nextPage > 0, !visitedPages.contains(nextPage) else {
                throw BulkSourceMigrationSearchError.paginationCycle
            }
            guard fetchedPages < maximumSearchPages else { break }
            page = nextPage
        }

        return candidates
    }

    private static func normalizedTitles(of work: Work) -> Set<String> {
        Set(([work.title] + work.alternativeTitles).compactMap { title in
            let normalized = title.mangoReaderSearchNormalized
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return normalized.isEmpty ? nil : normalized
        })
    }

    private static func nonemptyRemoteID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum BulkSourceMigrationSearchError: Error {
    case paginationCycle
}

private struct DestinationPublicationIdentity: Hashable {
    let sourceID: SourceID
    let remoteID: String
}
