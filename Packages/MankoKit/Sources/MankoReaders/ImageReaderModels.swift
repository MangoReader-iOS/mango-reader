import CoreGraphics
import Foundation
import MankoDomain
import OSLog

public enum ImageReadingDirection: String, Codable, CaseIterable, Sendable {
    case leftToRight
    case rightToLeft
}

public enum ImageReaderLayout: String, Codable, CaseIterable, Sendable {
    case paged
    case vertical
    case webtoon
    case verticalPaged

    public var isPaged: Bool { self == .paged || self == .verticalPaged }
}

public enum ImagePageSpread: String, Codable, CaseIterable, Sendable {
    case automatic
    case single
    case double
}

public enum WidePageBehavior: String, Codable, CaseIterable, Sendable {
    case fit
    case split
}

public enum ImagePageTransition: String, Codable, CaseIterable, Sendable {
    case none
    case slide
    case fade
    case pageCurl

    /// Motion-sensitive page transitions are disabled when Reduce Motion is active.
    public func resolved(reduceMotion: Bool) -> Self {
        reduceMotion ? .none : self
    }
}

public enum ImageNavigationIntent: Sendable {
    case forward
    case backward
    case jump
}

public struct NormalizedPageInsets: Codable, Hashable, Sendable {
    public let top: Double
    public let leading: Double
    public let bottom: Double
    public let trailing: Double

    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = Self.clamp(top)
        self.leading = Self.clamp(leading)
        self.bottom = Self.clamp(bottom)
        self.trailing = Self.clamp(trailing)
    }

    public static let zero = Self()

    public var isZero: Bool {
        top == 0 && leading == 0 && bottom == 0 && trailing == 0
    }

    public func cropRect(pixelWidth: Int, pixelHeight: Int) -> CGRect {
        guard pixelWidth > 0, pixelHeight > 0 else {
            return .zero
        }

        let width = Double(pixelWidth)
        let height = Double(pixelHeight)
        let minimumX = floor(width * leading)
        let minimumY = floor(height * top)
        let maximumX = ceil(width * (1 - trailing))
        let maximumY = ceil(height * (1 - bottom))
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: max(1, maximumX - minimumX),
            height: max(1, maximumY - minimumY)
        )
    }

    private static func clamp(_ value: Double) -> Double {
        min(0.45, max(0, value))
    }
}

public enum ImageCropMode: Codable, Hashable, Sendable {
    case none
    case automatic
    case custom(NormalizedPageInsets)
}

public struct ImageZoomSettings: Codable, Hashable, Sendable {
    public let minimumScale: Double
    public let maximumScale: Double
    public let doubleTapScale: Double

    public init(minimumScale: Double = 1, maximumScale: Double = 6, doubleTapScale: Double = 2.5) {
        let minimumScale = min(4, max(0.5, minimumScale))
        let maximumScale = min(12, max(minimumScale, maximumScale))
        self.minimumScale = minimumScale
        self.maximumScale = maximumScale
        self.doubleTapScale = min(maximumScale, max(minimumScale, doubleTapScale))
    }
}

public struct ImagePrefetchSettings: Codable, Hashable, Sendable {
    public let pagesAhead: Int
    public let pagesBehind: Int
    public let maximumConcurrentRequests: Int

    public init(pagesAhead: Int = 4, pagesBehind: Int = 2, maximumConcurrentRequests: Int = 3) {
        self.pagesAhead = min(20, max(0, pagesAhead))
        self.pagesBehind = min(20, max(0, pagesBehind))
        self.maximumConcurrentRequests = min(8, max(1, maximumConcurrentRequests))
    }
}

public enum TapZoneRegion: String, Codable, CaseIterable, Sendable {
    case topLeading
    case topCenter
    case topTrailing
    case middleLeading
    case middleCenter
    case middleTrailing
    case bottomLeading
    case bottomCenter
    case bottomTrailing

    public var column: TapZoneColumn {
        switch self {
        case .topLeading, .middleLeading, .bottomLeading:
            .leading
        case .topCenter, .middleCenter, .bottomCenter:
            .center
        case .topTrailing, .middleTrailing, .bottomTrailing:
            .trailing
        }
    }

