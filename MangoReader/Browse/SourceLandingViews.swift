import MangoReaderDomain
import MangoReaderExtensions
import MangoReaderSources
import Observation
import SwiftUI

struct SourceLandingSectionPreview: View {
    @Environment(AppModel.self) private var model
    let source: SourceDescriptor
    let section: SourceLandingSectionDescriptor
    let selectedKind: ContentKind?
    let filters: [String: String]
    let sortID: String?
    let refreshRevision: Int
    let state: SourceCatalogSectionState

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 14) {
            SourceLandingSectionHeader(section: section)
                .padding(.horizontal, PublicationGridLayout.contentMargin)

            if SourceSkeletonVisibilityPolicy.shouldShow(
                isLoading: state.isLoading,
                contentCount: state.works.count
            ) {
                SourceShelfSkeletonContent()
                    .sourceSkeletonContainer(accessibilityLabel: "Loading \(section.title)")
            } else if state.works.isEmpty, state.isAwaitingVerification {
                AppInlineStatus(
                    title: "Verification required",
                    message: "Complete source verification, then try this section again.",
                    systemImage: "checkmark.shield",
                    actionTitle: "Retry"
                ) {
                    state.retryRevision &+= 1
                }
                .padding(.vertical, 8)
                .padding(.horizontal, PublicationGridLayout.contentMargin)
            } else if state.works.isEmpty, let errorMessage = state.errorMessage {
                AppInlineStatus(
                    title: "Section unavailable",
                    message: errorMessage,
                    actionTitle: "Retry"
                ) {
                    state.retryRevision &+= 1
                }
                .padding(.vertical, 8)
                .padding(.horizontal, PublicationGridLayout.contentMargin)
            } else if state.works.isEmpty {
                Text("No titles available in this section.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, PublicationGridLayout.contentMargin)
            } else {
                SourceWorkShelf(
                    works: state.works,
                    scrollPosition: $state.shelfScrollPosition
                )

                if state.isAwaitingVerification {
                    AppInlineStatus(
                        title: "Verification required",
                        message: "Loaded titles are preserved. Complete source verification, then retry.",
                        systemImage: "checkmark.shield",
                        actionTitle: "Retry"
                    ) {
                        state.retryRevision &+= 1
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, PublicationGridLayout.contentMargin)
                } else if let errorMessage = state.errorMessage {
                    AppInlineStatus(
                        title: "Couldn’t refresh section",
                        message: errorMessage,
                        actionTitle: "Retry"
                    ) {
                        state.retryRevision &+= 1
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, PublicationGridLayout.contentMargin)
                }
            }
        }
        .task(id: taskIdentity) {
            await load()
        }
        .onAppear {
            guard state.completedIdentity != nil else { return }
            state.completedIdentity = nil
            Task { await load() }
        }
        .onChange(of: model.sourcesModel.contentCacheActivationRevision) { _, _ in
            state.completedIdentity = nil
            Task { await load() }
        }
    }

    private func load() async {
        let requestedIdentity = requestIdentity
        let force = state.appliedRefreshRevision != refreshRevision
            || state.appliedRetryRevision != state.retryRevision
            || state.isAwaitingVerification
        let intent: SourceCatalogLoadIntent = force ? .userInitiated : .automatic
        state.appliedRefreshRevision = refreshRevision
        state.appliedRetryRevision = state.retryRevision

        if SourceCatalogRequestPolicy.shouldReset(
            currentIdentity: state.requestIdentity,
            requestedIdentity: requestedIdentity
        ) {
            state.reset(for: requestedIdentity)
            state.appliedRefreshRevision = refreshRevision
            state.appliedRetryRevision = state.retryRevision
        }
        guard SourceCatalogRequestPolicy.shouldLoad(
            completedIdentity: state.completedIdentity,
            requestedIdentity: requestedIdentity,
            isLoading: state.isLoading,
            force: force
        ) else { return }

        let progress = SourceCatalogProgressPresentation(existing: state.works, page: 1, previousCount: 0)
        let loadID = UUID()
        state.currentLoadID = loadID
        state.isLoading = true
        state.errorMessage = nil
        state.isAwaitingVerification = false
        defer {
            if state.currentLoadID == loadID {
                state.isLoading = false
                state.currentLoadID = nil
            }
        }
        do {
            let kinds = selectedKind.map { Set([$0]) } ?? []
            let page = try await model.sourcesModel.discover(
                source,
                sectionID: section.sourceSectionID,
                kinds: kinds,
                filters: filters,
                sortID: sortID,
                force: force,
                recoveryMode: intent.recoveryMode(hasContent: !state.works.isEmpty),
                onProgress: { works in
                    guard SourceCatalogRequestPolicy.acceptsResult(
                        loadID: loadID, currentLoadID: state.currentLoadID,
                        requestedIdentity: requestedIdentity, currentIdentity: state.requestIdentity
                    ), let visible = progress.update(works) else { return }
                    state.works = visible
                },
                onCached: { cached in
                    progress.receivedCachedPage()
                    guard SourceCatalogRequestPolicy.acceptsResult(
                        loadID: loadID, currentLoadID: state.currentLoadID,
                        requestedIdentity: requestedIdentity, currentIdentity: state.requestIdentity
                    ) else { return }
                    if state.works.isEmpty {
                        state.works = SourceLatestGalleryPolicy.merging(existing: [], incoming: cached.items)
                    }
                }
            )
            guard SourceCatalogRequestPolicy.acceptsResult(
                loadID: loadID, currentLoadID: state.currentLoadID,
                requestedIdentity: requestedIdentity, currentIdentity: state.requestIdentity
            ) else { return }
            state.works = SourceLatestGalleryPolicy.merging(existing: [], incoming: page.items)
            state.completedIdentity = requestedIdentity
            state.errorMessage = nil
            state.isAwaitingVerification = false
        } catch is CancellationError {
            return
        } catch {
            guard SourceCatalogRequestPolicy.acceptsResult(
                loadID: loadID, currentLoadID: state.currentLoadID,
                requestedIdentity: requestedIdentity, currentIdentity: state.requestIdentity
            ) else { return }
            guard progress.hasUpdates || !intent.keepsFailureQuiet(hasContent: !state.works.isEmpty) else { return }
            if model.sourcesModel.handleCloudflareHandoff(error) {
                state.isAwaitingVerification = true
            } else {
                state.errorMessage = error.localizedDescription
            }
        }
    }

    private var requestIdentity: String {
        let filterIdentity = filters
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        return [
            section.id,
            selectedKind?.rawValue ?? "all",
            filterIdentity,
            sortID ?? "default",
            model.sourcesModel.persistentSearchExclusions(for: source).map(\.id).sorted().joined(separator: "&"),
        ].joined(separator: "|")
    }

    private var taskIdentity: String {
        [
            requestIdentity,
            String(refreshRevision),
            String(state.retryRevision),
            String(model.sourcesModel.cloudflareVerificationRevision),
        ].joined(separator: "|")
    }
}

