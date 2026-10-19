import CoreGraphics
import Foundation
import MankoDomain
import Observation
import ReadiumZIPFoundation

public struct CBZPageWindowPlanner: Hashable, Sendable {
    public let maximumCachedPages: Int

    public init(maximumCachedPages: Int = 12) {
        self.maximumCachedPages = max(2, maximumCachedPages)
    }

    public func pageIndices(for state: ImageReaderState) -> [Int] {
        ImagePageWindow.pageIndices(for: state, maximumCachedPages: maximumCachedPages)
    }

}

public actor CBZPublication {
    public nonisolated let sourceURL: URL
    public nonisolated let pages: [ImagePageDescriptor]

    private let archive: Archive
    private let entries: [Entry]
    private let maximumPageBytes: UInt64

    fileprivate init(
        sourceURL: URL,
        archive: Archive,
        entries: [Entry],
        maximumPageBytes: UInt64
    ) {
        self.sourceURL = sourceURL
        self.archive = archive
        self.entries = entries
        self.maximumPageBytes = maximumPageBytes
        pages = entries.enumerated().map { index, entry in
            ImagePageDescriptor(
                id: "\(index):\(entry.path)",
                index: index,
                archivePath: entry.path
            )
        }
    }

    public func pageData(at index: Int) async throws -> Data {
        guard entries.indices.contains(index) else {
            throw ReaderError.pageIndexOutOfRange(index)
        }
        let entry = entries[index]
        guard entry.uncompressedSize <= maximumPageBytes else {
            throw ReaderError.archiveLimitExceeded("page \(entry.path) is too large")
        }

        let collector = CBZDataCollector(maximumBytes: maximumPageBytes)
        do {
            _ = try await archive.extract(entry) { data in
                try Task.checkCancellation()
                try await collector.append(data)
            }
            return await collector.value
        } catch let error as ReaderError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ReaderError.malformedPublication("page \(entry.path) could not be extracted")
        }
    }
}

public struct CBZPublicationService: Sendable {
    private let validator: any LocalPublicationValidating
    private let maximumPageBytes: UInt64
    private let maximumPageCount: Int

    public init(
        validator: any LocalPublicationValidating = DefaultLocalPublicationValidator(),
        maximumPageBytes: UInt64 = 128 * 1_024 * 1_024,
        maximumPageCount: Int = 50_000
    ) {
        self.validator = validator
        self.maximumPageBytes = max(1, maximumPageBytes)
        self.maximumPageCount = max(1, maximumPageCount)
    }

    public func open(url: URL) async throws -> CBZPublication {
        _ = try await validator.validate(url, expectedFormat: .cbz)

        let archive: Archive
        do {
            archive = try await Archive(url: url, accessMode: .read)
        } catch {
            throw ReaderError.malformedPublication("the comic archive could not be opened")
        }

        let allEntries: [Entry]
        do {
            allEntries = try await archive.entries()
        } catch {
            throw ReaderError.malformedPublication("the comic archive directory could not be read")
        }

        let imageEntries = allEntries
            .filter { entry in
                entry.type == .file && Self.isSupportedImagePath(entry.path)
            }
            .sorted { lhs, rhs in
                CBZPageOrdering.lessThan(lhs.path, rhs.path)
            }

        guard !imageEntries.isEmpty else {
            throw ReaderError.noReadableImages
        }
        guard imageEntries.count <= maximumPageCount else {
            throw ReaderError.archiveLimitExceeded("the comic contains too many pages")
        }
        guard imageEntries.allSatisfy({ $0.uncompressedSize <= maximumPageBytes }) else {
            throw ReaderError.archiveLimitExceeded("a comic page is too large")
        }

        return CBZPublication(
            sourceURL: url,
            archive: archive,
            entries: imageEntries,
            maximumPageBytes: maximumPageBytes
        )
    }

    private static func isSupportedImagePath(_ path: String) -> Bool {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp":
            true
        default:
            false
        }
    }
}

