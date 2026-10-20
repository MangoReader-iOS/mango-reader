import CoreGraphics
import Foundation
import MangoReaderDomain
import Observation
import OSLog
import SwiftUI

public enum ImageReaderChapterSource: Sendable {
    case archive(URL)
    case remote(RemoteImagePublication)
    case external
}

public enum ImageReaderSessionPhase: Equatable {
    case loading, ready, failed(String)
}

struct ChapterRequestKey: Hashable {
    let chapterID: InstallmentID
    let direction: ReaderChapterDirection
}

@MainActor @Observable
final class ImageReaderChapter {
    let installment: Installment
    let model: any ImageReaderControlling
    var isSuspended = false

    init(installment: Installment, source: ImageReaderChapterSource, settings: ImageReaderSettings,
         locator: ReadingLocator?, onLocatorChange: @escaping @MainActor (ReadingLocator) -> Void) {
        self.installment = installment
        switch source {
        case let .archive(url):
            model = CBZReaderModel(sourceURL: url, settings: settings, initialLocator: locator,
                maximumCachedPages: 6, onLocatorChange: onLocatorChange)
        case let .remote(publication):
            model = RemoteImageReaderModel(publication: publication, settings: settings, initialLocator: locator,
                maximumCachedPages: 6, onLocatorChange: onLocatorChange)
        case .external:
            preconditionFailure("External publications retain their own reader")
        }
    }

    var phase: ImageReaderSessionPhase {
        if let model = model as? CBZReaderModel {
            switch model.phase { case .ready: return .ready; case let .failed(error): return .failed(error); default: return .loading }
        }
        if let model = model as? RemoteImageReaderModel {
            switch model.phase { case .ready: return .ready; case let .failed(error): return .failed(error); default: return .loading }
        }
        return .loading
    }

    var failureMessage: String? {
        if case let .failed(error) = phase { return error }
        if let model = model as? CBZReaderModel { return model.pageErrorMessage }
        return (model as? RemoteImageReaderModel)?.pageErrorMessage
    }

    func resume() {
        if isSuspended { isSuspended = false; model.openIfNeeded() }
    }
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true; model.suspend()
    }
}

/// Owns chapter loaders for the whole reading session. The active chapter can
/// change without replacing the UIKit reader or its scroll coordinate space.
@MainActor @Observable
public final class ImageReaderSession: ImageReaderControlling {
    public let catalog: ReaderChapterCatalog
    public private(set) var activeChapter: Installment
    public private(set) var phase: ImageReaderSessionPhase = .loading
    public private(set) var chapterRevision: UInt = 0
    public private(set) var jumpIsLoading = false
    public private(set) var jumpError: String?
    private var lastViewport: ReaderViewport?
    private var jumpTarget: Installment?
    @ObservationIgnored private var jumpTask: Task<Void, Never>?
    @ObservationIgnored private var jumpGeneration = UUID()
    public var onActiveChapterChange: ((Installment, ReadingLocator) -> Void)?
    public var onLocatorChange: ((Installment, ReadingLocator) -> Void)?
    public var onChapterCompleted: ((Installment) -> Void)?
    public var onExternalChapter: ((Installment, ReaderChapterDirection) -> Void)?

    private(set) var entries: [ImageReaderChapter] = []
    private var settings: ImageReaderSettings
    private let initialChapter: Installment
    private let initialLocator: ReadingLocator?
    @ObservationIgnored private let prepare: @MainActor (Installment) async throws -> ImageReaderChapterSource
    @ObservationIgnored private var requests: [ChapterRequestKey: Task<Void, Never>] = [:]
    private var failures: [ChapterRequestKey: String] = [:]
    private var preparing: Set<ChapterRequestKey> = []
    @ObservationIgnored private var activationRequests: Set<ChapterRequestKey> = []
    @ObservationIgnored private var externalChapters: Set<InstallmentID> = []
    @ObservationIgnored private var completed: Set<InstallmentID> = []
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    private var hasStarted = false
    private static let performanceLog = OSLog(subsystem: "com.k800k.manko", category: "ReaderPerformance")
    public private(set) var scrollRequestRevision: UInt = 0
    public private(set) var scrollTargetPageIndex: Int?
    private var fallbackState: ImageReaderState

