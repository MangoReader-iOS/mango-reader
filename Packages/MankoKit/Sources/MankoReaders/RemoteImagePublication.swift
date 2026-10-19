import Foundation
import MankoDomain
import MankoSources

/// Remote streams request visible pages first, then the configured lookahead
/// (two pages by default) and one behind. Cache capacity never widens the window.
public struct RemoteImagePageWindowPlanner: Hashable, Sendable {
    public let maximumCachedPages: Int

    public init(maximumCachedPages: Int = 12) {
        self.maximumCachedPages = min(64, max(2, maximumCachedPages))
    }

    public func pageIndices(for state: ImageReaderState) -> [Int] {
        Array(activePageIndices(for: state, visiblePageIndices: [state.currentPageIndex] + state.visiblePageIndices()).prefix(maximumCachedPages))
    }

    func activePageIndices(for state: ImageReaderState, visiblePageIndices: [Int], prefetch: ImagePrefetchSettings? = nil) -> [Int] {
        let prefetch = prefetch ?? state.settings.prefetch
        return ImagePageWindow.activePageIndices(for: state, visiblePageIndices: visiblePageIndices,
            pagesAhead: min(10, max(1, state.settings.options.preloadCount), prefetch.pagesAhead), pagesBehind: min(1, prefetch.pagesBehind))
    }

    public func requestBatches(for state: ImageReaderState) -> [[Int]] {
        pageIndices(for: state).map { [$0] }
    }
}

