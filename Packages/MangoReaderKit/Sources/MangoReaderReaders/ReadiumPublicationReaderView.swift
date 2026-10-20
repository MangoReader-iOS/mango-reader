import Foundation
import MangoReaderDomain
import Observation
import OSLog
import PDFKit
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
import SwiftUI
import UIKit

public enum ReadiumReaderPhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(String)
}

public enum PublicationOutlinePhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(String)
}

public struct PublicationOutlineItem: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let depth: Int
    public let href: String

    public init(id: String, title: String, depth: Int, href: String) {
        self.id = id
        self.title = title
        self.depth = max(0, depth)
        self.href = href
    }
}

public enum PublicationSearchPhase: Equatable, Sendable {
    case idle
    case searching
    case receiving(Int)
    case complete(Int)
    case failed(String)

    public var isSearching: Bool {
        switch self {
        case .searching, .receiving:
            true
        case .idle, .complete, .failed:
            false
        }
    }
}

/// The layout capability Readium resolved from the active EPUB metadata.
/// Typography preferences are intentionally unavailable for fixed-layout
/// publications because their page composition is publisher-controlled.
public enum EPUBPublicationLayout: String, Codable, Hashable, Sendable {
    case reflowable
    case fixed
}

public struct PublicationSearchResult: Hashable, Sendable, Identifiable {
    public let id: String
    public let locator: PersistedReadiumLocator
    public let title: String?
    public let before: String
    public let match: String
    public let after: String
    public let totalProgression: Double?

    public init(
        id: String,
        locator: PersistedReadiumLocator,
        title: String?,
        before: String,
        match: String,
        after: String,
        totalProgression: Double?
    ) {
        self.id = id
        self.locator = locator
        self.title = title
        self.before = before
        self.match = match
        self.after = after
        self.totalProgression = totalProgression.map { min(1, max(0, $0)) }
    }

    public var accessibilityExcerpt: String {
        [before, match, after]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }
}

public enum ReaderAnnotationAnchorKind: String, Hashable, Sendable {
    case textSelection
    case currentPosition
}

/// A durable annotation position captured from the active publication.
/// `selectedText` is present only when Readium exposes an active text
/// selection; callers can still attach a note to the current position.
public struct ReaderAnnotationAnchor: Hashable, Sendable {
    public let locator: ReadingLocator
    public let selectedText: String?
    public let kind: ReaderAnnotationAnchorKind

    public init(
        locator: ReadingLocator,
        selectedText: String?,
        kind: ReaderAnnotationAnchorKind
    ) {
        self.locator = locator
        self.selectedText = selectedText
        self.kind = kind
    }
}

/// A validated annotation that can be submitted to a Readium decoration
/// navigator. Keeping this value independent of UIKit makes the persistence to
/// decoration mapping deterministic and directly testable.
public struct PublicationAnnotationHighlight: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let locator: PersistedReadiumLocator
    public let selectedText: String
    public let highlightColor: ReaderHighlightColor

    public init(
        id: UUID,
        locator: PersistedReadiumLocator,
        selectedText: String,
        highlightColor: ReaderHighlightColor
    ) {
        self.id = id
        self.locator = locator
        self.selectedText = selectedText
        self.highlightColor = highlightColor
    }
}

public extension ReaderHighlightColor {
    @MainActor
    func resolvedUIColor(
        interfaceStyle: UIUserInterfaceStyle,
        accessibilityContrast: UIAccessibilityContrast
    ) -> UIColor {
        let semanticColor: UIColor = switch self {
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .orange: .systemOrange
        case .pink: .systemPink
        }
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = interfaceStyle
            traits.accessibilityContrast = accessibilityContrast
        }
        return semanticColor.resolvedColor(with: traits)
    }
}

/// The public capability boundary of the Readium 3.10 PDF adapter.
///
/// Thumbnail navigation is backed by PDFKit's `PDFThumbnailView`, connected to
/// the exact `PDFDocumentView` owned by Readium. Persisted highlight overlays
/// are intentionally unavailable: `PDFNavigatorViewController` does not
/// conform to `DecorableNavigator`, and its persisted selection locator keeps
/// the page and selected string but not an unambiguous character range or page
/// geometry. Re-searching the string would select the wrong occurrence in
/// repeated text, while adding `PDFAnnotation` objects would mutate the opened
/// PDF document. Both approaches are too fragile for durable annotations.
public enum PDFReaderAdapterCapabilities {
    public static let supportsThumbnailNavigation = true
    public static let supportsPersistedAnnotationOverlays = false
    public static let annotationOverlayLimitation =
        "Readium 3.10's PDF navigator has no decoration API, and its persisted selection locator does not contain the range geometry needed to redraw an exact highlight."
}

/// Coordinates publication-level tools with the active Readium navigator.
///
/// The controller intentionally owns no library persistence. Every navigation
/// still travels through Readium's navigator delegate, preserving the exact
/// locator callback used by reader progress, bookmarks, and sessions.
@MainActor
@Observable
public final class ReadiumReaderController: PublicationSpeechSynthesizerDelegate {
    public private(set) var currentPosition = 0
    public private(set) var positionCount = 0
    public var tapZones = TapZoneConfiguration.standard(direction: .leftToRight)
    public var scrollNavigation = false {
        didSet {
            if oldValue != scrollNavigation { dismissChapterBoundary() }
            observeChapterBoundaries()
        }
    }
    public var animatesNavigation = true
    public var onBoundary: ((Bool) -> Void)?
    /// A compact edge cue; nil dismisses it without covering the navigator.
    public var onBoundaryHint: ((Bool?) -> Void)?
    public var onUserNavigation: (() -> Void)?
    @ObservationIgnored private var positions: [Locator] = []
    @ObservationIgnored private var positionsTask: Task<Void, Never>?
    @ObservationIgnored private var chapterBoundaryObserver: ReadiumChapterBoundaryObserver?
    @ObservationIgnored private var chapterGate = ReaderChapterGestureGate<ObjectIdentifier>()
    @ObservationIgnored private var boundaryHintDirection: Bool?

    public func navigate(toPosition index: Int) {
        if let progressiveBackend { progressiveBackend.navigate(position: index); return }
        guard positions.indices.contains(index), let locator = try? PersistedReadiumLocator(locator: positions[index]) else { return }
        navigate(to: locator.readingLocator, animated: false)
    }

    fileprivate func updateLocation(_ locator: Locator) {
        if let position = locator.locations.position { currentPosition = max(0, position - 1) }
        else if let progression = locator.locations.totalProgression, positionCount > 0 {
            currentPosition = min(positionCount - 1, Int(progression * Double(positionCount)))
        }
        observeChapterBoundaries()
    }

    fileprivate func handleTap(in navigator: VisualNavigator, at point: CGPoint, controls: Binding<Bool>?) {
        guard let view = navigator.view, view.bounds.width > 0, view.bounds.height > 0 else { return }
        if let selectable = navigator as? any SelectableNavigator, selectable.currentSelection != nil { return }
        let region = TapZoneRegion.region(normalizedX: point.x / view.bounds.width, normalizedY: point.y / view.bounds.height)
        switch tapZones.action(for: region) {
        case .nextPage, .scrollForward: moveForward(animated: animatesNavigation)
        case .previousPage, .scrollBackward: moveBackward(animated: animatesNavigation)
        case .toggleControls: controls?.wrappedValue.toggle()
        case .none: break
        }
    }

    private func verticalViewport() -> UIScrollView? {
        guard let root = (navigator as? VisualNavigator)?.view else { return nil }
        return Self.verticalViewport(in: root)
    }