    public init(chapter: Installment, catalog: ReaderChapterCatalog, settings: ImageReaderSettings,
                initialLocator: ReadingLocator? = nil,
                prepare: @escaping @MainActor (Installment) async throws -> ImageReaderChapterSource) {
        initialChapter = chapter; activeChapter = chapter; self.catalog = catalog
        self.settings = settings; self.initialLocator = initialLocator; self.prepare = prepare
        fallbackState = ImageReaderState(pages: [], settings: settings)
    }

    var activeModel: (any ImageReaderControlling)? { entry(activeChapter.id)?.model }
    var state: ImageReaderState { activeModel?.state ?? fallbackState }
    var loadedImages: [Int: CGImage] { activeModel?.loadedImages ?? [:] }
    var pageLoadingStates: [Int: ImagePageLoadingState] { activeModel?.pageLoadingStates ?? [:] }
    var previewPageIndices: Set<Int> { activeModel?.previewPageIndices ?? [] }
    var pageErrorMessage: String? { entry(activeChapter.id)?.failureMessage }
    func retryPageFailure() {
        if let remote = activeModel as? RemoteImageReaderModel { remote.retryPageWindow() }
        else if let archive = activeModel as? CBZReaderModel {
            archive.retryPage(at: archive.pageErrorPageIndex ?? archive.state.currentPageIndex)
        }
    }
    func dismissPageFailure() {
        (activeModel as? RemoteImageReaderModel)?.dismissPageError()
        (activeModel as? CBZReaderModel)?.dismissPageError()
    }
    var lastNavigationIntent: ImageNavigationIntent { activeModel?.lastNavigationIntent ?? .jump }
    var chapterIDs: [InstallmentID] { entries.map { $0.installment.id } }
    // Observation must cover neighboring loaders as well as the active one.
    var observedStates: [ImageReaderState] { entries.map { $0.model.state } }
    var observedImages: [[Int: ObjectIdentifier]] { entries.map { $0.model.loadedImages.mapValues(ObjectIdentifier.init) } }
    var observedLoadingStates: [[Int: ImagePageLoadingState]] { entries.map { $0.model.pageLoadingStates } }
    var observedBoundaries: [ReaderChapterBoundaryState] {
        entries.flatMap { [boundary(from: $0.installment.id, direction: .previous), boundary(from: $0.installment.id, direction: .next)] }
    }

    func entry(_ id: InstallmentID) -> ImageReaderChapter? { entries.first { $0.installment.id == id } }
    func model(for id: InstallmentID) -> (any ImageReaderControlling)? { entry(id)?.model }
    func chapter(_ id: InstallmentID) -> Installment? { entry(id)?.installment ?? catalog.chapters.first { $0.id == id } }

    public func start() async {
        if let startTask { await startTask.value; return }
        guard !hasStarted else { return }
        hasStarted = true
        let token = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let entry = try await load(initialChapter, locator: initialLocator)
                guard token == generation, !Task.isCancelled else { return }
                entries = [entry]; phase = .ready; chapterRevision &+= 1
                onLocatorChange?(activeChapter, entry.model.state.currentLocator)
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
        startTask = task
        await task.value
        startTask = nil
    }

    public func retryInitialChapter() async {
        hasStarted = false; phase = .loading
        await start()
    }

