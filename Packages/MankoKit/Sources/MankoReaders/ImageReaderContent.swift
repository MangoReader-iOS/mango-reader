import CoreGraphics
import MankoDomain
import Observation
import SwiftUI
import UIKit

public enum ImagePageLoadingState: Equatable, Sendable {
    case waiting
    case downloading(RemoteImageDownloadProgress)
    case preparing
    case failed
}

@MainActor
protocol ImageReaderControlling: AnyObject {
    var state: ImageReaderState { get }
    var loadedImages: [Int: CGImage] { get }
    var previewPageIndices: Set<Int> { get }
    var pageLoadingStates: [Int: ImagePageLoadingState] { get }
    var pageErrorMessage: String? { get }
    var lastNavigationIntent: ImageNavigationIntent { get }
    var scrollTargetPageIndex: Int? { get }
    var scrollRequestRevision: UInt { get }
    func openIfNeeded()
    func suspend()
    func updateSettings(_ settings: ImageReaderSettings)
    func updateLoadingBudget(_ prefetch: ImagePrefetchSettings?)
    @discardableResult func moveForward() -> Bool
    @discardableResult func moveBackward() -> Bool
    func move(to index: Int)
    func navigate(to locator: ReadingLocator)
    func moveScreenLeft()
    func moveScreenRight()
    func moveToBeginning()
    func moveToEnd()
    func markPageVisible(_ index: Int)
    func markPosition(page: Int, offset: Double)
    func updateViewport(_ viewport: ReaderViewport)
    func togglePageIsolation(_ index: Int)
    func reloadPage(_ index: Int)
    func updateVisiblePageIndices(_ indices: [Int], scrollRequestRevision: UInt)
    func beginViewportInteraction()
    func releaseRecentImages()
    func performTap(in region: TapZoneRegion)
    func toggleDoubleTapZoom()
    func updateMagnification(_ magnification: Double)
    func endMagnification()
}

extension CBZReaderModel: ImageReaderControlling {}
extension ImageReaderControlling {
    func updateViewport(_ size: CGSize) { updateViewport(ReaderViewport(size: size)) }
    var previewPageIndices: Set<Int> { [] }
    var pageLoadingStates: [Int: ImagePageLoadingState] { [:] }
    var pageErrorMessage: String? { nil }
}
extension RemoteImageReaderModel: ImageReaderControlling {}

/// App chrome and keyboard commands use the same navigation as touch gestures.
@MainActor @Observable
public final class ImageReaderController {
    public private(set) var currentPageIndex = 0
    public private(set) var pageCount = 0
    public private(set) var isAutoScrolling = false
    public private(set) var isAtBeginning = true
    public private(set) var isAtEnd = true
    public var onBoundary: ((Bool) -> Void)?
    @ObservationIgnored var move: ((Bool) -> Void)?
    @ObservationIgnored var seek: ((Int) -> Void)?
    @ObservationIgnored var autoScroll: (() -> Void)?
    @ObservationIgnored var pause: (() -> Void)?
    public init() {}
    public func moveForward() { move?(true) }
    public func moveBackward() { move?(false) }
    public func move(to page: Int) { seek?(page) }
    public func toggleAutoScroll() { autoScroll?() }
    public func pauseAutoScroll() { pause?() }
    func update(page: Int, count: Int, atBeginning: Bool, atEnd: Bool, autoScrolling: Bool) {
        if currentPageIndex != page { currentPageIndex = page }
        if pageCount != count { pageCount = count }
        if isAtBeginning != atBeginning { isAtBeginning = atBeginning }
        if isAtEnd != atEnd { isAtEnd = atEnd }
        if isAutoScrolling != autoScrolling { isAutoScrolling = autoScrolling }
    }
}

struct ImageReaderContent<Model: ImageReaderControlling>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: Model
    let liveTextEnabled: Bool
    let controlsVisible: Binding<Bool>?
    let accessibilityLabel: String
    let scrollingAccessibilityLabel: String
    var navigation: ImageReaderController? = nil

    var body: some View {
        let _ = model.pageLoadingStates
        let _ = model.loadedImages
        let _ = model.scrollRequestRevision
        NativeImageReader(model: model, liveTextEnabled: liveTextEnabled,
            reduceMotion: reduceMotion, controlsVisible: controlsVisible, navigation: navigation)
            .accessibilityLabel(model.state.settings.layout.isPaged ? accessibilityLabel : scrollingAccessibilityLabel)
            .overlay(alignment: .bottom) {
                if navigation == nil, controlsVisible?.wrappedValue ?? model.state.controlsVisible {
                    ImageReaderPageControls(currentPageIndex: model.state.currentPageIndex,
                        pageCount: model.state.pages.count, isAtBeginning: model.state.isAtBeginning,
                        isAtEnd: model.state.isAtEnd, direction: model.state.settings.direction,
                        layout: model.state.settings.layout,
                        moveBackward: { model.moveBackward() }, moveForward: { model.moveForward() })
                        .padding()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                model.releaseRecentImages()
            }
    }

    func performTap(in region: TapZoneRegion) {
        let action = model.state.settings.tapZones.action(for: region)
        model.performTap(in: region)
        if action == .toggleControls, let controlsVisible { controlsVisible.wrappedValue.toggle() }
    }
}