    static func verticalViewport(in root: UIView) -> UIScrollView? {
        func scrollViews(in view: UIView) -> [UIScrollView] {
            ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
        }
        let candidates = scrollViews(in: root).filter {
            $0.isScrollEnabled && $0.bounds.height > 0 && $0.contentSize.height >= $0.bounds.height - 1
        }
        // Readium's outer pager is larger than its text viewport but has no
        // vertical travel. Prefer actual text scrolling so Next doesn't skip it.
        let overflowing = candidates.filter {
            $0.contentSize.height + $0.adjustedContentInset.top + $0.adjustedContentInset.bottom > $0.bounds.height + 1
        }
        // Keep a viewport for vertical boundary gestures on short chapters.
        return (overflowing.isEmpty ? candidates : overflowing)
            .max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    private func isAtPublicationBoundary(_ forward: Bool) -> Bool {
        if let selectable = navigator as? any SelectableNavigator, selectable.currentSelection != nil { return false }
        guard let publication, let visual = navigator as? any ViewportObservingNavigator,
              let viewport = visual.viewport,
              let link = forward ? publication.readingOrder.last : publication.readingOrder.first else { return false }
        let href = link.url().removingFragment().string
        guard let resource = viewport.resources.first(where: { $0.href.removingFragment().string == href }) else { return false }
        return forward ? resource.progression.upperBound >= 0.999 : resource.progression.lowerBound <= 0.001
    }

    private func observeChapterBoundaries() {
        guard let root = (navigator as? any VisualNavigator)?.view else {
            chapterBoundaryObserver?.invalidate(); chapterBoundaryObserver = nil; return
        }
        let scroll = scrollNavigation ? verticalViewport() : nil
        let rtl: Bool
        if let epub = navigator as? EPUBNavigatorViewController { rtl = epub.settings.readingProgression == .rtl }
        else if let pdf = navigator as? PDFNavigatorViewController { rtl = pdf.readingProgression == .rtl }
        else { rtl = publication?.metadata.readingProgression == .rtl }
        if chapterBoundaryObserver?.root === root, chapterBoundaryObserver?.scroll === scroll,
           chapterBoundaryObserver?.rightToLeft == rtl { return }
        if let observer = chapterBoundaryObserver, observer.rightToLeft != rtl { dismissChapterBoundary() }
        chapterBoundaryObserver?.invalidate()
        chapterBoundaryObserver = ReadiumChapterBoundaryObserver(root: root, scroll: scroll, rightToLeft: rtl,
            atBoundary: { [weak self] in self?.isAtPublicationBoundary($0) == true },
            began: { [weak self] in
                guard let self, let identity = publicationIdentity else { return }
                chapterGate.beginInteraction(chapterID: identity)
            },
            moved: { [weak self] forward in
                guard let self else { return }
                chapterGate.noteMovement(forward ? .next : .previous)
                if let hint = boundaryHintDirection, hint != forward {
                    boundaryHintDirection = nil; onBoundaryHint?(nil)
                }
                if !isAtPublicationBoundary(forward) {
                    chapterGate.clearArm()
                    if boundaryHintDirection != nil { boundaryHintDirection = nil; onBoundaryHint?(nil) }
                }
            },
            attempt: { [weak self] in self?.attemptChapterBoundary($0) },
            ended: { [weak self] in self?.chapterGate.endInteraction() })
    }

    private func attemptChapterBoundary(_ forward: Bool) {
        guard let identity = publicationIdentity else { return }
        switch chapterGate.attempt(forward ? .next : .previous, chapterID: identity) {
        case .stop:
            if boundaryHintDirection != forward { boundaryHintDirection = forward; onBoundaryHint?(forward) }
        case .continueChapter: onBoundary?(forward)
        case .ignored: break
        }
    }

    public func dismissChapterBoundary() {
        chapterGate.reset()
        if boundaryHintDirection != nil { boundaryHintDirection = nil; onBoundaryHint?(nil) }
    }

    private func discreteChapterBoundary(_ forward: Bool) {
        guard let identity = publicationIdentity else { return }
        chapterGate.beginInteraction(chapterID: identity)
        attemptChapterBoundary(forward)
        chapterGate.endInteraction()
    }

    fileprivate func beginViewportChange() {
        chapterBoundaryObserver?.cancelGesture()
        dismissChapterBoundary()
        isRestoringInitialLocation = true
    }

    private func scrollViewport(forward: Bool, animated: Bool) -> Bool {
        guard scrollNavigation, let scroll = verticalViewport() else { return false }
        let minimum = -scroll.adjustedContentInset.top
        let maximum = max(minimum, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let target = min(maximum, max(minimum, scroll.contentOffset.y + ImageReaderSizing.scrollStep(viewportHeight: scroll.bounds.height, forward: forward)))
        guard abs(target - scroll.contentOffset.y) > 0.5 else { return false }
        chapterBoundaryObserver?.cancelGesture()
        dismissChapterBoundary()
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target), animated: animated)
        onUserNavigation?()
        return true
    }

    public private(set) var isPublicationReady = false
    public fileprivate(set) var isRestoringInitialLocation = true
    public fileprivate(set) var restoredReadingLocator: ReadingLocator?
    @ObservationIgnored fileprivate weak var locationRestorer: ReadiumInitialLocationRestorer?
    public private(set) var isSearchable = false
    public private(set) var isTTSSupported = false
    public private(set) var outlinePhase: PublicationOutlinePhase = .idle
    public private(set) var outline: [PublicationOutlineItem] = []
    public private(set) var searchPhase: PublicationSearchPhase = .idle
    public private(set) var searchResults: [PublicationSearchResult] = []
    public private(set) var searchQuery = ""
    public private(set) var ttsState: PublicationTTSState = .idle
    public private(set) var ttsExcerpt: String?
    public private(set) var toolErrorMessage: String?
    public private(set) var annotationHighlights: [PublicationAnnotationHighlight] = []
    public private(set) var isAnnotationHighlightSupported = false
    public private(set) var isPDFThumbnailNavigationAvailable = false
    public private(set) var pdfThumbnailNavigationRevision = 0
    public private(set) var epubLayout: EPUBPublicationLayout?

    @ObservationIgnored weak var progressiveBackend: (any ProgressiveReaderBackend)?
    @ObservationIgnored private weak var navigator: (any Navigator)?
    @ObservationIgnored private var publication: Publication?
    @ObservationIgnored private var sectionMap: GeneratedPublicationSections?
    @ObservationIgnored private var unresolvedAnnotationIDs: Set<UUID> = []
    @ObservationIgnored private var publicationIdentity: ObjectIdentifier?
    @ObservationIgnored private var outlineLinks: [String: ReadiumShared.Link] = [:]
    @ObservationIgnored private var outlineTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var navigationTask: Task<Void, Never>?
    @ObservationIgnored private var ttsTask: Task<Void, Never>?
    @ObservationIgnored private var speechSynthesizer: PublicationSpeechSynthesizer?
    @ObservationIgnored private var lastSpokenLocator: Locator?
    @ObservationIgnored private var annotationInterfaceStyle: UIUserInterfaceStyle = .light
    @ObservationIgnored private var annotationAccessibilityContrast: UIAccessibilityContrast = .normal
    @ObservationIgnored fileprivate weak var pdfDocumentView: PDFDocumentView?

    public init() {}

    public func restoreReadingPosition(_ locator: ReadingLocator) {
        if let progressiveBackend { progressiveBackend.navigate(locator: locator); return }
        dismissChapterBoundary()
        guard let navigator = navigator as? any VisualNavigator else { return }
        do {
            let location = try resolvedLocator(PersistedReadiumLocator(readingLocator: locator)).makeLocator()
            locationRestorer?.start(navigator: navigator, location: location, waitForFirstLocation: false)
        } catch { toolErrorMessage = error.localizedDescription }
    }

    private func resolvedLocator(_ persisted: PersistedReadiumLocator, selectedText: String? = nil, requiresTextMatch: Bool = false) throws -> PersistedReadiumLocator {
        guard let sectionMap else { return persisted }
        return try PersistedReadiumLocator(jsonData: sectionMap.remap(persisted.jsonData, selectedText: selectedText, requiresTextMatch: requiresTextMatch))
    }

    fileprivate func attach(publication: Publication, navigator: any Navigator, sectionMap: GeneratedPublicationSections? = nil) {
        self.navigator = navigator
        let identity = ObjectIdentifier(publication)
        guard publicationIdentity != identity else {
            updateAnnotationHighlightSupport()
            applyAnnotationHighlights()
            return
        }

        resetForNewPublication()
        self.publication = publication
        self.sectionMap = sectionMap
        publicationIdentity = identity
        if publication.conforms(to: .epub) {
            let editor = EPUBPreferencesEditor(
                initialPreferences: .empty,
                metadata: publication.metadata,
                defaults: EPUBDefaults()
            )
            epubLayout = editor.layout == .reflowable ? .reflowable : .fixed
        }
        isPublicationReady = true
        isSearchable = publication.isSearchable
        speechSynthesizer = PublicationSpeechSynthesizer(publication: publication, delegate: self)
        isTTSSupported = speechSynthesizer != nil
        updateAnnotationHighlightSupport()
        applyAnnotationHighlights()
        loadOutline()
        positionsTask = Task { [weak self, weak publication] in
            guard let publication, let values = try? await publication.positions().get(), !Task.isCancelled,
                  let self, publicationIdentity == ObjectIdentifier(publication) else { return }
            positions = values
            positionCount = values.count
            if let location = navigator.currentLocation { updateLocation(location) }
        }
    }