    private func load(_ chapter: Installment, locator: ReadingLocator?) async throws -> ImageReaderChapter {
        let source = try await prepare(chapter)
        try Task.checkCancellation()
        if case .external = source { throw ReaderError.unsupportedFormat(chapter.format) }
        let result = ImageReaderChapter(installment: chapter, source: source,
            settings: settings, locator: locator) { [weak self] locator in
            guard let self, activeChapter.id == chapter.id, phase == .ready else { return }
            onLocatorChange?(chapter, locator)
        }
        result.model.updateLoadingBudget(chapter.id == activeChapter.id ? nil : inactivePrefetch)
        result.model.openIfNeeded()
        do {
            while result.phase == .loading {
                try await Task.sleep(for: .milliseconds(10))
            }
            if case let .failed(error) = result.phase { throw ChapterLoadError(message: error) }
            while result.model.loadedImages[result.model.state.currentPageIndex] == nil, result.failureMessage == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            if let error = result.failureMessage { throw ChapterLoadError(message: error) }
            try Task.checkCancellation()
            if let lastViewport { result.model.updateViewport(lastViewport) }
            return result
        } catch { result.suspend(); throw error }
    }

    func boundary(from id: InstallmentID, direction: ReaderChapterDirection) -> ReaderChapterBoundaryState {
        guard let chapter = chapter(id) else { return .loading(nil) }
        let base = catalog.boundary(from: chapter, direction: direction, skipDuplicates: settings.options.skipDuplicateChapters)
        let key = ChapterRequestKey(chapterID: id, direction: direction)
        if let error = failures[key] { return .failed(error, base.neighbor) }
        if preparing.contains(key) { return .loading(base.neighbor) }
        return base
    }