    /// Maps normalized view coordinates to the reader's 3x3 interaction grid.
    public static func region(normalizedX: Double, normalizedY: Double) -> Self {
        let x = min(1, max(0, normalizedX))
        let y = min(1, max(0, normalizedY))
        let column = min(2, Int(x * 3))
        let row = min(2, Int(y * 3))
        let regions: [[Self]] = [
            [.topLeading, .topCenter, .topTrailing],
            [.middleLeading, .middleCenter, .middleTrailing],
            [.bottomLeading, .bottomCenter, .bottomTrailing],
        ]
        return regions[row][column]
    }
}

public enum TapZoneColumn: String, Codable, CaseIterable, Sendable {
    case leading
    case center
    case trailing
}

public enum ReaderTapAction: String, Codable, CaseIterable, Sendable {
    case none
    case previousPage
    case nextPage
    case scrollBackward
    case scrollForward
    case toggleControls
}

public struct TapZoneConfiguration: Codable, Hashable, Sendable {
    private let actions: [TapZoneRegion: ReaderTapAction]

    public init(actions: [TapZoneRegion: ReaderTapAction]) {
        self.actions = actions
    }

    public init(
        leading: ReaderTapAction,
        center: ReaderTapAction,
        trailing: ReaderTapAction
    ) {
        self.init(actions: Dictionary(uniqueKeysWithValues: TapZoneRegion.allCases.map { region in
            let action = switch region.column {
            case .leading: leading
            case .center: center
            case .trailing: trailing
            }
            return (region, action)
        }))
    }

    public static func standard(direction: ImageReadingDirection) -> Self {
        let leadingAction: ReaderTapAction = direction == .leftToRight ? .previousPage : .nextPage
        let trailingAction: ReaderTapAction = direction == .leftToRight ? .nextPage : .previousPage
        return Self(actions: [
            .topLeading: leadingAction,
            .topCenter: .toggleControls,
            .topTrailing: trailingAction,
            .middleLeading: leadingAction,
            .middleCenter: .toggleControls,
            .middleTrailing: trailingAction,
            .bottomLeading: leadingAction,
            .bottomCenter: .toggleControls,
            .bottomTrailing: trailingAction,
        ])
    }

    public static func preset(_ name: String, direction: ImageReadingDirection, layout: ImageReaderLayout, inverted: Bool = false) -> Self {
        let name = name == "automatic" ? (layout.isPaged ? "left-right" : "l-shaped") : name
        let leftIsForward = layout == .paged && direction == .rightToLeft
        let left: ReaderTapAction = leftIsForward != inverted ? .nextPage : .previousPage
        let right: ReaderTapAction = leftIsForward != inverted ? .previousPage : .nextPage
        return Self(actions: Dictionary(uniqueKeysWithValues: TapZoneRegion.allCases.map { region in
            let row: Int = [.topLeading, .topCenter, .topTrailing].contains(region) ? 0
                : ([.bottomLeading, .bottomCenter, .bottomTrailing].contains(region) ? 2 : 1)
            let column = region.column
            let action: ReaderTapAction
            switch name {
            case "disabled": action = .toggleControls
            case "l-shaped":
                action = row == 0 || (row == 1 && column == .leading) ? left
                    : (row == 2 || column == .trailing ? right : .toggleControls)
            case "kindle": action = row == 0 ? .toggleControls : (column == .leading ? left : right)
            case "edge": action = column != .center ? right : (row == 2 ? left : .toggleControls)
            default: action = column == .leading ? left : (column == .trailing ? right : .toggleControls)
            }
            return (region, action)
        }))
    }

    public func action(for region: TapZoneRegion) -> ReaderTapAction {
        actions[region] ?? .none
    }
}

public struct ImageReaderSettings: Codable, Hashable, Sendable {
    public let options: ReaderAdditionalPreferences
    public let direction: ImageReadingDirection
    public let layout: ImageReaderLayout
    public let spread: ImagePageSpread
    public let widePageBehavior: WidePageBehavior
    public let widePageAspectRatioThreshold: Double
    public let cropMode: ImageCropMode
    public let zoom: ImageZoomSettings
    public let tapZones: TapZoneConfiguration
    public let prefetch: ImagePrefetchSettings
    public let transition: ImagePageTransition