    func attachProgressive(_ backend: any ProgressiveReaderBackend) {
        resetForNewPublication()
        progressiveBackend = backend
        epubLayout = .reflowable
        isAnnotationHighlightSupported = true
    }

    func updateProgressive(blocks: [ProgressivePublicationBlock], complete: Bool, current: Int, count: Int,
        locator: ReadingLocator?, restored: Bool) {
        isPublicationReady = locator != nil
        isRestoringInitialLocation = !restored
        if restored, restoredReadingLocator == nil { restoredReadingLocator = locator }
        isSearchable = complete; isTTSSupported = !blocks.isEmpty
        // Unknown total stays unknown; an expanding denominator is not a page count.
        positionCount = count
        currentPosition = current
        outline = blocks.compactMap { block in block.heading.map {
            PublicationOutlineItem(id: block.id, title: $0, depth: 0, href: block.id)
        } }
        outlinePhase = blocks.isEmpty ? .loading : .ready
    }
    func updateProgressiveSpeech(_ state: PublicationTTSState, excerpt: String?) {
        ttsState = state; ttsExcerpt = excerpt
    }
    func detachProgressive(_ backend: any ProgressiveReaderBackend) {
        guard progressiveBackend === backend else { return }
        backend.stopSpeech(); resetForNewPublication()
    }

    fileprivate func attachPDFDocumentView(_ view: PDFDocumentView) {
        pdfDocumentView = view
        isPDFThumbnailNavigationAvailable = true
        pdfThumbnailNavigationRevision &+= 1
    }

    fileprivate func detachPDFDocumentView(_ view: PDFDocumentView?) {
        if let view, pdfDocumentView !== view { return }
        pdfDocumentView = nil
        isPDFThumbnailNavigationAvailable = false
        pdfThumbnailNavigationRevision &+= 1
    }

    public func dismissToolError() {
        toolErrorMessage = nil
    }

    public func navigate(to item: PublicationOutlineItem, animated: Bool = true) {
        if let progressiveBackend { progressiveBackend.navigate(blockID: item.href); return }
        guard let navigator, let link = outlineLinks[item.id] else {
            toolErrorMessage = "This section could not be located."
            return
        }
        navigationTask?.cancel()
        navigationTask = Task { [weak self] in
            let moved = await navigator.go(
                to: link,
                options: NavigatorGoOptions(animated: animated)
            )
            guard !Task.isCancelled, !moved else {
                return
            }
            self?.toolErrorMessage = "This section could not be opened."
        }
    }

    public func navigate(to result: PublicationSearchResult, animated: Bool = true) {
        if let progressiveBackend { progressiveBackend.navigate(locator: result.locator.readingLocator); return }
        guard let navigator else {
            toolErrorMessage = "The reader is not ready."
            return
        }
        let locator: Locator
        do {
            locator = try result.locator.makeLocator()
        } catch {
            toolErrorMessage = ReaderError.invalidLocator.localizedDescription
            return
        }

        navigationTask?.cancel()
        navigationTask = Task { [weak self] in
            let moved = await navigator.go(
                to: locator,
                options: NavigatorGoOptions(animated: animated)
            )
            guard !Task.isCancelled else {
                return
            }
            if moved {
                self?.displaySelectedSearchResult(locator)
            } else {
                self?.toolErrorMessage = "This search result could not be opened."
            }
        }
    }

    /// Navigates to a durable bookmark or annotation locator.
    public func navigate(to readingLocator: ReadingLocator, animated: Bool = true) {
        if let progressiveBackend { progressiveBackend.navigate(locator: readingLocator); return }
        dismissChapterBoundary()
        let locator: Locator
        do {
            locator = try resolvedLocator(PersistedReadiumLocator(readingLocator: readingLocator)).makeLocator()
        } catch {
            toolErrorMessage = error.localizedDescription
            return
        }
        guard let navigator else {
            toolErrorMessage = "The reader is not ready."
            return
        }

        navigationTask?.cancel()
        navigationTask = Task { [weak self] in
            let moved = await navigator.go(
                to: locator,
                options: NavigatorGoOptions(animated: animated)
            )
            guard !Task.isCancelled, !moved else { return }
            self?.toolErrorMessage = "This saved position could not be opened."
        }
    }

    /// Moves in logical publication order for keyboard and Catalyst menu
    /// commands. Readium resolves the physical direction from the active
    /// publication's reading progression.
    public func moveForward(animated: Bool = true) {
        if let progressiveBackend { progressiveBackend.move(forward: true); return }
        if scrollViewport(forward: true, animated: animated) { return }
        moveInReadingOrder(forward: true, animated: animated)
    }

    public func moveBackward(animated: Bool = true) {
        if let progressiveBackend { progressiveBackend.move(forward: false); return }
        if scrollViewport(forward: false, animated: animated) { return }
        moveInReadingOrder(forward: false, animated: animated)
    }

    /// Captures a text selection when one exists, otherwise falls back to the
    /// current reader position. PDF selections remain fully navigable and
    /// persisted even though the current Readium PDF navigator cannot render
    /// decoration overlays.
    public func annotationAnchor(fallback: ReadingLocator? = nil) -> ReaderAnnotationAnchor? {
        if let progressiveBackend { return progressiveBackend.annotationAnchor(fallback: fallback) }
        if let selectable = navigator as? any SelectableNavigator,
           let selection = selectable.currentSelection
        {
            do {
                let persisted = try PersistedReadiumLocator(locator: selection.locator)
                let selectedText = selection.locator.text.highlight?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                selectable.clearSelection()
                return ReaderAnnotationAnchor(
                    locator: persisted.readingLocator,
                    selectedText: selectedText.flatMap { $0.isEmpty ? nil : String($0.prefix(20_000)) },
                    kind: .textSelection
                )
            } catch {
                toolErrorMessage = ReaderError.invalidLocator.localizedDescription
                return nil
            }
        }

        if let fallback {
            return ReaderAnnotationAnchor(
                locator: fallback,
                selectedText: nil,
                kind: .currentPosition
            )
        }
        guard let location = navigator?.currentLocation else {
            toolErrorMessage = "Move to a readable position before adding a note."
            return nil
        }
        do {
            return ReaderAnnotationAnchor(
                locator: try PersistedReadiumLocator(locator: location).readingLocator,
                selectedText: nil,
                kind: .currentPosition
            )
        } catch {
            toolErrorMessage = ReaderError.invalidLocator.localizedDescription
            return nil
        }
    }

    /// Replaces the complete persisted annotation decoration set. Position-only
    /// notes remain available in the annotation sheet but are intentionally not
    /// rendered as highlights.
    public func setAnnotations(_ annotations: [Annotation]) {
        if let progressiveBackend { progressiveBackend.setAnnotations(annotations) }
        annotationHighlights = annotations.compactMap { annotation in
            guard
                let selectedText = annotation.selectedText?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !selectedText.isEmpty,
                let locator = try? PersistedReadiumLocator(readingLocator: annotation.locator)
            else {
                return nil
            }
            return PublicationAnnotationHighlight(
                id: annotation.id,
                locator: locator,
                selectedText: selectedText,
                highlightColor: annotation.highlightColor
            )
        }
        applyAnnotationHighlights()
    }

    fileprivate func setAnnotationAppearance(isDark: Bool, increasedContrast: Bool) {
        let interfaceStyle: UIUserInterfaceStyle = isDark ? .dark : .light
        let accessibilityContrast: UIAccessibilityContrast = increasedContrast ? .high : .normal
        guard
            annotationInterfaceStyle != interfaceStyle
                || annotationAccessibilityContrast != accessibilityContrast
        else {
            return
        }
        annotationInterfaceStyle = interfaceStyle
        annotationAccessibilityContrast = accessibilityContrast
        applyAnnotationHighlights()
    }

    private func moveInReadingOrder(forward: Bool, animated: Bool) {
        guard navigator != nil else {
            toolErrorMessage = "The reader is not ready."
            return
        }
        navigationTask?.cancel()
        navigationTask = Task { [weak self] in
            guard let self, let navigator else { return }
            let options = NavigatorGoOptions(animated: animated)
            let moved = forward ? await navigator.goForward(options: options) : await navigator.goBackward(options: options)
            guard !Task.isCancelled else { return }
            if moved { dismissChapterBoundary(); onUserNavigation?() }
            else { discreteChapterBoundary(forward) }
        }
    }

