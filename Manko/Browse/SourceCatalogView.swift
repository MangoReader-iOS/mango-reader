import MankoDomain
import MankoExtensions
import MankoSources
import Observation
import OSLog
import SwiftUI
import UIKit

struct SourceCatalogView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let source: SourceDescriptor
    @State private var session = SourceCatalogSession()
    @State private var landingSections: [SourceLandingSectionDescriptor] = []
    @State private var isLoadingLandingStructure = false
    @State private var landingErrorMessage: String?
    @State private var isLandingAwaitingVerification = false
    @State private var landingRefreshRevision = 0
    @State private var currentLandingLoadID: UUID?
    @State private var hasLoadedLandingStructure = false
    @State private var landingHeaderState = CollapsingScreenHeaderState()
    @State private var searchHeaderState = CollapsingScreenHeaderState()
    @State private var isSearchPresented = false
    @FocusState private var isSearchFocused: Bool
    @State private var isComposingSearch = false
    @State private var query: String
    @State private var searchSelections: [SourceSearchSelection]
    @State private var searchConfiguration: SourceSearchConfiguration?
    @State private var isLoadingSearchConfiguration = false
    @State private var hasLoadedSearchConfiguration = false
    @State private var searchConfigurationError: String?
    @State private var isConfigurationAwaitingVerification = false
    @State private var suggestionLoader = SourceSuggestionLoader()
    @State private var suggestionRetryRevision = 0
    @State private var structuredQueryMessage: String?
    @State private var selectedSortID: String?
    @State private var selectedKind: ContentKind?
    @State private var filterSelections: [String: String] = [:]
    @State private var filterDefaults: [String: String] = [:]
    @State private var didLoadFilterDefaults = false
    @State private var catalogOpenedAt = ContinuousClock.now
    @State private var initialCoversFinished = false
    @State private var initialCoversReady = false
    @State private var initialCoversReadyUptime: TimeInterval?
    @State private var completedCoverIdentity: String?
    @State private var skeletonSections: [SourceSkeletonSectionDescriptor]
    @AppStorage(SourceSearchResultsLayout.storageKey)
    private var searchResultsLayoutStorage = SourceSearchResultsLayout.grid.rawValue

    init(
        source: SourceDescriptor,
        initialQuery: String = "",
        initialSelections: [SourceSearchSelection] = []
    ) {
        self.source = source
        _query = State(initialValue: initialQuery)
        _searchSelections = State(initialValue: initialSelections)
        _selectedSortID = State(initialValue: nil)
        _skeletonSections = State(
            initialValue: SourceSkeletonLayoutStore().load(sourceID: source.id.rawValue)
        )
    }

    var body: some View {
        ZStack {
            if isSearching {
                searchPresentation
            } else {
                // Hidden shelves still run their task modifiers. Keep only the
                // active surface mounted so browse work cannot delay a search.
                landingPresentation
            }
        }
        .screenHeaderBar {
            VStack(spacing: 0) {
                CollapsingScreenHeader(isExpanded: true) {
                    if isLoadingSearchConfiguration && !hasLoadedSearchConfiguration {
                        AppContentSkeleton(kind: .filters, label: String(localized: "Loading source filters…"))
                            .font(.footnote)
                            .padding(8)
                    } else if let searchConfigurationError {
                        AppInlineStatus(
                            title: "Source filters unavailable",
                            message: searchConfigurationError,
                            actionTitle: "Retry"
                        ) {
                            Task { await loadSearchConfiguration(force: true) }
                        }
                        .padding(.horizontal, AppLayout.pageMargin)
                        .padding(.vertical, 8)
                    }
                    if isSearching {
                        searchResultsHeader
                            .padding(.horizontal, PublicationGridLayout.contentMargin)
                            .padding(.top, PublicationGridLayout.contentMargin)
                            .padding(.bottom, 4)
                    }
                }

                if let structuredQueryMessage {
                    Text(structuredQueryMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, AppLayout.pageMargin)
                        .accessibilityIdentifier("source-query-validation")
                }
            }
        }
        .navigationTitle(source.name)
        .toolbarTitleDisplayMode(.inline)
        .appNativeNavigationChrome()
        .nativeScreenHeader(isEditing: isEditingSearch, minimizesOnScroll: false)
        .appBackground()
        .modifier(SourceNativeSearch(
            text: $query,
            isPresented: searchPresentationBinding, isComposing: $isComposingSearch, focus: $isSearchFocused,
            placement: searchPlacement, prompt: "Search \(source.name)",
            suggestions: searchSuggestionRows
        ))
        .searchPresentationToolbarBehavior(
            horizontalSizeClass == .compact ? .automatic : .avoidHidingContent
        )
        .toolbar {
            if #available(iOS 26.0, *) {
                if showsSortMenu {
                    sourceSortToolbarItem
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                DefaultToolbarItem(kind: .search, placement: .topBarTrailing)
            } else if showsSortMenu {
                sourceSortToolbarItem
            }
        }
        .onSubmit(of: .search, submitSearch)
        .onDisappear(perform: finishSearchEditing)
        .onChange(of: query) { _, _ in structuredQueryMessage = nil }
        .onAppear {
            guard hasLoadedLandingStructure else { return }
            Task {
                await loadLandingStructure()
                await loadSearchConfiguration()
                if isSearching {
                    session.completedSearchIdentity = nil
                    await loadSearch(page: 1, query: query.trimmingCharacters(in: .whitespacesAndNewlines), requestIdentity: searchIdentity)
                }
            }
        }
        .onChange(of: model.sourcesModel.contentCacheActivationRevision) { _, _ in
            Task {
                await loadLandingStructure()
                await loadSearchConfiguration()
                if isSearching {
                    session.completedSearchIdentity = nil
                    await loadSearch(page: 1, query: query.trimmingCharacters(in: .whitespacesAndNewlines), requestIdentity: searchIdentity)
                }
            }
        }
        .task(id: source.id) {
            guard !didLoadFilterDefaults || !hasLoadedLandingStructure else { return }
            catalogOpenedAt = .now
#if DEBUG
            SourcePerformanceAudit.shared.begin("catalog")
#endif
            let defaults = model.sourcesModel.browseFilterDefaults(for: source)
            if !didLoadFilterDefaults {
                filterDefaults = defaults
                filterSelections = defaults
                didLoadFilterDefaults = true
            }
            if !hasLoadedLandingStructure {
                await loadLandingStructure()
            }
        }
        .task(id: "\(hasLoadedLandingStructure)|\(mayLoadSecondarySections)") {
            guard hasLoadedLandingStructure, mayLoadSecondarySections else { return }
            await loadSearchConfiguration()
        }
        .task(id: initialCoverIdentity) {
            let identity = initialCoverIdentity
            guard completedCoverIdentity != identity || !initialCoversReady else { return }
            initialCoversFinished = false
            initialCoversReady = false
            initialCoversReadyUptime = nil
            let works = initialCoverWorks
            guard !works.isEmpty else { return }
#if DEBUG
            SourcePerformanceAudit.shared.covers(works.map { $0.remoteID ?? $0.id.description })
#endif
            _ = await SourceCatalogCoverPrefetch.load(works: works) { work in
                _ = try await model.sourcesModel.catalogCoverImage(for: work, previewOnly: true)
            }
            guard !Task.isCancelled else { return }
            let firstSection = displayedLandingSections.first.flatMap { session.sectionState(for: $0.id) }
            initialCoversFinished = works.count >= 5 || firstSection?.nextPage == nil
            // Previews unblock the other shelves; audit readiness still means final artwork.
            let ready = await SourceCatalogCoverPrefetch.load(works: works) { work in
                _ = try await model.sourcesModel.catalogCoverImage(for: work)
            }
            guard !Task.isCancelled else { return }
            initialCoversReady = ready == 5
            if initialCoversReady { completedCoverIdentity = identity }
            let elapsed = catalogOpenedAt.duration(to: .now)
            initialCoversReadyUptime = ProcessInfo.processInfo.systemUptime
            Logger(subsystem: "com.k800k.manko", category: "SourceCatalog").info(
                "Initial covers source=\(source.id.rawValue, privacy: .public) ready=\(ready) elapsed=\(String(describing: elapsed), privacy: .public)"
            )
        }
        .task(id: "\(suggestionIdentity)|\(suggestionRetryRevision)") {
            await loadValueSuggestions()
        }
        .task(id: "\(searchIdentity)|\(isComposingSearch)") {
            guard didLoadFilterDefaults else { return }
            guard !isIncompleteStructuredDraft, !isComposingSearch else { return }
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSearching else {
                session.clearSearch()
                return
            }
            let requestIdentity = searchIdentity
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, searchIdentity == requestIdentity else { return }
            if SourceCatalogRequestPolicy.shouldReset(
                currentIdentity: session.searchRequestIdentity,
                requestedIdentity: requestIdentity
            ) {
                session.resetSearch(for: requestIdentity)
                searchHeaderState.reset()
            }
            guard SourceCatalogRequestPolicy.shouldLoad(
                completedIdentity: session.completedSearchIdentity,
                requestedIdentity: requestIdentity,
                isLoading: session.isLoadingSearch,
                force: false
            ) else { return }
            await loadSearch(
                page: 1,
                query: trimmedQuery,
                requestIdentity: requestIdentity
            )
        }
        .onChange(of: model.sourcesModel.cloudflareVerificationRevision) { _, _ in
            if isConfigurationAwaitingVerification {
                Task { await loadSearchConfiguration() }
            }
            if suggestionLoader.isAwaitingVerification {
                suggestionRetryRevision &+= 1
            }
            if isLandingAwaitingVerification {
                isLandingAwaitingVerification = false
                landingErrorMessage = nil
                Task { await loadLandingStructure(force: true) }
            }
            if session.isSearchAwaitingVerification, isSearching {
                Task { await retrySearch() }
            }
        }
    }

    @ViewBuilder
    private var landingPresentation: some View {
        @Bindable var session = session
        if SourceSkeletonVisibilityPolicy.shouldShow(
            isLoading: isLoadingLandingStructure,
            contentCount: landingSections.count
        ) {
            SourceCatalogSkeletonView(
                sourceName: source.name,
                sections: skeletonSections
            )
        } else if landingSections.isEmpty, isLandingAwaitingVerification {
            ContentUnavailableView {
                Label("Verification required", systemImage: "checkmark.shield")
            } description: {
                Text("Complete the visible source verification, then Manko will retry automatically.")
            } actions: {
                Button("Retry") {
                    isLandingAwaitingVerification = false
                    Task { await loadLandingStructure(force: true) }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.actionFill)
                .foregroundStyle(AppColors.onAction)
            }
        } else if landingSections.isEmpty, let landingErrorMessage {
            ContentUnavailableView {
                Text("Connection failed")
                    .font(.title2.bold())
            } description: {
                Text(landingErrorMessage)
            } actions: {
                Button("Retry") { Task { await loadLandingStructure(force: true) } }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.actionFill)
                    .foregroundStyle(AppColors.onAction)
            }
        } else if landingSections.isEmpty {
            ContentUnavailableView {
                Label("No titles available", systemImage: "books.vertical")
            } description: {
                Text("This source returned an empty catalog.")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
                    if let landingErrorMessage {
                        AppInlineStatus(
                            title: "Couldn’t refresh source",
                            message: landingErrorMessage
                        )
                        .padding(.vertical, 8)
                        .padding(.horizontal, PublicationGridLayout.contentMargin)
                    }

                    ForEach(displayedLandingSections) { section in
                        if let state = session.sectionState(for: section.id),
                           section.id == displayedLandingSections.first?.id || mayLoadSecondarySections || !state.works.isEmpty {
                            Group {
                                if section.role == .latestGallery {
                                    SourceLatestGallery(
                                        source: source,
                                        section: section,
                                        selectedKind: selectedKind,
                                        filters: filterSelections,
                                        sortID: effectiveSortID,
                                        refreshRevision: landingRefreshRevision,
                                        state: state
                                    )
                                } else {
                                    SourceLandingSectionPreview(
                                        source: source,
                                        section: section,
                                        selectedKind: selectedKind,
                                        filters: filterSelections,
                                        sortID: effectiveSortID,
                                        refreshRevision: landingRefreshRevision,
                                        state: state
                                    )
                                }
                            }
                            .id(section.id)
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 20)
            }
            .scrollPosition($session.landingScrollPosition)
            .accessibilityIdentifier(initialCoversReady ? "source-catalog-five-covers-ready" : "source-catalog-scroll")
            .accessibilityValue(sourceAuditTimingValue)
            .scrollDismissesKeyboard(.interactively)
            .observesCollapsingHeader(
                $landingHeaderState,
                isEnabled: !isSearching && !isEditingSearch,
                onUserScroll: dismissSearchForScroll
            )
            .refreshable {
                do {
                    try await model.sourcesModel.invalidateContentCache(for: source)
                    await loadSearchConfiguration(force: true)
                    await loadLandingStructure(force: true)
                    landingRefreshRevision &+= 1
                } catch { model.sourcesModel.show(error, title: "Couldn’t refresh source") }
            }
        }
    }

    @ViewBuilder
    private var selectedSearchFilters: some View {
        SourceSearchFilterCapsules(
            selections: searchSelections,
            configuration: isLoadingSearchConfiguration || searchConfigurationError != nil ? nil : searchConfiguration,
            persistentExclusions: persistentExclusions,
            onChange: updateSearchFilter
        )
    }

    private func updateSearchFilter(_ selection: SourceSearchSelection, _ polarity: SourceSearchPolarity?) {
        do {
            searchSelections = try SourceSearchFilterPolicy.updating(
                selection, polarity: polarity, in: searchSelections,
                configuration: isLoadingSearchConfiguration || searchConfigurationError != nil ? nil : searchConfiguration,
                persistentExclusions: persistentExclusions
            )
            structuredQueryMessage = nil
        } catch {
            structuredQueryMessage = error.localizedDescription
        }
    }

    private func searchStatus<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
                selectedSearchFilters
                content().frame(maxWidth: .infinity)
            }
            .padding(.horizontal, PublicationGridLayout.contentMargin)
            .padding(.vertical, AppLayout.sectionSpacing)
        }
        .scrollDismissesKeyboard(.interactively)
        .observesCollapsingHeader($searchHeaderState, isEnabled: !isEditingSearch, onUserScroll: dismissSearchForScroll)
    }

    @ViewBuilder
    private var searchPresentation: some View {
        switch searchPresentationState {
        case .loading:
            searchStatus {
                Group {
                    if searchResultsLayout == .grid {
                        SourceGallerySkeletonContent(presentation: .sourceSearch)
                    } else {
                        SourceDenseResultsSkeletonContent()
                    }
                }
                .sourceSkeletonContainer(accessibilityLabel: "Searching \(source.name)")
            }
        case .verification:
            searchStatus {
                ContentUnavailableView {
                    Label("Verification required", systemImage: "checkmark.shield")
                } description: {
                    Text("Complete the visible source verification, then Manko will retry automatically.")
                } actions: {
                    Button("Retry") { Task { await retrySearch() } }
                        .buttonStyle(.borderedProminent)
                        .tint(AppColors.actionFill)
                        .foregroundStyle(AppColors.onAction)
                }
            }
        case let .connectionError(message):
            searchStatus {
                ContentUnavailableView {
                    Text("Connection failed").font(.title2.bold())
                } description: {
                    Text(message)
                } actions: {
                    searchRetryAction
                }
            }
        case let .emptySearch(searchText):
            searchStatus {
                ContentUnavailableView {
                    Label("No results", systemImage: "magnifyingglass")
                } description: {
                    Text("No titles matched “\(searchText)”.")
                }
            }
        case .emptyDiscovery:
            searchStatus { EmptyView() }
        case .results:
            searchResults
        }
    }

    private var searchResults: some View {
        @Bindable var session = session
        return ScrollView {
            VStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
                selectedSearchFilters
                Group {
                    if searchResultsLayout == .grid {
                        SourceSearchWorkGrid(works: session.searchWorks)
                            .transition(.opacity)
                    } else {
                        SourceSearchWorkList(works: session.searchWorks)
                            .transition(.opacity)
                    }
                }

                if session.isSearchAwaitingVerification {
                    AppInlineStatus(
                        title: "Verification required",
                        message: "Loaded titles are preserved. Complete source verification, then retry.",
                        systemImage: "checkmark.shield",
                        actionTitle: "Retry"
                    ) { Task { await retrySearch() } }
                } else if let searchErrorMessage = session.searchErrorMessage,
                   !session.searchWorks.isEmpty {
                    AppInlineStatus(
                        title: session.searchFailedPage == 1 ? "Couldn’t refresh results" : "Couldn’t load more",
                        message: searchErrorMessage,
                        actionTitle: "Retry"
                    ) {
                        Task {
                            await loadSearch(
                                page: session.searchFailedPage ?? 1,
                                query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                                requestIdentity: searchIdentity,
                                force: true
                            )
                        }
                    }
                    .padding(.vertical, 8)
                }

                if session.isLoadingSearch, (session.searchLoadingPage ?? 1) > 1 {
                    Group {
                        if searchResultsLayout == .grid { SourceGallerySkeletonContent(rowCount: 1, presentation: .sourceSearch) }
                        else { SourceDenseResultsSkeletonContent(itemCount: 3) }
                    }.sourceSkeletonContainer(accessibilityLabel: "Loading more results")
                        .frame(maxWidth: .infinity)
                }

                if let nextPage = session.searchNextPage {
                    SourceCatalogPaginationSentinel(
                        nextPage: nextPage,
                        isLoading: session.isLoadingSearch,
                        hasError: session.searchErrorMessage != nil || session.isSearchAwaitingVerification,
                        isPaused: session.searchAutomaticPaginationPaused,
                        isVisible: $session.isSearchBottomSentinelVisible
                    ) { page in
                        guard session.searchRequestIdentity == searchIdentity,
                              session.searchNextPage == page,
                              session.searchErrorMessage == nil, !session.isSearchAwaitingVerification,
                              !session.searchAutomaticPaginationPaused else { return }
                        await loadSearch(page: page, query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                                         requestIdentity: searchIdentity)
                    }
                    .id(searchIdentity)
                }
            }
            .padding(.horizontal, PublicationGridLayout.contentMargin)
            .padding(.top, AppLayout.sectionSpacing)
            .padding(.bottom, PublicationGridLayout.contentMargin)
            .padding(.bottom)
        }
        .scrollPosition($session.searchScrollPosition)
        .scrollDismissesKeyboard(.interactively)
        .observesCollapsingHeader($searchHeaderState, isEnabled: !isEditingSearch, onUserScroll: dismissSearchForScroll)
        .accessibilityIdentifier("source-search-results-scroll")
        .refreshable {
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            await loadSearch(
                page: 1,
                query: trimmedQuery,
                requestIdentity: searchIdentity,
                force: true
            )
        }
    }

    private var searchResultsHeader: some View {
        SourceSearchResultsHeader(selection: Binding(
            get: { searchResultsLayout },
            set: { layout in
                withAnimation(searchLayoutAnimation) {
                    searchResultsLayoutStorage = layout.rawValue
                }
            }
        ))
    }

    private var searchResultsLayout: SourceSearchResultsLayout {
        SourceSearchResultsLayout(storedValue: searchResultsLayoutStorage)
    }

    private var searchLayoutAnimation: Animation? {
        accessibilityReduceMotion
            ? nil
            : .smooth(duration: 0.22, extraBounce: 0)
    }

    private var searchRetryAction: some View {
        Button("Retry") { Task { await retrySearch() } }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.actionFill)
            .foregroundStyle(AppColors.onAction)
    }

    private func retrySearch() async {
        await loadSearch(
            page: session.searchFailedPage ?? 1,
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            requestIdentity: searchIdentity,
            force: true
        )
    }

    private var searchPresentationState: SourceCatalogPresentationState {
        .resolve(
            hasWorks: !session.searchWorks.isEmpty || (
                session.searchNextPage != nil && session.searchErrorMessage == nil && !session.isSearchAwaitingVerification
            ),
            isLoading: session.isLoadingSearch,
            isAwaitingVerification: session.isSearchAwaitingVerification,
            errorMessage: session.searchErrorMessage,
            query: searchDisplayText
        )
    }

    private func loadLandingStructure(force: Bool = false) async {
        let intent: SourceCatalogLoadIntent = force ? .userInitiated : .automatic
        let loadID = UUID()
        currentLandingLoadID = loadID
        isLoadingLandingStructure = true
        landingErrorMessage = nil
        isLandingAwaitingVerification = false
        defer {
            if currentLandingLoadID == loadID {
                isLoadingLandingStructure = false
                currentLandingLoadID = nil
            }
        }
        do {
            let sections = try await model.sourcesModel.sourceDiscoverSections(
                for: source, force: force,
                recoveryMode: intent.recoveryMode(hasContent: !landingSections.isEmpty)
            ) { cached in
                guard !Task.isCancelled, currentLandingLoadID == loadID, landingSections.isEmpty else { return }
                let arranged = SourceLandingSectionClassifier.arrange(cached)
                session.reconcileSections(arranged.map(\.id))
                landingSections = arranged
                hasLoadedLandingStructure = true
            }
            guard !Task.isCancelled, currentLandingLoadID == loadID else { return }
            let arrangedSections = SourceLandingSectionClassifier.arrange(sections)
            let loadedSkeletonSections = arrangedSections.map { section in
                SourceSkeletonSectionDescriptor(
                    id: section.sourceSectionID,
                    title: section.title,
                    subtitle: section.subtitle,
                    kind: section.role == .carousel ? .shelf : .gallery
                )
            }
            SourceSkeletonLayoutStore().save(
                loadedSkeletonSections,
                sourceID: source.id.rawValue
            )
            skeletonSections = SourceSkeletonLayoutPolicy.bounded(loadedSkeletonSections)
            session.reconcileSections(arrangedSections.map(\.id))
            landingSections = arrangedSections
            hasLoadedLandingStructure = true
            landingErrorMessage = nil
            isLandingAwaitingVerification = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, currentLandingLoadID == loadID else { return }
            guard !intent.keepsFailureQuiet(hasContent: !landingSections.isEmpty) else { return }
            if model.sourcesModel.handleCloudflareHandoff(error) {
                landingErrorMessage = nil
                isLandingAwaitingVerification = true
            } else {
                landingErrorMessage = error.localizedDescription
                isLandingAwaitingVerification = false
            }
        }
    }

    private func loadSearchConfiguration(force: Bool = false) async {
        guard !isLoadingSearchConfiguration else { return }
        let intent: SourceCatalogLoadIntent = force ? .userInitiated : .automatic
        isLoadingSearchConfiguration = true
        searchConfigurationError = nil
        isConfigurationAwaitingVerification = false
        defer { isLoadingSearchConfiguration = false }
        do {
            let configuration = try await model.sourcesModel.sourceSearchConfiguration(
                for: source, force: force,
                recoveryMode: intent.recoveryMode(hasContent: hasLoadedSearchConfiguration)
            ) { cached in
                guard !Task.isCancelled, !hasLoadedSearchConfiguration else { return }
                searchConfiguration = cached
                hasLoadedSearchConfiguration = true
            }
            try Task.checkCancellation()
            searchConfiguration = configuration
            hasLoadedSearchConfiguration = true
            if selectedSortID == nil || !(configuration?.sortOptions.contains { $0.id == selectedSortID } ?? false) {
                selectedSortID = configuration?.defaultSortID
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            guard !intent.keepsFailureQuiet(hasContent: hasLoadedSearchConfiguration) else { return }
            isConfigurationAwaitingVerification = model.sourcesModel.handleCloudflareHandoff(error)
            searchConfigurationError = isConfigurationAwaitingVerification
                ? "Complete source verification to load its filters."
                : error.localizedDescription
        }
    }

    private func loadSearch(
        page: Int,
        query: String,
        requestIdentity: String,
        force: Bool = false
    ) async {
        guard isSearching, !isIncompleteStructuredDraft, requestIdentity == searchIdentity else { return }
        if SourceCatalogRequestPolicy.shouldReset(
            currentIdentity: session.searchRequestIdentity, requestedIdentity: requestIdentity
        ) {
            guard page == 1 else { return }
            session.resetSearch(for: requestIdentity)
        }
        if page == 1 {
            guard SourceCatalogRequestPolicy.shouldLoad(
                completedIdentity: session.completedSearchIdentity,
                requestedIdentity: requestIdentity,
                isLoading: session.isLoadingSearch,
                force: force
            ) else { return }
        } else {
            guard !session.isLoadingSearch,
                  session.searchNextPage == page || session.searchFailedPage == page else { return }
        }
        let retrying = session.searchFailedPage == page
        let previousCount = retrying
            ? (session.searchFailedPagePreviousCount ?? session.searchWorks.count) : session.searchWorks.count
        let intent: SourceCatalogLoadIntent = force || retrying || page > 1 ? .userInitiated : .automatic
        let requestedCursor = page > 1 ? (retrying ? session.searchFailedCursor : session.searchNextCursor) : nil
        let progress = SourceCatalogProgressPresentation(existing: session.searchWorks, page: page, previousCount: previousCount)
        let loadID = UUID()
        session.currentSearchLoadID = loadID
        session.isLoadingSearch = true
        session.searchLoadingPage = page
        session.searchErrorMessage = nil
        session.isSearchAwaitingVerification = false
        defer {
            if session.currentSearchLoadID == loadID {
                session.isLoadingSearch = false
                session.searchLoadingPage = nil
                session.currentSearchLoadID = nil
            }
        }
        do {
            if let searchConfiguration {
                try searchConfiguration.validate(selections: model.sourcesModel.effectiveSearchSelections(for: source, temporary: searchSelections), sortID: effectiveSortID, query: query)
            }
            let result = try await model.sourcesModel.browse(
                source,
                page: page,
                text: query,
                filters: filterSelections,
                searchSelections: searchSelections,
                sortID: effectiveSortID,
                cursor: requestedCursor,
                force: force || retrying,
                recoveryMode: intent.recoveryMode(hasContent: !session.searchWorks.isEmpty, page: page),
                onProgress: { works in
                    guard SourceCatalogRequestPolicy.acceptsResult(
                        loadID: loadID, currentLoadID: session.currentSearchLoadID,
                        requestedIdentity: requestIdentity, currentIdentity: searchIdentity
                    ), let visible = progress.update(works) else { return }
                    session.searchWorks = visible
                },
                onCached: { cached in
                    progress.receivedCachedPage()
                    guard SourceCatalogRequestPolicy.acceptsResult(
                        loadID: loadID, currentLoadID: session.currentSearchLoadID,
                        requestedIdentity: requestIdentity, currentIdentity: searchIdentity
                    ) else { return }
                    if page == 1, !session.searchWorks.isEmpty { return }
                    session.searchWorks = SourceLatestGalleryPolicy.merging(existing: page == 1 ? [] : session.searchWorks, incoming: cached.items)
                    session.searchNextPage = cached.nextPage
                    session.searchNextCursor = cached.nextCursor
                    session.searchLoadedPages.insert(page)
                }
            )
            guard SourceCatalogRequestPolicy.acceptsResult(
                loadID: loadID, currentLoadID: session.currentSearchLoadID,
                requestedIdentity: requestIdentity, currentIdentity: searchIdentity
            ) else { return }
            if page == 1 {
                let window = try await model.sourcesModel.refreshedPageWindow(first: result, loadedPages: session.searchLoadedPageCount) { next, cursor in
                    try await model.sourcesModel.browse(source, page: next, text: query,
                        filters: filterSelections, searchSelections: searchSelections,
                        sortID: effectiveSortID, cursor: cursor,
                        recoveryMode: intent.recoveryMode(hasContent: !session.searchWorks.isEmpty))
                }
                guard SourceCatalogRequestPolicy.acceptsResult(
                    loadID: loadID, currentLoadID: session.currentSearchLoadID,
                    requestedIdentity: requestIdentity, currentIdentity: searchIdentity
                ) else { return }
                session.completedSearchIdentity = requestIdentity
                session.searchWorks = window.result.items
                session.searchLoadedPages = window.pages
                session.searchNextPage = window.result.nextPage; session.searchNextCursor = window.result.nextCursor
            } else {
                session.searchWorks = SourceLatestGalleryPolicy.merging(
                    existing: progress.previousWorks,
                    incoming: result.items
                )
                if SourceCatalogPaginationPolicy.isStalled(
                    page: page, previousCount: previousCount, resultCount: session.searchWorks.count,
                    requestedCursor: requestedCursor, nextPage: result.nextPage, nextCursor: result.nextCursor
                ) {
                    session.searchAutomaticPaginationPaused = true
                    throw SourceCatalogPaginationError.stalled
                }
                session.searchLoadedPages.insert(page)
                session.searchNextPage = result.nextPage
                session.searchNextCursor = result.nextCursor
            }
            session.searchAutomaticPaginationPaused = false
            session.searchErrorMessage = nil
            session.isSearchAwaitingVerification = false
            session.searchFailedPage = nil
            session.searchFailedCursor = nil
            session.searchFailedPagePreviousCount = nil
        } catch is CancellationError {
            return
        } catch {
            guard SourceCatalogRequestPolicy.acceptsResult(
                loadID: loadID, currentLoadID: session.currentSearchLoadID,
                requestedIdentity: requestIdentity, currentIdentity: searchIdentity
            ) else { return }
            guard progress.hasUpdates || !intent.keepsFailureQuiet(hasContent: !session.searchWorks.isEmpty, page: page) else { return }
            session.searchFailedPage = page
            session.searchFailedCursor = requestedCursor
            session.searchFailedPagePreviousCount = previousCount
            if model.sourcesModel.handleCloudflareHandoff(error) {
                session.searchErrorMessage = nil
                session.isSearchAwaitingVerification = true
            } else {
                session.searchErrorMessage = error.localizedDescription
                session.isSearchAwaitingVerification = false
            }
        }
    }

    private var isSearching: Bool {
        let hasSearchableText = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isIncompleteStructuredDraft
        return hasSearchableText || !searchSelections.isEmpty
    }

    private var isIncompleteStructuredDraft: Bool {
        guard let context = suggestionContext else { return false }
        return context.field != nil
    }

    private var searchDisplayText: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return searchSelections.map(\.title).joined(separator: ", ")
    }

    private var searchPlacement: SearchFieldPlacement {
#if targetEnvironment(macCatalyst)
        .toolbar
#else
        if #available(iOS 26.0, *) {
            .toolbar
        } else {
            horizontalSizeClass == .compact ? .navigationBarDrawer(displayMode: .always) : .toolbar
        }
