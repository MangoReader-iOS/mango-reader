import MangoReaderDomain
import Photos
import SwiftUI
import UIKit

@MainActor
struct NativeImageReader<Model: ImageReaderControlling>: UIViewControllerRepresentable {
    let model: Model
    let liveTextEnabled: Bool
    let reduceMotion: Bool
    let controlsVisible: Binding<Bool>?
    let navigation: ImageReaderController?

    func makeUIViewController(context: Context) -> NativeImageReaderController<Model> {
        NativeImageReaderController(model: model)
    }
    func updateUIViewController(_ controller: NativeImageReaderController<Model>, context: Context) {
        // Reading observable values here subscribes SwiftUI to decoder/state changes.
        _ = model.loadedImages
        _ = model.pageLoadingStates
        _ = model.state
        _ = model.scrollRequestRevision
        controller.configure(liveText: liveTextEnabled, reduceMotion: reduceMotion,
            controls: controlsVisible, navigation: navigation)
    }
    static func dismantleUIViewController(_ controller: NativeImageReaderController<Model>, coordinator: ()) {
        controller.stopAutoScroll()
    }
}

@MainActor
final class NativeImageReaderController<Model: ImageReaderControlling>: UIViewController,
    UIPageViewControllerDataSource, UIPageViewControllerDelegate,
    UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
    let model: Model
    private var pager: UIPageViewController?
    private var collection: UICollectionView?
    private var zoomScroll: UIScrollView?
    private var activeLayout: ImageReaderLayout?
    private var lastSize = CGSize.zero
    private var lastViewport: ReaderViewport?
    private var lastState: ImageReaderState?
    private var lastImages: [Int: ObjectIdentifier] = [:]
    private var revision: UInt?
    private var pendingPosition: ReadingLocator?
    private var transitioning = false
    private var interactivePaging = false
    private var interactivePagingReleased = false
    private var pagerGeneration = UUID()
    private var transitionStartRevision: UInt = 0
    var isPagingTransitionInFlight: Bool { transitioning }
    var isCollectionUpdateInFlight: Bool { applyingLayout }
    private var liveText = false
    private var reduceMotion = false
    private var controls: Binding<Bool>?
    private weak var navigation: ImageReaderController?
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private let standaloneChapterID = InstallmentID()
    private var session: ImageReaderSession? { model as? ImageReaderSession }
    private var activeChapterID: InstallmentID { session?.activeChapter.id ?? standaloneChapterID }
    private var collectionDataSource: UICollectionViewDiffableDataSource<InstallmentID, ChapterPresentationItem>?
    private var renderedItems: [[ChapterPresentationItem]] = []
    private var renderedMetadata: [[ImagePageDescriptor]] = []
    private var scrollingItemCache: [InstallmentID: (pages: [ImagePageDescriptor], items: [ChapterPresentationItem])] = [:]
    private var cachedScrollingChapterIDs: [InstallmentID] = []
    private let boundarySizingPage = ImageChapterBoundaryPage()
    private var renderedBoundaryStates: [ReaderChapterBoundaryState] = []
    private var frozenBoundaryHeights: [ChapterPresentationItem: CGFloat] = [:]
    private var continuousChapters: Bool { session != nil && model.state.settings.options.infiniteScroll }
    private var renderedChapterIDs: [InstallmentID] = []
    private var pagedItem: ChapterPresentationItem?
    private var previousPagedItems: [ChapterPresentationItem] = []
    private var applyingLayout = false
    private var isUserScrolling = false
    private var scrollInteractionRevision: UInt = 0
    private var hasInteracted = false
    private var programmaticScrollTarget: CGFloat?
    private var lastRecordedScrollOffset: CGFloat?
    private var wantsAutoScroll = false
    private var waitingForChapter = false
    private var autoScrollWasRunning = false
    private let zoomDelegate = ContinuousZoomDelegate()
    private var chapterGate = ReaderChapterGestureGate<InstallmentID>()
    private var boundaryPageDirection: ReaderChapterDirection?
    private var boundaryPageChapterID: InstallmentID?
    private var lastActiveChapterID: InstallmentID?
    private var clampingScroll = false
    private var interactionContinuedChapter = false
    private var humanInteractionInFlight = false
    private var gestureIsCoasting = false
    private var continuationDirection: ReaderChapterDirection?
    private var continuationTargetChapterID: InstallmentID?

    init(model: Model) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); becomeFirstResponder() }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        dismissBoundaryPage()
        humanInteractionInFlight = false
        isUserScrolling = false
        scrollInteractionRevision &+= 1
        programmaticScrollTarget = nil
        stopAutoScroll()
    }

    func configure(liveText: Bool, reduceMotion: Bool, controls: Binding<Bool>?, navigation: ImageReaderController?) {
        self.liveText = liveText; self.reduceMotion = reduceMotion; self.controls = controls; self.navigation = navigation
        loadViewIfNeeded()
        if lastActiveChapterID != activeChapterID {
            if humanInteractionInFlight, interactionContinuedChapter, continuationTargetChapterID == nil {
                continuationTargetChapterID = activeChapterID
            }
            dismissBoundaryPage(); lastActiveChapterID = activeChapterID
        }
        navigation?.move = { [weak self] in self?.move(forward: $0) }
        navigation?.seek = { [weak self] in self?.dismissBoundaryPage(); self?.model.move(to: $0) }
        navigation?.autoScroll = { [weak self] in self?.toggleAutoScroll() }
        navigation?.pause = { [weak self] in self?.stopAutoScroll() }
        view.backgroundColor = backgroundColor
        if activeLayout != model.state.settings.layout { rebuild() }
        if !model.state.settings.options.autoScroll { stopAutoScroll() }
        refresh()
    }

    private var animated: Bool { !reduceMotion && model.state.settings.transition != .none }
    private var backgroundColor: UIColor {
        switch model.state.settings.options.background {
        case "white": .white
        case "system": .systemBackground
        case "auto": model.loadedImages[model.state.currentPageIndex].map(ImagePageCanvas.edgeColor) ?? .black
        default: .black
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let viewport = ReaderViewport.measure(view)
        guard viewport != lastViewport, view.bounds.width > 0 else { return }
        lastViewport = viewport
        dismissBoundaryPage()
        humanInteractionInFlight = false
        isUserScrolling = false
        scrollInteractionRevision &+= 1
        programmaticScrollTarget = nil
        let anchor = currentScrollAnchor()
        applyingLayout = true
        defer { applyingLayout = false; refresh() }
        lastSize = view.bounds.size
        frozenBoundaryHeights.removeAll()
        model.updateViewport(viewport)
        pagedItem = activePageItem
        pagerGeneration = UUID(); transitioning = false; interactivePaging = false
        pager?.view.frame = view.bounds
        if let collection, let zoomScroll {
            zoomScroll.setZoomScale(1, animated: false)
            zoomScroll.frame = view.bounds
            collection.frame = view.bounds
            zoomScroll.contentSize = view.bounds.size
            collection.collectionViewLayout.invalidateLayout()
            collection.layoutIfNeeded()
            if let anchor { restoreScroll(anchor) }
        }
        lastRecordedScrollOffset = collection?.contentOffset.y
    }

    private func rebuild() {
        dismissBoundaryPage()
        humanInteractionInFlight = false
        isUserScrolling = false
        scrollInteractionRevision &+= 1
        programmaticScrollTarget = nil
        pagerGeneration = UUID(); transitioning = false; interactivePaging = false
        stopAutoScroll()
        if let pager {
            pager.willMove(toParent: nil); pager.view.removeFromSuperview(); pager.removeFromParent()
        }
        collection?.removeFromSuperview(); zoomScroll?.removeFromSuperview()
        pager = nil; collection = nil; zoomScroll = nil
        activeLayout = model.state.settings.layout
        lastState = nil; revision = nil; lastImages = [:]; pagedItem = nil; previousPagedItems = []; renderedItems = []; renderedMetadata = []; renderedChapterIDs = []; collectionDataSource = nil
        scrollingItemCache.removeAll()
        cachedScrollingChapterIDs.removeAll()
        frozenBoundaryHeights.removeAll()
        if model.state.settings.layout.isPaged {
            let pager = UIPageViewController(transitionStyle: .scroll,
                navigationOrientation: activeLayout == .verticalPaged ? .vertical : .horizontal)
            self.pager = pager
            addChild(pager); view.addSubview(pager.view); pager.view.frame = view.bounds
            pager.didMove(toParent: self); pager.dataSource = self; pager.delegate = self
            for direction: UISwipeGestureRecognizer.Direction in activeLayout == .verticalPaged ? [.up, .down] : [.left, .right] {
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(boundarySwipe(_:)))
                swipe.direction = direction; swipe.delegate = self
                pager.view.addGestureRecognizer(swipe)
            }
            for scroll in pager.view.subviews.compactMap({ $0 as? UIScrollView }) {
                scroll.showsVerticalScrollIndicator = false
                scroll.showsHorizontalScrollIndicator = false
                scroll.panGestureRecognizer.addTarget(self, action: #selector(pagerPanned(_:)))
                #if targetEnvironment(macCatalyst)
                scroll.panGestureRecognizer.allowedScrollTypesMask = []
                scroll.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                #else
                scroll.panGestureRecognizer.allowedScrollTypesMask = .all
                #endif
            }
            #if targetEnvironment(macCatalyst)
            let pointerPan = UIPanGestureRecognizer(target: self, action: #selector(pointerPanned(_:)))
            pointerPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            pointerPan.allowedScrollTypesMask = .all
            pointerPan.delegate = self
            pager.view.addGestureRecognizer(pointerPan)
            #endif
        } else {
            let layout = UICollectionViewFlowLayout()
            layout.minimumLineSpacing = activeLayout == .webtoon ? 0 : 15
            layout.minimumInteritemSpacing = 0
            let collection = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
            collection.register(ImagePageCell.self, forCellWithReuseIdentifier: "page")
            collection.register(ImageChapterBoundaryCell.self, forCellWithReuseIdentifier: "boundary")
            collection.delegate = self
            collectionDataSource = UICollectionViewDiffableDataSource(collectionView: collection) { [weak self] collection, indexPath, item in
                self?.makeCell(collection, at: indexPath, item: item)
            }
            collection.backgroundColor = .clear
            collection.showsVerticalScrollIndicator = false
            collection.showsHorizontalScrollIndicator = false
            collection.alwaysBounceVertical = true
            collection.contentInsetAdjustmentBehavior = .never
            collection.panGestureRecognizer.allowedScrollTypesMask = .all
            let zoom = UIScrollView(frame: view.bounds)
            zoom.showsVerticalScrollIndicator = false
            zoom.showsHorizontalScrollIndicator = false
            zoom.minimumZoomScale = 1; zoom.maximumZoomScale = 6
            zoom.contentInsetAdjustmentBehavior = .never
            zoom.delegate = zoomDelegate
            zoom.isScrollEnabled = false
            zoomDelegate.content = collection
            zoom.addSubview(collection); zoom.contentSize = view.bounds.size
            view.addSubview(zoom)
            self.collection = collection; zoomScroll = zoom
            let single = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            single.delegate = self; single.cancelsTouchesInView = false
            let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
            double.numberOfTapsRequired = 2; double.delegate = self
            single.require(toFail: double)
            collection.addGestureRecognizer(single); collection.addGestureRecognizer(double)
            pendingPosition = model.state.currentLocator
        }
        view.setNeedsLayout()
    }

    private func chapterModel(_ id: InstallmentID) -> (any ImageReaderControlling)? {
        session?.model(for: id) ?? (id == standaloneChapterID ? model : nil)
    }
    private func chapterIDs() -> [InstallmentID] { session?.chapterIDs ?? [standaloneChapterID] }
    private func pageItem(chapter: InstallmentID, page: Int, segment: Int = 0) -> ChapterPresentationItem {
        .init(chapterID: chapter, content: .page(.init(page: page, segment: segment)))
    }
    private var activePageItem: ChapterPresentationItem {
        pageItem(chapter: activeChapterID, page: model.state.displayPosition.page, segment: model.state.displayPosition.segment)
    }

    private func scrollingItems(ids: [InstallmentID], metadata: [[ImagePageDescriptor]]) -> [[ChapterPresentationItem]] {
        if cachedScrollingChapterIDs != ids {
            let retained = Set(ids)
            for id in scrollingItemCache.keys where !retained.contains(id) { scrollingItemCache.removeValue(forKey: id) }
            cachedScrollingChapterIDs = ids
        }
        return zip(ids, metadata).map { id, pages in
            if let cached = scrollingItemCache[id] {
                if cached.pages == pages { return cached.items }
                if cached.pages.elementsEqual(pages, by: { $0.id == $1.id && $0.index == $1.index }) {
                    scrollingItemCache[id] = (pages, cached.items)
                    return cached.items
                }
            }
            let items = ChapterPresentationItem.chapterPages(id: id,
                positions: pages.map { .init(page: $0.index, segment: 0) }, includesBoundaries: session != nil)
            scrollingItemCache[id] = (pages, items)
            return items
        }
    }

    private func pagingItems() -> [ChapterPresentationItem] {
        var items = ChapterPresentationItem.chapterPages(id: activeChapterID, positions: model.state.displayPositions,
            includesBoundaries: session != nil)
        guard let session, !items.isEmpty else { return items }
        // Adjacent images are ordinary pager destinations. Merely displaying a
        // transition or preparing its neighbor does not change the active chapter.
        for direction: ReaderChapterDirection in [.previous, .next] {
            guard let neighbor = session.boundary(from: activeChapterID, direction: direction).neighbor,
                  let neighborModel = session.model(for: neighbor.id),
                  let position = direction == .next ? neighborModel.state.displayPositions.first : neighborModel.state.displayPositions.last else { continue }
            let preview = ChapterPresentationItem(chapterID: neighbor.id, content: .page(position))
            if direction == .next { items.append(preview) } else { items.insert(preview, at: 0) }
        }
        return items
    }

    private func refresh() {
        guard !applyingLayout else { return }
        guard pager == nil || !transitioning else { return }
        if lastActiveChapterID != activeChapterID {
            if humanInteractionInFlight, interactionContinuedChapter, continuationTargetChapterID == nil {
                continuationTargetChapterID = activeChapterID
            }
            dismissBoundaryPage()
            lastActiveChapterID = activeChapterID
        }
        let state = model.state
        defer {
            lastState = state; lastImages = model.loadedImages.mapValues(ObjectIdentifier.init)
            revision = model.scrollRequestRevision; publishPosition(); refreshBoundaryPage()
        }
        if let pager {
            let items = pagingItems()
            if revision != nil, revision != model.scrollRequestRevision { dismissBoundaryPage() }
            if pagedItem == nil || (revision != nil && revision != model.scrollRequestRevision) { pagedItem = activePageItem }
            if let current = pagedItem, !items.contains(current) { pagedItem = activePageItem }
            if let item = pagedItem, !transitioning {
                if let visible = pager.viewControllers?.first, presentationItem(of: visible) == item {
                    configurePage(visible, item: item)
                } else { pager.setViewControllers([makePage(item)], direction: .forward, animated: false) }
            }
            if items != previousPagedItems, !transitioning {
                previousPagedItems = items
                pager.dataSource = nil; pager.dataSource = self
            }
            scheduleNeighborPreparation()
        }
        if let collection, let source = collectionDataSource {
            let ids = chapterIDs()
            let metadata = ids.map { chapterModel($0)?.state.pages ?? [] }
            let items = scrollingItems(ids: ids, metadata: metadata)
            let boundaryStates = session?.observedBoundaries ?? []
            let explicitNavigation = revision != nil && revision != model.scrollRequestRevision
            let settingsChanged = lastState?.settings != state.settings
            if explicitNavigation || settingsChanged {
                dismissBoundaryPage()
                isUserScrolling = false
                scrollInteractionRevision &+= 1
            }
            // First dimensions must replace placeholder geometry immediately.
            // Defer subsequent crop changes until the drag and coast have ended.
            if !explicitNavigation, !settingsChanged,
               isUserScrolling || collection.isDragging || collection.isDecelerating {
                if let first = renderedChapterIDs.first, let start = ids.firstIndex(of: first),
                   start + renderedChapterIDs.count <= ids.count,
                   ids[start..<start + renderedChapterIDs.count].elementsEqual(renderedChapterIDs),
                   items[start..<start + renderedChapterIDs.count].elementsEqual(renderedItems) {
                    var dimensionsArrived = false
                    var updated = renderedMetadata
                    for section in updated.indices where updated[section] != metadata[start + section] {
                        for index in metadata[start + section].indices where updated[section].indices.contains(index) {
                            let page = metadata[start + section][index]
                            if updated[section][index].aspectRatio == nil, page.aspectRatio != nil {
                                updated[section][index] = page
                                dimensionsArrived = true
                            }
                        }
                    }
                    if dimensionsArrived {
                        let anchor = currentScrollAnchor()
                        applyingLayout = true
                        freezeBoundaryGeometry()
                        updateScrollGeometry(preserving: anchor) { renderedMetadata = updated }
                        applyingLayout = false
                    }
                    // Appending below the viewport does not move existing pages.
                    // Publish ready chapters during the gesture, even if a prepend
                    // is also pending. Keep existing geometry and the scroll offset.
                    let end = start + renderedChapterIDs.count
                    if continuousChapters, end < ids.count {
                        applyingLayout = true
                        // Loading labels can disappear as a neighbor becomes ready.
                        // A diff also asks for existing sizes; freeze divider heights
                        // as well as image geometry until the gesture has settled.
                        freezeBoundaryGeometry()
                        var snapshot = source.snapshot()
                        for section in end..<ids.count {
                            snapshot.appendSections([ids[section]])
                            snapshot.appendItems(items[section], toSection: ids[section])
                            renderedChapterIDs.append(ids[section])
                            renderedItems.append(items[section])
                            renderedMetadata.append(metadata[section])
                        }
                        source.apply(snapshot, animatingDifferences: false) { [weak self] in
                            guard let self, self.collection === collection else { return }
                            applyingLayout = false
                            configureVisibleCells(); updateVisibleChapterLoads()
                            refresh(); recordScrollPosition(); scheduleNeighborPreparation()
                        }
                        return
                    }
                }
                configureVisibleCells(); updateVisibleChapterLoads(); scheduleNeighborPreparation()
                return
            }
            let anchor = explicitNavigation ? nil : currentScrollAnchor()
            let thawBoundaryGeometry = !frozenBoundaryHeights.isEmpty
            if items != renderedItems {
                frozenBoundaryHeights.removeAll()
                applyingLayout = true
                renderedItems = items; renderedMetadata = metadata; renderedChapterIDs = ids; renderedBoundaryStates = boundaryStates
                let interactionRevision = scrollInteractionRevision
                let navigationRevision = model.scrollRequestRevision
                let chapterID = activeChapterID
                var snapshot = NSDiffableDataSourceSnapshot<InstallmentID, ChapterPresentationItem>()
                for (section, id) in ids.enumerated() {
                    snapshot.appendSections([id]); snapshot.appendItems(items[section], toSection: id)
                }
                source.apply(snapshot, animatingDifferences: false) { [weak self] in
                    guard let self, self.collection === collection else { return }
                    if !isUserScrolling, !collection.isDragging, !collection.isDecelerating,
                       interactionRevision == scrollInteractionRevision,
                       navigationRevision == model.scrollRequestRevision, chapterID == activeChapterID {
                        collection.collectionViewLayout.invalidateLayout(); collection.layoutIfNeeded()
                        if let anchor, !explicitNavigation { restoreScroll(anchor) }
                        else if explicitNavigation || pendingPosition != nil { restoreActivePosition() }
                    }
                    applyingLayout = false
                    configureVisibleCells(); updateVisibleChapterLoads()
                    refresh(); recordScrollPosition(); scheduleNeighborPreparation()
                    resumeAutoScrollIfNeeded(); resumeWaitingAutoScroll()
                }
            } else {
                if metadata != renderedMetadata || settingsChanged || boundaryStates != renderedBoundaryStates || thawBoundaryGeometry {
                    applyingLayout = true
                    updateScrollGeometry(preserving: anchor) {
                        frozenBoundaryHeights.removeAll()
                        renderedMetadata = metadata; renderedBoundaryStates = boundaryStates
                    }
                    applyingLayout = false
                }
                configureVisibleCells()
                if explicitNavigation { pendingPosition = state.currentLocator; restoreActivePosition() }
                if pendingPosition != nil, model.loadedImages[state.currentPageIndex] != nil {
                    restoreActivePosition(); pendingPosition = nil
                }
                updateVisibleChapterLoads(); scheduleNeighborPreparation(); resumeWaitingAutoScroll()
            }
        }
    }

    private func maximumScrollOffset(_ scroll: UIScrollView) -> CGFloat {
        max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
    }

    private func publishPosition() {
        let page = model.state.currentPageIndex, count = model.state.pages.count
        var atBeginning = model.state.isAtBeginning
        var atEnd = model.state.isAtEnd
        if let collection {
            atBeginning = collection.contentOffset.y <= 0.5
            atEnd = collection.contentOffset.y >= maximumScrollOffset(collection) - 0.5
            if let session, let first = renderedChapterIDs.first, let last = renderedChapterIDs.last {
                if session.boundary(from: first, direction: .previous).neighbor != nil { atBeginning = false }
                if session.boundary(from: last, direction: .next).neighbor != nil { atEnd = false }
            }
        } else if let session {
            // Even a terminal transition page is reachable from the first/last image.
            atBeginning = pagedItem?.content == .boundary(.previous)
                && session.boundary(from: activeChapterID, direction: .previous) == .absent
            atEnd = pagedItem?.content == .boundary(.next)
                && session.boundary(from: activeChapterID, direction: .next) == .absent
        }
        let beginning = atBeginning, end = atEnd, running = wantsAutoScroll
        Task { @MainActor [weak navigation] in
            navigation?.update(page: page, count: count, atBeginning: beginning, atEnd: end, autoScrolling: running)
        }
    }

    private func presentationItem(of controller: UIViewController) -> ChapterPresentationItem? {
        if let page = controller as? ImagePageCanvas {
            return .init(chapterID: page.chapterID ?? standaloneChapterID, content: .page(page.position))
        }
        if let boundary = controller as? ImageChapterBoundaryController { return boundary.item }
        return nil
    }
    private func makePage(_ item: ChapterPresentationItem) -> UIViewController {
        switch item.content {
        case let .page(position):
            if item.chapterID != activeChapterID, let entry = session?.entry(item.chapterID) {
                entry.resume()
                if entry.model.state.displayPosition != position {
                    // A cached chapter may have been left in its middle. Warm
                    // the preview's edge without publishing reading progress.
                    entry.model.navigate(to: .image(page: position.page, total: entry.model.state.pages.count,
                        offset: Double(position.segment) / 2))
                }
            }
            let page = ImagePageCanvas(position: position, chapterID: item.chapterID)
            configurePage(page, item: item)
            page.onTap = { [weak self] point, size in self?.performTap(point, size: size) }
            page.onQuickAction = { [weak self] index, image, source in
                self?.quickActions(index: index, image: image, source: source, pageModel: self?.chapterModel(item.chapterID)) ?? UIMenu()
            }
            return page
        case .boundary:
            let boundary = ImageChapterBoundaryController(item: item)
            boundary.loadViewIfNeeded()
            configureBoundary(boundary.page, item: item)
            boundary.onTap = { [weak self] point, size in self?.performTap(point, size: size) }
            return boundary
        }
    }
    private func configurePage(_ controller: UIViewController, item: ChapterPresentationItem) {
        if case let .page(position) = item.content, let page = controller as? ImagePageCanvas,
           let chapterModel = chapterModel(item.chapterID) {
            let preview = chapterModel.state.preview(at: position)
            page.configure(state: preview, images: chapterModel.loadedImages,
                liveText: liveText && chapterModel.previewPageIndices.isDisjoint(with: preview.visiblePageIndices()),
                loadingStates: chapterModel.pageLoadingStates, previewIndices: chapterModel.previewPageIndices)
        }
        if let boundary = controller as? ImageChapterBoundaryController {
            configureBoundary(boundary.page, item: item)
        }
        controller.view.backgroundColor = backgroundColor
    }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        adjacent(to: viewController, screenForward: false)
    }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        adjacent(to: viewController, screenForward: true)
    }
    private func adjacent(to controller: UIViewController, screenForward: Bool) -> UIViewController? {
        if let canvas = controller as? ImagePageCanvas, canvas.scroll.zoomScale > 1.01 { return nil }
        let items = previousPagedItems
        guard let item = presentationItem(of: controller), let index = items.firstIndex(of: item) else { return nil }
        let rtl = activeLayout == .paged && model.state.settings.direction == .rightToLeft
        let next = index + (screenForward != rtl ? 1 : -1)
        guard items.indices.contains(next) else { return nil }
        return makePage(items[next])
    }
    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        pagerGeneration = UUID(); transitionStartRevision = model.scrollRequestRevision
        transitioning = true; interactivePaging = true; interactivePagingReleased = false; hasInteracted = true
    }
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard pageViewController === pager else { return }
        finishPageTransition(completed: completed,
            target: completed ? pageViewController.viewControllers?.first : previousViewControllers.first,
            generation: pagerGeneration)
    }

    private func finishPageTransition(completed: Bool, target: UIViewController?, generation: UUID) {
        guard generation == pagerGeneration, let target else { return }
        transitioning = true; interactivePaging = false
        let startRevision = transitionStartRevision
        if completed, model.scrollRequestRevision == startRevision, let item = presentationItem(of: target) {
            commit(item); hideBarsAfterMovement()
        }
        // UIKit must finish its own completion callback before its neighbors
        // are changed. Retain the actual destination, including across chapters.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, generation == pagerGeneration, let pager else { return }
            guard model.scrollRequestRevision == startRevision else {
                pagedItem = activePageItem; transitioning = false; refresh(); return
            }
            let items = pagingItems()
            if items != previousPagedItems {
                previousPagedItems = items
                pager.dataSource = nil
                pager.setViewControllers([target], direction: .forward, animated: false)
                pager.dataSource = self
            }
            transitioning = false
            refresh()
        }
    }
    private func commit(_ item: ChapterPresentationItem) {
        pagedItem = item
        switch item.content {
        case let .page(position):
            dismissBoundaryPage()
            if let session { session.recordPage(chapter: item.chapterID, position: position) }
            else { model.navigate(to: .image(page: position.page, total: model.state.pages.count, offset: Double(position.segment) / 2)) }
        case let .boundary(direction):
            showBoundaryPage(direction)
            if direction == .next { session?.completeChapter(activeChapterID) }
            session?.prepareNeighbor(from: activeChapterID, direction: direction)
        }
        revision = model.scrollRequestRevision
    }

    private func move(forward: Bool) {
#if DEBUG
        if ProcessInfo.processInfo.environment["MANGOREADER_PERFORMANCE_RUN"] != nil {
            NotificationCenter.default.post(name: Notification.Name("MangoReaderPerformance"), object: nil,
                userInfo: ["nextPage": model.state.currentPageIndex + (forward ? 1 : -1)])
        }
#endif
        settleInterruptedPaging()
        hasInteracted = true
        if let collection {
            isUserScrolling = false
            scrollInteractionRevision &+= 1
            pendingPosition = nil
            let maximum = maximumScrollOffset(collection)
            let range = continuousChapters ? 0...maximum : (activeChapterScrollRange() ?? 0...maximum)
            let offset = collection.contentOffset.y
            let step = ImageReaderSizing.scrollStep(viewportHeight: collection.bounds.height, forward: forward)
            let target: CGFloat
            if !continuousChapters, let images = activeImageScrollRange() {
                if forward {
                    target = offset >= images.upperBound - 0.5 ? range.upperBound : min(images.upperBound, offset + step)
                } else {
                    target = offset <= images.lowerBound + 0.5 ? range.lowerBound : max(images.lowerBound, offset + step)
                }
            } else {
                target = min(range.upperBound, max(range.lowerBound, offset + step))
            }
            guard abs(target - collection.contentOffset.y) > 0.5 else { requestDiscreteBoundary(forward); return }
            dismissBoundaryPage()
            pendingPosition = nil; model.beginViewportInteraction()
            programmaticScrollTarget = animated ? target : nil
            collection.setContentOffset(CGPoint(x: 0, y: target), animated: animated)
            if !animated { recordScrollPosition() }
        } else if let pager, !transitioning {
            let items = pagingItems()
            guard let current = items.firstIndex(of: pagedItem ?? activePageItem) else { return }
            let next = current + (forward ? 1 : -1)
            guard items.indices.contains(next) else { requestDiscreteBoundary(forward); return }
            dismissBoundaryPage()
            let rtl = activeLayout == .paged && model.state.settings.direction == .rightToLeft
            transitioning = true; interactivePaging = false
            pagerGeneration = UUID(); transitionStartRevision = model.scrollRequestRevision
            let generation = pagerGeneration
            let origin = pager.viewControllers?.first
            let target = makePage(items[next])
            let complete: (Bool) -> Void = { [weak self] completed in
                guard let self else { return }
                finishPageTransition(completed: completed, target: completed ? target : origin,
                    generation: generation)
            }
            let direction: UIPageViewController.NavigationDirection = forward != rtl ? .forward : .reverse
            if animated, model.state.settings.transition == .fade {
                UIView.transition(with: pager.view, duration: 0.14, options: .transitionCrossDissolve) {
                    pager.setViewControllers([target], direction: direction, animated: false)
                } completion: { complete($0) }
            } else { pager.setViewControllers([target], direction: direction, animated: animated, completion: complete) }
        }
    }
    private func requestDiscreteBoundary(_ forward: Bool) {
        if pager != nil {
            guard let session else { navigation?.onBoundary?(forward); return }
            let direction: ReaderChapterDirection = forward ? .next : .previous
            // Image chapters enter through their preview after a completed page
            // turn. Loading/retry never queues a jump. Other formats keep their
            // explicit handoff to the corresponding reader.
            let external = session.boundary(from: activeChapterID, direction: direction).neighbor?.format.isTextPublication == true
            session.prepareNeighbor(from: activeChapterID, direction: direction, activate: external, retry: true)
            refresh()
            return
        }
        chapterGate.beginInteraction(chapterID: activeChapterID)
        attemptBoundary(forward)
        chapterGate.endInteraction()
        // Cached chapter activation is synchronous. Show its canvas now,
        // before a later SwiftUI reconfiguration publishes the same state.
        refresh()
    }

    private func attemptBoundary(_ forward: Bool) {
        let direction: ReaderChapterDirection = forward ? .next : .previous
        switch chapterGate.attempt(direction, chapterID: activeChapterID) {
        case .stop:
            showBoundaryPage(direction)
            if forward { session?.completeChapter(activeChapterID) }
            if model.state.settings.options.infiniteScroll {
                session?.prepareNeighbor(from: activeChapterID, direction: direction)
            }
        case .continueChapter:
            interactionContinuedChapter = true
            continuationDirection = direction
            continuationTargetChapterID = session?.boundary(from: activeChapterID, direction: direction).neighbor?.id
            if let session { session.continuePastBoundary(from: activeChapterID, direction: direction) }
            else { navigation?.onBoundary?(forward) }
        case .ignored: break
        }
    }

    private func dismissBoundaryPage(cancelInteraction: Bool = true) {
        if cancelInteraction { chapterGate.reset() } else { chapterGate.clearArm() }
        if let direction = boundaryPageDirection, let id = boundaryPageChapterID {
            session?.cancelBoundaryContinuation(from: id, direction: direction)
        }
        hideBoundaryPage()
    }

    private func hideBoundaryPage() {
        boundaryPageDirection = nil; boundaryPageChapterID = nil
    }

    private func showBoundaryPage(_ direction: ReaderChapterDirection) {
        guard session != nil else { return }
        boundaryPageDirection = direction
        boundaryPageChapterID = activeChapterID
        refreshBoundaryPage()
    }

    private func configureBoundary(_ page: ImageChapterBoundaryPage, item: ChapterPresentationItem) {
        guard case let .boundary(direction) = item.content, let session,
              let chapter = session.chapter(item.chapterID) else { return }
        page.configure(current: chapter, direction: direction,
            state: session.boundary(from: item.chapterID, direction: direction), background: backgroundColor,
            retry: { [weak session] in session?.retryBoundary(from: item.chapterID, direction: direction) },
            continueChapter: { [weak self] in
                guard let self, item.chapterID == activeChapterID else { return }
                if pager != nil { move(forward: direction.isForward) }
                else { requestDiscreteBoundary(direction.isForward) }
            })
    }

    private func refreshBoundaryPage() {
        if let controller = pager?.viewControllers?.first as? ImageChapterBoundaryController {
            configureBoundary(controller.page, item: controller.item)
        }
        configureVisibleCells()
    }

    private func activeChapterScrollRange(for chapterID: InstallmentID? = nil) -> ClosedRange<CGFloat>? {
        guard let collection, let section = renderedChapterIDs.firstIndex(of: chapterID ?? activeChapterID),
              renderedItems.indices.contains(section), !renderedItems[section].isEmpty,
              let first = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: section)),
              let last = collection.layoutAttributesForItem(at: IndexPath(item: renderedItems[section].count - 1, section: section)) else { return nil }
        let minimum = max(0, first.frame.minY)
        return minimum...max(minimum, last.frame.maxY - collection.bounds.height)
    }

    private func activeImageScrollRange(for chapterID: InstallmentID? = nil) -> ClosedRange<CGFloat>? {
        guard let collection, let section = renderedChapterIDs.firstIndex(of: chapterID ?? activeChapterID),
              renderedItems.indices.contains(section) else { return nil }
        let indices = renderedItems[section].indices.filter { renderedItems[section][$0].imagePosition != nil }
        guard let firstIndex = indices.first, let lastIndex = indices.last,
              let first = collection.layoutAttributesForItem(at: IndexPath(item: firstIndex, section: section)),
              let last = collection.layoutAttributesForItem(at: IndexPath(item: lastIndex, section: section)) else { return nil }
        return first.frame.minY...max(first.frame.minY, last.frame.maxY - collection.bounds.height)
    }

    private func continuationScrollAnchor() -> CGFloat? {
        guard let direction = continuationDirection else { return nil }
        if let target = continuationTargetChapterID, activeChapterID == target,
           let range = activeImageScrollRange(for: target) {
            return direction == .next ? range.lowerBound : range.upperBound
        }
        guard let range = activeChapterScrollRange() else { return nil }
        // Until the neighbor finishes loading, keep the original edge visible.
        return direction == .next ? range.upperBound : range.lowerBound
    }

    private func clampHumanScroll(_ scroll: UIScrollView, proposedOffset: CGFloat? = nil) -> CGFloat {
        guard !continuousChapters, session != nil, !wantsAutoScroll,
              let range = activeChapterScrollRange() else { return proposedOffset ?? scroll.contentOffset.y }
        let offset = proposedOffset ?? scroll.contentOffset.y
        let velocity = scroll.panGestureRecognizer.velocity(in: scroll).y
        let delta = offset - (lastRecordedScrollOffset ?? offset)
        if gestureIsCoasting, !interactionContinuedChapter, let direction = boundaryPageDirection {
            // UIKit can settle a few points back toward the images after clamping.
            // That movement belongs to the first swipe, not a deliberate reversal.
            return direction == .next ? range.upperBound : range.lowerBound
        }
        if interactionContinuedChapter {
            let hasMotion = abs(velocity) > 1 || abs(delta) > 0.5
            let forward = abs(velocity) > 1 ? velocity < 0 : delta > 0
            if hasMotion, boundaryPageChapterID == activeChapterID,
               continuationDirection?.isForward != forward {
                // Reversing before the neighbor arrives withdraws activation.
                dismissBoundaryPage(cancelInteraction: false)
                interactionContinuedChapter = false
                continuationDirection = nil; continuationTargetChapterID = nil
            } else {
                // One accepted gesture reveals one neighbor. Its remaining
                // drag and coast stay at that chapter's entry position.
                return continuationScrollAnchor() ?? min(range.upperBound, max(range.lowerBound, scroll.contentOffset.y))
            }
        }
        guard abs(velocity) > 1 || abs(delta) > 0.5 else { return min(range.upperBound, max(range.lowerBound, offset)) }
        let forward = abs(velocity) > 1 ? velocity < 0 : delta > 0
        if let direction = boundaryPageDirection, direction.isForward != forward {
            dismissBoundaryPage(cancelInteraction: false)
        }
        chapterGate.noteMovement(forward ? .next : .previous)
        // Once the transition occupies most of the viewport, finish landing on
        // its page. A nearly-complete swipe must not require an extra gesture
        // merely to scroll the last few points before the continuation can arm.
        if offset >= range.upperBound - scroll.bounds.height / 2, forward {
            attemptBoundary(true)
            if !interactionContinuedChapter { return range.upperBound }
        } else if offset <= range.lowerBound + scroll.bounds.height / 2, !forward {
            attemptBoundary(false)
            if !interactionContinuedChapter { return range.lowerBound }
        }
        if interactionContinuedChapter { return continuationScrollAnchor() ?? offset }
        return min(range.upperBound, max(range.lowerBound, offset))
    }

    private func hideBarsAfterMovement() {
        if model.state.settings.options.hideBarsOnSwipe { controls?.wrappedValue = false }
    }

    @objc private func pointerPanned(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .ended,
              (pager?.viewControllers?.first as? ImagePageCanvas)?.scroll.zoomScale ?? 1 <= 1.01,
              let forward = ImageReaderGesturePolicy.pageTurn(translation: pan.translation(in: view),
                layout: model.state.settings.layout, direction: model.state.settings.direction) else { return }
        move(forward: forward)
    }

    private func isForwardSwipe(_ direction: UISwipeGestureRecognizer.Direction) -> Bool {
        if activeLayout == .verticalPaged { return direction == .up }
        return (direction == .left) != (model.state.settings.direction == .rightToLeft)
    }
    @objc private func pagerPanned(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            if interactivePagingReleased { settleInterruptedPaging(freshDrag: true) }
            interactivePagingReleased = false
        case .ended, .cancelled, .failed: interactivePagingReleased = true
        default: break
        }
    }
    private func settleInterruptedPaging(freshDrag: Bool = false) {
        // UIKit can settle a cancelled drag without delivering its completion.
        // A new input may recover that settled page, never an animation or coast.
        guard transitioning, interactivePaging, let pager,
              let scroll = pager.view.subviews.compactMap({ $0 as? UIScrollView }).first,
              !scroll.isDecelerating, freshDrag || (!scroll.isDragging && !scroll.isTracking),
              let visible = pager.viewControllers?.first, let item = presentationItem(of: visible) else { return }
        let offset = activeLayout == .verticalPaged ? scroll.contentOffset.y : scroll.contentOffset.x
        let extent = activeLayout == .verticalPaged ? scroll.bounds.height : scroll.bounds.width
        guard extent > 0, abs(offset - extent) < 2 else { return }
        pagerGeneration = UUID(); transitioning = false; interactivePaging = false
        if pagedItem != item { commit(item) }
        refresh()
    }
    @objc private func boundarySwipe(_ swipe: UISwipeGestureRecognizer) {
        guard !transitioning else { return }
        requestDiscreteBoundary(isForwardSwipe(swipe.direction))
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let swipe = gestureRecognizer as? UISwipeGestureRecognizer else { return true }
        guard !transitioning, (pager?.viewControllers?.first as? ImagePageCanvas)?.scroll.zoomScale ?? 1 <= 1.01,
              let current = pagingItems().firstIndex(of: pagedItem ?? activePageItem) else { return false }
        return isForwardSwipe(swipe.direction) ? current == pagingItems().count - 1 : current == 0
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UISwipeGestureRecognizer || otherGestureRecognizer is UISwipeGestureRecognizer
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) { performTap(tap.location(in: view), size: view.bounds.size) }
    private func performTap(_ point: CGPoint, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let region = TapZoneRegion.region(normalizedX: point.x / size.width, normalizedY: point.y / size.height)
        switch model.state.settings.tapZones.action(for: region) {
        case .nextPage, .scrollForward: move(forward: true)
        case .previousPage, .scrollBackward: move(forward: false)
        case .toggleControls:
            model.performTap(in: region)
            controls?.wrappedValue.toggle()
        case .none: break
        }
    }
    @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
        guard !model.state.settings.options.disableDoubleTap, let zoomScroll else { return }
        if zoomScroll.zoomScale > 1 { zoomScroll.setZoomScale(1, animated: animated) }
        else {
            let point = tap.location(in: collection)
            let size = CGSize(width: zoomScroll.bounds.width / 2.5, height: zoomScroll.bounds.height / 2.5)
            zoomScroll.zoom(to: CGRect(x: point.x - size.width/2, y: point.y - size.height/2, width: size.width, height: size.height), animated: animated)
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer is UITapGestureRecognizer, (gestureRecognizer as? UITapGestureRecognizer)?.numberOfTapsRequired == 2,
           model.state.settings.options.disableDoubleTap { return false }
        var target = touch.view
        while let view = target {
            if view is UIControl { return false }
            target = view.superview
        }
        return !(collection?.visibleCells.compactMap { ($0 as? ImagePageCell)?.renderer.interaction }.contains { $0.selectableItemsHighlighted } ?? false)
    }

    private func makeCell(_ collection: UICollectionView, at indexPath: IndexPath, item: ChapterPresentationItem) -> UICollectionViewCell {
        switch item.content {
        case .page:
            let cell = collection.dequeueReusableCell(withReuseIdentifier: "page", for: indexPath) as! ImagePageCell
            configure(cell, item: item)
            return cell
        case .boundary:
            let cell = collection.dequeueReusableCell(withReuseIdentifier: "boundary", for: indexPath) as! ImageChapterBoundaryCell
            configureBoundary(cell.page, item: item)
            cell.contentView.isHidden = (continuousChapters && item.content == .boundary(.previous) && indexPath.section > 0)
                || (!continuousChapters && item.chapterID != activeChapterID && !wantsAutoScroll)
            return cell
        }
    }
    private func configureVisibleCells() {
        guard let collection else { return }
        for index in collection.indexPathsForVisibleItems {
            guard let item = collectionDataSource?.itemIdentifier(for: index) else { continue }
            if let cell = collection.cellForItem(at: index) as? ImagePageCell { configure(cell, item: item) }
            if let cell = collection.cellForItem(at: index) as? ImageChapterBoundaryCell {
                configureBoundary(cell.page, item: item)
                cell.contentView.isHidden = (continuousChapters && item.content == .boundary(.previous) && index.section > 0)
                    || (!continuousChapters && item.chapterID != activeChapterID && !wantsAutoScroll)
            }
        }
    }
    private func configure(_ cell: ImagePageCell, item: ChapterPresentationItem) {
        guard case let .page(position) = item.content, let pageModel = chapterModel(item.chapterID),
              pageModel.state.pages.indices.contains(position.page) else { return }
        let index = position.page
        cell.pageIndex = index
        cell.quickActions = { [weak self] image, source in self?.quickActions(index: index, image: image, source: source, pageModel: pageModel) ?? UIMenu() }
        if let image = pageModel.loadedImages[index] {
            cell.renderer.render(image, cropInsets: pageModel.state.pages[index].cropInsets(for: pageModel.state.settings.cropMode),
                liveTextEnabled: liveText && !pageModel.previewPageIndices.contains(index),
                layoutAspectRatio: pageModel.state.pages[index].croppedAspectRatio(for: pageModel.state.settings.cropMode),
                in: cell.surface)
        } else { cell.renderer.stop(); cell.surface.imageView.image = nil }
        if pageModel.loadedImages[index] == nil || pageModel.previewPageIndices.contains(index) {
            cell.spinner.configure(state: pageModel.pageLoadingStates[index] ?? .waiting,
                pageIndex: index, pageCount: pageModel.state.pages.count)
        } else { cell.spinner.stopAnimating() }
        cell.surface.isAccessibilityElement = true
        cell.surface.accessibilityLabel = "Page \(index + 1) of \(pageModel.state.pages.count)"
        cell.accessibilityElements = cell.spinner.isHidden ? [cell.surface] : [cell.spinner]
        cell.contentView.isHidden = session != nil && !continuousChapters && !wantsAutoScroll && item.chapterID != activeChapterID
        cell.accessibilityLabel = "Page \(index + 1) of \(pageModel.state.pages.count)"
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        guard renderedItems.indices.contains(indexPath.section), renderedItems[indexPath.section].indices.contains(indexPath.item) else { return .init(width: max(1, view.bounds.width), height: 1) }
        let item = renderedItems[indexPath.section][indexPath.item]
        let width = ImageReaderSizing.contentWidth(viewport: view.bounds.size, options: model.state.settings.options)
        if case let .page(position) = item.content, renderedMetadata.indices.contains(indexPath.section),
           renderedMetadata[indexPath.section].indices.contains(position.page) {
            let ratio = renderedMetadata[indexPath.section][position.page].croppedAspectRatio(for: model.state.settings.cropMode) ?? 0.7
            return CGSize(width: width, height: width / max(0.001, ratio))
        }
        if case let .boundary(direction) = item.content {
            if let height = frozenBoundaryHeights[item] { return CGSize(width: width, height: height) }
            if !continuousChapters { return CGSize(width: width, height: collectionView.bounds.height) }
            // The preceding chapter's ending already separates these chapters.
            if continuousChapters, direction == .previous, indexPath.section > 0 {
                return CGSize(width: width, height: 1)
            }
            configureBoundary(boundarySizingPage, item: item)
            return CGSize(width: width, height: boundarySizingPage.compactHeight(for: width))
        }
        return CGSize(width: width, height: 1)
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
        let width = ImageReaderSizing.contentWidth(viewport: view.bounds.size, options: model.state.settings.options)
        let margin = max(0, (view.bounds.width - width) / 2)
        return UIEdgeInsets(top: 0, left: margin, bottom: 0, right: margin)
    }
    private struct ScrollAnchor {
        let item: ChapterPresentationItem
        let fraction: CGFloat
    }
    private func freezeBoundaryGeometry() {
        guard let collection else { return }
        for (section, items) in renderedItems.enumerated() {
            for (index, item) in items.enumerated() {
                if case .boundary = item.content, frozenBoundaryHeights[item] == nil,
                   let attributes = collection.layoutAttributesForItem(at: IndexPath(item: index, section: section)) {
                    frozenBoundaryHeights[item] = attributes.frame.height
                }
            }
        }
    }

    /// Correct geometry inside the layout transaction. Issuing a new scroll
    /// command here interrupts UIKit's drag/deceleration at a chapter handoff.
    private func updateScrollGeometry(preserving anchor: ScrollAnchor?, update: () -> Void) {
        guard let collection, let layout = collection.collectionViewLayout as? UICollectionViewFlowLayout else {
            update(); return
        }
        let anchorIndex = anchor.flatMap { collectionDataSource?.indexPath(for: $0.item) }
        var precedingHeights: [(IndexPath, CGFloat)] = []
        if let anchorIndex {
            for section in renderedItems.indices where section <= anchorIndex.section {
                for item in renderedItems[section].indices {
                    let index = IndexPath(item: item, section: section)
                    guard index <= anchorIndex else { break }
                    if let attributes = layout.layoutAttributesForItem(at: index) {
                        precedingHeights.append((index, attributes.frame.height))
                    }
                }
            }
        }
        update()
        let context = UICollectionViewFlowLayoutInvalidationContext()
        context.invalidateFlowLayoutDelegateMetrics = true
        context.invalidateFlowLayoutAttributes = true
        if let anchor, let anchorIndex {
            context.contentOffsetAdjustment.y = precedingHeights.reduce(0) { adjustment, previous in
                let height = collectionView(collection, layout: layout, sizeForItemAt: previous.0).height
                return adjustment + (height - previous.1) * (previous.0 == anchorIndex ? anchor.fraction : 1)
            }
        }
        layout.invalidateLayout(with: context)
        collection.layoutIfNeeded()
        lastRecordedScrollOffset = collection.contentOffset.y
    }

    private func currentScrollAnchor() -> ScrollAnchor? {
        guard let collection else { return nil }
        let y = max(0, collection.contentOffset.y)
        let attributes = collection.collectionViewLayout.layoutAttributesForElements(in: collection.bounds)?.sorted { $0.frame.minY < $1.frame.minY }
        guard let first = attributes?.first(where: { $0.frame.maxY > y }),
              let item = collectionDataSource?.itemIdentifier(for: first.indexPath) else { return nil }
        return ScrollAnchor(item: item, fraction: (y - first.frame.minY) / max(1, first.frame.height))
    }
    private func restoreScroll(_ anchor: ScrollAnchor, clampToImages: Bool = false) {
        guard let collection, let index = collectionDataSource?.indexPath(for: anchor.item),
              let item = collection.layoutAttributesForItem(at: index) else { return }
        let maximum = maximumScrollOffset(collection)
        var offset = min(maximum, max(0, item.frame.minY + item.frame.height * anchor.fraction))
        if clampToImages, let images = activeImageScrollRange() {
            offset = min(images.upperBound, max(images.lowerBound, offset))
        }
        offset = min(maximum, max(0, offset))
        let target = CGPoint(x: 0, y: offset)
        if abs(target.y - collection.contentOffset.y) > 0.5 || target.x != collection.contentOffset.x {
            collection.setContentOffset(target, animated: false)
        }
        lastRecordedScrollOffset = collection.contentOffset.y
    }
    private func restoreActivePosition() {
        let locator = pendingPosition ?? model.state.currentLocator
        guard case let .image(page, _, offset) = locator else { return }
        restoreScroll(.init(item: pageItem(chapter: activeChapterID, page: page), fraction: offset), clampToImages: true)
    }
    private func updateVisibleChapterLoads() {
        guard let session, let collection, !applyingLayout else { return }
        var visible: [InstallmentID: [Int]] = [:]
        for index in collection.indexPathsForVisibleItems {
            guard let item = collectionDataSource?.itemIdentifier(for: index), case let .page(position) = item.content else { continue }
            visible[item.chapterID, default: []].append(position.page)
        }
        session.updateVisibleChapters(visible)
    }
    private func recordScrollPosition() {
        guard !applyingLayout, pendingPosition == nil, let collection else { return }
        let movingForward = lastRecordedScrollOffset.map { collection.contentOffset.y > $0 + 0.5 } ?? false
        lastRecordedScrollOffset = collection.contentOffset.y
        let attributes = (collection.collectionViewLayout.layoutAttributesForElements(in: collection.bounds) ?? []).sorted { $0.frame.minY < $1.frame.minY }
        var visible: [InstallmentID: [Int]] = [:]
        for attribute in attributes {
            guard let item = collectionDataSource?.itemIdentifier(for: attribute.indexPath), case let .page(position) = item.content else { continue }
            visible[item.chapterID, default: []].append(position.page)
        }
        let centerY = collection.contentOffset.y + collection.bounds.height / 2
        let center = attributes.first { $0.frame.minY <= centerY && $0.frame.maxY > centerY }
        if let center, let item = collectionDataSource?.itemIdentifier(for: center.indexPath),
           case let .boundary(direction) = item.content, item.chapterID == activeChapterID,
           !continuousChapters, abs(collection.contentOffset.y - center.frame.minY) <= 0.5 {
            // A transition has no locator of its own. Keep the adjacent real image's locator.
            let page = direction == .next ? max(0, model.state.pages.count - 1) : 0
            model.markPosition(page: page, offset: direction == .next ? 0.999_999 : 0)
            if !wantsAutoScroll, boundaryPageDirection != direction {
                if !humanInteractionInFlight { chapterGate.beginInteraction(chapterID: activeChapterID) }
                attemptBoundary(direction.isForward)
                if !humanInteractionInFlight { chapterGate.endInteraction() }
            }
        }
        let imageAttributes = attributes.filter {
            collectionDataSource?.itemIdentifier(for: $0.indexPath)?.imagePosition != nil
        }
        var positionAttribute = center
        if continuousChapters, hasInteracted {
            if movingForward, collection.contentOffset.y >= maximumScrollOffset(collection) - 0.5 {
                // A short terminal chapter may never reach the viewport center.
                positionAttribute = imageAttributes.last ?? center
            } else if center.flatMap({ collectionDataSource?.itemIdentifier(for: $0.indexPath)?.imagePosition }) == nil {
                positionAttribute = movingForward
                    ? imageAttributes.first(where: { $0.frame.minY >= centerY })
                    : imageAttributes.last(where: { $0.frame.maxY <= centerY })
            }
        }
        if let positionAttribute, let item = collectionDataSource?.itemIdentifier(for: positionAttribute.indexPath),
           case let .page(position) = item.content,
           ((continuousChapters && hasInteracted) || wantsAutoScroll || item.chapterID == activeChapterID), let pageModel = chapterModel(item.chapterID) {
            let offset = max(0, (collection.contentOffset.y - positionAttribute.frame.minY) / max(1, positionAttribute.frame.height))
            let locator: ReadingLocator = .image(page: position.page, total: pageModel.state.pages.count, offset: offset)
            session?.activate(item.chapterID, locator: locator, completingPrevious: hasInteracted && movingForward)
        }
        if let session { session.updateVisibleChapters(visible) }
        else { model.updateVisiblePageIndices(visible[standaloneChapterID] ?? [], scrollRequestRevision: model.scrollRequestRevision) }
        if let first = attributes.first(where: {
            guard let item = collectionDataSource?.itemIdentifier(for: $0.indexPath), case .page = item.content else { return false }
            return item.chapterID == activeChapterID && $0.frame.maxY > collection.contentOffset.y
        }), let item = collectionDataSource?.itemIdentifier(for: first.indexPath), case let .page(position) = item.content {
            model.markPosition(page: position.page, offset: max(0, (collection.contentOffset.y - first.frame.minY) / max(1, first.frame.height)))
        }
        if continuousChapters, hasInteracted, movingForward, let session,
           renderedChapterIDs.last == activeChapterID,
           collection.contentOffset.y >= maximumScrollOffset(collection) - 0.5,
           session.boundary(from: activeChapterID, direction: .next) == .absent {
            session.completeChapter(activeChapterID)
        }
        publishPosition(); scheduleNeighborPreparation()
    }
    private func scheduleNeighborPreparation() {
        guard let session, !applyingLayout else { return }
        if let collection {
            guard model.state.settings.options.infiniteScroll else { return }
            // Prepare only the active chapter's successor, independently of the
            // page preload distance. A source manifest and its opening images
            // need more lead time than an ordinary page fetch.
            session.prepareNeighbor(from: activeChapterID, direction: .next)
            let indices = collection.indexPathsForVisibleItems
            if let first = renderedChapterIDs.first, indices.contains(where: { $0.section == 0 && $0.item <= model.state.settings.prefetch.pagesBehind + 1 }) {
                session.prepareNeighbor(from: first, direction: .previous)
            }
        } else {
            if model.state.currentPageIndex <= model.state.settings.prefetch.pagesBehind { session.prepareNeighbor(from: activeChapterID, direction: .previous) }
            if model.state.currentPageIndex + model.state.settings.prefetch.pagesAhead >= model.state.pages.count - 1 { session.prepareNeighbor(from: activeChapterID, direction: .next) }
        }
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === collection else { return }
        isUserScrolling = true
        gestureIsCoasting = false
        interactionContinuedChapter = false
        continuationDirection = nil; continuationTargetChapterID = nil
        humanInteractionInFlight = true
        chapterGate.beginInteraction(chapterID: activeChapterID)
        scrollInteractionRevision &+= 1
        programmaticScrollTarget = nil
        pendingPosition = nil; hasInteracted = true; lastRecordedScrollOffset = scrollView.contentOffset.y; model.beginViewportInteraction()
        autoScrollWasRunning = wantsAutoScroll; stopAutoScroll()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collection, !clampingScroll else { return }
        if humanInteractionInFlight || isUserScrolling || scrollView.isDragging || scrollView.isDecelerating {
            let offset = clampHumanScroll(scrollView)
            if abs(offset - scrollView.contentOffset.y) > 0.5 {
                clampingScroll = true
                scrollView.contentOffset.y = offset
                clampingScroll = false
            }
        }
        if humanInteractionInFlight || isUserScrolling || scrollView.isDragging || scrollView.isDecelerating || displayLink != nil || programmaticScrollTarget != nil {
            recordScrollPosition()
        }
        if let target = programmaticScrollTarget, abs(scrollView.contentOffset.y - target) < 0.5 { programmaticScrollTarget = nil }
    }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard scrollView === collection else { return }
        targetContentOffset.pointee.y = clampHumanScroll(scrollView, proposedOffset: targetContentOffset.pointee.y)
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === collection else { return }
        gestureIsCoasting = decelerate
        if !decelerate { chapterGate.endInteraction(); humanInteractionInFlight = false }
        if isUserScrolling { isUserScrolling = decelerate }
        hideBarsAfterMovement()
        if !decelerate { refresh(); recordScrollPosition(); resumeAutoScrollIfNeeded() }
        scheduleNeighborPreparation()
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === collection else { return }
        isUserScrolling = false
        gestureIsCoasting = false
        humanInteractionInFlight = false
        chapterGate.endInteraction()
        refresh(); recordScrollPosition(); resumeAutoScrollIfNeeded(); scheduleNeighborPreparation()
    }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        recordScrollPosition(); refresh(); scheduleNeighborPreparation()
        // Interrupted animations can report completion before their final
        // didScroll. Keep tracking until the target or a new interaction.
        if let target = programmaticScrollTarget, abs(scrollView.contentOffset.y - target) < 0.5 {
            programmaticScrollTarget = nil
        }
    }

    private func toggleAutoScroll() {
        guard collection != nil, model.state.settings.options.autoScroll else { return }
        if wantsAutoScroll { stopAutoScroll() } else { startAutoScroll() }
    }
    private func startAutoScroll() {
        guard displayLink == nil else { return }
        dismissBoundaryPage()
        wantsAutoScroll = true; waitingForChapter = false; hasInteracted = true
        configureVisibleCells()
        let link = CADisplayLink(target: WeakDisplayLinkTarget { [weak self] link in self?.tick(link) }, selector: #selector(WeakDisplayLinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common); displayLink = link; lastTick = 0; publishPosition()
    }
    func stopAutoScroll() {
        wantsAutoScroll = false; waitingForChapter = false
        displayLink?.invalidate(); displayLink = nil; lastTick = 0; publishPosition()
        configureVisibleCells()
    }
    private func resumeAutoScrollIfNeeded() {
        guard !applyingLayout, !isUserScrolling else { return }
        if autoScrollWasRunning { autoScrollWasRunning = false; startAutoScroll() }
    }
    private func resumeWaitingAutoScroll() {
        guard wantsAutoScroll, waitingForChapter, !hasMissingVisiblePage,
              model.pageErrorMessage == nil, let session else { return }
        switch session.boundary(from: activeChapterID, direction: .next) {
        case .available: startAutoScroll()
        case .absent: stopAutoScroll()
        default: break
        }
    }
    private var hasMissingVisiblePage: Bool {
        collection?.indexPathsForVisibleItems.contains { index in
            guard let item = collectionDataSource?.itemIdentifier(for: index), case let .page(position) = item.content else { return false }
            return chapterModel(item.chapterID)?.loadedImages[position.page] == nil
        } ?? false
    }
    private func tick(_ link: CADisplayLink) {
        defer { lastTick = link.timestamp }
        guard lastTick > 0, let collection else { return }
        if hasMissingVisiblePage || model.pageErrorMessage != nil {
            waitingForChapter = true; displayLink?.invalidate(); displayLink = nil
            return
        }
        let maximum = maximumScrollOffset(collection)
        let target = min(maximum, collection.contentOffset.y + (link.timestamp - lastTick) * model.state.settings.options.autoScrollSpeed * 12)
        if let session, let range = activeImageScrollRange(), target >= range.upperBound {
            switch session.boundary(from: activeChapterID, direction: .next) {
            case .available where model.state.settings.options.infiniteScroll:
                // Timed scrolling skips prepared transition pages without requiring a gesture.
                session.continuePastBoundary(from: activeChapterID, direction: .next)
                refresh()
                return
            default:
                if let edge = activeChapterScrollRange()?.upperBound {
                    collection.contentOffset.y = edge
                    showBoundaryPage(.next)
                    recordScrollPosition()
                }
                if model.state.settings.options.infiniteScroll,
                   session.boundary(from: activeChapterID, direction: .next) != .absent {
                    waitingForChapter = true; displayLink?.invalidate(); displayLink = nil
                    session.prepareNeighbor(from: activeChapterID, direction: .next)
                } else {
                    session.completeChapter(activeChapterID)
                    stopAutoScroll()
                }
                return
            }
        }
        collection.contentOffset.y = target
        recordScrollPosition()
        if target >= maximum { stopAutoScroll() }
    }

    private func quickActions(index: Int, image: UIImage, source: UIView, pageModel: (any ImageReaderControlling)? = nil) -> UIMenu {
        let pageModel = pageModel ?? model
        guard !model.state.settings.options.disableQuickActions else { return UIMenu() }
        var actions = [
            UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self, weak source] _ in
                let sheet = UIActivityViewController(activityItems: [image], applicationActivities: nil)
                sheet.popoverPresentationController?.sourceView = source
                sheet.popoverPresentationController?.sourceRect = source?.bounds ?? .zero
                self?.present(sheet, animated: true)
            },
            UIAction(title: "Save to Photos", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                Task { @MainActor in
                    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                    guard status == .authorized || status == .limited else { self?.showError("Allow photo access in Settings to save this page."); return }
                    do { try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) } }
                    catch { self?.showError(error.localizedDescription) }
                }
            },
            UIAction(title: "Reload Page", image: UIImage(systemName: "arrow.clockwise")) { _ in pageModel.reloadPage(index) }
        ]
        if pageModel.state.usesDoublePages {
            actions.append(UIAction(title: pageModel.state.isolatedPages.contains(index) ? "Use in Two-Page Spread" : "Show as Single Page", image: UIImage(systemName: "rectangle.portrait")) { _ in pageModel.togglePageIsolation(index) })
        }
        return UIMenu(children: actions)
    }
    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Reader", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(left)),
         UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(right)),
         UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(previous)),
         UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(nextPage)),
         UIKeyCommand(input: " ", modifierFlags: [], action: #selector(nextPage)),
         UIKeyCommand(input: UIKeyCommand.inputPageUp, modifierFlags: [], action: #selector(previous)),
         UIKeyCommand(input: UIKeyCommand.inputPageDown, modifierFlags: [], action: #selector(nextPage)),
         UIKeyCommand(input: UIKeyCommand.inputHome, modifierFlags: [], action: #selector(first)),
         UIKeyCommand(input: UIKeyCommand.inputEnd, modifierFlags: [], action: #selector(last))]
    }
    @objc private func left() { move(forward: activeLayout == .paged && model.state.settings.direction == .rightToLeft) }
    @objc private func right() { move(forward: !(activeLayout == .paged && model.state.settings.direction == .rightToLeft)) }
    @objc private func nextPage() { move(forward: true) }
    @objc private func previous() { move(forward: false) }
    @objc private func first() { model.moveToBeginning() }
    @objc private func last() { model.moveToEnd() }
}

@MainActor private final class WeakDisplayLinkTarget: NSObject {
    let callback: (CADisplayLink) -> Void
    init(_ callback: @escaping (CADisplayLink) -> Void) { self.callback = callback }
    @objc func tick(_ link: CADisplayLink) { callback(link) }
}

@MainActor private final class ContinuousZoomDelegate: NSObject, UIScrollViewDelegate {
    weak var content: UIView?
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        scrollView.isScrollEnabled = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
    }
}

@MainActor private final class ImagePageCell: UICollectionViewCell, UIContextMenuInteractionDelegate {
    let surface = ImageAnalysisContainerView()
    let renderer = ReaderImageSurface.Coordinator()
    let spinner = ReaderPageLoadingView()
    var pageIndex = 0
    var quickActions: ((UIImage, UIView) -> UIMenu)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(surface); contentView.addSubview(spinner)
        surface.addInteraction(UIContextMenuInteraction(delegate: self))
    }
    required init?(coder: NSCoder) { nil }
    override func layoutSubviews() { super.layoutSubviews(); surface.frame = contentView.bounds; spinner.frame = contentView.bounds }
    override func prepareForReuse() { super.prepareForReuse(); renderer.stop(); spinner.stopAnimating(); surface.imageView.image = nil }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard renderer.interaction?.selectableItemsHighlighted != true, let image = surface.imageView.image else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in guard let self else { return nil }; return quickActions?(image, surface) })
    }
}