private struct SourceLandingSectionHeader: View {
    let section: SourceLandingSectionDescriptor

    var body: some View {
        SourceSectionHeaderLayout(
            title: section.title,
            subtitle: section.subtitle
        )
    }
}

private struct SourceWorkShelf: View {
    @ScaledMetric(relativeTo: .body) private var scaledMinimumCoverWidth = SourceCatalogCoverLayoutPolicy.baseMinimumWidth
    let works: [Work]
    @Binding var scrollPosition: ScrollPosition

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(
                alignment: .top,
                spacing: SourceCatalogCoverLayoutPolicy.horizontalSpacing
            ) {
                ForEach(works) { work in
                    NavigationLink {
                        WorkDetailView(work: work)
                    } label: {
                        SourceShelfCard(work: work)
                    }
                    .buttonStyle(.plain)
                    .id(work.id)
                    .sourceCatalogShelfItemFrame(
                        minimumCoverWidth: minimumCoverWidth,
                        itemCount: works.count
                    )
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, PublicationGridLayout.contentMargin)
        }
        .scrollPosition($scrollPosition)
        .scrollIndicators(.hidden)
    }

    private var minimumCoverWidth: CGFloat {
        SourceCatalogCoverLayoutPolicy.minimumCoverWidth(
            scaledWidth: scaledMinimumCoverWidth
        )
    }
}

private struct SourceShelfCard: View {
    let work: Work