    /// Starts a cancellable search and appends each Readium result page as it
    /// arrives. Calling this again cancels the previous iterator immediately.
    public func search(
        _ query: String,
        preferences: PublicationSearchPreferences = PublicationSearchPreferences()
    ) {
        searchTask?.cancel()
        clearSearchDecoration()

        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchQuery = query
        searchResults = []
        guard !query.isEmpty else {
            searchPhase = .idle
            return
        }
        if let progressiveBackend {
            searchResults = progressiveBackend.search(query, preferences: preferences)
            searchPhase = .complete(searchResults.count)
            return
        }
        guard let publication, publication.isSearchable else {
            searchPhase = .failed("This publication does not provide searchable text.")
            return
        }

        searchPhase = .searching
        searchTask = Task { [weak self] in
            let options = SearchOptions(
                caseSensitive: preferences.isCaseSensitive,
                diacriticSensitive: preferences.isDiacriticSensitive,
                wholeWord: preferences.matchesWholeWords
            )
            let iterator: any SearchIterator
            switch await publication.search(query: query, options: options) {
            case let .success(value):
                iterator = value
            case let .failure(error):
                guard !Task.isCancelled else { return }
                self?.searchPhase = .failed(Self.searchErrorDescription(error))
                return
            }

            while !Task.isCancelled, (self?.searchResults.count ?? 0) < preferences.maximumResults {
                let collection: LocatorCollection?
                switch await iterator.next() {
                case let .success(value):
                    collection = value
                case let .failure(error):
                    guard !Task.isCancelled else { return }
                    self?.searchPhase = .failed(Self.searchErrorDescription(error))
                    return
                }
                guard !Task.isCancelled else { return }
                guard let collection else {
                    let count = self?.searchResults.count ?? 0
                    self?.searchPhase = .complete(count)
                    return
                }

                for locator in collection.locators {
                    guard !Task.isCancelled,
                          let self,
                          searchResults.count < preferences.maximumResults
                    else {
                        return
                    }
                    do {
                        let persisted = try PersistedReadiumLocator(locator: locator)
                        let text = locator.text.sanitized()
                        searchResults.append(
                            PublicationSearchResult(
                                id: "\(searchResults.count)-\(locator.href.string)",
                                locator: persisted,
                                title: locator.title,
                                before: text.before ?? "",
                                match: text.highlight ?? "",
                                after: text.after ?? "",
                                totalProgression: locator.locations.totalProgression
                            )
                        )
                    } catch {
                        continue
                    }
                }
                self?.searchPhase = .receiving(self?.searchResults.count ?? 0)
                await Task.yield()
            }

            guard !Task.isCancelled else { return }
            let count = self?.searchResults.count ?? 0
            self?.searchPhase = .complete(count)
        }
    }

    public func cancelSearch(clearResults: Bool = true) {
        searchTask?.cancel()
        searchTask = nil
        searchPhase = .idle
        if clearResults {
            searchQuery = ""
            searchResults = []
            clearSearchDecoration()
        }
    }

    public func toggleTTS() {
        if let progressiveBackend { progressiveBackend.toggleSpeech(); return }
        switch ttsState {
        case .idle:
            startTTS()
        case .speaking:
            speechSynthesizer?.pause()
        case .paused:
            speechSynthesizer?.resume()
        }
    }

    public func startTTS() {
        if let progressiveBackend { progressiveBackend.toggleSpeech(); return }
        guard let navigator, let speechSynthesizer else {
            toolErrorMessage = "Text to speech is unavailable for this publication."
            return
        }
        ttsTask?.cancel()
        ttsTask = Task {
            let locator: Locator?
            if let visualNavigator = navigator as? any VisualNavigator {
                locator = await visualNavigator.firstVisibleElementLocator()
                    ?? navigator.currentLocation
            } else {
                locator = navigator.currentLocation
            }
            guard !Task.isCancelled else { return }
            speechSynthesizer.start(from: locator)
        }
    }

    public func stopTTS() {
        progressiveBackend?.stopSpeech()
        ttsTask?.cancel()
        ttsTask = nil
        speechSynthesizer?.stop()
        clearTTSDecoration()
        ttsState = .idle
        ttsExcerpt = nil
        lastSpokenLocator = nil
    }

    public func previousTTSUtterance() {
        if let progressiveBackend { progressiveBackend.advanceSpeech(forward: false); return }
        speechSynthesizer?.previous()
    }

    public func nextTTSUtterance() {
        if let progressiveBackend { progressiveBackend.advanceSpeech(forward: true); return }
        speechSynthesizer?.next()
    }

    public func publicationSpeechSynthesizer(
        _ synthesizer: PublicationSpeechSynthesizer,
        stateDidChange state: PublicationSpeechSynthesizer.State
    ) {
        switch state {
        case .stopped:
            ttsState = .idle
            ttsExcerpt = nil
            lastSpokenLocator = nil
            clearTTSDecoration()

        case let .paused(utterance):
            ttsState = .paused
            ttsExcerpt = utterance.text
            displaySpokenUtterance(utterance.locator)

        case let .playing(utterance, range):
            ttsState = .speaking
            ttsExcerpt = utterance.text
            displaySpokenUtterance(range ?? utterance.locator)
            guard lastSpokenLocator != utterance.locator, let navigator else {
                return
            }
            lastSpokenLocator = utterance.locator
            ttsTask?.cancel()
            ttsTask = Task {
                _ = await navigator.go(
                    to: utterance.locator,
                    options: NavigatorGoOptions(animated: true)
                )
            }
        }
    }

    public func publicationSpeechSynthesizer(
        _ synthesizer: PublicationSpeechSynthesizer,
        utterance: PublicationSpeechSynthesizer.Utterance,
        didFailWithError error: PublicationSpeechSynthesizer.Error
    ) {
        ttsState = .paused
        toolErrorMessage = "Text to speech could not read this passage."
    }

    private func loadOutline() {
        guard let publication else { return }
        outlineTask?.cancel()
        outlinePhase = .loading
        outlineTask = Task { [weak self] in
            let tableOfContents: [ReadiumShared.Link]
            do {
                tableOfContents = try await publication.tableOfContents().get()
            } catch {
                guard !Task.isCancelled else { return }
                self?.outlinePhase = .failed("The publication outline could not be read.")
                return
            }
            guard !Task.isCancelled, let self else { return }

            let roots = tableOfContents.isEmpty ? publication.readingOrder : tableOfContents
            var items: [PublicationOutlineItem] = []
            var links: [String: ReadiumShared.Link] = [:]

            func append(_ values: [ReadiumShared.Link], depth: Int, path: [Int]) {
                for (index, link) in values.enumerated() {
                    let itemPath = path + [index]
                    let id = itemPath.map(String.init).joined(separator: ".") + "|" + link.href
                    let trimmedTitle = link.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                    items.append(
                        PublicationOutlineItem(
                            id: id,
                            title: trimmedTitle.flatMap { $0.isEmpty ? nil : $0 }
                                ?? "Untitled section",
                            depth: depth,
                            href: link.href
                        )
                    )
                    links[id] = link
                    append(link.children, depth: depth + 1, path: itemPath)
                }
            }

            append(roots, depth: 0, path: [])
            outline = items
            outlineLinks = links
            outlinePhase = .ready
        }
    }

    private func resetForNewPublication() {
        progressiveBackend?.stopSpeech()
        progressiveBackend = nil
        dismissChapterBoundary()
        chapterBoundaryObserver?.invalidate()
        chapterBoundaryObserver = nil
        positionsTask?.cancel()
        positions = []; positionCount = 0; currentPosition = 0
        outlineTask?.cancel()
        searchTask?.cancel()
        navigationTask?.cancel()
        stopTTS()
        publication = nil
        sectionMap = nil
        unresolvedAnnotationIDs = []
        publicationIdentity = nil
        outlineLinks = [:]
        outline = []
        outlinePhase = .idle
        searchResults = []
        searchQuery = ""
        searchPhase = .idle
        isPublicationReady = false
        isRestoringInitialLocation = true
        restoredReadingLocator = nil
        isSearchable = false
        isTTSSupported = false
        isAnnotationHighlightSupported = false
        isPDFThumbnailNavigationAvailable = false
        epubLayout = nil
        pdfDocumentView = nil
        pdfThumbnailNavigationRevision &+= 1
        speechSynthesizer = nil
        toolErrorMessage = nil
    }

    private func updateAnnotationHighlightSupport() {
        guard let decorator = navigator as? any DecorableNavigator else {
            isAnnotationHighlightSupported = false
            return
        }
        isAnnotationHighlightSupported = decorator.supports(decorationStyle: .highlight)
    }

