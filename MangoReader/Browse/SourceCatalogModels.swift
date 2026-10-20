import MangoReaderDomain
import MangoReaderExtensions
import MangoReaderSources
import Observation
import OSLog
import SwiftUI

/// Edits temporary filters without touching the text draft or saved source rules.
enum SourceSearchFilterPolicy {
    nonisolated static func isPersistentlyExcluded(_ selection: SourceSearchSelection, in exclusions: [SourceSearchSelection]) -> Bool {
        exclusions.contains { $0.fieldID == selection.fieldID && $0.value == selection.value && $0.polarity == .exclude }
    }

    nonisolated static func updating(
        _ selection: SourceSearchSelection,
        polarity: SourceSearchPolarity?,
        in selections: [SourceSearchSelection],
        configuration: SourceSearchConfiguration?,
        persistentExclusions: [SourceSearchSelection]
    ) throws -> [SourceSearchSelection] {
        guard let index = selections.firstIndex(where: { $0.id == selection.id }) else { return selections }
        guard let polarity else {
            return selections.filter { $0.fieldID != selection.fieldID || $0.value != selection.value }
        }
        guard let configuration else {
            throw SourceSearchValidationError(String(localized: "Source filters are unavailable. You can still remove this filter."))
        }
        guard polarity != .include || !isPersistentlyExcluded(selection, in: persistentExclusions) else {
            throw SourceSearchValidationError(String(localized: "Excluded in source settings"))
        }
        var result = selections
        result[index].polarity = polarity
        try configuration.validate(selections: result)
        return result
    }
}

/// Fetch and decode a bounded first screen, including cards just outside a
/// horizontal shelf's lazy viewport. The regular cover cache coalesces visible
/// image requests with these loads; failure must not stall the other shelves.
enum SourceCatalogCoverPrefetch {
    @MainActor
    static func load(
        works: [Work],
        loader: @escaping @MainActor @Sendable (Work) async throws -> Void
    ) async -> Int {
        var seen = Set<WorkID>()
        let initial = works.filter { seen.insert($0.id).inserted }.prefix(5)
        return await withTaskGroup(of: Bool.self) { group in
            for work in initial {
                group.addTask { [work, loader] in
                    guard work.coverURL != nil, !Task.isCancelled else { return false }
                    do {
                        try await loader(work)
                        return !Task.isCancelled
                    } catch { return false }
                }
            }
            var ready = 0
            for await loaded in group where loaded { ready += 1 }
            return ready
        }
    }
}

enum SourceCatalogPresentationState: Equatable {
    case loading
    case verification
    case connectionError(String)
    case emptySearch(String)
    case emptyDiscovery
    case results

    static func resolve(
        hasWorks: Bool,
        isLoading: Bool,
        isAwaitingVerification: Bool,
        errorMessage: String?,
        query: String
    ) -> Self {
        if !hasWorks, isLoading { return .loading }
        if !hasWorks, isAwaitingVerification { return .verification }
        if !hasWorks, let errorMessage { return .connectionError(errorMessage) }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hasWorks, !trimmedQuery.isEmpty { return .emptySearch(trimmedQuery) }
        if !hasWorks { return .emptyDiscovery }
        return .results
    }
}

enum SourceCatalogReloadPolicy {
    static func reset<Item>(items: inout [Item], nextPage: inout Int?) {
        items.removeAll()
        nextPage = nil
    }
}

enum SourceCatalogRequestPolicy {
    static func acceptsResult(
        loadID: UUID,
        currentLoadID: UUID?,
        requestedIdentity: String,
        currentIdentity: String?
    ) -> Bool {
        !Task.isCancelled && currentLoadID == loadID && currentIdentity == requestedIdentity
    }

    static func shouldLoad(
        completedIdentity: String?,
        requestedIdentity: String,
        isLoading: Bool,
        force: Bool
    ) -> Bool {
        guard !isLoading else { return false }
        return force || completedIdentity != requestedIdentity
    }