    public init(
        options: ReaderAdditionalPreferences = ReaderAdditionalPreferences(),
        direction: ImageReadingDirection = .rightToLeft,
        layout: ImageReaderLayout = .vertical,
        spread: ImagePageSpread = .single,
        widePageBehavior: WidePageBehavior = .fit,
        widePageAspectRatioThreshold: Double = 1.2,
        cropMode: ImageCropMode = .none,
        zoom: ImageZoomSettings = ImageZoomSettings(),
        tapZones: TapZoneConfiguration? = nil,
        prefetch: ImagePrefetchSettings = ImagePrefetchSettings(),
        transition: ImagePageTransition = .slide
    ) {
        self.options = options
        self.direction = direction
        self.layout = layout
        self.spread = spread
        self.widePageBehavior = widePageBehavior
        self.widePageAspectRatioThreshold = min(3, max(1, widePageAspectRatioThreshold))
        self.cropMode = cropMode
        self.zoom = zoom
        self.tapZones = tapZones ?? .standard(direction: direction)
        self.prefetch = prefetch
        self.transition = transition
    }
    private enum CodingKeys: String, CodingKey {
        case options, direction, layout, spread, widePageBehavior, widePageAspectRatioThreshold, cropMode, zoom, tapZones, prefetch, transition
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(options: try c.decodeIfPresent(ReaderAdditionalPreferences.self, forKey: .options) ?? .init(),
            direction: try c.decode(ImageReadingDirection.self, forKey: .direction),
            layout: try c.decode(ImageReaderLayout.self, forKey: .layout),
            spread: try c.decode(ImagePageSpread.self, forKey: .spread),
            widePageBehavior: try c.decode(WidePageBehavior.self, forKey: .widePageBehavior),
            widePageAspectRatioThreshold: try c.decode(Double.self, forKey: .widePageAspectRatioThreshold),
            cropMode: try c.decode(ImageCropMode.self, forKey: .cropMode),
            zoom: try c.decode(ImageZoomSettings.self, forKey: .zoom),
            tapZones: try c.decode(TapZoneConfiguration.self, forKey: .tapZones),
            prefetch: try c.decode(ImagePrefetchSettings.self, forKey: .prefetch),
            transition: try c.decode(ImagePageTransition.self, forKey: .transition))
    }

}

public struct ImagePageDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let index: Int
    public let sourceURL: URL?
    public let archivePath: String?
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let detectedCropInsets: NormalizedPageInsets?

    public init(
        id: String,
        index: Int,
        sourceURL: URL? = nil,
        archivePath: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        detectedCropInsets: NormalizedPageInsets? = nil
    ) {
        self.id = id
        self.index = max(0, index)
        self.sourceURL = sourceURL
        self.archivePath = archivePath
        self.pixelWidth = pixelWidth.flatMap { $0 > 0 ? $0 : nil }
        self.pixelHeight = pixelHeight.flatMap { $0 > 0 ? $0 : nil }
        self.detectedCropInsets = detectedCropInsets
    }

    public var aspectRatio: Double? {
        guard let pixelWidth, let pixelHeight, pixelHeight > 0 else {
            return nil
        }
        return Double(pixelWidth) / Double(pixelHeight)
    }

    public func isWide(threshold: Double) -> Bool {
        aspectRatio.map { $0 >= threshold } ?? false
    }

    public func cropInsets(for mode: ImageCropMode) -> NormalizedPageInsets {
        switch mode {
        case .none:
            .zero
        case .automatic:
            detectedCropInsets ?? .zero
        case let .custom(insets):
            insets
        }
    }

    public func croppedAspectRatio(for mode: ImageCropMode) -> Double? {
        guard let aspectRatio else {
            return nil
        }
        let insets = cropInsets(for: mode)
        let horizontalFraction = max(0.1, 1 - insets.leading - insets.trailing)
        let verticalFraction = max(0.1, 1 - insets.top - insets.bottom)
        return aspectRatio * horizontalFraction / verticalFraction
    }
}