    private func applyAnnotationHighlights() {
        guard
            let decorator = navigator as? any DecorableNavigator,
            decorator.supports(decorationStyle: .highlight)
        else {
            isAnnotationHighlightSupported = false
            return
        }
        isAnnotationHighlightSupported = true
        var unresolved: Set<UUID> = []
        let decorations = annotationHighlights.compactMap { highlight -> Decoration? in
            guard let locator = try? resolvedLocator(highlight.locator, selectedText: highlight.selectedText, requiresTextMatch: true).makeLocator() else {
                unresolved.insert(highlight.id)
                return nil
            }
            return Decoration(
                id: highlight.id.uuidString,
                locator: locator,
                style: .highlight(
                    tint: Self.annotationTint(
                        for: highlight.highlightColor,
                        interfaceStyle: annotationInterfaceStyle,
                        accessibilityContrast: annotationAccessibilityContrast
                    )
                )
            )
        }
        decorator.apply(decorations: decorations, in: "annotations")
        if sectionMap != nil, !unresolved.isEmpty, unresolved != unresolvedAnnotationIDs {
            toolErrorMessage = "Some saved highlights could not be placed in this updated volume. They are still available in Bookmarks & Notes."
        }
        unresolvedAnnotationIDs = unresolved
    }

    static func annotationTint(
        for color: ReaderHighlightColor,
        interfaceStyle: UIUserInterfaceStyle,
        accessibilityContrast: UIAccessibilityContrast
    ) -> UIColor {
        color.resolvedUIColor(
            interfaceStyle: interfaceStyle,
            accessibilityContrast: accessibilityContrast
        )
    }

    private func displaySelectedSearchResult(_ locator: Locator) {
        guard let decorator = navigator as? any DecorableNavigator,
              decorator.supports(decorationStyle: .highlight)
        else {
            return
        }
        decorator.apply(
            decorations: [
                Decoration(
                    id: "selected-search-result",
                    locator: locator,
                    style: .highlight(tint: .systemYellow)
                ),
            ],
            in: "search"
        )
    }

    private func clearSearchDecoration() {
        (navigator as? any DecorableNavigator)?.apply(decorations: [], in: "search")
    }

    private func displaySpokenUtterance(_ locator: Locator) {
        guard let decorator = navigator as? any DecorableNavigator,
              decorator.supports(decorationStyle: .highlight)
        else {
            return
        }
        decorator.apply(
            decorations: [
                Decoration(
                    id: "spoken-text",
                    locator: locator,
                    style: .highlight(tint: .systemIndigo)
                ),
            ],
            in: "tts"
        )
    }

    private func clearTTSDecoration() {
        (navigator as? any DecorableNavigator)?.apply(decorations: [], in: "tts")
    }

    private static func searchErrorDescription(_ error: SearchError) -> String {
        switch error {
        case .publicationNotSearchable:
            "This publication does not provide searchable text."
        case .badQuery:
            "That search query is not supported."
        case .reading:
            "The publication text could not be searched."
        }
    }
}

/// A native, lazily rendered PDF page strip connected to the active Readium
/// navigator. Selecting a thumbnail drives the same `PDFView` that Readium
/// observes, so its normal location callback persists the resulting locator.
@MainActor
public struct PDFThumbnailNavigationView: UIViewRepresentable {
    private let controller: ReadiumReaderController
    private let revision: Int

    public init(controller: ReadiumReaderController) {
        self.controller = controller
        revision = controller.pdfThumbnailNavigationRevision
    }

    public func makeUIView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView(frame: .zero)
        view.layoutMode = .horizontal
        view.thumbnailSize = CGSize(width: 72, height: 96)
        view.contentInset = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "pdf-thumbnail-navigation"
        view.accessibilityLabel = "PDF page thumbnails"
        view.pdfView = controller.pdfDocumentView
        return view
    }

    public func updateUIView(_ view: PDFThumbnailView, context: Context) {
        _ = revision
        guard view.pdfView !== controller.pdfDocumentView else { return }
        view.pdfView = controller.pdfDocumentView
    }

    public static func dismantleUIView(_ view: PDFThumbnailView, coordinator: Void) {
        view.pdfView = nil
    }
}

/// Main-actor state for a local EPUB or PDF navigator.
///
/// The opened Readium publication remains isolated to the UI actor because the
/// navigator view controllers are UIKit objects. File validation and Readium's
/// asynchronous asset parsing are still performed by their respective services.
@MainActor
@Observable
public final class ReadiumReaderModel {
    public let sourceURL: URL
    public let format: PublicationFormat
    public let initialLocator: PersistedReadiumLocator?

    public private(set) var phase: ReadiumReaderPhase = .idle
    public private(set) var latestLocator: PersistedReadiumLocator?
    public private(set) var navigatorErrorMessage: String?
    public var textPreferences: TextReaderPreferences
    public var pdfPreferences: PDFReaderPreferences

    @ObservationIgnored public private(set) var document: ReadiumPublicationDocument?
    @ObservationIgnored public private(set) var resolvedInitialLocator: PersistedReadiumLocator?
    @ObservationIgnored private let service: ReadiumPublicationService
    @ObservationIgnored private let onLocatorChange: (@MainActor (ReadingLocator) -> Void)?
    @ObservationIgnored private var openTask: Task<Void, Never>?

    public init(
        sourceURL: URL,
        format: PublicationFormat,
        initialLocator: PersistedReadiumLocator? = nil,
        textPreferences: TextReaderPreferences = TextReaderPreferences(),
        pdfPreferences: PDFReaderPreferences = PDFReaderPreferences(),
        service: ReadiumPublicationService = ReadiumPublicationService(),
        onLocatorChange: (@MainActor (ReadingLocator) -> Void)? = nil
    ) {
        self.sourceURL = sourceURL
        self.format = format
        self.initialLocator = initialLocator
        self.latestLocator = initialLocator
        self.textPreferences = textPreferences
        self.pdfPreferences = pdfPreferences
        self.service = service
        self.onLocatorChange = onLocatorChange
    }

    deinit {
        openTask?.cancel()
    }

    public func openIfNeeded() {
        guard phase == .idle else {
            return
        }
        guard format == .epub || format == .pdf else {
            phase = .failed(ReaderError.unsupportedFormat(format).localizedDescription)
            return
        }

        phase = .loading
        navigatorErrorMessage = nil
        openTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try Task.checkCancellation()
                let document = try await service.open(url: sourceURL, format: format)
                try Task.checkCancellation()
                if let initialLocator {
                    resolvedInitialLocator = try document.resolvedLocator(initialLocator)
                }
                self.document = document
                phase = .ready
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(Self.userFacingMessage(for: error))
            }
        }
    }

    public func cancelOpening() { openTask?.cancel() }

    public func retry() {
        openTask?.cancel()
        openTask = nil
        document = nil
        resolvedInitialLocator = nil
        phase = .idle
        openIfNeeded()
    }

    public func dismissNavigatorError() {
        navigatorErrorMessage = nil
    }

    /// Synchronizes values supplied by the convenience SwiftUI initializer
    /// into the retained model. Nil means the caller passed an owned model via
    /// `init(model:)`, so its preferences must remain authoritative.
    func synchronizeSuppliedPreferences(
        text: TextReaderPreferences?,
        pdf: PDFReaderPreferences?
    ) {
        if let text, textPreferences != text {
            textPreferences = text
        }
        if let pdf, pdfPreferences != pdf {
            pdfPreferences = pdf
        }
    }

    fileprivate func record(_ locator: Locator) {
        do {
            let persisted = try PersistedReadiumLocator(locator: locator)
            latestLocator = persisted
            onLocatorChange?(persisted.readingLocator)
        } catch {
            navigatorErrorMessage = ReaderError.invalidLocator.localizedDescription
        }
    }

    fileprivate func reportNavigatorError(_ message: String) {
        navigatorErrorMessage = message
    }

    fileprivate static func userFacingMessage(for error: Error) -> String {
        if let localizedError = error as? any LocalizedError,
           let description = localizedError.errorDescription
        {
            return description
        }
        return error.localizedDescription
    }
}

/// A SwiftUI host for Readium's UIKit EPUB and PDF navigators.
public struct ReadiumPublicationReaderView: View {
    @State private var model: ReadiumReaderModel
    private let controller: ReadiumReaderController?
    private let controlsVisible: Binding<Bool>?
    private let onPhaseChange: (@MainActor (ReadiumReaderPhase) -> Void)?
    private let onRequestClose: (@MainActor () -> Void)?
    private let suppliedTextPreferences: TextReaderPreferences?
    private let suppliedPDFPreferences: PDFReaderPreferences?
    private let expandedReading: String

