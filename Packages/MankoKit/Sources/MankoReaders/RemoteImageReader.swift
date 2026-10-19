import CoreGraphics
import Foundation
import MankoDomain
import Observation
import OSLog

public enum RemoteImageReaderPhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(String)
}

/// Main-actor presentation state for a streamed image sequence. The source
/// descriptors remain inside `RemoteImagePublication`; this model holds the
/// active window plus a bounded cache of recently decoded pages.
@MainActor
@Observable
public final class RemoteImageReaderModel {
    public let initialLocator: ReadingLocator?

    public private(set) var phase: RemoteImageReaderPhase = .idle
    public private(set) var state: ImageReaderState
    public private(set) var loadedImages: [Int: CGImage] = [:]
    public private(set) var pageLoadingStates: [Int: ImagePageLoadingState] = [:]
    public private(set) var pageErrorMessage: String?
    public private(set) var lastNavigationIntent: ImageNavigationIntent = .jump
    public private(set) var scrollTargetPageIndex: Int?
    public private(set) var scrollRequestRevision: UInt = 0

    @ObservationIgnored private let publication: RemoteImagePublication
    @ObservationIgnored private let windowPlanner: RemoteImagePageWindowPlanner
    @ObservationIgnored private var imageCache: ImagePageCache
    @ObservationIgnored private var loadingPrefetch: ImagePrefetchSettings?
    @ObservationIgnored private var loadingBudgetTask: Task<Void, Never>?
    var recentImageCacheCount: Int { imageCache.count }
    @ObservationIgnored private var previewIndices: Set<Int> = []
    var previewPageIndices: Set<Int> { previewIndices }
    @ObservationIgnored private let onLocatorChange: (@MainActor (ReadingLocator) -> Void)?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var decodingTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var downloadRequestID: UUID?
    @ObservationIgnored private var downloadingIndex: Int?
    @ObservationIgnored private var decodingIndex: Int?
    @ObservationIgnored private var bufferedPage: (index: Int, content: RemoteImagePageContent)?
    @ObservationIgnored private var desiredIndices: [Int] = []
    @ObservationIgnored private var failedPages: [Int: String] = [:]
    @ObservationIgnored private var viewportPageIndices: [Int]?
    @ObservationIgnored private var pendingViewportTarget: Int?
    @ObservationIgnored private var isSuspended = false
    private static let performanceLog = OSLog(subsystem: "com.k800k.manko", category: "ReaderPerformance")
    @ObservationIgnored private var magnificationStartScale: Double?
    @ObservationIgnored private var pendingInitialLocator: ReadingLocator?

    public init(
        publication: RemoteImagePublication,
        settings: ImageReaderSettings = ImageReaderSettings(),
        initialLocator: ReadingLocator? = nil,
        maximumCachedPages: Int = 12,
        onLocatorChange: (@MainActor (ReadingLocator) -> Void)? = nil
    ) {
        self.publication = publication
        self.initialLocator = initialLocator
        self.windowPlanner = RemoteImagePageWindowPlanner(
            maximumCachedPages: maximumCachedPages
        )
        imageCache = ImagePageCache(countLimit: windowPlanner.maximumCachedPages)
        self.onLocatorChange = onLocatorChange
        pendingInitialLocator = initialLocator
        state = ImageReaderState(pages: publication.pages, settings: settings)
    }

    deinit {
        loadingBudgetTask?.cancel()
        downloadTask?.cancel()
        decodingTask?.cancel()
        previewTask?.cancel()
    }

    public func openIfNeeded() {
        if isSuspended {
            // Background failures belong to the previous attempt. Retry once
            // on resume, without turning viewport updates into a retry loop.
            failedPages.removeAll()
            pageErrorMessage = nil
            pageLoadingStates = pageLoadingStates.filter { $0.value != .failed }
            scrollTargetPageIndex = nil
            scrollRequestRevision &+= 1
            invalidateViewport()
        }
        isSuspended = false
        guard phase == .idle else {
            if phase == .ready { refreshPageWindow() }
            return
        }
        phase = .loading
        pageErrorMessage = nil

        do {
            var restoredState = ImageReaderState(
                pages: publication.pages,
                settings: state.settings
            )
            guard !restoredState.pages.isEmpty else {
                throw ReaderError.noReadableImages
            }
            if let initialLocator {
                try restoredState.restore(from: initialLocator)
            }
            if let viewport = state.viewport { restoredState.updateViewport(viewport) }
            state = restoredState
            if initialLocator != nil { invalidateViewport() }
            phase = .ready
            if pendingInitialLocator == nil {
                notifyLocatorChange()
            }
            refreshPageWindow()
        } catch {
            phase = .failed(Self.userFacingMessage(for: error))
        }
    }