public struct ImageReaderState: Codable, Hashable, Sendable {
    public var settings: ImageReaderSettings
    public private(set) var pages: [ImagePageDescriptor]
    public private(set) var currentPageIndex: Int
    public private(set) var widePageSegment: Int
    public private(set) var zoomScale: Double
    public private(set) var controlsVisible: Bool
    public private(set) var scrollOffset: Double = 0
    public var isLandscape = false
    public var isolatedPages: Set<Int> = []
    public private(set) var viewport: ReaderViewport? = nil
    private var expansionAnchor: Int? = nil

    private enum CodingKeys: String, CodingKey {
        case settings, pages, currentPageIndex, widePageSegment, zoomScale, controlsVisible
        case scrollOffset, isLandscape, isolatedPages
    }

    private var usesExpansionPairing: Bool {
        viewport?.supportsSpread == true && settings.options.expandedReading == "right"
            && settings.spread == .automatic && settings.layout == .paged
            && !settings.options.pageOffset && !settings.options.workOverrides.values.contains { $0.pageOffset != nil }
    }

    public mutating func updateViewport(_ viewport: ReaderViewport) {
        let wasExpanded = self.viewport?.isExpanded == true
        self.viewport = viewport
        isLandscape = viewport.size.width > viewport.size.height
        if !viewport.isExpanded { expansionAnchor = nil }
        else if !wasExpanded || expansionAnchor == nil { expansionAnchor = currentPageIndex }
        // Resizing changes presentation, never the logical reading locator.
    }

    public var displayPosition: ImageReaderPosition {
        .init(page: spreadStart, segment: widePageSegment)
    }

    private var spreadStart: Int {
        guard usesDoublePages else { return currentPageIndex }
        return displayPositions.last(where: { $0.page <= currentPageIndex })?.page ?? currentPageIndex
    }

    public var usesDoublePages: Bool {
        guard settings.layout.isPaged else { return false }
        if let viewport, viewport.isExpanded, !viewport.supportsSpread { return false }
        return settings.spread == .double || (settings.spread == .automatic
            && (viewport?.isExpanded == true ? viewport?.supportsSpread == true : isLandscape))
    }

    public mutating func updateSettings(_ settings: ImageReaderSettings) {
        self.settings = settings
        normalizePosition()
        if !isCurrentPageSplit { widePageSegment = 0 }
        setZoomScale(zoomScale)
    }

    public mutating func setScrollOffset(_ offset: Double) {
        scrollOffset = offset.isFinite ? min(0.999_999, max(0, offset)) : 0
    }


    public init(
        pages: [ImagePageDescriptor],
        settings: ImageReaderSettings = ImageReaderSettings(),
        initialPageIndex: Int = 0
    ) {
        self.pages = pages.sorted { lhs, rhs in
            if lhs.index != rhs.index {
                return lhs.index < rhs.index
            }
            return lhs.id < rhs.id
        }
        self.settings = settings
        currentPageIndex = Self.clampedIndex(initialPageIndex, pageCount: pages.count)
        widePageSegment = 0
        zoomScale = settings.zoom.minimumScale
        controlsVisible = true
    }

    public var isAtBeginning: Bool {
        spreadStart == 0 && widePageSegment == 0
    }

    public var isAtEnd: Bool {
        guard !pages.isEmpty else {
            return true
        }
        if isCurrentPageSplit {
            return currentPageIndex == pages.count - 1 && widePageSegment == 1
        }
        return visibleDocumentOrderIndices().last == pages.count - 1
    }

    public var currentLocator: ReadingLocator {
        .image(
            page: currentPageIndex,
            total: pages.count,
            offset: settings.layout.isPaged ? (isCurrentPageSplit ? Double(widePageSegment) * 0.5 : 0) : scrollOffset
        )
    }

    public var currentPage: ImagePageDescriptor? {
        pages.indices.contains(currentPageIndex) ? pages[currentPageIndex] : nil
    }