    public init(
        model: ReadiumReaderModel,
        expandedReading: String = "right",
        controller: ReadiumReaderController? = nil,
        controlsVisible: Binding<Bool>? = nil,
        onPhaseChange: (@MainActor (ReadiumReaderPhase) -> Void)? = nil,
        onRequestClose: (@MainActor () -> Void)? = nil
    ) {
        _model = State(initialValue: model)
        self.expandedReading = expandedReading
        self.controller = controller
        self.controlsVisible = controlsVisible
        self.onPhaseChange = onPhaseChange
        self.onRequestClose = onRequestClose
        suppliedTextPreferences = nil
        suppliedPDFPreferences = nil
    }

    public init(
        sourceURL: URL,
        format: PublicationFormat,
        initialLocator: PersistedReadiumLocator? = nil,
        textPreferences: TextReaderPreferences = TextReaderPreferences(),
        pdfPreferences: PDFReaderPreferences = PDFReaderPreferences(),
        expandedReading: String = "right",
        service: ReadiumPublicationService = ReadiumPublicationService(),
        controller: ReadiumReaderController? = nil,
        controlsVisible: Binding<Bool>? = nil,
        onPhaseChange: (@MainActor (ReadiumReaderPhase) -> Void)? = nil,
        onRequestClose: (@MainActor () -> Void)? = nil,
        onLocatorChange: (@MainActor (ReadingLocator) -> Void)? = nil
    ) {
        _model = State(
            initialValue: ReadiumReaderModel(
                sourceURL: sourceURL,
                format: format,
                initialLocator: initialLocator,
                textPreferences: textPreferences,
                pdfPreferences: pdfPreferences,
                service: service,
                onLocatorChange: onLocatorChange
            )
        )
        self.expandedReading = expandedReading
        self.controller = controller
        self.controlsVisible = controlsVisible
        self.onPhaseChange = onPhaseChange
        self.onRequestClose = onRequestClose
        suppliedTextPreferences = textPreferences
        suppliedPDFPreferences = pdfPreferences
    }

    public var body: some View {
        Group {
            switch model.phase {
            case .idle, .loading:
                ReaderContentSkeleton(layout: model.format == .pdf ? .page : .text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                if let document = model.document {
                    navigator(document: document)
                } else {
                    failureView(message: "The publication could not be prepared for reading.")
                }
            case let .failed(message):
                failureView(message: message)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .safeAreaInset(edge: .top, spacing: 0) {
            if let message = model.navigatorErrorMessage {
                navigatorErrorBanner(message: message)
            }
        }
        .task {
            model.openIfNeeded()
        }
        .onDisappear { model.cancelOpening() }
        .onChange(of: model.phase, initial: true) { _, phase in
            onPhaseChange?(phase)
        }
        .onChange(of: suppliedTextPreferences, initial: true) { _, preferences in
            model.synchronizeSuppliedPreferences(text: preferences, pdf: nil)
        }
        .onChange(of: suppliedPDFPreferences, initial: true) { _, preferences in
            model.synchronizeSuppliedPreferences(text: nil, pdf: preferences)
        }
    }

    @ViewBuilder
    private func navigator(document: ReadiumPublicationDocument) -> some View {
        let initialLocation = try? model.resolvedInitialLocator?.makeLocator()
        switch document.snapshot.format {
        case .epub:
            EPUBNavigatorContainer(
                document: document,
                initialLocation: initialLocation,
                preferences: model.textPreferences,
                expandedReading: expandedReading,
                controller: controller,
                controlsVisible: controlsVisible,
                onLocatorChange: model.record,
                onError: model.reportNavigatorError
            )
            .id(document.snapshot.id)
        case .pdf:
            PDFNavigatorContainer(
                document: document,
                initialLocation: initialLocation,
                preferences: model.pdfPreferences,
                expandedReading: expandedReading,
                controller: controller,
                controlsVisible: controlsVisible,
                onLocatorChange: model.record,
                onError: model.reportNavigatorError
            )
            .id(document.snapshot.id)
        case .cbz, .remoteImageSequence:
            failureView(message: ReaderError.unsupportedFormat(document.snapshot.format).localizedDescription)
        }
    }

    private func failureView(message: String) -> some View {
        ReaderFailureView(
            title: "Unable to Open Publication",
            systemImage: "book.closed",
            message: message,
            retry: { model.retry() },
            returnToTitle: onRequestClose
        )
    }

    private func navigatorErrorBanner(message: String) -> some View {
        ReaderErrorBanner(
            message: message,
            dismiss: { model.dismissNavigatorError() }
        )
    }
}

private struct EPUBNavigatorContainer: UIViewControllerRepresentable {
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.colorScheme) private var colorScheme

    let document: ReadiumPublicationDocument
    let initialLocation: Locator?
    let preferences: TextReaderPreferences
    let expandedReading: String
    let controller: ReadiumReaderController?
    let controlsVisible: Binding<Bool>?
    let onLocatorChange: @MainActor (Locator) -> Void
    let onError: @MainActor (String) -> Void

    func makeCoordinator() -> EPUBCoordinator {
        EPUBCoordinator(
            controller: controller,
            controlsVisible: controlsVisible,
            onLocatorChange: onLocatorChange,
            onError: onError
        )
    }

    func makeUIViewController(context: Context) -> UIViewController {
        do {
            let config = EPUBNavigatorViewController.Configuration(
                preferences: preferences.readiumPreferences
            )
            let navigator = try EPUBNavigatorViewController(
                publication: document.publication,
                initialLocation: initialLocation,
                config: config
            )
            navigator.delegate = context.coordinator
            context.coordinator.lastPreferences = preferences
            context.coordinator.lastAnnotationIsDark = annotationIsDark
            context.coordinator.lastIncreasedContrast = increasedContrast
            controller?.setAnnotationAppearance(
                isDark: annotationIsDark,
                increasedContrast: increasedContrast
            )
            controller?.attach(publication: document.publication, navigator: navigator, sectionMap: document.sectionMap)
            context.coordinator.restoration.start(navigator: navigator, location: initialLocation)
            let host = ReadiumLayoutHost(content: navigator, navigator: navigator, restoration: context.coordinator.restoration)
            configure(host, coordinator: context.coordinator)
            return host
        } catch {
            return NavigatorFailureViewController(
                message: ReadiumReaderModel.userFacingMessage(for: error)
            )
        }
    }

    func updateUIViewController(_ viewController: UIViewController, context: Context) {
        guard let host = viewController as? ReadiumLayoutHost else { return }
        context.coordinator.controlsVisible = controlsVisible
        configure(host, coordinator: context.coordinator)
        if context.coordinator.lastAnnotationIsDark != annotationIsDark
            || context.coordinator.lastIncreasedContrast != increasedContrast
        {
            controller?.setAnnotationAppearance(
                isDark: annotationIsDark,
                increasedContrast: increasedContrast
            )
            context.coordinator.lastAnnotationIsDark = annotationIsDark
            context.coordinator.lastIncreasedContrast = increasedContrast
        }
    }

    private func configure(_ host: ReadiumLayoutHost, coordinator: EPUBCoordinator) {
        guard let navigator = host.content as? EPUBNavigatorViewController else { return }
        let editor = EPUBPreferencesEditor(initialPreferences: .empty,
            metadata: document.publication.metadata, defaults: EPUBDefaults())
        let reflowable = editor.layout == .reflowable
        host.layout = { viewport in
            let frame = preferences.presentationFrame(in: viewport, reflowable: reflowable,
                publisherSinglePage: editor.spread.effectiveValue == .never, expandedReading: expandedReading)
            var resolved = preferences.readiumPreferences
            if reflowable, viewport.isExpanded, frame != viewport.unobscuredBounds { resolved.columnCount = .one }
            if coordinator.appliedPreferences != resolved {
                coordinator.appliedPreferences = resolved
                navigator.submitPreferences(resolved)
            }
            return frame
        }
        if coordinator.lastPreferences != preferences || coordinator.expandedReading != expandedReading {
            coordinator.lastPreferences = preferences
            coordinator.expandedReading = expandedReading
            host.invalidateLayout()
        }
    }

    private var annotationIsDark: Bool {
        preferences.theme == .black || (preferences.theme == .system && colorScheme == .dark)
    }

    private var increasedContrast: Bool {
        accessibilityContrast == .increased
    }

    static func dismantleUIViewController(_ viewController: UIViewController, coordinator: EPUBCoordinator) {
        coordinator.restoration.cancel()
        ((viewController as? ReadiumLayoutHost)?.content as? EPUBNavigatorViewController)?.delegate = nil
    }
}

private struct PDFNavigatorContainer: UIViewControllerRepresentable {
    let document: ReadiumPublicationDocument
    let initialLocation: Locator?
    let preferences: PDFReaderPreferences
    let expandedReading: String
    let controller: ReadiumReaderController?
    let controlsVisible: Binding<Bool>?
    let onLocatorChange: @MainActor (Locator) -> Void
    let onError: @MainActor (String) -> Void

    func makeCoordinator() -> PDFCoordinator {
        PDFCoordinator(
            controller: controller,
            controlsVisible: controlsVisible,
            onLocatorChange: onLocatorChange,
            onError: onError
        )
    }

    func makeUIViewController(context: Context) -> UIViewController {
        do {
            let config = PDFNavigatorViewController.Configuration(
                preferences: preferences.readiumPreferences
            )
            let navigator = try PDFNavigatorViewController(
                publication: document.publication,
                initialLocation: initialLocation,
                config: config,
                delegate: context.coordinator
            )
            context.coordinator.lastPreferences = preferences
            controller?.attach(publication: document.publication, navigator: navigator, sectionMap: document.sectionMap)
            context.coordinator.restoration.start(navigator: navigator, location: initialLocation)
            let host = ReadiumLayoutHost(content: navigator, navigator: navigator, restoration: context.coordinator.restoration)
            configure(host, coordinator: context.coordinator)
            return host
        } catch {
            return NavigatorFailureViewController(
                message: ReadiumReaderModel.userFacingMessage(for: error)
            )
        }
    }

    func updateUIViewController(_ viewController: UIViewController, context: Context) {
        context.coordinator.controlsVisible = controlsVisible
        guard let host = viewController as? ReadiumLayoutHost else { return }
        configure(host, coordinator: context.coordinator)
    }

    private func configure(_ host: ReadiumLayoutHost, coordinator: PDFCoordinator) {
        guard let navigator = host.content as? PDFNavigatorViewController else { return }
        host.layout = { viewport in
            if viewport.isExpanded, !coordinator.wasExpanded || coordinator.expansionPage == nil {
                let view = coordinator.pdfDocumentView
                coordinator.expansionPage = coordinator.restoration.anchorLocation?.locations.position.map { $0 - 1 }
                    ?? view?.currentPage.flatMap { view?.document?.index(for: $0) }
            }
            let presentation = preferences.presentation(in: viewport, expandedReading: expandedReading,
                anchorPage: coordinator.expansionPage)
            let resolved = presentation.preferences
            let frame = presentation.frame
            coordinator.wasExpanded = viewport.isExpanded
            if !viewport.isExpanded { coordinator.expansionPage = nil }
            if coordinator.appliedPreferences != resolved {
                coordinator.appliedPreferences = resolved
                navigator.submitPreferences(resolved)
            }
            return frame
        }
        if coordinator.lastPreferences != preferences || coordinator.expandedReading != expandedReading {
            coordinator.lastPreferences = preferences
            coordinator.expandedReading = expandedReading
            host.invalidateLayout()
        }
    }

    static func dismantleUIViewController(_ viewController: UIViewController, coordinator: PDFCoordinator) {
        coordinator.restoration.cancel()
        ((viewController as? ReadiumLayoutHost)?.content as? PDFNavigatorViewController)?.delegate = nil
        coordinator.detachPDFDocumentView()
    }
}

@MainActor
private final class EPUBCoordinator: NSObject, EPUBNavigatorDelegate {
    private weak var controller: ReadiumReaderController?
    var lastPreferences: TextReaderPreferences?
    var appliedPreferences: EPUBPreferences?
    var expandedReading: String?
    var lastAnnotationIsDark = false
    var lastIncreasedContrast = false
    var controlsVisible: Binding<Bool>?
    let restoration: ReadiumInitialLocationRestorer
    private let onLocatorChange: @MainActor (Locator) -> Void
    private let onError: @MainActor (String) -> Void

    init(
        controller: ReadiumReaderController?,
        controlsVisible: Binding<Bool>?,
        onLocatorChange: @escaping @MainActor (Locator) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        restoration = ReadiumInitialLocationRestorer(controller: controller, onError: onError)
        self.controller = controller
        self.controlsVisible = controlsVisible
        self.onLocatorChange = onLocatorChange
        self.onError = onError
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        controller?.updateLocation(locator)
        if restoration.accepts(locator) { onLocatorChange(locator) }
    }

    func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
        toggleControlsIfNeeded(in: navigator, at: point)
    }

    private func toggleControlsIfNeeded(in navigator: VisualNavigator, at point: CGPoint) {
        controller?.handleTap(in: navigator, at: point, controls: controlsVisible)
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        onError(Self.message(for: error))
    }

    func navigator(
        _ navigator: Navigator,
        didFailToLoadResourceAt href: RelativeURL,
        withError error: ReadError
    ) {
        onError("A publication resource could not be loaded.")
    }

    private static func message(for error: NavigatorError) -> String {
        switch error {
        case .copyForbidden:
            "Copying is not permitted for this selection."
        }
    }
}

@MainActor
private final class PDFCoordinator: NSObject, @MainActor PDFNavigatorDelegate {
    var lastPreferences: PDFReaderPreferences?
    var appliedPreferences: PDFPreferences?
    var expandedReading: String?
    var wasExpanded = false
    var expansionPage: Int?
    var controlsVisible: Binding<Bool>?
    private weak var controller: ReadiumReaderController?
    fileprivate weak var pdfDocumentView: PDFDocumentView?
    let restoration: ReadiumInitialLocationRestorer
    private let onLocatorChange: @MainActor (Locator) -> Void
    private let onError: @MainActor (String) -> Void