    public func retry() {
        cancelDownload()
        decodingTask?.cancel()
        previewTask?.cancel()
        viewportPageIndices = nil
        pendingViewportTarget = nil
        scrollTargetPageIndex = nil
        scrollRequestRevision &+= 1
        pageErrorMessage = nil
        failedPages.removeAll()
        pageLoadingStates.removeAll()
        phase = .idle
        openIfNeeded()
    }

    public func suspend() {
        loadingBudgetTask?.cancel(); loadingBudgetTask = nil
        isSuspended = true
        cancelDownload()
        decodingTask?.cancel()
        previewTask?.cancel()
        bufferedPage = nil
        pageLoadingStates.removeAll()
        ImagePageRetirement.release(Array(loadedImages.values))
        loadedImages.removeAll()
        previewIndices.removeAll()
        imageCache.removeAll()
    }

    func updateLoadingBudget(_ prefetch: ImagePrefetchSettings?) {
        guard loadingPrefetch != prefetch else { return }
        loadingPrefetch = prefetch
        loadingBudgetTask?.cancel()
        loadingBudgetTask = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            imageCache.setByteLimit(loadingPrefetch == nil
                ? ImagePageCache.byteLimit(physicalMemory: ProcessInfo.processInfo.physicalMemory) : 32 * 1_024 * 1_024)
            refreshPageWindow()
            loadingBudgetTask = nil
        }
    }

    public func updateSettings(_ settings: ImageReaderSettings) {
        guard settings != state.settings else { return }
        let layoutChanged = settings.layout != state.settings.layout
        let decodingChanged = settings.options.downsampleImages != state.settings.options.downsampleImages
        state.updateSettings(settings)
        if decodingChanged {
            loadedImages.removeAll()
            imageCache = ImagePageCache(countLimit: windowPlanner.maximumCachedPages)
        }
        if layoutChanged {
            scrollTargetPageIndex = state.currentPageIndex
            scrollRequestRevision &+= 1
            invalidateViewport()
        }
        if pendingInitialLocator == nil {
            notifyLocatorChange()
        }
        refreshPageWindow()
    }

    @discardableResult
    public func moveForward() -> Bool {
        let changed = state.moveForward()
        if changed { lastNavigationIntent = .forward }
        didNavigate(changed: changed)
        return changed
    }

    @discardableResult
    public func moveBackward() -> Bool {
        let changed = state.moveBackward()
        if changed { lastNavigationIntent = .backward }
        didNavigate(changed: changed)
        return changed
    }

    public func moveScreenLeft() {
        if state.settings.direction == .rightToLeft {
            moveForward()
        } else {
            moveBackward()
        }
    }

    public func moveScreenRight() {
        if state.settings.direction == .rightToLeft {
            moveBackward()
        } else {
            moveForward()
        }
    }

    public func move(to index: Int) {
        let previous = state.currentPageIndex
        state.move(to: index)
        if previous != state.currentPageIndex {
            lastNavigationIntent = state.currentPageIndex > previous ? .forward : .backward
        }
        didNavigate(changed: previous != state.currentPageIndex, forceScroll: true)
    }

    public func navigate(to locator: ReadingLocator) {
        guard case .image = locator else { return }
        guard (try? state.restore(from: locator)) != nil else { return }
        pendingInitialLocator = loadedImages[state.currentPageIndex] == nil ? locator : nil
        lastNavigationIntent = .jump
        scrollTargetPageIndex = state.currentPageIndex
        scrollRequestRevision &+= 1
        invalidateViewport()
        magnificationStartScale = nil
        if pendingInitialLocator == nil { notifyLocatorChange() }
        refreshPageWindow()
    }

    public func moveToBeginning() {
        move(to: 0)
    }

    public func moveToEnd() {
        let previousLocator = state.currentLocator
        state.moveToEnd()
        let changed = state.currentLocator != previousLocator
        if changed { lastNavigationIntent = .jump }
        didNavigate(changed: changed, forceScroll: true)
    }

    public func markPageVisible(_ index: Int) {
        guard !isSuspended, state.pages.indices.contains(index), state.currentPageIndex != index,
              pendingViewportTarget == nil || pendingViewportTarget == index else {
            return
        }
        lastNavigationIntent = index > state.currentPageIndex ? .forward : .backward
        state.move(to: index)
        pendingInitialLocator = nil
        notifyLocatorChange()
        if viewportPageIndices == nil { refreshPageWindow() }
    }

    /// Viewport membership drives loading only; the scroll anchor owns progress.
    func updateVisiblePageIndices(_ indices: [Int], scrollRequestRevision: UInt) {
        guard phase == .ready, !isSuspended, !state.settings.layout.isPaged,
              scrollRequestRevision == self.scrollRequestRevision else { return }
        let visible = Set(indices.filter { state.pages.indices.contains($0) }).sorted()
        guard !visible.isEmpty else { return }
        if let pendingViewportTarget, !visible.contains(pendingViewportTarget) { return }
        pendingViewportTarget = nil
        guard viewportPageIndices != visible else { return }
        viewportPageIndices = visible
        refreshPageWindow()
    }

    func beginViewportInteraction() { pendingViewportTarget = nil }

    public func performTap(in region: TapZoneRegion) {
        let locator = state.currentLocator
        let action = state.performTap(in: region)
        if state.currentLocator != locator {
            pendingInitialLocator = nil
            switch action {
            case .nextPage, .scrollForward:
                lastNavigationIntent = .forward
            case .previousPage, .scrollBackward:
                lastNavigationIntent = .backward
            case .none, .toggleControls:
                lastNavigationIntent = .jump
            }
            didNavigate(changed: true)
        }
    }

    func reloadPage(_ index: Int) {
        guard state.pages.indices.contains(index) else { return }
        // A reload must fence callbacks from the request it replaces.
        if downloadingIndex == index { cancelDownload() }
        loadedImages.removeValue(forKey: index)
        imageCache = ImagePageCache(countLimit: windowPlanner.maximumCachedPages)
        failedPages.removeValue(forKey: index)
        pageLoadingStates[index] = .waiting
        Task {
            await publication.removeCachedContent(at: index)
            refreshPageWindow()
        }
    }

    func updateViewport(_ viewport: ReaderViewport) {
        guard state.viewport != viewport else { return }
        state.updateViewport(viewport)
        refreshPageWindow()
    }

    func markPosition(page: Int, offset: Double) {
        markPageVisible(page)
        guard state.currentPageIndex == page else { return }
        state.setScrollOffset(offset)
        notifyLocatorChange()
    }

    func togglePageIsolation(_ index: Int) {
        if state.isolatedPages.contains(index) { state.isolatedPages.remove(index) }
        else { state.isolatedPages.insert(index) }
        state.normalizePosition()
        refreshPageWindow()
    }

    public func toggleDoubleTapZoom() {
        state.toggleDoubleTapZoom()
        magnificationStartScale = nil
    }

    public func updateMagnification(_ magnification: Double) {
        if magnificationStartScale == nil {
            magnificationStartScale = state.zoomScale
        }
        state.setZoomScale((magnificationStartScale ?? 1) * magnification)
    }

    public func endMagnification() {
        magnificationStartScale = nil
    }

    public func dismissPageError() {
        pageErrorMessage = nil
    }

    func releaseRecentImages() {
        imageCache.removeAll(byteLimit: 32 * 1_024 * 1_024)
    }

    public func retryPageWindow() {
        pageErrorMessage = nil
        failedPages.removeAll()
        pageLoadingStates = pageLoadingStates.filter { $0.value != .failed }
        if isSuspended {
            scrollTargetPageIndex = nil
            scrollRequestRevision &+= 1
            invalidateViewport()
        }
        isSuspended = false
        refreshPageWindow()
    }

    private func didNavigate(changed: Bool, forceScroll: Bool = false) {
        guard changed || forceScroll else { return }
        scrollTargetPageIndex = state.currentPageIndex
        scrollRequestRevision &+= 1
        invalidateViewport()
        guard changed else {
            refreshPageWindow()
            return
        }
        magnificationStartScale = nil
        pendingInitialLocator = nil
        notifyLocatorChange()
        refreshPageWindow()
    }

    private func notifyLocatorChange() {
        onLocatorChange?(state.currentLocator)
    }

    private var visiblePageIndices: [Int] {
        viewportPageIndices ?? ([state.currentPageIndex]
            + state.visiblePageIndices().filter { $0 != state.currentPageIndex })
    }

    private func invalidateViewport() {
        viewportPageIndices = nil
        pendingViewportTarget = state.settings.layout.isPaged ? nil : state.currentPageIndex
    }

    private func updatePageError() {
        pageErrorMessage = visiblePageIndices.lazy.compactMap { self.failedPages[$0] }.first
    }

    private func refreshPageWindow() {
        guard phase == .ready, !isSuspended else { return }
        let visible = visiblePageIndices
        desiredIndices = windowPlanner.activePageIndices(for: state, visiblePageIndices: visible, prefetch: loadingPrefetch)
        let desiredSet = Set(desiredIndices)
        let retired = loadedImages.filter { !desiredSet.contains($0.key) }
        if !retired.isEmpty {
            ImagePageRetirement.release(Array(retired.values))
            for index in retired.keys { loadedImages.removeValue(forKey: index) }
        }
        for index in desiredIndices where loadedImages[index] == nil {
            if let image = imageCache.image(at: index) { loadedImages[index] = image }
        }
        pageLoadingStates = pageLoadingStates.filter { desiredSet.contains($0.key) }
        for index in desiredIndices {
            if failedPages[index] != nil { pageLoadingStates[index] = .failed }
            else if loadedImages[index] != nil && !previewIndices.contains(index) { pageLoadingStates[index] = nil }
            else if pageLoadingStates[index] == nil { pageLoadingStates[index] = .waiting }
        }
        updatePageError()
        if let downloadingIndex {
            let visibleIsMissing = visible.contains {
                loadedImages[$0] == nil && decodingIndex != $0
                    && bufferedPage?.index != $0 && failedPages[$0] == nil
            }
            if !desiredIndices.contains(downloadingIndex)
                || (visibleIsMissing && !visible.contains(downloadingIndex)) {
                cancelDownload()
            } else {
                let priority: RemoteImageRequestPriority = visible.contains(downloadingIndex) ? .visible : .prefetch
                Task { await publication.setPagePriority(at: downloadingIndex, priority: priority) }
            }
        }
        if let decodingIndex, !desiredIndices.contains(decodingIndex) { decodingTask?.cancel() }
        if let bufferedPage, !desiredIndices.contains(bufferedPage.index) { self.bufferedPage = nil }
        pumpPageLoads()
    }

    /// One network request, one decoder, and at most one waiting compressed page.
    private func pumpPageLoads() {
        guard phase == .ready, !isSuspended else { return }
        if decodingTask == nil, let page = bufferedPage {
            bufferedPage = nil
            decodingIndex = page.index
            decodingTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let decoded = try await ImagePageDecoder.decode(page.content.data, id: publication.pages[page.index].id, downsample: state.settings.options.downsampleImages)
                    try Task.checkCancellation()
                    loadedImages[page.index] = decoded.image
                    previewIndices.remove(page.index)
                    pageLoadingStates[page.index] = nil
                    imageCache.insert(decoded.image, at: page.index)
                    updatePageMetadata(at: page.index, width: decoded.width, height: decoded.height, detectedCropInsets: decoded.detectedCropInsets)
                    os_signpost(.event, log: Self.performanceLog, name: "Page Ready", "page=%d", page.index)
                    if publication.cachesPreviews {
                        previewTask?.cancel()
                        previewTask = Task(priority: .utility) { [publication] in
                            if let data = await ImagePageDecoder.cachedPreviewData(decoded), !Task.isCancelled {
                                await publication.storePreview(data, at: page.index)
                            }
                        }
                    }
                } catch {
                    if !Task.isCancelled, !(error is CancellationError) {
                        await publication.removeCachedContent(at: page.index)
                        if !Task.isCancelled, !isSuspended { recordPageFailure(error, index: page.index) }
                    }
                }
                decodingIndex = nil
                decodingTask = nil
                pumpPageLoads()
            }
        }
        guard downloadTask == nil, bufferedPage == nil,
              let index = desiredIndices.first(where: {
                  (loadedImages[$0] == nil || previewIndices.contains($0)) && decodingIndex != $0 && failedPages[$0] == nil
              }) else { return }
        downloadingIndex = index
        let requestID = UUID()
        downloadRequestID = requestID
        pageLoadingStates[index] = .waiting
        let priority: RemoteImageRequestPriority = visiblePageIndices.contains(index) ? .visible : .prefetch
        downloadTask = Task { [weak self] in
            guard let self else { return }
            let signpost = OSSignpostID(log: Self.performanceLog)
            os_signpost(.begin, log: Self.performanceLog, name: "Page Fetch", signpostID: signpost, "page=%d", index)
            do {
                if priority == .visible, let data = await publication.preview(at: index),
                   let preview = await ImagePageDecoder.decodeCachedPreview(data),
                   downloadRequestID == requestID, !Task.isCancelled { showPreview(preview, at: index, hasFinalGeometry: true) }
                let content = try await publication.pageContent(at: index, priority: priority,
                    onProgress: { [weak self] progress in
                        await self?.updateDownloadProgress(progress, at: index, requestID: requestID)
                    }, onPartial: { [weak self] partial in
                        await self?.showPartialImage(partial, at: index, requestID: requestID)
                    })
                try Task.checkCancellation()
                if downloadRequestID == requestID, !isSuspended, desiredIndices.contains(index) {
                    pageLoadingStates[index] = .preparing
                    bufferedPage = (index, content)
                }
            } catch {
                if downloadRequestID == requestID, !isSuspended,
                   !Task.isCancelled, !(error is CancellationError) {
                    recordPageFailure(error, index: index)
                }
            }
            os_signpost(.end, log: Self.performanceLog, name: "Page Fetch", signpostID: signpost)
            if downloadRequestID == requestID { downloadRequestID = nil }
            downloadingIndex = nil
            downloadTask = nil
            pumpPageLoads()
        }
    }

    private func cancelDownload() {
        downloadRequestID = nil
        if let downloadingIndex { pageLoadingStates[downloadingIndex] = nil }
        downloadTask?.cancel()
    }

    private func updateDownloadProgress(_ progress: RemoteImageDownloadProgress, at index: Int, requestID: UUID) {
        guard downloadRequestID == requestID, !Task.isCancelled, !isSuspended, desiredIndices.contains(index) else { return }
        pageLoadingStates[index] = progress.fractionCompleted == 1 ? .preparing : .downloading(progress)
    }

    private func showPartialImage(_ content: RemoteImagePageContent, at index: Int, requestID: UUID) async {
        guard downloadRequestID == requestID, desiredIndices.contains(index), !isSuspended else { return }
        if state.pages[index].aspectRatio == nil,
           let dimensions = await ImagePageDecoder.headerDimensions(content.data) {
            guard downloadRequestID == requestID, desiredIndices.contains(index),
                  !isSuspended, !Task.isCancelled else { return }
            updatePageMetadata(at: index, width: dimensions.width, height: dimensions.height,
                detectedCropInsets: state.pages[index].detectedCropInsets)
        }
        guard visiblePageIndices.contains(index),
              let preview = await ImagePageDecoder.progressivePreview(content.data),
              downloadRequestID == requestID, !Task.isCancelled else { return }
        showPreview(preview, at: index)
    }

    private func showPreview(_ preview: DecodedImagePage, at index: Int, hasFinalGeometry: Bool = false) {
        guard !isSuspended, downloadingIndex == index, desiredIndices.contains(index),
              loadedImages[index] == nil || previewIndices.contains(index) else { return }
        // Cold automatic cropping needs the final image to establish its frame.
        // Saved previews already carry the final crop and remain safe to show.
        guard hasFinalGeometry || state.settings.cropMode != .automatic || state.pages[index].detectedCropInsets != nil else { return }
        updatePageMetadata(at: index, width: preview.width, height: preview.height,
            detectedCropInsets: state.pages[index].detectedCropInsets ?? preview.detectedCropInsets)
        previewIndices.insert(index)
        loadedImages[index] = preview.image
        os_signpost(.event, log: Self.performanceLog, name: "Page Preview", "page=%d", index)
    }

    private func recordPageFailure(_ error: Error, index: Int) {
        failedPages[index] = Self.userFacingMessage(for: error)
        pageLoadingStates[index] = .failed
        updatePageError()
    }

    private func updatePageMetadata(
        at index: Int,
        width: Int,
        height: Int,
        detectedCropInsets: NormalizedPageInsets?
    ) {
        guard state.pages.indices.contains(index) else { return }
        let page = state.pages[index]
        if page.pixelWidth != width || page.pixelHeight != height
            || page.detectedCropInsets != detectedCropInsets {
            var pages = state.pages
            pages[index] = ImagePageDescriptor(
                id: page.id,
                index: page.index,
                sourceURL: page.sourceURL,
                archivePath: page.archivePath,
                pixelWidth: width,
                pixelHeight: height,
                detectedCropInsets: detectedCropInsets
            )
            state.replacePages(pages)
        }
        if case let .image(savedPage, _, _) = pendingInitialLocator,
           savedPage == index,
           let locator = pendingInitialLocator
        {
            try? state.restore(from: locator)
            pendingInitialLocator = nil
            notifyLocatorChange()
        }
    }

    nonisolated private static func userFacingMessage(for error: Error) -> String {
        if let localizedError = error as? any LocalizedError,
           let description = localizedError.errorDescription
        {
            return description
        }
        return error.localizedDescription
    }
}