enum CBZPageOrdering {
    static func lessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(
            rhs,
            options: [.caseInsensitive, .diacriticInsensitive, .numeric],
            range: nil,
            locale: Locale(identifier: "en_US_POSIX")
        ) == .orderedAscending
    }
}

public enum CBZReaderPhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(String)
}

enum CBZPageLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

struct CBZReaderPublication: Sendable {
    let pages: [ImagePageDescriptor]
    private let pageDataProvider: @Sendable (Int) async throws -> Data

    init(_ publication: CBZPublication) {
        pages = publication.pages
        pageDataProvider = { index in
            try await publication.pageData(at: index)
        }
    }

    init(
        pages: [ImagePageDescriptor],
        pageDataProvider: @escaping @Sendable (Int) async throws -> Data
    ) {
        self.pages = pages
        self.pageDataProvider = pageDataProvider
    }

    func pageData(at index: Int) async throws -> Data {
        try await pageDataProvider(index)
    }
}

@MainActor
@Observable
public final class CBZReaderModel {
    public let sourceURL: URL
    public let initialLocator: ReadingLocator?

    public private(set) var phase: CBZReaderPhase = .idle
    public private(set) var state: ImageReaderState
    public private(set) var loadedImages: [Int: CGImage] = [:]
    public private(set) var pageErrorMessage: String?
    public private(set) var lastNavigationIntent: ImageNavigationIntent = .jump
    public private(set) var scrollTargetPageIndex: Int?
    public private(set) var scrollRequestRevision: UInt = 0

    private(set) var pageLoadStates: [Int: CBZPageLoadState] = [:]
    private(set) var pageErrorPageIndex: Int?

    @ObservationIgnored private let publicationLoader:
        @Sendable (URL) async throws -> CBZReaderPublication
    @ObservationIgnored private let windowPlanner: CBZPageWindowPlanner
    @ObservationIgnored private let onLocatorChange: (@MainActor (ReadingLocator) -> Void)?
    @ObservationIgnored private var publication: CBZReaderPublication?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var windowTask: Task<Void, Never>?
    @ObservationIgnored private var magnificationStartScale: Double?
    @ObservationIgnored private var windowGeneration = 0
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var viewportPageIndices: [Int]?
    @ObservationIgnored private var pendingViewportTarget: Int?
    @ObservationIgnored private var pendingLocator: ReadingLocator?
    @ObservationIgnored private var desiredIndices: [Int] = []
    @ObservationIgnored private var loadingIndex: Int?
    @ObservationIgnored private var imageCache: ImagePageCache
    @ObservationIgnored private var loadingPrefetch: ImagePrefetchSettings?
    @ObservationIgnored private var loadingBudgetTask: Task<Void, Never>?
    var recentImageCacheCount: Int { imageCache.count }

    public init(
        sourceURL: URL,
        settings: ImageReaderSettings = ImageReaderSettings(),
        initialLocator: ReadingLocator? = nil,
        maximumCachedPages: Int = 12,
        service: CBZPublicationService = CBZPublicationService(),
        onLocatorChange: (@MainActor (ReadingLocator) -> Void)? = nil
    ) {
        self.sourceURL = sourceURL
        self.initialLocator = initialLocator
        pendingLocator = initialLocator
        publicationLoader = { url in
            CBZReaderPublication(try await service.open(url: url))
        }
        self.windowPlanner = CBZPageWindowPlanner(maximumCachedPages: maximumCachedPages)
        imageCache = ImagePageCache(countLimit: windowPlanner.maximumCachedPages)
        self.onLocatorChange = onLocatorChange
        state = ImageReaderState(pages: [], settings: settings)
    }