    public mutating func replacePages(_ pages: [ImagePageDescriptor]) {
        let currentID = currentPage?.id
        self.pages = pages.sorted { lhs, rhs in
            if lhs.index != rhs.index {
                return lhs.index < rhs.index
            }
            return lhs.id < rhs.id
        }
        if let currentID, let newIndex = self.pages.firstIndex(where: { $0.id == currentID }) {
            currentPageIndex = newIndex
        } else {
            currentPageIndex = Self.clampedIndex(currentPageIndex, pageCount: self.pages.count)
        }
        normalizePosition()
        widePageSegment = min(widePageSegment, isCurrentPageSplit ? 1 : 0)
    }

    public mutating func move(to index: Int) {
        currentPageIndex = Self.clampedIndex(index, pageCount: pages.count)
        normalizePosition()
        scrollOffset = 0
        widePageSegment = 0
        resetZoom()
    }

    public mutating func moveToEnd() {
        guard !pages.isEmpty else { return }
        currentPageIndex = pages.count - 1
        widePageSegment = isCurrentPageSplit ? 1 : 0
        resetZoom()
    }

    @discardableResult
    public mutating func moveForward() -> Bool {
        guard !pages.isEmpty else {
            return false
        }
        if isCurrentPageSplit, widePageSegment == 0 {
            widePageSegment = 1
            resetZoom()
            return true
        }

        let nextIndex = (visibleDocumentOrderIndices().last ?? currentPageIndex) + 1
        guard nextIndex < pages.count else {
            return false
        }
        currentPageIndex = nextIndex
        scrollOffset = 0
        widePageSegment = 0
        resetZoom()
        return true
    }

    @discardableResult
    public mutating func moveBackward() -> Bool {
        guard !pages.isEmpty else {
            return false
        }
        if isCurrentPageSplit, widePageSegment == 1 {
            widePageSegment = 0
            resetZoom()
            return true
        }
        guard spreadStart > 0 else {
            return false
        }

        let previous = displayPositions.last { $0.page < spreadStart } ?? .init(page: 0, segment: 0)
        currentPageIndex = previous.page
        scrollOffset = 0
        widePageSegment = isCurrentPageSplit ? 1 : 0
        resetZoom()
        return true
    }

    public mutating func restore(from locator: ReadingLocator) throws {
        guard case let .image(page, _, offset) = locator else {
            throw ReaderError.invalidLocator
        }
        currentPageIndex = Self.clampedIndex(page, pageCount: pages.count)
        normalizePosition()
        widePageSegment = isCurrentPageSplit && offset >= 0.5 ? 1 : 0
        setScrollOffset(settings.layout.isPaged ? 0 : offset)
        resetZoom()
    }

    public func visiblePageIndices() -> [Int] {
        let indices = visibleDocumentOrderIndices()
        if settings.layout.isPaged, settings.direction == .rightToLeft {
            return indices.reversed()
        }
        return indices
    }

    public func prefetchPageIndices() -> [Int] {
        guard !pages.isEmpty else {
            return []
        }
        let visible = visibleDocumentOrderIndices()
        guard let first = visible.first, let last = visible.last else {
            return []
        }
        let lowerBound = max(0, first - settings.prefetch.pagesBehind)
        let upperBound = min(pages.count - 1, last + settings.prefetch.pagesAhead)
        let visibleSet = Set(visible)
        return (lowerBound...upperBound).filter { !visibleSet.contains($0) }
    }

    public mutating func setZoomScale(_ scale: Double) {
        zoomScale = min(settings.zoom.maximumScale, max(settings.zoom.minimumScale, scale))
    }

    public mutating func toggleDoubleTapZoom() {
        if zoomScale > settings.zoom.minimumScale {
            resetZoom()
        } else {
            zoomScale = settings.zoom.doubleTapScale
        }
    }

    public mutating func resetZoom() {
        zoomScale = settings.zoom.minimumScale
    }

    @discardableResult
    public mutating func performTap(in region: TapZoneRegion) -> ReaderTapAction {
        let action = settings.tapZones.action(for: region)
        switch action {
        case .none:
            break
        case .previousPage, .scrollBackward:
            moveBackward()
        case .nextPage, .scrollForward:
            moveForward()
        case .toggleControls:
            controlsVisible.toggle()
        }
        return action
    }

