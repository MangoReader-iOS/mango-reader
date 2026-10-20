import MangoReaderDomain
import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @State private var recentQueries = SearchHistory.load()
    @State private var isSearchPresented = false
    @State private var headerContainerWidth: CGFloat = 0
    @State private var headerState = CollapsingScreenHeaderState()
    @State private var searchEditingStartedCompact: Bool?
    @State private var searchEditingUsesInlineField: Bool?
    @FocusState private var isSearchFocused: Bool
    @State private var isInlineSearchFocused = false
    @State private var searchScrollPosition = ScrollPosition()

    private var usesRegularSearchNavigation: Bool {
#if targetEnvironment(macCatalyst)
        false
#else
        horizontalSizeClass == .regular
#endif
    }

    var body: some View {
        Group {
            if model.searchModel.searchCloudflareSourceCount > 0 {
                sourceResultsList
            } else {
                switch model.searchModel.searchState {
                case .initial:
                    initialContent
                case .searching:
                    searchingContent
                case .results:
                    sourceResultsList
                case .partial:
                    sourceResultsList
                case .noMatches:
                    ContentUnavailableView.search(text: model.searchModel.searchText)
                case let .failed(failures):
                    failedContent(failures: failures)
                }
            }
        }
        .screenTitle(Text("Search"), presentation: showsCompactSearchContext ? .hidden : .expanded)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { headerContainerWidth = $0 }
        .softScreenHeaderEdge()
        .navigationDestination(for: Work.self) { work in
            WorkDetailView(work: work)
        }
        .appBackground()
        .nativeHeaderSearch(
            isEnabled: !usesCompactInlineSearch,
            text: Binding(get: { model.searchModel.searchText }, set: { text in
                guard text != model.searchModel.searchText else { return }
                model.searchModel.search(text)
            }),
            isPresented: searchPresentationBinding,
            focus: $isSearchFocused,
            placement: searchPlacement,
            prompt: "Titles, authors, tags"
        )
        .toolbar {
            if usesCompactInlineSearch {
                ToolbarItem(placement: .topBarTrailing) {
                    FixedNavigationChrome {
                        CompactHeaderSearchField(
                            text: Binding(
                                get: { model.searchModel.searchText },
                                set: { text in
                                    guard text != model.searchModel.searchText else { return }
                                    model.searchModel.search(text)
                                }
                            ),
                            isFocused: $isInlineSearchFocused,
                            prompt: String(localized: "Titles, authors, tags"),
                            accessibilityIdentifier: "search-inline-search-field",
                            onSubmit: submitSearch
                        )
                        .frame(width: HeaderSearchToolbarLayout.width(containerWidth: headerContainerWidth, hasBackButton: false), height: 44)
                    }
                }.searchFieldToolbarBackground()
            }
            if !showsCompactSearchContext, usesRegularSearchNavigation, isSearchFocused {
                ToolbarItem(placement: .confirmationAction) {
                    FixedNavigationChrome {
                        Button("Done", action: finishSearchEditing)
                            .accessibilityIdentifier("search-done")
                    }
                }
            }
        }
        .onSubmit(of: .search, submitSearch)
        .onChange(of: isEditingSearch) { _, isFocused in
            if isFocused {
                if searchEditingStartedCompact == nil {
                    searchEditingStartedCompact = headerState.isCollapsed
                }
                if searchEditingUsesInlineField == nil {
                    searchEditingUsesInlineField = isInlineSearchFocused
                }
            } else {
                searchEditingStartedCompact = nil
                searchEditingUsesInlineField = nil
            }
        }
        .onChange(of: model.searchModel.searchText) { _, _ in
            headerState.reset()
            searchScrollPosition = ScrollPosition()
        }
    }

    private var searchPlacement: SearchFieldPlacement {
        .navigationBarDrawer(displayMode: .always)
    }

    private func finishSearchEditing() {
        isSearchFocused = false
        isInlineSearchFocused = false
        isSearchPresented = false
    }

    private func submitSearch() {
        SearchHistory.remember(model.searchModel.searchText, in: &recentQueries)
        finishSearchEditing()
    }

    private func dismissSearchForScroll() {
        if isEditingSearch || isSearchPresented { finishSearchEditing() }
    }

    private var usesCompactSearchPlacement: Bool {
        guard ScreenHeaderPlatform.allowsCollapse else { return false }
        if ScreenHeaderPlatform.verifiesCollapsedHeader { return true }
        return isEditingSearch
            ? (searchEditingStartedCompact ?? headerState.isCollapsed)
            : headerState.isCollapsed
    }

    private var usesCompactInlineSearch: Bool {
        guard ScreenHeaderPlatform.allowsCollapse else { return false }
        return HeaderSearchFieldPolicy.usesInlineField(
            isCollapsed: usesCompactSearchPlacement,
            editingFieldIsInline: isEditingSearch ? (searchEditingUsesInlineField ?? isInlineSearchFocused) : nil
        )
    }

    private var showsCompactSearchContext: Bool { usesCompactSearchPlacement || usesCompactInlineSearch }

    private var isEditingSearch: Bool { isSearchFocused || isInlineSearchFocused }

    private var searchPresentationBinding: Binding<Bool> {
        Binding(
            get: { isSearchPresented },
            set: { isPresented in
                if isPresented, !isSearchPresented {
                    searchEditingStartedCompact = headerState.isCollapsed
                }
                withAnimation(AppSelectionTransition.animation(reduceMotion: accessibilityReduceMotion)) {
                    isSearchPresented = isPresented
                }
            }
        )
    }

    @ViewBuilder
    private var initialContent: some View {
        if recentQueries.isEmpty {
            GeometryReader { geometry in
                ScrollView {
                    ContentUnavailableView(
                        "Search Library and Sources",
                        systemImage: "magnifyingglass",
                        description: Text("Find titles, authors, or tags.")
                    )
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollPosition($searchScrollPosition)
                .observesCollapsingHeader($headerState, isEnabled: !isEditingSearch, onUserScroll: dismissSearchForScroll)
            }
            .accessibilityIdentifier("search-empty-guidance")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("Recent Searches")
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            recentQueries = []
                            SearchHistory.save([])
                        } label: {
                            Text("Clear")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .font(.subheadline)
                        .foregroundStyle(AppColors.action)
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear Recent Searches")
                        .accessibilityIdentifier("clear-recent-searches")
                    }
                    .padding(.horizontal, PublicationGridLayout.contentMargin)
                    .padding(.bottom, 8)

                    ForEach(recentQueries, id: \.self) { query in
                        Button {
                            model.searchModel.search(query)
                            SearchHistory.remember(query, in: &recentQueries)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text(query)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, PublicationGridLayout.contentMargin)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("recent-search-\(query)")
                        .accessibilityHint("Runs this search again")

                        if query != recentQueries.last {
                            Divider()
                                .padding(.leading, PublicationGridLayout.contentMargin + 32)
                        }
                    }
                }
                .padding(.vertical, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollPosition($searchScrollPosition)
            .observesCollapsingHeader($headerState, isEnabled: !isEditingSearch, onUserScroll: dismissSearchForScroll)
            .accessibilityIdentifier("search-recent-queries")
        }
    }

    @ViewBuilder
    private var searchingContent: some View {
        if model.searchModel.searchSourceSections.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
                    AppContentSkeleton(kind: .textRows, count: 1)
                    SourceShelfSkeletonContent()
                    AppContentSkeleton(kind: .textRows, count: 1)
                    SourceShelfSkeletonContent()
                }.padding(.vertical, 20)
            }
            .sourceSkeletonContainer(accessibilityLabel: "Searching library and connected servers")
        } else {
            sourceResultsList
        }
    }

    private var sourceResultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
                if model.searchModel.searchCloudflareSourceCount > 0 {
                    SearchCloudflarePrompt(
                        summary: model.searchModel.searchCloudflareSummary,
                        isVerifying: model.searchModel.isVerifyingSearchSources
                    ) {
                        model.searchModel.verifySearchCloudflareSources()
                    }
                    .appCard()
                    .padding(.horizontal, PublicationGridLayout.contentMargin)
                }

                ForEach(model.searchModel.searchSourceSections) { section in
                    VStack(alignment: .leading, spacing: 14) {
                        SearchSourceHeader(section: section, query: model.searchModel.searchText)
                            .padding(.horizontal, PublicationGridLayout.contentMargin)

                        SearchSourceSectionContent(section: section)
                    }
                }
            }
            .padding(.vertical, 20)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollPosition($searchScrollPosition)
        .observesCollapsingHeader($headerState, isEnabled: !isEditingSearch, onUserScroll: dismissSearchForScroll)
        .accessibilityIdentifier("search-source-results")
    }

    @ViewBuilder
    private func failedContent(failures: [SearchSourceFailure]) -> some View {
        if model.searchModel.searchSourceSections.isEmpty {
            ContentUnavailableView {
                Text("Search unavailable")
                    .font(.title2.bold())
            } description: {
                Text(searchFailureDescription(failures))
            } actions: {
                Button("Try Again") { model.searchModel.search(model.searchModel.searchText) }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.actionFill)
                    .foregroundStyle(AppColors.onAction)
            }
        } else {
            sourceResultsList
        }
    }

    private func searchFailureDescription(_ failures: [SearchSourceFailure]) -> String {
        guard !failures.isEmpty else {
            return "Your library and connected servers could not be searched."
        }
        return failures
            .map { "\($0.sourceName): \($0.message)" }
            .joined(separator: "\n")
    }


}