/// A chapter-scoped remote publication. Fetched bytes are kept in a disk cache
/// so evicting decoded pages does not require another source request.
public actor RemoteImagePublication {
    public nonisolated let sourcePages: [RemoteImagePageDescriptor]
    public nonisolated let pages: [ImagePageDescriptor]

    private let loader: any RemoteImagePageLoading
    private let maximumPageBytes: Int
    private let cacheScope: String?
    nonisolated var cachesPreviews: Bool { cacheScope != nil }
    private var temporary: [Int: RemoteImagePageContent] = [:]
    private var temporaryOrder: [Int] = []
    private var cachedIndices: Set<Int> = []

    public init(
        sourcePages: [RemoteImagePageDescriptor],
        loader: any RemoteImagePageLoading,
        maximumPageBytes: Int = 128 * 1_024 * 1_024,
        cacheScope: String? = nil
    ) {
        let orderedPages = sourcePages.sorted { lhs, rhs in
            if lhs.index != rhs.index {
                return lhs.index < rhs.index
            }
            return lhs.id < rhs.id
        }
        self.sourcePages = orderedPages
        self.loader = loader
        self.cacheScope = cacheScope
        self.maximumPageBytes = max(1, maximumPageBytes)
        pages = orderedPages.enumerated().map { position, page in
            ImagePageDescriptor(
                id: page.id,
                index: position,
                sourceURL: page.resourceURL
            )
        }
    }

    public func pageContent(at index: Int, priority: RemoteImageRequestPriority = .visible,
        onProgress: RemoteImageDownloadProgressHandler? = nil,
        onPartial: (@Sendable (RemoteImagePageContent) async -> Void)? = nil) async throws -> RemoteImagePageContent {
        guard sourcePages.indices.contains(index) else {
            throw ReaderError.pageIndexOutOfRange(index)
        }
        try Task.checkCancellation()
        if let cached = temporary[index] { return cached }
        if cacheScope != nil, let cached = await ContentCache.shared.entry(for: cacheKey(index)) {
            cachedIndices.insert(index)
            return RemoteImagePageContent(data: cached.data, mediaType: cached.mediaType)
        }
        let cacheToken = await ContentCache.shared.writeToken()
        let content: RemoteImagePageContent
        if let onProgress {
            content = try await loader.streamImagePageContent(for: sourcePages[index], priority: priority,
                onPartial: onPartial ?? { _ in }, onProgress: onProgress)
        }
        else if let onPartial { content = try await loader.streamImagePageContent(for: sourcePages[index], priority: priority, onPartial: onPartial) }
        else { content = try await loader.imagePageContent(for: sourcePages[index], priority: priority) }
        try Task.checkCancellation()
        let validated = try Self.validated(content, index: index, maximumPageBytes: maximumPageBytes)
        if cacheScope != nil {
            await ContentCache.shared.store(validated.data, for: cacheKey(index), mediaType: validated.mediaType, token: cacheToken)
        } else {
            temporary[index] = validated; temporaryOrder.removeAll { $0 == index }; temporaryOrder.append(index)
            while temporary.values.reduce(0, { $0 + $1.data.count }) > 32 * 1_024 * 1_024, let oldest = temporaryOrder.first {
                temporaryOrder.removeFirst(); temporary[oldest] = nil
            }
        }
        cachedIndices.insert(index)
        return validated
    }

    private func cacheKey(_ index: Int) -> String {
        let page = sourcePages[index]
        return ContentCache.key([cacheScope ?? "temporary", "page", page.installmentID.description,
            page.id, String(page.index), page.resourceURL.absoluteString])
    }

    func preview(at index: Int) async -> Data? {
        guard cacheScope != nil, sourcePages.indices.contains(index) else { return nil }
        return await ContentCache.shared.entry(for: cacheKey(index) + ".preview")?.data
    }
    func storePreview(_ data: Data, at index: Int) async {
        guard cacheScope != nil, sourcePages.indices.contains(index) else { return }
        await ContentCache.shared.store(data, for: cacheKey(index) + ".preview")
    }

    public func preparePage(at index: Int) async throws {
        let content = try await pageContent(at: index)
        _ = try await ImagePageDecoder.decode(content.data, id: pages[index].id)
    }

    public func setPagePriority(at index: Int, priority: RemoteImageRequestPriority) async {
        guard sourcePages.indices.contains(index) else { return }
        await loader.setImagePagePriority(for: sourcePages[index], priority: priority)
    }

    /// Loads only the nearby window, one request at a time in reading priority order.
    @discardableResult
    public func loadWindow(
        for state: ImageReaderState,
        planner: RemoteImagePageWindowPlanner = RemoteImagePageWindowPlanner()
    ) async throws -> [Int: RemoteImagePageContent] {
        let desiredIndices = planner.pageIndices(for: state)
        var content: [Int: RemoteImagePageContent] = [:]
        for index in desiredIndices {
            try Task.checkCancellation()
            content[index] = try await pageContent(at: index)
        }
        return content
    }

    public func cachedPageIndices() async -> [Int] {
        var indices: [Int] = []
        for index in sourcePages.indices {
            if temporary[index] != nil { indices.append(index) }
            else if cacheScope != nil, await ContentCache.shared.entry(for: cacheKey(index)) != nil { indices.append(index) }
        }
        return indices
    }

    public func removeCachedContent(at index: Int) async {
        guard sourcePages.indices.contains(index) else { return }
        if cacheScope != nil {
            await ContentCache.shared.remove(cacheKey(index))
            await ContentCache.shared.remove(cacheKey(index) + ".preview")
        }
        temporary[index] = nil
        temporaryOrder.removeAll { $0 == index }
        cachedIndices.remove(index)
    }

    public func removeAllCachedContent() async {
        for index in sourcePages.indices { await removeCachedContent(at: index) }
        cachedIndices.removeAll()
    }

    private nonisolated static func validated(
        _ content: RemoteImagePageContent,
        index: Int,
        maximumPageBytes: Int
    ) throws -> RemoteImagePageContent {
        guard !content.data.isEmpty else {
            throw ReaderError.emptyImagePage(index)
        }
        guard content.data.count <= maximumPageBytes else {
            throw ReaderError.imagePageTooLarge(index)
        }
        return content
    }
}
