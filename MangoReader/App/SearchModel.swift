import Foundation
import ImageIO
import MangoReaderData
import MangoReaderDomain
import MangoReaderExtensions
import MangoReaderReaders
import MangoReaderSources
import MangoReaderSync
import Observation
import OSLog
import SwiftUI
import WebKit

@MainActor
@Observable
final class SearchModel {
    @ObservationIgnored var database: MangoReaderDatabase?
    let sourcesModel: SourcesModel

    init(
        database: MangoReaderDatabase?,
        sourcesModel: SourcesModel
    ) {
        self.database = database
        self.sourcesModel = sourcesModel
    }

    var searchResults: [Work] = []

    var searchState: SearchState = .initial

    var searchSourceOrder: [SourceID] = []

    var searchSourceNames: [SourceID: String] = [:]

    var searchSourcePhases: [SourceID: SearchSourcePhase] = [:]

    var isVerifyingSearchSources = false

    var isSearching = false

    var searchText = ""

    @ObservationIgnored var searchSourcePageLoaderForTesting: (@MainActor @Sendable (SourceDescriptor, String) async throws -> SourcePage<Work>)?

    var searchTask: Task<Void, Never>?

    var searchVerificationTask: Task<Void, Never>?

    var searchGeneration: UUID?

    @ObservationIgnored private var retryTasks: [SourceID: Task<Void, Never>] = [:]
    @ObservationIgnored private var retryIDs: [SourceID: UUID] = [:]
    @ObservationIgnored private var interruptedSources: Set<SourceID> = []
    @ObservationIgnored private var verificationSourceID: SourceID?
    private var isBackgrounded = false
    @ObservationIgnored var searchDebounce: @MainActor @Sendable () async throws -> Void = {
        try await Task.sleep(for: .milliseconds(180))
    }

    func updateScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            guard !isBackgrounded else { return }
            isBackgrounded = true
            interruptedSources = Set(searchSourcePhases.compactMap { $0.value == .loading ? $0.key : nil })
            if let verificationSourceID { interruptedSources.insert(verificationSourceID) }
            cancelSearchWork()
        case .active:
            guard isBackgrounded else { return }
            isBackgrounded = false
            let pending = interruptedSources
            interruptedSources = []
            if !pending.isEmpty {
                startSearch(searchText, resuming: pending)
            } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Completed failures/challenges still need working Retry/Verify
                // actions after a return, without automatically repeating them.
                searchGeneration = UUID()
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    /// Private-library locking must never replay a private query after unlock.
    func discardPendingSearch() {
        interruptedSources = []
        cancelSearchWork()
    }

    private func cancelSearchWork() {
        // Ownership changes synchronously before cancellation callbacks run.
        searchGeneration = nil
        searchTask?.cancel()
        searchTask = nil
        searchVerificationTask?.cancel()
        searchVerificationTask = nil
        for task in retryTasks.values { task.cancel() }
        retryTasks = [:]
        retryIDs = [:]
        verificationSourceID = nil
        isSearching = false
        isVerifyingSearchSources = false
    }

    func search(_ text: String) {
        interruptedSources = []
        startSearch(text, resuming: nil)
    }

    private func startSearch(_ text: String, resuming sourceIDs: Set<SourceID>?) {
        let previousQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchText = text
        cancelSearchWork()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchGeneration = nil
            searchResults = []
            searchSourceOrder = []
            searchSourceNames = [:]
            searchSourcePhases = [:]
            isSearching = false
            searchState = .initial
            searchTask = nil
            return
        }