    private var isCurrentPageSplit: Bool {
        settings.layout.isPaged
            && settings.widePageBehavior == .split
            && isWidePage(at: currentPageIndex)
    }

    private func isWidePage(at index: Int) -> Bool {
        pages.indices.contains(index)
            && pages[index].isWide(threshold: settings.widePageAspectRatioThreshold)
    }

    private func visibleDocumentOrderIndices() -> [Int] {
        let start = spreadStart
        guard pages.indices.contains(start) else { return [] }
        return Array(start..<(start + pageCount(at: start)))
    }

    private func pageCount(at index: Int) -> Int {
        guard usesDoublePages,
            !(settings.options.pageOffset && index == 0),
            !isolatedPages.contains(index), !isolatedPages.contains(index + 1),
            !isWidePage(at: index), pages.indices.contains(index + 1),
            !isWidePage(at: index + 1) else { return 1 }
        if usesExpansionPairing, let anchor = expansionAnchor {
            let start = settings.direction == .leftToRight ? max(0, anchor - 1) : anchor
            if index + 1 == start || (index == anchor && settings.direction == .leftToRight) { return 1 }
        }
        return 2
    }

    public mutating func normalizePosition() {
        guard usesDoublePages, viewport?.isExpanded != true else { return }
        currentPageIndex = spreadStart
    }

    public var displayPositions: [ImageReaderPosition] {
        var result: [ImageReaderPosition] = []
        var index = 0
        while index < pages.count {
            result.append(.init(page: index, segment: 0))
            if settings.layout.isPaged && settings.widePageBehavior == .split && isWidePage(at: index) {
                result.append(.init(page: index, segment: 1))
            }
            index += pageCount(at: index)
        }
        return result
    }

    public func preview(at position: ImageReaderPosition) -> Self {
        var preview = self
        preview.currentPageIndex = position.page
        preview.widePageSegment = position.segment
        return preview
    }

    private static func clampedIndex(_ index: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else {
            return 0
        }
        return min(pageCount - 1, max(0, index))
    }
}

/// Recently decoded pages remain reusable within a fixed memory budget. The
/// reader separately holds its active window so visible pages cannot be evicted.
/// Retain discarded image buffers until a utility executor can release them.
/// UIKit-owned images remain on MainActor; only immutable CGImages cross over.
enum ImagePageRetirement {
    @discardableResult
    static func release(_ images: [CGImage]) -> Task<Void, Never>? {
        guard !images.isEmpty else { return nil }
        return Task.detached(priority: .utility) {
            // Let the synchronous reader callback drop its references before
            // this task releases the retained buffers on the utility executor.
            await MainActor.run {}
            let log = OSLog(subsystem: "com.k800k.manko", category: "ReaderPerformance")
            os_signpost(.event, log: log, name: "Images Retired", "count=%d", images.count)
            withExtendedLifetime(images) {}
        }
    }
}

struct ImagePageCache {
    let countLimit: Int
    private(set) var byteLimit: Int
    private var images: [Int: CGImage] = [:]
    private var recency: [Int] = []
    private(set) var byteCount = 0
    var count: Int { images.count }

    mutating func removeAll(byteLimit: Int? = nil) {
        ImagePageRetirement.release(Array(images.values))
        images.removeAll(); recency.removeAll(); byteCount = 0
        if let byteLimit { self.byteLimit = max(0, byteLimit) }
    }

    mutating func setByteLimit(_ limit: Int) {
        byteLimit = max(0, limit)
        while byteCount > byteLimit, let oldest = recency.first { remove(at: oldest) }
    }

    static func byteLimit(physicalMemory: UInt64) -> Int {
        // Reserve at most 1/32 of device memory for reusable images. The active
        // reading window is owned separately and never competes with this cache.
        let minimum: UInt64 = 32 * 1_024 * 1_024
        let maximum: UInt64 = 192 * 1_024 * 1_024
        return Int(min(max(physicalMemory / 32, minimum), maximum))
    }