    var body: some View {
        SourceShelfCardLayout(
            title: work.title,
            metadata: work.latestChapterTitle,
            cover: RemoteCover(work: work)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens title details")
    }

    private var accessibilityLabel: String {
        guard let latestChapterTitle = work.latestChapterTitle else { return work.title }
        return "\(work.title), Latest chapter, \(latestChapterTitle)"
    }

}

struct SourceLatestGallery: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ScaledMetric(relativeTo: .body) private var scaledMinimumCoverWidth = SourceCatalogCoverLayoutPolicy.baseMinimumWidth
    let source: SourceDescriptor
    let section: SourceLandingSectionDescriptor
    let selectedKind: ContentKind?
    let filters: [String: String]
    let sortID: String?
    let refreshRevision: Int
    let state: SourceCatalogSectionState

    var body: some View {
        @Bindable var state = state
        let loadingPresentation = SourceLatestGalleryPolicy.loadingPresentation(
            isLoading: state.isLoading,
            loadingPage: state.loadingPage,
            contentCount: state.works.count
        )
        VStack(alignment: .leading, spacing: 14) {
            SourceLandingSectionHeader(section: section)

            if loadingPresentation == .initialSkeleton {
                SourceGallerySkeletonContent()
                    .sourceSkeletonContainer(accessibilityLabel: "Loading \(section.title)")
            } else if state.works.isEmpty, state.isAwaitingVerification {
                status(
                    title: "Verification required",
                    message: "Complete source verification, then retry this section.",
                    systemImage: "checkmark.shield"
                )
            } else if state.works.isEmpty, let errorMessage = state.errorMessage {
                status(
                    title: "\(section.title) unavailable",
                    message: errorMessage
                )
            } else if state.works.isEmpty {
                Text("No titles are available in this section.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: PublicationGridLayout.verticalSpacing) {
                    LazyVGrid(
                        columns: SourceCatalogCoverLayoutPolicy.columns(
                            minimumCoverWidth: minimumCoverWidth,
                            dynamicTypeSize: dynamicTypeSize,
                            horizontalSizeClass: horizontalSizeClass
                        ),
                        alignment: .leading,
                        spacing: PublicationGridLayout.verticalSpacing
                    ) {
                        ForEach(state.works) { work in
                            NavigationLink {
                                WorkDetailView(work: work)
                            } label: {
                                SourceLatestTile(work: work)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if loadingPresentation == .appendedSkeletons {
                        SourceGallerySkeletonContent(
                            rowCount: SourceLatestGalleryPolicy.paginationSkeletonRows
                        )
                            .sourceSkeletonContainer(
                                accessibilityLabel: "Loading more \(section.title)"
                            )
                    }
                }

                if state.isAwaitingVerification {
                    status(
                        title: "Verification required",
                        message: "Loaded titles are preserved. Complete source verification, then retry.",
                        systemImage: "checkmark.shield"
                    )
                } else if let errorMessage = state.errorMessage {
                    status(
                        title: state.failedPage == 1 ? "Couldn’t refresh section" : "Couldn’t load more",
                        message: errorMessage
                    )
                }

            }
            if let nextPage = state.nextPage {
                SourceCatalogPaginationSentinel(
                    nextPage: nextPage,
                    isLoading: state.isLoading,
                    hasError: state.errorMessage != nil || state.isAwaitingVerification,
                    isPaused: state.automaticPaginationPaused,
                    isVisible: $state.isBottomSentinelVisible
                ) { page in
                    guard state.requestIdentity == requestIdentity,
                          state.nextPage == page,
                          state.errorMessage == nil, !state.isAwaitingVerification,
                          !state.automaticPaginationPaused else { return }
                    await load(page: page)
                }
                .id(requestIdentity)
            }
        }
        .padding(.horizontal, PublicationGridLayout.contentMargin)
        .task(id: taskIdentity) {
            await loadInitialPageIfNeeded()
        }
        .onAppear {
            guard state.completedIdentity != nil else { return }
            state.completedIdentity = nil
            Task { await loadInitialPageIfNeeded() }
        }
        .onChange(of: model.sourcesModel.contentCacheActivationRevision) { _, _ in
            state.completedIdentity = nil
            Task { await loadInitialPageIfNeeded() }
        }
        .onChange(of: model.sourcesModel.cloudflareVerificationRevision) { _, _ in
            guard state.isAwaitingVerification,
                  let failedPage = state.failedPage
            else { return }
            Task { await load(page: failedPage) }
        }
    }

    private var minimumCoverWidth: CGFloat {
        SourceCatalogCoverLayoutPolicy.minimumCoverWidth(
            scaledWidth: scaledMinimumCoverWidth
        )
    }

    private func status(
        title: String,
        message: String,
        systemImage: String? = nil
    ) -> some View {
        AppInlineStatus(
            title: title,
            message: message,
            systemImage: systemImage,
            actionTitle: "Retry"
        ) {
            Task { await load(page: state.failedPage ?? 1) }
        }
        .padding(.vertical, 8)
    }

    private func loadInitialPageIfNeeded() async {
        let requestedIdentity = requestIdentity
        let force = state.appliedRefreshRevision != refreshRevision
        state.appliedRefreshRevision = refreshRevision
        if SourceCatalogRequestPolicy.shouldReset(
            currentIdentity: state.requestIdentity,
            requestedIdentity: requestedIdentity
        ) {
            state.reset(for: requestedIdentity)
            state.appliedRefreshRevision = refreshRevision
        }
        guard SourceCatalogRequestPolicy.shouldLoad(
            completedIdentity: state.completedIdentity,
            requestedIdentity: requestedIdentity,
            isLoading: state.isLoading,
            force: force
        ) else { return }
        await load(page: 1, requestedIdentity: requestedIdentity, force: force)
        // A source can return a small first batch so its first title is usable
        // immediately. Fill the first five without waiting for viewport geometry.
        for _ in 0..<4 {
            guard !Task.isCancelled, state.requestIdentity == requestedIdentity,
                  !state.isLoading, !state.works.isEmpty, state.works.count < 5,
                  state.errorMessage == nil, !state.isAwaitingVerification,
                  !state.automaticPaginationPaused, let next = state.nextPage else { break }
            await load(page: next, requestedIdentity: requestedIdentity)
        }
    }

    private func load(
        page: Int,
        requestedIdentity: String? = nil,
        force: Bool = false
    ) async {
        let activeIdentity = requestedIdentity ?? state.requestIdentity ?? requestIdentity
        guard !state.isLoading else { return }
        guard page == 1
                || state.nextPage == page
                || state.failedPage == page
        else { return }

        let retrying = state.failedPage == page
        let previousCount = retrying ? (state.failedPagePreviousCount ?? state.works.count) : state.works.count
        let progress = SourceCatalogProgressPresentation(existing: state.works, page: page, previousCount: previousCount)
        let loadID = UUID()
        let intent: SourceCatalogLoadIntent = force || retrying || page > 1 ? .userInitiated : .automatic
        let requestedCursor = page > 1 ? (retrying ? state.failedCursor : state.nextCursor) : nil
        state.currentLoadID = loadID
        state.loadingPage = page
        state.isLoading = true
        state.errorMessage = nil
        state.isAwaitingVerification = false
        state.failedPage = nil
        defer {
            if state.currentLoadID == loadID {
                state.isLoading = false
                state.loadingPage = nil
                state.currentLoadID = nil
            }
        }
        do {
            let kinds = selectedKind.map { Set([$0]) } ?? []
            let result = try await model.sourcesModel.discover(
                source,
                sectionID: section.sourceSectionID,
                page: page,
                kinds: kinds,
                filters: filters,
                sortID: sortID,
                cursor: requestedCursor,
                force: force || retrying,
                recoveryMode: intent.recoveryMode(hasContent: !state.works.isEmpty, page: page),
                onProgress: { works in
                    guard SourceCatalogRequestPolicy.acceptsResult(
                        loadID: loadID, currentLoadID: state.currentLoadID,
                        requestedIdentity: activeIdentity, currentIdentity: state.requestIdentity
                    ), let visible = progress.update(works) else { return }
                    state.works = visible
                },
                onCached: { cached in
                    progress.receivedCachedPage()
                    guard SourceCatalogRequestPolicy.acceptsResult(
                        loadID: loadID, currentLoadID: state.currentLoadID,
                        requestedIdentity: activeIdentity, currentIdentity: state.requestIdentity
                    ) else { return }
                    if page == 1, !state.works.isEmpty { return }
                    state.works = SourceLatestGalleryPolicy.merging(existing: page == 1 ? [] : state.works, incoming: cached.items)
                    state.nextPage = cached.nextPage
                    state.nextCursor = cached.nextCursor
                    state.loadedPages.insert(page)
                }
            )
            guard SourceCatalogRequestPolicy.acceptsResult(
                loadID: loadID, currentLoadID: state.currentLoadID,
                requestedIdentity: activeIdentity, currentIdentity: state.requestIdentity
            ) else { return }
            if page == 1 {
                let window = try await model.sourcesModel.refreshedPageWindow(first: result, loadedPages: state.loadedPageCount) { next, cursor in
                    try await model.sourcesModel.discover(source, sectionID: section.sourceSectionID,
                        page: next, kinds: kinds, filters: filters, sortID: sortID, cursor: cursor,
                        recoveryMode: intent.recoveryMode(hasContent: !state.works.isEmpty))
                }
                guard SourceCatalogRequestPolicy.acceptsResult(
                    loadID: loadID, currentLoadID: state.currentLoadID,
                    requestedIdentity: activeIdentity, currentIdentity: state.requestIdentity
                ) else { return }
                state.completedIdentity = activeIdentity
                state.works = window.result.items
                state.loadedPages = window.pages
                state.nextPage = window.result.nextPage; state.nextCursor = window.result.nextCursor
            } else {
                state.works = SourceLatestGalleryPolicy.merging(
                    existing: progress.previousWorks,
                    incoming: result.items
                )
                if SourceCatalogPaginationPolicy.isStalled(
                    page: page, previousCount: previousCount, resultCount: state.works.count,
                    requestedCursor: requestedCursor, nextPage: result.nextPage, nextCursor: result.nextCursor
                ) {
                    state.automaticPaginationPaused = true
                    throw SourceCatalogPaginationError.stalled
                }
                state.loadedPages.insert(page)
                state.nextPage = result.nextPage
                state.nextCursor = result.nextCursor
            }
            state.automaticPaginationPaused = false
            state.errorMessage = nil
            state.isAwaitingVerification = false
            state.failedPage = nil
            state.failedCursor = nil
            state.failedPagePreviousCount = nil
        } catch is CancellationError {
            return
        } catch {
            guard SourceCatalogRequestPolicy.acceptsResult(
                loadID: loadID, currentLoadID: state.currentLoadID,
                requestedIdentity: activeIdentity, currentIdentity: state.requestIdentity
            ) else { return }
            guard progress.hasUpdates || !intent.keepsFailureQuiet(hasContent: !state.works.isEmpty, page: page) else { return }
            state.failedPage = page
            state.failedCursor = requestedCursor
            state.failedPagePreviousCount = previousCount
            if model.sourcesModel.handleCloudflareHandoff(error) {
                state.errorMessage = nil
                state.isAwaitingVerification = true
            } else {
                state.errorMessage = error.localizedDescription
                state.isAwaitingVerification = false
            }
        }
    }

    private var requestIdentity: String {
        let filterIdentity = filters
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        return [
            section.id,
            selectedKind?.rawValue ?? "all",
            filterIdentity,
            sortID ?? "default",
            model.sourcesModel.persistentSearchExclusions(for: source).map(\.id).sorted().joined(separator: "&"),
        ].joined(separator: "|")
    }

    private var taskIdentity: String {
        "\(requestIdentity)|\(refreshRevision)"
    }
}

struct SourceLatestTile: View {
    let work: Work
    var presentation = SourceGalleryTilePresentation.standard

    var body: some View {
        SourceGalleryTileLayout(
            title: work.title,
            metadata: work.latestChapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            languageCode: work.languageCode,
            presentation: presentation,
            cover: RemoteCover(work: work)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens title details")
    }

    private var accessibilityLabel: String {
        if presentation == .sourceSearch {
            return SourceSearchResultAccessibilityPolicy.label(for: work)
        }
        guard let latestChapterTitle = work.latestChapterTitle else { return work.title }
        return "\(work.title), Latest chapter, \(latestChapterTitle)"
    }
}