    static func shouldReset(
        currentIdentity: String?,
        requestedIdentity: String
    ) -> Bool {
        currentIdentity != requestedIdentity
    }
}

enum SourceCatalogPaginationPolicy {
    static func shouldLoadNextPage(
        isBottomVisible: Bool, isLoading: Bool, hasError: Bool, madeProgress: Bool = true
    ) -> Bool {
        isBottomVisible && !isLoading && !hasError && madeProgress
    }

    static func isStalled(
        page: Int, previousCount: Int, resultCount: Int,
        requestedCursor: SourceCursor?, nextPage: Int?, nextCursor: SourceCursor?
    ) -> Bool {
        guard page > 1 else { return false }
        if let nextPage, nextPage <= page { return true }
        if let requestedCursor, nextCursor == requestedCursor { return true }
        return (nextPage != nil || nextCursor != nil) && resultCount <= previousCount
    }
}

enum SourceCatalogPaginationError: LocalizedError {
    case stalled

    var errorDescription: String? {
        String(localized: "This source did not advance to new titles. Retry to load this page again.")
    }
}

/// Remains mounted while a page loads so visibility also works for short pages.
struct SourceCatalogPaginationSentinel: View {
    let nextPage: Int
    let isLoading: Bool
    let hasError: Bool
    let isPaused: Bool
    @Binding var isVisible: Bool
    let load: (Int) async -> Void

    private struct Trigger: Equatable {
        let page: Int
        let isLoading: Bool
        let hasError: Bool
        let isPaused: Bool
        let isVisible: Bool
    }

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 1)
            .accessibilityHidden(true)
            .onScrollVisibilityChange(threshold: 0.1) { visible in
                isVisible = visible
            }
            .onChange(of: Trigger(page: nextPage, isLoading: isLoading,
                                 hasError: hasError, isPaused: isPaused, isVisible: isVisible), initial: true) { _, _ in
                guard SourceCatalogPaginationPolicy.shouldLoadNextPage(
                    isBottomVisible: isVisible, isLoading: isLoading,
                    hasError: hasError, madeProgress: !isPaused
                ) else { return }
                Task { await load(nextPage) }
            }
            .onDisappear { isVisible = false }
    }
}

enum SourceCatalogLoadIntent {
    case automatic
    case userInitiated

    func keepsFailureQuiet(hasContent: Bool, page: Int = 1) -> Bool {
        self == .automatic && page == 1 && hasContent
    }

    func recoveryMode(hasContent: Bool, page: Int = 1) -> CloudflareRecoveryMode? {
        if self == .userInitiated { return .foreground }
        return keepsFailureQuiet(hasContent: hasContent, page: page) ? .background : nil
    }
}

struct SourceCatalogCoverLayout: Equatable {
    let columnCount: Int
    let coverWidth: CGFloat
}

enum SourceCatalogCoverLayoutPolicy {
    static let baseMinimumWidth: CGFloat = 132
    static let minimumWidth: CGFloat = 120
    static let maximumMinimumWidth: CGFloat = 220
    static let overflowPeekFraction: CGFloat = 0.15
    static let horizontalSpacing = PublicationGridLayout.horizontalSpacing

    static func minimumCoverWidth(scaledWidth: CGFloat) -> CGFloat {
        min(max(scaledWidth, minimumWidth), maximumMinimumWidth)
    }

    static func layout(
        availableWidth: CGFloat,
        minimumCoverWidth: CGFloat,
        spacing: CGFloat = horizontalSpacing
    ) -> SourceCatalogCoverLayout {
        let minimumCoverWidth = max(minimumCoverWidth, 1)
        guard availableWidth > 0 else {
            return SourceCatalogCoverLayout(
                columnCount: 1,
                coverWidth: minimumCoverWidth
            )
        }

        let columnCount = max(
            1,
            Int((availableWidth + spacing) / (minimumCoverWidth + spacing))
        )
        let totalSpacing = spacing * CGFloat(columnCount - 1)
        let coverWidth = max(
            0,
            (availableWidth - totalSpacing) / CGFloat(columnCount)
        )
        return SourceCatalogCoverLayout(
            columnCount: columnCount,
            coverWidth: coverWidth
        )
    }