    init(countLimit: Int, byteLimit: Int = ImagePageCache.byteLimit(physicalMemory: ProcessInfo.processInfo.physicalMemory)) {
        self.countLimit = max(0, countLimit)
        self.byteLimit = max(0, byteLimit)
    }

    mutating func image(at index: Int) -> CGImage? {
        guard let image = images[index] else { return nil }
        recency.removeAll { $0 == index }
        recency.append(index)
        return image
    }

    mutating func insert(_ image: CGImage, at index: Int) {
        remove(at: index)
        let cost = image.bytesPerRow * image.height
        guard cost <= byteLimit, countLimit > 0 else { return }
        images[index] = image
        recency.append(index)
        byteCount += cost
        while images.count > countLimit || byteCount > byteLimit {
            guard let oldest = recency.first else { break }
            remove(at: oldest)
        }
    }

    private mutating func remove(at index: Int) {
        if let image = images.removeValue(forKey: index) {
            byteCount -= image.bytesPerRow * image.height
            ImagePageRetirement.release([image])
        }
        recency.removeAll { $0 == index }
    }
}

/// Shared visible-first ordering; each publication keeps its own cache ceiling.
enum ImagePageWindow {
    static func activePageIndices(for state: ImageReaderState, visiblePageIndices: [Int], pagesAhead: Int? = nil, pagesBehind: Int? = nil) -> [Int] {
        var seen: Set<Int> = []
        let visible = visiblePageIndices.filter { state.pages.indices.contains($0) && seen.insert($0).inserted }
        guard let first = visible.min(), let last = visible.max() else { return [] }
        let lower = max(0, first - (pagesBehind ?? state.settings.prefetch.pagesBehind))
        let upper = min(state.pages.count, last + 1 + (pagesAhead ?? state.settings.prefetch.pagesAhead))
        return visible + Array((last + 1)..<upper) + Array((lower..<first).reversed())
    }

    static func pageIndices(for state: ImageReaderState, maximumCachedPages: Int) -> [Int] {
        let visible = state.visiblePageIndices()
        let prefetched = Set(state.prefetchPageIndices())
        let firstVisible = visible.min() ?? state.currentPageIndex
        let lastVisible = visible.max() ?? state.currentPageIndex
        let ahead = prefetched
            .filter { $0 > lastVisible }
            .sorted()
        let behind = prefetched
            .filter { $0 < firstVisible }
            .sorted(by: >)

        var seen: Set<Int> = []
        var result: [Int] = []
        for index in visible + ahead + behind
            where state.pages.indices.contains(index) && seen.insert(index).inserted
        {
            result.append(index)
            if result.count == maximumCachedPages {
                break
            }
        }
        return result
    }
}

public struct ImageReaderPosition: Hashable, Sendable {
    public let page: Int
    public let segment: Int
    public init(page: Int, segment: Int) { self.page = page; self.segment = segment }
}

public enum ImageReaderSizing {
    public static func contentWidth(viewport: CGSize, options: ReaderAdditionalPreferences) -> CGFloat {
        let portrait = viewport.height >= viewport.width
        let applies = options.pillarbox && (options.pillarboxOrientation == "both"
            || (options.pillarboxOrientation == "portrait" && portrait)
            || (options.pillarboxOrientation == "landscape" && !portrait))
        return max(1, viewport.width * (applies ? 1 - min(95, max(5, options.pillarboxAmount)) / 100 : 1))
    }
    public static func scrollStep(viewportHeight: CGFloat, forward: Bool) -> CGFloat {
        max(0, viewportHeight) * 2 / 3 * (forward ? 1 : -1)
    }
}

public enum ImageReaderGesturePolicy {
    public static func pageTurn(translation: CGPoint, layout: ImageReaderLayout, direction: ImageReadingDirection) -> Bool? {
        guard layout.isPaged else { return nil }
        let primary = layout == .verticalPaged ? translation.y : translation.x
        let secondary = layout == .verticalPaged ? translation.x : translation.y
        guard abs(primary) >= 32, abs(primary) > abs(secondary) else { return nil }
        return (primary < 0) != (layout == .paged && direction == .rightToLeft)
    }
}