    init(
        controller: ReadiumReaderController?,
        controlsVisible: Binding<Bool>?,
        onLocatorChange: @escaping @MainActor (Locator) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        restoration = ReadiumInitialLocationRestorer(controller: controller, onError: onError)
        self.controller = controller
        self.controlsVisible = controlsVisible
        self.onLocatorChange = onLocatorChange
        self.onError = onError
    }

    func navigator(_ navigator: PDFNavigatorViewController, setupPDFView view: PDFDocumentView) {
        pdfDocumentView = view
        controller?.attachPDFDocumentView(view)
    }

    func detachPDFDocumentView() {
        controller?.detachPDFDocumentView(pdfDocumentView)
        pdfDocumentView = nil
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        controller?.updateLocation(locator)
        if restoration.accepts(locator) { onLocatorChange(locator) }
    }

    func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
        controller?.handleTap(in: navigator, at: point, controls: controlsVisible)
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        switch error {
        case .copyForbidden:
            onError("Copying is not permitted for this selection.")
        }
    }

    func navigator(
        _ navigator: Navigator,
        didFailToLoadResourceAt href: RelativeURL,
        withError error: ReadError
    ) {
        onError("A PDF page could not be loaded.")
    }
}

enum ReaderControlsTapTarget {
    static func contains(_ point: CGPoint, in size: CGSize) -> Bool {
        guard size.width > 0,
              size.height > 0,
              point.x >= 0,
              point.x <= size.width,
              point.y >= 0,
              point.y <= size.height
        else {
            return false
        }

        return TapZoneRegion.region(
            normalizedX: Double(point.x / size.width),
            normalizedY: Double(point.y / size.height)
        ).column == .center
    }
}

@MainActor
private final class NavigatorFailureViewController: UIViewController {
    private let message: String

    init(message: String) {
        self.message = message
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let imageView = UIImageView(image: UIImage(systemName: "book.closed"))
        imageView.tintColor = .secondaryLabel
        imageView.contentMode = .scaleAspectFit

        let label = UILabel()
        label.text = message
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [imageView, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 44),
            imageView.heightAnchor.constraint(equalToConstant: 44),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}

@MainActor
private final class ReadiumChapterBoundaryObserver: NSObject, UIGestureRecognizerDelegate {
    weak var root: UIView?
    weak var scroll: UIScrollView?
    private let atBoundary: (Bool) -> Bool
    private let began: () -> Void
    private let moved: (Bool) -> Void
    private let attempt: (Bool) -> Void
    private let ended: () -> Void
    let rightToLeft: Bool
    private var observation: NSKeyValueObservation?
    private let pan = UIPanGestureRecognizer()
    private var userScrolling = false
    private var lastDirection = true
    private var attemptedDirection: Bool?
    private var beganAtBeginning = false
    private var beganAtEnd = false
    private var hasDeliberateMovement = false