    static func skeletonCount(availableWidth: CGFloat, minimumCoverWidth: CGFloat, rowCount: Int) -> Int {
        guard availableWidth > 0 else { return 0 }
        return layout(availableWidth: availableWidth, minimumCoverWidth: minimumCoverWidth).columnCount
            * max(0, rowCount)
    }

    static func shelfLayout(
        availableWidth: CGFloat,
        minimumCoverWidth: CGFloat,
        itemCount: Int,
        spacing: CGFloat = horizontalSpacing
    ) -> SourceCatalogCoverLayout {
        let fittedLayout = layout(
            availableWidth: availableWidth,
            minimumCoverWidth: minimumCoverWidth,
            spacing: spacing
        )
        guard availableWidth > 0, itemCount > fittedLayout.columnCount else {
            return fittedLayout
        }

        let fullyVisibleCount = CGFloat(fittedLayout.columnCount)
        let spacingWidth = spacing * fullyVisibleCount
        let peekCoverWidth = max(
            0,
            (availableWidth - spacingWidth)
                / (fullyVisibleCount + overflowPeekFraction)
        )
        return SourceCatalogCoverLayout(
            columnCount: fittedLayout.columnCount,
            coverWidth: max(minimumWidth, peekCoverWidth)
        )
    }

    static func columns(
        minimumCoverWidth: CGFloat,
        dynamicTypeSize: DynamicTypeSize,
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> [GridItem] {
        let effectiveMinimumWidth = PublicationGridLayout.minimumWidth(
            for: dynamicTypeSize,
            horizontalSizeClass: horizontalSizeClass,
            regularMinimumWidth: minimumCoverWidth
        )
        return [
            GridItem(
                .adaptive(minimum: effectiveMinimumWidth),
                spacing: horizontalSpacing,
                alignment: .top
            ),
        ]
    }
}

enum SourceSearchResultsLayout: String, CaseIterable {
    static let storageKey = "sourceSearchResultsLayout"

    case grid
    case list

    init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .grid
    }

    var systemImage: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .grid: "Grid"
        case .list: "List"
        }
    }
}

enum SourceSearchResultAccessibilityPolicy {
    static func label(for work: Work) -> String {
        var values = [work.title]
        if let latestChapterTitle = work.latestChapterTitle, !latestChapterTitle.isEmpty {
            values.append("Latest chapter, \(latestChapterTitle)")
        }
        if let languageCode = work.languageCode, !languageCode.isEmpty {
            values.append("Language, \(languageCode)")
        }
        return values.joined(separator: ", ")
    }
}

@Observable
final class SourceCatalogSectionState {
    var works: [Work] = []
    var nextPage: Int?
    var nextCursor: SourceCursor?
    var loadedPages: Set<Int> = []
    var loadedPageCount: Int { loadedPages.count }
    var failedCursor: SourceCursor?
    var failedPagePreviousCount: Int?
    var isLoading = false
    var loadingPage: Int?
    var errorMessage: String?
    var isAwaitingVerification = false
    var failedPage: Int?
    var currentLoadID: UUID?
    var isBottomSentinelVisible = false
    var automaticPaginationPaused = false
    var requestIdentity: String?
    var completedIdentity: String?
    var appliedRefreshRevision = 0
    var retryRevision = 0
    var appliedRetryRevision = 0
    var shelfScrollPosition = ScrollPosition(idType: WorkID.self)

    func reset(for requestIdentity: String) {
        works.removeAll()
        nextPage = nil
        nextCursor = nil
        loadedPages = []; failedCursor = nil
        failedPagePreviousCount = nil
        isLoading = false
        loadingPage = nil
        errorMessage = nil
        isAwaitingVerification = false
        failedPage = nil
        currentLoadID = nil
        isBottomSentinelVisible = false
        automaticPaginationPaused = false
        self.requestIdentity = requestIdentity
        completedIdentity = nil
        shelfScrollPosition = ScrollPosition(idType: WorkID.self)
    }
}