        let generation = UUID()
        searchGeneration = generation
        // Keep same-query results visible while a retry or metadata refresh
        // checks remote sources again. A genuinely new query must never show
        // stale results from the previous search.
        if query != previousQuery {
            searchResults = []
        }
        if let sourceIDs {
            let available = Set(sourcesModel.sources.filter(\.isEnabled).map(\.id)).union([.local])
            for id in sourceIDs { searchSourcePhases[id] = available.contains(id) ? .loading : .empty }
        } else {
            prepareSearchSources()
        }
        if isBackgrounded {
            interruptedSources = sourceIDs ?? Set(searchSourceOrder)
            return
        }
        isSearching = true
        searchState = .searching
        searchTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if searchGeneration == generation {
                    isSearching = false
                    searchTask = nil
                }
            }

            do {
                if sourceIDs == nil { try await searchDebounce() }
                guard !Task.isCancelled, searchGeneration == generation else { return }

                if sourceIDs?.contains(.local) ?? true {
                    if let database {
                        do {
                            let localResults = try await database.search(query, limit: 100)
                            guard !Task.isCancelled, searchGeneration == generation else { return }
                            if sourceIDs == nil { searchResults = localResults }
                            else { mergeSearchResults(localResults) }
                            searchSourcePhases[.local] = localResults.contains(where: { $0.sourceID == .local })
                                ? .results(hasMore: localResults.count >= 100)
                                : .empty
                        } catch is CancellationError {
                            return
                        } catch {
                            guard !Task.isCancelled, searchGeneration == generation else { return }
                            searchSourcePhases[.local] = .failed(
                                SearchSourceFailure(
                                    id: SourceID.local.rawValue,
                                    sourceName: "Library",
                                    message: error.localizedDescription
                                )
                            )
                        }
                    } else {
                        searchSourcePhases[.local] = .failed(
                            SearchSourceFailure(
                                id: SourceID.local.rawValue,
                                sourceName: "Library",
                                message: WorkDetailLoadError.storageUnavailable.localizedDescription
                            )
                        )
                    }
                }
                updateSearchState()

                await withTaskGroup(of: RemoteSearchOutcome.self) { group in
                    for descriptor in sourcesModel.sources where descriptor.isEnabled && (sourceIDs?.contains(descriptor.id) ?? true) {
                        group.addTask { [weak self] in
                            guard let self else {
                                return .failure(
                                    sourceID: descriptor.id,
                                    failure: SearchSourceFailure(
                                        id: descriptor.id.rawValue,
                                        sourceName: descriptor.name,
                                        message: "Search was cancelled."
                                    )
                                )
                            }
                            do {
                                let page = try await self.searchRemoteSource(
                                    descriptor,
                                    query: query
                                )
                                return .success(sourceID: descriptor.id, page: page)
                            } catch is CancellationError {
                                return .failure(
                                    sourceID: descriptor.id,
                                    failure: SearchSourceFailure(
                                        id: descriptor.id.rawValue,
                                        sourceName: descriptor.name,
                                        message: "Search was cancelled."
                                    )
                                )
                            } catch {
                                if Self.isCloudflareChallenge(error) {
                                    return .verificationRequired(sourceID: descriptor.id)
                                }
                                return .failure(
                                    sourceID: descriptor.id,
                                    failure: SearchSourceFailure(
                                        id: descriptor.id.rawValue,
                                        sourceName: descriptor.name,
                                        message: error.localizedDescription
                                    )
                                )
                            }
                        }
                    }

                    for await outcome in group {
                        guard !Task.isCancelled, searchGeneration == generation else {
                            group.cancelAll()
                            return
                        }
                        switch outcome {
                        case let .success(sourceID, page):
                            mergeSearchResults(page.items)
                            searchSourcePhases[sourceID] = page.items.isEmpty
                                ? .empty
                                : .results(hasMore: page.nextPage != nil || page.nextCursor != nil)
                        case let .verificationRequired(sourceID):
                            searchSourcePhases[sourceID] = .verificationRequired
                        case let .failure(sourceID, failure):
                            searchSourcePhases[sourceID] = .failed(failure)
                        }
                        updateSearchState()
                    }
                }

                guard !Task.isCancelled, searchGeneration == generation else { return }
                updateSearchState()
            } catch is CancellationError {
                return
            } catch {
                guard searchGeneration == generation else { return }
                searchState = .failed([
                    SearchSourceFailure(
                        id: "search",
                        sourceName: "Search",
                        message: error.localizedDescription
                    ),
                ])
            }
        }
    }

    var searchSourceSections: [SearchSourceSection] {
        let groupedResults = Dictionary(grouping: searchResults, by: \.sourceID)
        let descriptors = Dictionary(uniqueKeysWithValues: sourcesModel.sources.map { ($0.id, $0) })
        var orderedIDs = searchSourceOrder
        var includedIDs = Set(orderedIDs)
        let remainingIDs = groupedResults.keys
            .filter { includedIDs.insert($0).inserted }
            .sorted { sourceName(for: $0) < sourceName(for: $1) }
        orderedIDs.append(contentsOf: remainingIDs)

        return orderedIDs.compactMap { sourceID in
            let works = groupedResults[sourceID] ?? []
            let phase = searchSourcePhases[sourceID]
                ?? (works.isEmpty ? .empty : .results(hasMore: false))
            if works.isEmpty {
                switch phase {
                case .empty, .verificationRequired:
                    return nil
                case .loading, .results, .failed:
                    break
                }
            }
            return SearchSourceSection(
                id: sourceID,
                name: searchSourceNames[sourceID] ?? sourceName(for: sourceID),
                descriptor: descriptors[sourceID],
                works: works,
                phase: phase
            )
        }
    }

    func retrySearch(sourceID: SourceID) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBackgrounded, !query.isEmpty, let generation = searchGeneration else { return }
        retryTasks[sourceID]?.cancel()
        let retryID = UUID()
        retryIDs[sourceID] = retryID
        searchSourcePhases[sourceID] = .loading
        updateSearchState()

        retryTasks[sourceID] = Task { [weak self] in
            guard let self else { return }
            defer {
                if retryIDs[sourceID] == retryID {
                    retryTasks[sourceID] = nil
                    retryIDs[sourceID] = nil
                }
            }
            do {
                if sourceID == .local {
                    guard let database else { throw WorkDetailLoadError.storageUnavailable }
                    let results = try await database.search(query, limit: 100)
                    guard !Task.isCancelled, searchGeneration == generation, retryIDs[sourceID] == retryID else { return }
                    searchResults.removeAll { $0.sourceID == .local }
                    mergeSearchResults(results)
                    searchSourcePhases[sourceID] = results.contains(where: { $0.sourceID == .local })
                        ? .results(hasMore: results.count >= 100)
                        : .empty
                } else {
                    guard let descriptor = sourcesModel.sources.first(where: { $0.id == sourceID && $0.isEnabled }) else {
                        throw SourceError.notFound
                    }
                    let page = try await sourcesModel.performSourceOperation { [weak self] in
                        guard let self else { throw CancellationError() }
                        return try await self.searchRemoteSource(descriptor, query: query)
                    }
                    guard !Task.isCancelled, searchGeneration == generation, retryIDs[sourceID] == retryID else { return }
                    mergeSearchResults(page.items)
                    searchSourcePhases[sourceID] = page.items.isEmpty
                        ? .empty
                        : .results(hasMore: page.nextPage != nil || page.nextCursor != nil)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, searchGeneration == generation, retryIDs[sourceID] == retryID else { return }
                let name = searchSourceNames[sourceID] ?? sourceName(for: sourceID)
                searchSourcePhases[sourceID] = .failed(
                    SearchSourceFailure(
                        id: sourceID.rawValue,
                        sourceName: name,
                        message: error.localizedDescription
                    )
                )
            }
            updateSearchState()
        }
    }

    var searchCloudflareSourceCount: Int {
        searchSourceOrder.reduce(into: 0) { count, sourceID in
            if searchSourcePhases[sourceID] == .verificationRequired {
                count += 1
            }
        }
    }

    var searchCloudflareSummary: String {
        let count = searchCloudflareSourceCount
        return count == 1
            ? "1 source needs Cloudflare"
            : "\(count) sources need Cloudflare"
    }

    func verifySearchCloudflareSources() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBackgrounded, !query.isEmpty,
              !isVerifyingSearchSources,
              let generation = searchGeneration
        else { return }

        let sourceIDs = searchSourceOrder.filter {
            searchSourcePhases[$0] == .verificationRequired
        }
        guard !sourceIDs.isEmpty else { return }

        isVerifyingSearchSources = true
        searchVerificationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if searchGeneration == generation {
                    isVerifyingSearchSources = false
                    searchVerificationTask = nil
                    verificationSourceID = nil
                }
            }

            for sourceID in sourceIDs {
                guard !Task.isCancelled,
                      searchGeneration == generation,
                      searchSourcePhases[sourceID] == .verificationRequired
                else { return }

                guard let descriptor = sourcesModel.sources.first(where: {
                    $0.id == sourceID && $0.isEnabled
                }) else {
                    searchSourcePhases[sourceID] = .failed(searchFailure(
                        sourceID: sourceID,
                        error: SourceError.notFound
                    ))
                    updateSearchState()
                    continue
                }

                verificationSourceID = sourceID
                do {
                    let page = try await sourcesModel.performSourceOperation { [weak self] in
                        guard let self else { throw CancellationError() }
                        return try await self.searchRemoteSource(descriptor, query: query)
                    }
                    guard !Task.isCancelled, searchGeneration == generation else { return }
                    mergeSearchResults(page.items)
                    searchSourcePhases[sourceID] = page.items.isEmpty
                        ? .empty
                        : .results(hasMore: page.nextPage != nil || page.nextCursor != nil)
                } catch is CancellationError {
                    return
                } catch is CloudflareVerificationCancelledError {
                    return
                } catch {
                    guard !Task.isCancelled, searchGeneration == generation else { return }
                    searchSourcePhases[sourceID] = .failed(searchFailure(
                        sourceID: sourceID,
                        error: error
                    ))
                }
                updateSearchState()
            }
        }
    }

    func prepareSearchSources() {
        let enabledSources = sourcesModel.sources.filter(\.isEnabled)
        searchSourceOrder = [.local] + enabledSources.map(\.id)
        searchSourceNames = [.local: "Library"]
        for source in enabledSources {
            searchSourceNames[source.id] = source.name
        }
        searchSourcePhases = Dictionary(
            uniqueKeysWithValues: searchSourceOrder.map { ($0, SearchSourcePhase.loading) }
        )
    }

    func searchRemoteSource(
        _ descriptor: SourceDescriptor,
        query: String
    ) async throws -> SourcePage<Work> {
        if let searchSourcePageLoaderForTesting {
            return try await searchSourcePageLoaderForTesting(descriptor, query)
        }
        let source = try await sourcesModel.makeRemoteSource(for: descriptor)
        return try await source.search(
            SourceQuery(
                text: query,
                pageSize: 40,
                languageCodes: Set(descriptor.languageCodes)
            )
        )
    }

    func searchFailure(sourceID: SourceID, error: Error) -> SearchSourceFailure {
        SearchSourceFailure(
            id: sourceID.rawValue,
            sourceName: searchSourceNames[sourceID] ?? sourceName(for: sourceID),
            message: error.localizedDescription
        )
    }

    nonisolated static func isCloudflareChallenge(_ error: Error) -> Bool {
        guard case MangoReaderExtensionRuntimeError.cloudflareHandoff = error else {
            return false
        }
        return true
    }

    func mergeSearchResults(_ incoming: [Work]) {
        searchResults = Self.mergingSearchResults(existing: searchResults, incoming: incoming)
    }

    static func mergingSearchResults(existing: [Work], incoming: [Work]) -> [Work] {
        var known = Set(existing.map(\.id))
        return existing + incoming.filter { known.insert($0.id).inserted }
    }

    func sourceName(for sourceID: SourceID) -> String {
        if sourceID == .local { return "Library" }
        if let source = sourcesModel.sources.first(where: { $0.id == sourceID }) {
            return source.name
        }
        if let installed = sourcesModel.installedRepositorySources.first(where: { $0.descriptor.id == sourceID }) {
            return installed.descriptor.name
        }
        return sourceID.rawValue
    }

    func updateSearchState() {
        let phases = searchSourceOrder.compactMap { searchSourcePhases[$0] }
        let failures = phases.compactMap { phase -> SearchSourceFailure? in
            guard case let .failed(failure) = phase else { return nil }
            return failure
        }
        if phases.contains(.loading) {
            searchState = .searching
            return
        }
        let successfulSourceCount = phases.filter { phase in
            switch phase {
            case .results, .empty: true
            case .loading, .verificationRequired, .failed: false
            }
        }.count
        searchState = Self.resolvedSearchState(
            resultCount: searchResults.count,
            attemptedSourceCount: phases.count,
            successfulSourceCount: successfulSourceCount,
            failures: failures
        )
    }

    static func resolvedSearchState(
        resultCount: Int,
        attemptedSourceCount: Int,
        successfulSourceCount: Int,
        failures: [SearchSourceFailure]
    ) -> SearchState {
        if successfulSourceCount == 0, attemptedSourceCount > 0 {
            return .failed(failures)
        }
        if !failures.isEmpty {
            return .partial(failures)
        }
        return resultCount == 0 ? .noMatches : .results
    }
}