    func prepareNeighbor(from id: InstallmentID, direction: ReaderChapterDirection, activate: Bool = false, retry: Bool = false) {
        let key = ChapterRequestKey(chapterID: id, direction: direction)
        if activate { activationRequests.insert(key) }
        if retry { failures.removeValue(forKey: key) }
        guard requests[key] == nil, failures[key] == nil else { return }
        guard let chapter = chapter(id) else { return }
        let known = catalog.boundary(from: chapter, direction: direction, skipDuplicates: settings.options.skipDuplicateChapters)
        if let neighbor = known.neighbor, entry(neighbor.id) != nil || externalChapters.contains(neighbor.id) {
            if activationRequests.remove(key) != nil {
                if externalChapters.contains(neighbor.id) { onExternalChapter?(neighbor, direction) }
                else { navigateChapter(neighbor.id, direction: direction) }
            }
            return
        }
        if case .absent = known { activationRequests.remove(key); return }
        let token = generation
        preparing.insert(key)
        requests[key] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if token == generation { preparing.remove(key); requests.removeValue(forKey: key); chapterRevision &+= 1 }
            }
            if known.neighbor == nil {
                if retry, catalog.errorMessage != nil { await catalog.refresh() }
                else { await catalog.refreshIfNeeded() }
            }
            guard token == generation, !Task.isCancelled else { return }
            let state = catalog.boundary(from: chapter, direction: direction, skipDuplicates: settings.options.skipDuplicateChapters)
            guard let next = state.neighbor else {
                if case let .failed(error, _) = state { failures[key] = error }
                else { activationRequests.remove(key) }
                return
            }
            do {
                if entry(next.id) == nil, !externalChapters.contains(next.id) {
                    if next.format.isTextPublication {
                        _ = try await prepare(next)
                        externalChapters.insert(next.id)
                    } else {
                        let locator: ReadingLocator = .image(page: direction == .previous ? Int.max : 0, total: nil, offset: direction == .previous ? 0.999_999 : 0)
                        let loaded = try await load(next, locator: locator)
                        guard token == generation, !Task.isCancelled else { loaded.suspend(); return }
                        guard catalog.boundary(from: chapter, direction: direction, skipDuplicates: settings.options.skipDuplicateChapters).neighbor?.id == next.id else { loaded.suspend(); return }
                        guard let index = entries.firstIndex(where: { $0.installment.id == id }) else { loaded.suspend(); return }
                        entries.insert(loaded, at: direction == .next ? index + 1 : index)
                        chapterRevision &+= 1
                    }
                }
                guard token == generation, !Task.isCancelled else { return }
                if activationRequests.remove(key) != nil, activeChapter.id == id {
                    if externalChapters.contains(next.id) { onExternalChapter?(next, direction) }
                    else { navigateChapter(next.id, direction: direction) }
                }
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                failures[key] = error.localizedDescription
            }
        }
    }

    func continuePastBoundary(from id: InstallmentID, direction: ReaderChapterDirection) {
        if direction == .next { completeChapter(id) }
        prepareNeighbor(from: id, direction: direction, activate: true, retry: true)
    }

    /// Withdrawing intent keeps useful prefetch running but prevents its result
    /// from moving the viewport after the reader reverses or leaves the edge.
    func cancelBoundaryContinuation(from id: InstallmentID, direction: ReaderChapterDirection) {
        activationRequests.remove(ChapterRequestKey(chapterID: id, direction: direction))
    }

    func retryBoundary(from id: InstallmentID, direction: ReaderChapterDirection) {
        let key = ChapterRequestKey(chapterID: id, direction: direction)
        prepareNeighbor(from: id, direction: direction, activate: activationRequests.contains(key), retry: true)
    }

    public func openChapter(_ chapter: Installment) {
        jumpTask?.cancel(); jumpGeneration = UUID()
        jumpError = nil; jumpTarget = chapter
        if entry(chapter.id) != nil { jumpIsLoading = false; navigateChapter(chapter.id, direction: .next); return }
        let token = generation, jumpToken = jumpGeneration
        jumpIsLoading = true
        jumpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if jumpGeneration == jumpToken { jumpIsLoading = false; jumpTask = nil } }
            do {
                if chapter.format.isTextPublication {
                    _ = try await prepare(chapter)
                    guard token == generation, jumpGeneration == jumpToken, !Task.isCancelled else { return }
                    onExternalChapter?(chapter, .next)
                    return
                }
                let loaded = try await load(chapter, locator: .image(page: 0, total: nil, offset: 0))
                guard token == generation, jumpGeneration == jumpToken, !Task.isCancelled else { loaded.suspend(); return }
                for old in entries { old.suspend() }
                entries = [loaded]
                navigateChapter(chapter.id, direction: .next)
            } catch {
                if token == generation, jumpGeneration == jumpToken, !Task.isCancelled { jumpError = error.localizedDescription }
            }
        }
    }

    public func retryChapterJump() { if let jumpTarget { openChapter(jumpTarget) } }

    private func navigateChapter(_ id: InstallmentID, direction: ReaderChapterDirection) {
        guard let entry = entry(id) else { return }
        entry.resume()
        if direction == .previous { entry.model.moveToEnd() } else { entry.model.moveToBeginning() }
        activate(id, locator: entry.model.state.currentLocator)
        scrollTargetPageIndex = entry.model.state.currentPageIndex; scrollRequestRevision &+= 1
    }

    func activate(_ id: InstallmentID, locator: ReadingLocator, completingPrevious: Bool = false) {
        guard let entry = entry(id) else { return }
        if activeChapter.id != id {
            let signpost = OSSignpostID(log: Self.performanceLog)
            os_signpost(.begin, log: Self.performanceLog, name: "Chapter Activation", signpostID: signpost)
            defer { os_signpost(.end, log: Self.performanceLog, name: "Chapter Activation", signpostID: signpost) }
            let oldIndex = entries.firstIndex { $0.installment.id == activeChapter.id }
            let newIndex = entries.firstIndex { $0.installment.id == id }
            if completingPrevious, let oldIndex, let newIndex, newIndex > oldIndex { completeChapter(activeChapter.id) }
            let old = self.entry(activeChapter.id)
            entry.resume()
            if !settings.layout.isPaged, case let .image(page, _, offset) = locator {
                // A viewport handoff is not a jump. Publish its position before
                // observers can see the new chapter's prefetched opening locator.
                entry.model.beginViewportInteraction()
                entry.model.markPosition(page: page, offset: offset)
            }
            activeChapter = entry.installment
            old?.model.updateLoadingBudget(inactivePrefetch)
            entry.model.updateLoadingBudget(nil)
            onActiveChapterChange?(entry.installment, locator)
        }
    }

    func recordPage(chapter id: InstallmentID, position: ImageReaderPosition) {
        guard let entry = entry(id) else { return }
        let locator: ReadingLocator = .image(page: position.page, total: entry.model.state.pages.count, offset: Double(position.segment) / 2)
        activate(id, locator: locator, completingPrevious: true)
        entry.model.navigate(to: locator)
    }

    func completeChapter(_ id: InstallmentID) {
        guard let chapter = chapter(id), completed.insert(id).inserted else { return }
        onChapterCompleted?(chapter)
    }

    func updateVisibleChapters(_ visible: [InstallmentID: [Int]]) {
        let activeIndex = entries.firstIndex { $0.installment.id == activeChapter.id } ?? 0
        let kept = Set(entries.enumerated().filter { abs($0.offset - activeIndex) <= 1 || visible[$0.element.installment.id] != nil }.map { $0.element.installment.id })
        for entry in entries {
            if kept.contains(entry.installment.id) {
                entry.resume()
                if let pages = visible[entry.installment.id], !pages.isEmpty {
                    entry.model.beginViewportInteraction()
                    entry.model.updateVisiblePageIndices(pages, scrollRequestRevision: entry.model.scrollRequestRevision)
                }
            } else { entry.suspend() }
        }
    }

    private var inactivePrefetch: ImagePrefetchSettings {
        // Keep a small opening/closing buffer for continuous chapters. Do not
        // make chapter insertion wait for the entire buffer to finish loading.
        let buffer = settings.options.infiniteScroll && !settings.layout.isPaged
            ? min(2, settings.prefetch.pagesAhead) : 0
        return ImagePrefetchSettings(pagesAhead: buffer, pagesBehind: buffer, maximumConcurrentRequests: 1)
    }

    public func updateSettings(_ settings: ImageReaderSettings) {
        guard self.settings != settings else { return }
        self.settings = settings
        for entry in entries {
            entry.model.updateLoadingBudget(entry.installment.id == activeChapter.id ? nil : inactivePrefetch)
            entry.model.updateSettings(settings)
        }
        fallbackState.updateSettings(settings)
        chapterRevision &+= 1
    }
    public func cancel() {
        generation = UUID(); startTask?.cancel(); startTask = nil; jumpTask?.cancel(); jumpTask = nil; jumpIsLoading = false
        requests.values.forEach { $0.cancel() }; requests.removeAll(); preparing.removeAll(); activationRequests.removeAll()
        entries.forEach { $0.suspend() }
    }
    func openIfNeeded() { updateVisibleChapters([:]) }
    func suspend() { entries.forEach { $0.suspend() } }
    @discardableResult func moveForward() -> Bool { activeModel?.moveForward() ?? false }
    @discardableResult func moveBackward() -> Bool { activeModel?.moveBackward() ?? false }
    func move(to index: Int) { activeModel?.move(to: index); scrollTargetPageIndex = index; scrollRequestRevision &+= 1 }
    public var currentReadingLocator: ReadingLocator? {
        guard phase == .ready, !state.pages.isEmpty else { return nil }
        return state.currentLocator
    }

    public func navigate(to locator: ReadingLocator) { activeModel?.navigate(to: locator); scrollTargetPageIndex = state.currentPageIndex; scrollRequestRevision &+= 1 }
    func moveScreenLeft() { activeModel?.moveScreenLeft() }
    func moveScreenRight() { activeModel?.moveScreenRight() }
    func moveToBeginning() { move(to: 0) }
    func moveToEnd() { activeModel?.moveToEnd(); scrollTargetPageIndex = state.currentPageIndex; scrollRequestRevision &+= 1 }
    func markPageVisible(_ index: Int) { activeModel?.markPageVisible(index) }
    func markPosition(page: Int, offset: Double) { activeModel?.markPosition(page: page, offset: offset) }
    func updateViewport(_ viewport: ReaderViewport) {
        lastViewport = viewport
        entries.forEach { $0.model.updateViewport(viewport) }
    }
    func togglePageIsolation(_ index: Int) { activeModel?.togglePageIsolation(index) }
    func reloadPage(_ index: Int) { activeModel?.reloadPage(index) }
    func updateVisiblePageIndices(_ indices: [Int], scrollRequestRevision: UInt) {
        guard let activeModel else { return }
        activeModel.updateVisiblePageIndices(indices, scrollRequestRevision: activeModel.scrollRequestRevision)
    }
    func beginViewportInteraction() { activeModel?.beginViewportInteraction() }
    func releaseRecentImages() { entries.forEach { $0.model.releaseRecentImages() } }
    func updateLoadingBudget(_ prefetch: ImagePrefetchSettings?) { activeModel?.updateLoadingBudget(prefetch) }
    func performTap(in region: TapZoneRegion) { activeModel?.performTap(in: region) }
    func toggleDoubleTapZoom() { activeModel?.toggleDoubleTapZoom() }
    func updateMagnification(_ magnification: Double) { activeModel?.updateMagnification(magnification) }
    func endMagnification() { activeModel?.endMagnification() }
}