@Observable
final class SourceCatalogSession {
    var searchWorks: [Work] = []
    var searchNextPage: Int?
    var searchNextCursor: SourceCursor?
    var searchLoadedPages: Set<Int> = []
    var searchLoadedPageCount: Int { searchLoadedPages.count }
    var isLoadingSearch = false
    var isSearchBottomSentinelVisible = false
    var searchAutomaticPaginationPaused = false
    var searchLoadingPage: Int?
    var searchFailedPage: Int?
    var searchFailedCursor: SourceCursor?
    var searchFailedPagePreviousCount: Int?
    var searchErrorMessage: String?
    var isSearchAwaitingVerification = false
    var currentSearchLoadID: UUID?
    var searchRequestIdentity: String?
    var completedSearchIdentity: String?
    private(set) var hasSelectedBrowseSort = false
    var landingScrollPosition = ScrollPosition()
    var searchScrollPosition = ScrollPosition(idType: WorkID.self)

    @ObservationIgnored private var sectionStates: [String: SourceCatalogSectionState] = [:]

    func reconcileSections(_ sectionIDs: [String]) {
        let validIDs = Set(sectionIDs)
        sectionStates = sectionStates.filter { validIDs.contains($0.key) }
        for sectionID in sectionIDs where sectionStates[sectionID] == nil {
            sectionStates[sectionID] = SourceCatalogSectionState()
        }
    }

    func sectionState(for sectionID: String) -> SourceCatalogSectionState? {
        sectionStates[sectionID]
    }

    func selectBrowseSort() {
        hasSelectedBrowseSort = true
        // Fence late homepage/page responses before the new grid starts loading.
        for state in sectionStates.values { state.reset(for: "") }
        landingScrollPosition.scrollTo(edge: .top)
    }

    func resetSearch(for requestIdentity: String) {
        SourceCatalogReloadPolicy.reset(items: &searchWorks, nextPage: &searchNextPage)
        searchNextCursor = nil
        searchLoadedPages = []
        isLoadingSearch = false
        isSearchBottomSentinelVisible = false
        searchAutomaticPaginationPaused = false
        searchLoadingPage = nil
        searchFailedPage = nil
        searchFailedCursor = nil
        searchFailedPagePreviousCount = nil
        searchErrorMessage = nil
        isSearchAwaitingVerification = false
        currentSearchLoadID = nil
        searchRequestIdentity = requestIdentity
        completedSearchIdentity = nil
        searchScrollPosition = ScrollPosition(idType: WorkID.self)
    }

    func clearSearch() {
        resetSearch(for: "")
        searchRequestIdentity = nil
    }
}

/// Transient prefixes never advance cursors or replace a previously loaded page.
/// A retry replaces its partial tail instead of accumulating stale titles.
@MainActor
final class SourceCatalogProgressPresentation {
    let previousWorks: [Work]
    private(set) var hasUpdates = false
    private var suppressed: Bool

    init(existing: [Work], page: Int, previousCount: Int) {
        previousWorks = page == 1 ? [] : Array(existing.prefix(previousCount))
        suppressed = page == 1 && !existing.isEmpty
    }

    func receivedCachedPage() { suppressed = true }

    func update(_ prefix: [Work]) -> [Work]? {
        guard !suppressed, !prefix.isEmpty else { return nil }
        hasUpdates = true
        return SourceLatestGalleryPolicy.merging(existing: previousWorks, incoming: prefix)
    }
}

enum SourceLandingSectionRole: String, Sendable {
    case carousel
    case latestGallery
}

struct SourceLandingSectionDescriptor: Equatable, Identifiable, Sendable {
    var id: String
    var sourceSectionID: String
    var title: String
    var subtitle: String?
    var role: SourceLandingSectionRole
}