    init(root: UIView, scroll: UIScrollView?, rightToLeft: Bool,
         atBoundary: @escaping (Bool) -> Bool, began: @escaping () -> Void,
         moved: @escaping (Bool) -> Void, attempt: @escaping (Bool) -> Void, ended: @escaping () -> Void) {
        self.root = root; self.scroll = scroll; self.rightToLeft = rightToLeft
        self.atBoundary = atBoundary; self.began = began; self.moved = moved
        self.attempt = attempt; self.ended = ended
        super.init()
        pan.addTarget(self, action: #selector(panned(_:)))
        pan.delegate = self; pan.cancelsTouchesInView = false
        pan.allowedScrollTypesMask = .all
        root.addGestureRecognizer(pan)
        if let scroll {
            observation = scroll.observe(\.contentOffset, options: [.old, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, userScrolling, hasDeliberateMovement else { return }
                    guard pan.state == .changed || (pan.state == .ended && scroll.isDecelerating) else {
                        if pan.state == .ended { cancelGesture() }
                        return
                    }
                    checkBoundary()
                }
            }
        }
    }

    func cancelGesture() {
        userScrolling = false; attemptedDirection = nil
        ended()
    }

    func invalidate() {
        cancelGesture()
        observation = nil
        root?.removeGestureRecognizer(pan)
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            userScrolling = true; attemptedDirection = nil; hasDeliberateMovement = false
            beganAtBeginning = atBoundary(false); beganAtEnd = atBoundary(true)
            began()
        case .changed:
            let translation = gesture.translation(in: root)
            if scroll != nil {
                guard abs(translation.y) >= 20, abs(translation.y) > abs(translation.x) else { return }
                hasDeliberateMovement = true
                lastDirection = translation.y < 0
                moved(lastDirection)
                checkBoundary()
            } else {
                guard abs(translation.x) >= 36, abs(translation.x) > abs(translation.y) else { return }
                hasDeliberateMovement = true
                lastDirection = (translation.x < 0) != rightToLeft
                moved(lastDirection)
                // Only a gesture that began on the publication's outer edge
                // can arm it. Reaching the final page remains normal paging.
                guard lastDirection ? beganAtEnd : beganAtBeginning else { return }
                checkBoundary()
            }
        case .ended:
            if scroll == nil { cancelGesture() }
            else {
                Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self, pan.state == .ended, userScrolling else { return }
                    if hasDeliberateMovement { checkBoundary() }
                    if scroll?.isDecelerating != true { cancelGesture() }
                }
            }
        case .cancelled, .failed: cancelGesture()
        default: break
        }
    }

    private func checkBoundary() {
        guard userScrolling, attemptedDirection != lastDirection, atBoundary(lastDirection) else { return }
        if let scroll {
            let minimum = -scroll.adjustedContentInset.top
            let maximum = max(minimum, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let atEdge = lastDirection ? scroll.contentOffset.y >= maximum - 1 : scroll.contentOffset.y <= minimum + 1
            guard atEdge else { return }
        }
        attemptedDirection = lastDirection
        attempt(lastDirection)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let root, descendants(root).contains(where: { ($0 as? UIScrollView)?.zoomScale ?? 1 > 1.01 }) { return false }
        return true
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}


/// Keeps navigator identity stable while its viewport moves around the fold.
@MainActor
private final class ReadiumLayoutHost: UIViewController {
    let content: UIViewController
    let navigator: any VisualNavigator
    let restoration: ReadiumInitialLocationRestorer
    var layout: ((ReaderViewport) -> CGRect)?
    private var viewport: ReaderViewport?
    private var needsLayoutUpdate = true
    private var resizeTask: Task<Void, Never>?

    init(content: UIViewController, navigator: any VisualNavigator, restoration: ReadiumInitialLocationRestorer) {
        self.content = content; self.navigator = navigator; self.restoration = restoration
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(content); view.addSubview(content.view); content.didMove(toParent: self)
    }
    func invalidateLayout() { needsLayoutUpdate = true; view.setNeedsLayout() }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        restoration.beginResize(navigator)
        super.viewWillTransition(to: size, with: coordinator)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let next = ReaderViewport.measure(view)
        guard next.size.width > 0, next.size.height > 0,
              next != viewport || needsLayoutUpdate else { return }
        restoration.beginResize(navigator)
        viewport = next; needsLayoutUpdate = false
        let frame = layout?(next) ?? view.bounds
        if let coordinator = transitionCoordinator, content.view.bounds.size != frame.size {
            content.viewWillTransition(to: frame.size, with: coordinator)
        }
        content.view.frame = frame
        content.view.setNeedsLayout(); content.view.layoutIfNeeded()
        resizeTask?.cancel()
        resizeTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            restoration.finishResize(navigator)
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        resizeTask?.cancel()
    }
}

@MainActor
private final class ReadiumInitialLocationRestorer {
    private weak var controller: ReadiumReaderController?
    private weak var navigator: (any VisualNavigator)?
    private var target: Locator?
    private var resizeTarget: Locator?
    private var resizing = false
    private var logicalLocator: Locator?
    private var preservesProgress = false
    var anchorLocation: Locator? { logicalLocator ?? target }
    private let onError: @MainActor (String) -> Void
    private var gate = ReaderProgressRestorationGate()
    private var task: Task<Void, Never>?
    private let openingLog = OSLog(subsystem: "com.k800k.manko", category: "ReaderOpening")
    private var restorationID: OSSignpostID?

    init(controller: ReadiumReaderController?, onError: @escaping @MainActor (String) -> Void) {
        self.controller = controller
        self.onError = onError
    }

    func start(navigator: any VisualNavigator, location: Locator?, waitForFirstLocation: Bool = true, preservesProgress: Bool = false) {
        finishRestorationMeasurement()
        if !preservesProgress {
            let id = OSSignpostID(log: openingLog)
            restorationID = id
            os_signpost(.begin, log: openingLog, name: "PublicationRestoration", signpostID: id)
        }
        self.preservesProgress = preservesProgress
        task?.cancel(); task = nil
        self.navigator = navigator
        target = location
        gate.begin()
        controller?.locationRestorer = self
        controller?.isRestoringInitialLocation = true
        // The first native location callback signals that the navigator has
        // loaded its view. Calling go() from makeUIViewController is too early.
        if !waitForFirstLocation { restore(from: navigator.currentLocation) }
    }

    private func restore(from initial: Locator?) {
        guard task == nil, let navigator else { return }
        task = Task { [weak self, weak navigator] in
            guard let self, let navigator else { return }
            if let target {
                let restored = await navigator.go(to: target, options: NavigatorGoOptions(animated: false))
                guard !Task.isCancelled else { return }
                guard restored else {
                    finishRestorationMeasurement()
                    onError("The saved reading position could not be restored. Close and reopen the book to retry; your saved position has been kept.")
                    return
                }
            }
            guard !Task.isCancelled else { return }
            let locator = (navigator.currentLocation ?? initial).flatMap { try? PersistedReadiumLocator(locator: $0).readingLocator }
            gate.complete(at: locator)
            finishRestorationMeasurement()
            if !preservesProgress { os_signpost(.event, log: openingLog, name: "FirstReadableText") }
            if !preservesProgress {
                logicalLocator = target ?? navigator.currentLocation ?? initial
                controller?.restoredReadingLocator = locator
            }
            controller?.isRestoringInitialLocation = false
        }
    }

    func beginResize(_ navigator: any VisualNavigator) {
        guard !resizing, !gate.isRestoring, let location = logicalLocator ?? navigator.currentLocation else { return }
        resizeTarget = location
        controller?.beginViewportChange()
        resizing = true
        gate.begin()
    }

    func finishResize(_ navigator: any VisualNavigator) {
        guard resizing else { return }
        resizing = false
        start(navigator: navigator, location: resizeTarget, waitForFirstLocation: false, preservesProgress: true)
        resizeTarget = nil
    }

    func accepts(_ locator: Locator) -> Bool {
        guard !resizing else { return false }
        if gate.isRestoring {
            restore(from: locator)
            return false
        }
        guard let saved = try? PersistedReadiumLocator(locator: locator) else { return false }
        let accepted = gate.accepts(saved.readingLocator)
        if accepted { logicalLocator = locator }
        return accepted
    }

    private func finishRestorationMeasurement() {
        if let id = restorationID {
            os_signpost(.end, log: openingLog, name: "PublicationRestoration", signpostID: id)
            restorationID = nil
        }
    }

    func cancel() { task?.cancel(); finishRestorationMeasurement() }
}