#endif
    }

    private var isEditingSearch: Bool { isSearchFocused || isSearchPresented }

    private func submitSearch() {
        Task {
            guard !isComposingSearch, await submitStructuredQuery() else { return }
            finishSearchEditing()
            if isSearching {
                await loadSearch(page: 1, query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                                 requestIdentity: searchIdentity)
            }
        }
    }

    private func finishSearchEditing() {
        isSearchFocused = false
        isComposingSearch = false
        isSearchPresented = false
    }

    private func dismissSearchForScroll() {
        if isEditingSearch || isSearchPresented { finishSearchEditing() }
    }

    private var searchPresentationBinding: Binding<Bool> {
        Binding(
            get: { isSearchPresented },
            set: { isPresented in
                withAnimation(AppSelectionTransition.animation(reduceMotion: accessibilityReduceMotion)) {
                    isSearchPresented = isPresented
#if !targetEnvironment(macCatalyst)
                    if !isPresented {
                        isSearchFocused = false
                        isComposingSearch = false
                    }
#endif
                }
            }
        )
    }

    private var searchIdentity: String {
        let filters = filterSelections
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        let selections = searchSelections
            .map { "\($0.fieldID)=\($0.polarity.rawValue):\($0.value)" }
            .sorted()
            .joined(separator: "&")
        let exclusions = persistentExclusions
            .map { "\($0.fieldID)=\($0.value)" }
            .sorted()
            .joined(separator: "&")
        return "\(didLoadFilterDefaults)|\(query)|\(selectedKind?.rawValue ?? "all")|\(filters)|\(selections)|\(exclusions)|\(effectiveSortID ?? "default")"
    }

    private var queryFilterDefinitions: [SourceFilterDefinition] {
        CompiledSourceFilterCatalog.shared.definitions(for: source.kind, scope: .query)
    }

    private var sourceSortToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            FixedNavigationChrome {
                SourceCatalogSortMenu(
                    definitions: queryFilterDefinitions,
                    defaults: filterDefaults,
                    configuration: searchConfiguration,
                    selectedSortID: $selectedSortID,
                    filterSelections: $filterSelections,
                    onSelectSort: browseSortSelectionAction
                )
            }
        }
    }

    private var browseSortSelectionAction: ((String?) -> Void)? {
        guard searchConfiguration?.sortedBrowseSectionID != nil else { return nil }
        return { sortID in selectBrowseSort(sortID) }
    }

    private func selectBrowseSort(_ sortID: String?) {
        selectedSortID = sortID
        session.selectBrowseSort()
        landingHeaderState.reset()
        // A repeated selection (including the initial Newest) still opens page one.
        landingRefreshRevision &+= 1
    }

    private var sourceAuditTimingValue: String {
#if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["MANKO_SOURCE_AUDIT"] == "1",
           let initialCoversReadyUptime {
            return String(initialCoversReadyUptime)
        }
#endif
        return ""
    }

    private var initialCoverWorks: [Work] {
        guard source.kind == .mankoExtension,
              let first = displayedLandingSections.first,
              let state = session.sectionState(for: first.id) else { return [] }
        return Array(state.works.prefix(5))
    }

    private var initialCoverIdentity: String {
        ([String(model.sourcesModel.contentRevisions[source.id, default: 0])]
            + initialCoverWorks.map { model.sourcesModel.coverCacheKey(for: $0) }).joined(separator: "|")
    }

    private var mayLoadSecondarySections: Bool {
        guard source.kind == .mankoExtension,
              let first = displayedLandingSections.first,
              let state = session.sectionState(for: first.id) else { return true }
        return initialCoversFinished || state.errorMessage != nil || state.isAwaitingVerification
            || (state.completedIdentity != nil && state.works.isEmpty)
    }

    private var displayedLandingSections: [SourceLandingSectionDescriptor] {
        SourceCatalogBrowsePolicy.sections(
            landingSections, configuration: searchConfiguration,
            selectedSortID: selectedSortID, hasSelectedSort: session.hasSelectedBrowseSort
        )
    }

    private var showsSortMenu: Bool {
#if !targetEnvironment(macCatalyst)
        if horizontalSizeClass == .compact && isEditingSearch { return false }
#endif
        return SourceCatalogFilterPolicy.showsSorting(
            definitions: queryFilterDefinitions,
            configuration: searchConfiguration
        )
    }

    private var persistentExclusions: [SourceSearchSelection] {
        model.sourcesModel.persistentSearchExclusions(for: source)
    }

    private var effectiveSortID: String? {
        SourceCatalogBrowsePolicy.effectiveSortID(
            selectedSortID: selectedSortID, configuration: searchConfiguration,
            hasSelectedSort: session.hasSelectedBrowseSort
        )
    }

    private var suggestionContext: SourceCatalogQueryContext? {
        guard let searchConfiguration else { return nil }
        return SourceCatalogQueryParser.context(in: query, fields: searchConfiguration.fields)
    }

    private var suggestionIdentity: String {
        guard let context = suggestionContext else { return "none" }
        return [
            isEditingSearch && !isComposingSearch ? "editing" : "inactive",
            String(model.sourcesModel.contentCacheActivationRevision),
            context.field?.id ?? "all",
            context.value,
            context.isExcluding ? "exclude" : "include",
            searchSelections.map(\.id).sorted().joined(separator: "&"),
        ].joined(separator: "|")
    }

    @ViewBuilder
    private var searchSuggestionRows: some View {
        if isEditingSearch, let context = suggestionContext {
            let values = mergedValueSuggestions(for: context)
            if !values.isEmpty {
                Section(context.value.isEmpty ? "Recent tags" : "Suggestions") {
                    ForEach(values) { suggestion in
                        Button { selectSuggestion(suggestion, context: context) } label: {
                            SourceSearchSuggestionRow(
                                title: (context.isExcluding ? "Exclude " : "") + suggestion.title,
                                subtitle: searchConfiguration?.fields.first { $0.id == suggestion.fieldID }?.title
                            )
                        }
                        .accessibilityHint(context.isExcluding ? "Adds an excluded search tag" : "Adds a search tag")
                    }
                }
            }
            if context.field == nil, context.value.isEmpty {
                Section("Search by") {
                    ForEach(operatorSuggestions(excluding: context.isExcluding)) { field in
                        Button { selectOperator(field, excluding: context.isExcluding) } label: {
                            Label(field.title, systemImage: "line.3.horizontal.decrease")
                        }
                    }
                }
            }
            if suggestionLoader.isWaiting {
                Text("Waiting for typing to finish…").foregroundStyle(.secondary)
            } else if suggestionLoader.isLoading {
                Label("Loading suggestions…", systemImage: "ellipsis")
            } else if let error = suggestionLoader.errorMessage {
                Text(error)
                Button("Retry Suggestions") { suggestionRetryRevision &+= 1 }
            } else if values.isEmpty, context.value.count >= 2,
                      suggestionLoader.completedRequest?.query == context.value,
                      suggestionLoader.completedRequest?.fieldID == context.field?.id {
                Text("No matching suggestions").foregroundStyle(.secondary)
            }
        }
    }

    private func operatorSuggestions(excluding: Bool) -> [SourceSearchField] {
        (searchConfiguration?.fields ?? []).filter { field in
            !excluding || field.supportsExclusion
        }
    }

    private func mergedValueSuggestions(
        for context: SourceCatalogQueryContext
    ) -> [SourceSearchSuggestion] {
        let local = model.sourcesModel.localSourceSuggestions(for: source.id, query: context.value, fieldID: context.field?.id)
        let values = SourceCatalogSuggestionPolicy.mergedSuggestions(
            context: context,
            configuration: searchConfiguration,
            remote: suggestionLoader.suggestions,
            local: local
        )
        if context.field == nil, context.value.isEmpty {
            let recent = Set(local.map(\.id))
            return values.filter { recent.contains($0.id) }
        }
        return values
    }

    private func selectOperator(_ field: SourceSearchField, excluding: Bool) {
        let prefix = (excluding && field.supportsExclusion ? "-" : "") + field.queryPrefix
        query = prefix
    }

    private func selectSuggestion(
        _ suggestion: SourceSearchSuggestion,
        context: SourceCatalogQueryContext
    ) {
        searchSelections = SourceCatalogSuggestionPolicy.selecting(
            suggestion,
            configuration: searchConfiguration,
            excluding: context.isExcluding,
            current: searchSelections
        )
        Task { await model.sourcesModel.learnSourceSuggestions([suggestion], for: source.id, selected: true) }
        query = context.remainingQuery
        structuredQueryMessage = nil
        suggestionLoader.clearSuggestions()
    }

    private func submitStructuredQuery() async -> Bool {
        guard let context = suggestionContext, let field = context.field, let searchConfiguration else { return true }
        let submittedQuery = query
        if field.resolvedInputKind == .lookup {
            let normalized = SourceSearchMatching.normalized(context.value)
            let hasExact = mergedValueSuggestions(for: context).contains {
                SourceSearchMatching.normalized($0.title) == normalized || SourceSearchMatching.normalized($0.value) == normalized
            }
            if !hasExact { await loadValueSuggestions(explicit: true) }
        }
        guard !Task.isCancelled, query == submittedQuery else { return false }
        let candidates: [SourceSearchSuggestion]
        if field.resolvedInputKind == .text || field.resolvedInputKind == .number {
            candidates = context.value.isEmpty ? [] : [.init(fieldID: field.id, value: context.value)]
        } else {
            let normalized = SourceSearchMatching.normalized(context.value)
            candidates = mergedValueSuggestions(for: context).filter {
                SourceSearchMatching.normalized($0.title) == normalized || SourceSearchMatching.normalized($0.value) == normalized
            }
        }
        guard candidates.count == 1, let suggestion = candidates.first else {
            structuredQueryMessage = "Choose a matching tag or filter value."
            return false
        }
        do {
            let proposed = SourceCatalogSuggestionPolicy.selecting(suggestion, configuration: searchConfiguration, excluding: context.isExcluding, current: searchSelections)
            try searchConfiguration.validate(selections: proposed)
            selectSuggestion(suggestion, context: context)
            return true
        } catch {
            structuredQueryMessage = error.localizedDescription
            return false
        }
    }

    private func loadValueSuggestions(explicit: Bool = false) async {
        let identity = suggestionIdentity
        let request = (isEditingSearch && !isComposingSearch || explicit ? suggestionContext : nil).flatMap { context -> SourceSearchSuggestionRequest? in
            if let field = context.field, field.resolvedInputKind != .lookup { return nil }
            return SourceSearchSuggestionRequest(
                fieldID: context.field?.id,
                query: context.value,
                selections: searchSelections,
                limit: 20
            )
        }
        await suggestionLoader.load(
            request: request,
            local: suggestionContext.map {
                model.sourcesModel.localSourceSuggestions(for: source.id, query: $0.value, fieldID: $0.field?.id)
            } ?? [],
            explicit: explicit,
            isCurrent: { suggestionIdentity == identity },
            fetch: { request in
                try await model.sourcesModel.sourceSearchSuggestions(for: source, request: request, onCached: { values in
                    guard suggestionIdentity == identity else { return }
                    suggestionLoader.acceptCached(values, for: request)
                })
            },
            handleVerification: { model.sourcesModel.handleCloudflareHandoff($0) }
        )
    }

}