enum SourceCatalogBrowsePolicy {
    static func sections(
        _ sections: [SourceLandingSectionDescriptor],
        configuration: SourceSearchConfiguration?,
        selectedSortID: String?,
        hasSelectedSort: Bool
    ) -> [SourceLandingSectionDescriptor] {
        var displayed = sections
        if hasSelectedSort,
           let sectionID = configuration?.sortedBrowseSectionID,
           var catalog = sections.first(where: { $0.sourceSectionID == sectionID }) {
            catalog.role = .latestGallery
            catalog.subtitle = nil
            displayed = [catalog]
        }
        if displayed.count == 1, displayed[0].role == .latestGallery,
           let option = configuration?.sortOptions.first(where: {
               $0.id == (selectedSortID ?? configuration?.defaultSortID)
           }) {
            displayed[0].title = option.title
        }
        return displayed
    }

    static func effectiveSortID(
        selectedSortID: String?,
        configuration: SourceSearchConfiguration?,
        hasSelectedSort: Bool
    ) -> String? {
        if hasSelectedSort, configuration?.sortedBrowseSectionID != nil {
            return selectedSortID ?? configuration?.defaultSortID
        }
        return selectedSortID == configuration?.defaultSortID ? nil : selectedSortID
    }
}

enum SourceLandingSectionClassifier {
    static func arrange(
        _ sections: [SourceDiscoverSection]
    ) -> [SourceLandingSectionDescriptor] {
        let latestIndex = sections.indices.first {
            sections[$0].presentation == .latestGallery
        } ?? sections.indices.first {
            sections[$0].presentation == .automatic && matchesLatest(sections[$0])
        }

        var arranged = sections.indices.compactMap { index -> SourceLandingSectionDescriptor? in
            guard index != latestIndex else { return nil }
            return descriptor(for: sections[index], role: .carousel)
        }
        if let latestIndex {
            arranged.append(descriptor(for: sections[latestIndex], role: .latestGallery))
        }
        return arranged
    }

    private static func descriptor(
        for section: SourceDiscoverSection,
        role: SourceLandingSectionRole
    ) -> SourceLandingSectionDescriptor {
        SourceLandingSectionDescriptor(
            id: "discover:\(section.id)",
            sourceSectionID: section.id,
            title: section.title,
            subtitle: section.subtitle,
            role: role
        )
    }

    private static func matchesLatest(_ section: SourceDiscoverSection) -> Bool {
        let value = "\(section.id) \(section.title)"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        return value.contains("latest")
            || value.contains("update")
            || value.contains("recent release")
    }
}

enum SourceLatestGalleryPolicy {
    static let paginationSkeletonRows = 1

    enum LoadingPresentation: Equatable {
        case none
        case initialSkeleton
        case appendedSkeletons
    }

    static func loadingPresentation(
        isLoading: Bool,
        loadingPage: Int?,
        contentCount: Int
    ) -> LoadingPresentation {
        guard isLoading else { return .none }
        guard contentCount > 0 else { return .initialSkeleton }
        return (loadingPage ?? 1) > 1
            ? .appendedSkeletons
            : .none
    }

    private static let performanceLog = OSLog(subsystem: "com.k800k.manko", category: "SourceCatalogPerformance")

    static func merging(existing: [Work], incoming: [Work]) -> [Work] {
        let signpost = OSSignpostID(log: performanceLog)
        os_signpost(.begin, log: performanceLog, name: "Catalog Page Merge", signpostID: signpost,
                    "existing=%d incoming=%d", existing.count, incoming.count)
        defer { os_signpost(.end, log: performanceLog, name: "Catalog Page Merge", signpostID: signpost) }
        var seen: Set<WorkID> = []
        let updates = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let retained = existing.filter { seen.insert($0.id).inserted }.map { updates[$0.id] ?? $0 }
        return retained + incoming.filter { seen.insert($0.id).inserted }
    }
}