    init(
        sourceURL: URL,
        settings: ImageReaderSettings = ImageReaderSettings(),
        initialLocator: ReadingLocator? = nil,
        maximumCachedPages: Int = 12,
        publicationLoader: @escaping @Sendable (URL) async throws -> CBZReaderPublication,
        onLocatorChange: (@MainActor (ReadingLocator) -> Void)? = nil
    ) {
        self.sourceURL = sourceURL
        self.initialLocator = initialLocator
        pendingLocator = initialLocator
        self.publicationLoader = publicationLoader
        self.windowPlanner = CBZPageWindowPlanner(maximumCachedPages: maximumCachedPages)
        imageCache = ImagePageCache(countLimit: windowPlanner.maximumCachedPages)
        self.onLocatorChange = onLocatorChange
        state = ImageReaderState(pages: [], settings: settings)
    }

    deinit {
        loadingBudgetTask?.cancel()
        openTask?.cancel()
        windowTask?.cancel()
    }

    public func openIfNeeded() {
        let resuming = isSuspended
        isSuspended = false
        if resuming {
            scrollTargetPageIndex = nil
            scrollRequestRevision &+= 1
            invalidateViewport()
        }
        if phase == .ready {
            if resuming { refreshPageWindow() }
            return
        }
        guard phase == .idle else {
            return
        }
        phase = .loading
        pageErrorMessage = nil
        let generation = windowGeneration
        openTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let publication = try await publicationLoader(sourceURL)
                try Task.checkCancellation()
                guard windowGeneration == generation else { return }

                var restoredState = ImageReaderState(
                    pages: publication.pages,
                    settings: state.settings
                )
                if let locator = pendingLocator ?? initialLocator {
                    try restoredState.restore(from: locator)
                    pendingLocator = restoredState.currentPage?.pixelWidth == nil ? locator : nil
                }

                self.publication = publication
                if let viewport = state.viewport { restoredState.updateViewport(viewport) }
                state = restoredState
                viewportPageIndices = nil
                pendingViewportTarget = pendingLocator == nil ? nil : state.currentPageIndex
                phase = .ready
                notifyLocatorChange()
                refreshPageWindow()
            } catch is CancellationError {
                if windowGeneration == generation { phase = .idle }
            } catch {
                if windowGeneration == generation { phase = .failed(Self.userFacingMessage(for: error)) }
            }
        }
    }

    func suspend() {
        loadingBudgetTask?.cancel(); loadingBudgetTask = nil
        isSuspended = true
        windowGeneration &+= 1
        openTask?.cancel()
        windowTask?.cancel()
        openTask = nil
        windowTask = nil
        loadingIndex = nil
        if phase == .loading { phase = .idle }
        ImagePageRetirement.release(Array(loadedImages.values))
        loadedImages.removeAll()
        imageCache.removeAll()
    }

    public func retry() {
        openTask?.cancel()
        windowTask?.cancel()
        openTask = nil
        windowTask = nil
        publication = nil
        viewportPageIndices = nil
        pendingViewportTarget = nil
        loadingIndex = nil
        loadedImages = [:]
        imageCache = ImagePageCache(countLimit: windowPlanner.maximumCachedPages)
        pageLoadStates = [:]
        pageErrorMessage = nil
        pageErrorPageIndex = nil
        windowGeneration &+= 1
        phase = .idle
        openIfNeeded()
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
        notifyLocatorChange()
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

    public func moveToBeginning() {
        move(to: 0)
    }

    /// An explicit locator request keeps this chapter's publication and caches.
    func navigate(to locator: ReadingLocator) {
        guard case .image = locator else { return }
        pendingLocator = locator
        guard phase == .ready else { return }
        try? state.restore(from: locator)
        if state.currentPage?.pixelWidth != nil { pendingLocator = nil }
        lastNavigationIntent = .jump
        magnificationStartScale = nil
        scrollTargetPageIndex = state.currentPageIndex
        scrollRequestRevision &+= 1
        invalidateViewport()
        notifyLocatorChange()
        refreshPageWindow()
    }

    public func moveToEnd() {
        let previousLocator = state.currentLocator
        state.moveToEnd()
        let changed = state.currentLocator != previousLocator
        if changed { lastNavigationIntent = .jump }
        didNavigate(changed: changed, forceScroll: true)
    }

    public func markPageVisible(_ index: Int) {
        guard !isSuspended, state.pages.indices.contains(index), state.currentPageIndex != index else {
            return
        }
        lastNavigationIntent = index > state.currentPageIndex ? .forward : .backward
        state.move(to: index)
        pendingLocator = nil
        notifyLocatorChange()
        if viewportPageIndices == nil { refreshPageWindow() }
    }

    func beginViewportInteraction() { pendingViewportTarget = nil }

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

    public func performTap(in region: TapZoneRegion) {
        let locator = state.currentLocator
        let action = state.performTap(in: region)
        if state.currentLocator != locator {
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
        loadedImages.removeValue(forKey: index)
        imageCache = ImagePageCache(countLimit: windowPlanner.maximumCachedPages)
        retryPage(at: index)
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
        pageErrorPageIndex = nil
    }

    func pageLoadState(at index: Int) -> CBZPageLoadState {
        if loadedImages[index] != nil {
            return .loaded
        }
        return pageLoadStates[index] ?? .idle
    }

    func retryPage(at index: Int) {
        guard state.pages.indices.contains(index) else {
            return
        }
        pageLoadStates[index] = .idle
        if pageErrorPageIndex == index {
            dismissPageError()
        }
        refreshPageWindow()
    }

    private func didNavigate(changed: Bool, forceScroll: Bool = false) {
        guard changed || forceScroll else { return }
        pendingLocator = nil
        scrollTargetPageIndex = state.currentPageIndex
        scrollRequestRevision &+= 1
        invalidateViewport()
        guard changed else {
            refreshPageWindow()
            return
        }
        magnificationStartScale = nil
        notifyLocatorChange()
        refreshPageWindow()
    }

    private func notifyLocatorChange() {
        guard pendingLocator == nil else { return }
        onLocatorChange?(state.currentLocator)
    }

    func releaseRecentImages() {
        imageCache.removeAll(byteLimit: 32 * 1_024 * 1_024)
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

    private var visiblePageIndices: [Int] { viewportPageIndices ?? state.visiblePageIndices() }

    private func invalidateViewport() {
        viewportPageIndices = nil
        pendingViewportTarget = state.settings.layout.isPaged ? nil : state.currentPageIndex
    }

    private func refreshPageWindow() {
        guard publication != nil, phase == .ready, !isSuspended else {
            return
        }

        desiredIndices = ImagePageWindow.activePageIndices(for: state, visiblePageIndices: visiblePageIndices,
            pagesAhead: loadingPrefetch?.pagesAhead, pagesBehind: loadingPrefetch?.pagesBehind)
        let activeIndices = Set(desiredIndices)
        let retired = loadedImages.filter { !activeIndices.contains($0.key) }
        if !retired.isEmpty {
            ImagePageRetirement.release(Array(retired.values))
            for index in retired.keys { loadedImages.removeValue(forKey: index) }
        }
        for index in desiredIndices where loadedImages[index] == nil {
            if let image = imageCache.image(at: index) { loadedImages[index] = image }
        }
        pageLoadStates = pageLoadStates.filter { activeIndices.contains($0.key) }
        for index in desiredIndices {
            if loadedImages[index] != nil {
                pageLoadStates[index] = .loaded
            } else if pageLoadStates[index] == .loading, index != loadingIndex {
                pageLoadStates[index] = .idle
            }
        }
        let visibleIndices = Set(visiblePageIndices)
        if let pageErrorPageIndex, !visibleIndices.contains(pageErrorPageIndex) {
            dismissPageError()
        }

        if let loadingIndex {
            let missingVisible = visibleIndices.contains {
                loadedImages[$0] == nil && pageLoadStates[$0]?.isFailure != true
            }
            if !activeIndices.contains(loadingIndex) || (missingVisible && !visibleIndices.contains(loadingIndex)) {
                windowTask?.cancel()
            }
        }
        loadNextPageIfNeeded()
    }

    private func loadNextPageIfNeeded() {
        guard !isSuspended, phase == .ready, let publication, windowTask == nil,
              let index = desiredIndices.first(where: { loadedImages[$0] == nil && pageLoadStates[$0]?.isFailure != true }) else { return }
        let generation = windowGeneration
        loadingIndex = index
        pageLoadStates[index] = .loading
        windowTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                if windowGeneration == generation {
                    loadingIndex = nil
                    windowTask = nil
                    loadNextPageIfNeeded()
                }
            }
            do {
                try Task.checkCancellation()
                let page = publication.pages[index]
                let data = try await publication.pageData(at: index)
                let decoded = try await ImagePageDecoder.decode(data, id: page.archivePath ?? page.id, downsample: self.state.settings.options.downsampleImages)
                try Task.checkCancellation()
                guard windowGeneration == generation else {
                    return
                }
                loadedImages[index] = decoded.image
                imageCache.insert(decoded.image, at: index)
                pageLoadStates[index] = .loaded
                if pageErrorPageIndex == index {
                    dismissPageError()
                }
                updatePageMetadata(
                    at: index,
                    width: decoded.width,
                    height: decoded.height,
                    detectedCropInsets: decoded.detectedCropInsets
                )
            } catch is CancellationError {
                if windowGeneration == generation { pageLoadStates[index] = .idle }
                return
            } catch {
                guard !Task.isCancelled, windowGeneration == generation else {
                    return
                }
                let message = Self.userFacingMessage(for: error)
                pageLoadStates[index] = .failed(message)
                if visiblePageIndices.contains(index) {
                    pageErrorMessage = message
                    pageErrorPageIndex = index
                }
            }
        }
    }

    private func updatePageMetadata(
        at index: Int,
        width: Int,
        height: Int,
        detectedCropInsets: NormalizedPageInsets?
    ) {
        guard state.pages.indices.contains(index) else {
            return
        }
        var pages = state.pages
        let page = pages[index]
        if page.pixelWidth != width || page.pixelHeight != height
            || page.detectedCropInsets != detectedCropInsets {
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
        if let pendingLocator, state.currentPageIndex == index {
            try? state.restore(from: pendingLocator)
            self.pendingLocator = nil
            notifyLocatorChange()
        }
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let localizedError = error as? any LocalizedError,
           let description = localizedError.errorDescription
        {
            return description
        }
        return error.localizedDescription
    }
}


private actor CBZDataCollector {
    let maximumBytes: UInt64
    private var data = Data()

    init(maximumBytes: UInt64) {
        self.maximumBytes = maximumBytes
    }

    func append(_ chunk: Data) throws {
        let (newCount, overflow) = UInt64(data.count).addingReportingOverflow(UInt64(chunk.count))
        guard !overflow, newCount <= maximumBytes else {
            throw ReaderError.archiveLimitExceeded("an extracted comic page is too large")
        }
        data.append(chunk)
    }

    var value: Data {
        data
    }
}

#if DEBUG
/// Deterministic archive inputs for reader integration tests and manual verification.
public enum ReaderVerificationArchive {
    public static func write(pages: [Data], to url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let archive = try await Archive(url: url, accessMode: .create)
        for (index, data) in pages.enumerated() {
            try await archive.addEntry(with: String(format: "%03d.png", index + 1), type: .file,
                uncompressedSize: Int64(data.count), modificationDate: Date(timeIntervalSince1970: 315_532_800),
                permissions: 0o644, compressionMethod: .none) { offset, length in
                let start = Int(offset), end = min(data.count, Int(offset) + length)
                return start < end ? data.subdata(in: start..<end) : Data()
            }
        }
    }
}
#endif