private struct SearchSourceHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let section: SearchSourceSection
    let query: String

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 12))

        layout {
            Text(section.name)
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch section.phase {
            case .loading:
                if !section.works.isEmpty {
                    ProgressView().controlSize(.small)
                        .controlSize(.small)
                        .accessibilityLabel("Searching \(section.name)")
                }
            case .results, .empty, .failed:
                if let descriptor = section.descriptor {
                    NavigationLink {
                        SourceCatalogView(source: descriptor, initialQuery: query)
                    } label: {
                        Text("See All")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("search-source-see-all-\(section.id.rawValue)")
                }
            case .verificationRequired:
                EmptyView()
            }
        }
        .textCase(nil)
    }
}

private struct SearchSourceSectionContent: View {
    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .body) private var scaledMinimumCoverWidth = AllSourceSearchShelfLayoutPolicy.baseMinimumWidth
    let section: SearchSourceSection

    var body: some View {
        if !section.works.isEmpty {
            ScrollView(.horizontal) {
                LazyHStack(
                    alignment: .top,
                    spacing: AllSourceSearchShelfLayoutPolicy.horizontalSpacing
                ) {
                    ForEach(section.works) { work in
                        NavigationLink(value: work) {
                            SearchResultCard(work: work)
                        }
                        .buttonStyle(.plain)
                        .id(work.id)
                        .allSourceSearchShelfItemFrame(
                            minimumCoverWidth: minimumCoverWidth,
                            itemCount: section.works.count
                        )
                        .accessibilityIdentifier("search-result-\(work.id.rawValue.uuidString)")
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, PublicationGridLayout.contentMargin)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("search-source-carousel-\(section.id.rawValue)")
        }

        switch section.phase {
        case .loading:
            if SourceSkeletonVisibilityPolicy.shouldShow(
                isLoading: true,
                contentCount: section.works.count
            ) {
                AllSourceSearchShelfSkeletonContent()
                    .sourceSkeletonContainer(accessibilityLabel: "Searching \(section.name)")
            }
        case let .failed(failure):
            AppInlineStatus(
                title: "Couldn’t search \(section.name)",
                message: failure.message,
                actionTitle: "Retry"
            ) {
                model.searchModel.retrySearch(sourceID: section.id)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, PublicationGridLayout.contentMargin)
            .accessibilityIdentifier("retry-search-source-\(section.id.rawValue)")
        case .results, .empty, .verificationRequired:
            EmptyView()
        }
    }

    private var minimumCoverWidth: CGFloat {
        AllSourceSearchShelfLayoutPolicy.minimumCoverWidth(
            scaledWidth: scaledMinimumCoverWidth
        )
    }
}

enum AllSourceSearchShelfLayoutPolicy {
    static let baseMinimumWidth: CGFloat = 92
    static let minimumWidth: CGFloat = 88
    static let maximumMinimumWidth: CGFloat = 132
    static let overflowPeekFraction = SourceCatalogCoverLayoutPolicy.overflowPeekFraction
    static let horizontalSpacing = SourceCatalogCoverLayoutPolicy.horizontalSpacing

    static func minimumCoverWidth(scaledWidth: CGFloat) -> CGFloat {
        min(max(scaledWidth, minimumWidth), maximumMinimumWidth)
    }

    static func shelfLayout(
        availableWidth: CGFloat,
        minimumCoverWidth: CGFloat,
        itemCount: Int,
        spacing: CGFloat = horizontalSpacing
    ) -> SourceCatalogCoverLayout {
        let fittedLayout = SourceCatalogCoverLayoutPolicy.layout(
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
}

private extension View {
    func allSourceSearchShelfItemFrame(
        minimumCoverWidth: CGFloat,
        itemCount: Int
    ) -> some View {
        containerRelativeFrame(.horizontal, alignment: .topLeading) { length, _ in
            let contentWidth = max(
                0,
                length - (PublicationGridLayout.contentMargin * 2)
            )
            return AllSourceSearchShelfLayoutPolicy.shelfLayout(
                availableWidth: contentWidth,
                minimumCoverWidth: minimumCoverWidth,
                itemCount: itemCount
            ).coverWidth
        }
    }
}

private struct AllSourceSearchShelfSkeletonContent: View {
    @ScaledMetric(relativeTo: .body) private var scaledMinimumCoverWidth = AllSourceSearchShelfLayoutPolicy.baseMinimumWidth
    private let itemCount = 6

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(
                alignment: .top,
                spacing: AllSourceSearchShelfLayoutPolicy.horizontalSpacing
            ) {
                ForEach(0 ..< itemCount, id: \.self) { index in
                    SourceShelfCardLayout(
                        title: index.isMultiple(of: 2)
                            ? "Loading publication title"
                            : "Loading title",
                        metadata: index.isMultiple(of: 2)
                            ? "Creator name"
                            : "Publication",
                        cover: SourceSkeletonCover()
                    )
                    .allSourceSearchShelfItemFrame(
                        minimumCoverWidth: minimumCoverWidth,
                        itemCount: itemCount
                    )
                }
            }
            .padding(.horizontal, PublicationGridLayout.contentMargin)
        }
        .scrollIndicators(.hidden)
        .sourceSkeletonVisual()
    }

    private var minimumCoverWidth: CGFloat {
        AllSourceSearchShelfLayoutPolicy.minimumCoverWidth(
            scaledWidth: scaledMinimumCoverWidth
        )
    }
}

private struct SearchCloudflarePrompt: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let summary: String
    let isVerifying: Bool
    let verify: () -> Void

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))

        layout {
            Text(summary)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("search-cloudflare-summary")

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if isVerifying {
                    ProgressView().controlSize(.small)
                        .controlSize(.small)
                        .accessibilityLabel("Verifying sources")
                }
                Button("Verify", action: verify)
                    .buttonStyle(.bordered)
                    .disabled(isVerifying)
                    .accessibilityIdentifier("search-cloudflare-verify")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SearchResultCard: View {
    let work: Work

    private var metadata: String {
        if !work.authors.isEmpty {
            return work.authors.joined(separator: ", ")
        }
        return switch work.kind {
        case .manga: "Manga"
        case .comic: "Comic"
        case .lightNovel: "Light Novel"
        case .book: "Book"
        }
    }

    var body: some View {
        SourceShelfCardLayout(
            title: work.title,
            metadata: metadata,
            cover: RemoteCover(work: work)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(work.title), \(metadata)")
        .accessibilityHint("Opens title details")
    }
}

enum SearchHistory {
    private static let key = "searchHistory"

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func save(_ values: [String]) {
        UserDefaults.standard.set(values, forKey: key)
    }

    static func remember(_ query: String, in values: inout [String]) {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        values.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame }
        values.insert(value, at: 0)
        values = Array(values.prefix(20))
        save(values)
    }
}