private struct ChapterLoadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

public struct ImageReaderSessionView: View {
    @Environment(\.scenePhase) private var scenePhase
    let session: ImageReaderSession
    let settings: ImageReaderSettings
    let liveText: Bool
    let controls: Binding<Bool>
    let navigation: ImageReaderController
    let showsStatusOverlay: Bool
    public init(session: ImageReaderSession, settings: ImageReaderSettings, liveText: Bool,
                controls: Binding<Bool>, navigation: ImageReaderController, showsStatusOverlay: Bool = true) {
        self.session = session; self.settings = settings; self.liveText = liveText
        self.controls = controls; self.navigation = navigation
        self.showsStatusOverlay = showsStatusOverlay
    }
    public var body: some View {
        let _ = session.observedStates
        let _ = session.observedImages
        let _ = session.observedLoadingStates
        let _ = session.observedBoundaries
        let _ = session.chapterRevision
        Group {
            switch session.phase {
            case .loading: ReaderContentSkeleton().frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                ReaderFailureView(title: "Unable to Open Streamed Chapter", systemImage: "network.slash",
                    message: message, retry: { Task { await session.retryInitialChapter() } })
                    .environment(\.colorScheme, .dark)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                ImageReaderContent(model: session, liveTextEnabled: liveText, controlsVisible: controls,
                    accessibilityLabel: "Comic reader", scrollingAccessibilityLabel: "Scrolling comic reader", navigation: navigation)
            }
        }
        .overlay(alignment: .top) {
            if showsStatusOverlay {
                ImageReaderSessionStatusView(session: session)
                    .padding(.top, 80)
            }
        }
        .onChange(of: session.pageErrorMessage) { _, message in
            if message != nil { controls.wrappedValue = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.suspend() }
            else if phase == .active { session.openIfNeeded() }
        }
        .onChange(of: settings, initial: true) { _, settings in session.updateSettings(settings) }
    }
}

/// Session feedback can be composed with host chrome without resizing the reader surface.
public struct ImageReaderSessionStatusView: View {
    let session: ImageReaderSession

    public init(session: ImageReaderSession) {
        self.session = session
    }

    public var body: some View {
        Group {
            if session.jumpIsLoading {
                ReaderLoadingIndicator("Opening chapter…")
                    .padding().background(.regularMaterial, in: Capsule())
            } else if let error = session.jumpError {
                VStack {
                    Text(error)
                    Button("Retry") { session.retryChapterJump() }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("reader-session-retry")
                }
                .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            } else if session.phase == .ready, let error = session.pageErrorMessage {
                ReaderErrorBanner(message: error, retry: { session.retryPageFailure() }, dismiss: { session.dismissPageFailure() })
            }
        }
        .accessibilityIdentifier("reader-session-status")
    }
}
