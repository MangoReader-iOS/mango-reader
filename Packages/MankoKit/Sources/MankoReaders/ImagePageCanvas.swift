import MankoDomain
import UIKit

/// Each spread owns its own zoom surface. Image resolution never supplies the
/// viewport size, so decoded and cached images follow identical layout rules.
@MainActor
final class ImagePageCanvas: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate {
    let chapterID: InstallmentID?
    let position: ImageReaderPosition
    let scroll = UIScrollView()
    let canvas = UIView()
    var onTap: ((CGPoint, CGSize) -> Void)?
    var onQuickAction: ((Int, UIImage, UIView) -> UIMenu)?
    private var state: ImageReaderState?
    private var surfaces: [ImageAnalysisContainerView] = []
    private var renderers: [ReaderImageSurface.Coordinator] = []
    private var spinners: [ReaderPageLoadingView] = []
    private var viewport = CGSize.zero
    private var doubleTap: UITapGestureRecognizer?

    init(position: ImageReaderPosition, chapterID: InstallmentID? = nil) { self.position = position; self.chapterID = chapterID; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(scroll); scroll.addSubview(canvas)
        scroll.delegate = self; scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 6
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsVerticalScrollIndicator = false; scroll.showsHorizontalScrollIndicator = false
        scroll.panGestureRecognizer.allowedScrollTypesMask = .all
        scroll.isScrollEnabled = false
        let single = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        single.cancelsTouchesInView = false; single.delegate = self
        let double = UITapGestureRecognizer(target: self, action: #selector(zoomed(_:)))
        double.numberOfTapsRequired = 2; double.delegate = self; doubleTap = double
        single.require(toFail: double)
        view.addGestureRecognizer(single); view.addGestureRecognizer(double)
    }
    func configure(state: ImageReaderState, images: [Int: CGImage], liveText: Bool,
        loadingStates: [Int: ImagePageLoadingState] = [:], previewIndices: Set<Int> = []) {
        self.state = state
        loadViewIfNeeded()
        doubleTap?.isEnabled = !state.settings.options.disableDoubleTap
        let indices = state.visiblePageIndices()
        while surfaces.count > indices.count {
            surfaces.removeLast().removeFromSuperview(); renderers.removeLast().stop(); spinners.removeLast().removeFromSuperview()
        }
        while surfaces.count < indices.count {
            let surface = ImageAnalysisContainerView()
            surface.addInteraction(UIContextMenuInteraction(delegate: self))
            canvas.addSubview(surface); surfaces.append(surface); renderers.append(.init())
            let spinner = ReaderPageLoadingView()
            canvas.addSubview(spinner); spinners.append(spinner)
        }
        for (slot, index) in indices.enumerated() {
            if surfaces[slot].tag != index {
                renderers[slot].stop()
                surfaces[slot].imageView.image = nil
            }
            surfaces[slot].tag = index
            surfaces[slot].isAccessibilityElement = true
            surfaces[slot].accessibilityLabel = "Page \(index + 1) of \(state.pages.count)"
            if let image = images[index] {
                let descriptor = state.pages[index]
                let layoutAspectRatio = descriptor.croppedAspectRatio(for: state.settings.cropMode)
                var insets = state.pages[index].cropInsets(for: state.settings.cropMode)
                if state.settings.widePageBehavior == .split,
                   state.pages[index].isWide(threshold: state.settings.widePageAspectRatioThreshold) {
                    let firstIsLeft = (state.settings.direction == .leftToRight) != state.settings.options.reverseSplitOrder
                    let showLeft = state.widePageSegment == 0 ? firstIsLeft : !firstIsLeft
                    // Split the actual cropped bitmap, not an oversized view frame.
                    let rect = insets.cropRect(pixelWidth: image.width, pixelHeight: image.height)
                    let half = floor(rect.width / 2)
                    let split = CGRect(x: showLeft ? rect.minX : rect.minX + half, y: rect.minY,
                        width: showLeft ? half : rect.width - half, height: rect.height)
                    if let cropped = image.cropping(to: split) {
                        var splitAspectRatio = layoutAspectRatio.map { $0 / 2 }
                        if let width = descriptor.pixelWidth, let height = descriptor.pixelHeight {
                            let logicalRect = insets.cropRect(pixelWidth: width, pixelHeight: height)
                            let logicalHalf = floor(logicalRect.width / 2)
                            splitAspectRatio = Double((showLeft ? logicalHalf : logicalRect.width - logicalHalf) / logicalRect.height)
                        }
                        insets = .zero
                        renderers[slot].render(cropped, cropInsets: insets, liveTextEnabled: liveText,
                            layoutAspectRatio: splitAspectRatio, in: surfaces[slot])
                    }
                } else {
                    renderers[slot].render(image, cropInsets: insets, liveTextEnabled: liveText,
                        layoutAspectRatio: layoutAspectRatio, in: surfaces[slot])
                }
            }
            if images[index] == nil || previewIndices.contains(index) {
                spinners[slot].configure(state: loadingStates[index] ?? .waiting,
                    pageIndex: index, pageCount: state.pages.count)
            } else { spinners[slot].stopAnimating() }
#if DEBUG
            if ProcessInfo.processInfo.environment["MANKO_PERFORMANCE_RUN"] != nil,
               images[index] != nil, !previewIndices.contains(index) {
                NotificationCenter.default.post(name: Notification.Name("MankoPerformance"), object: surfaces[slot], userInfo: ["page": index])
            }
#endif
        }
        canvas.accessibilityElements = surfaces.indices.sorted { surfaces[$0].tag < surfaces[$1].tag }.map {
            spinners[$0].isHidden ? surfaces[$0] as UIView : spinners[$0]
        }
        view.setNeedsLayout()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if viewport != size {
            viewport = size
            scroll.setZoomScale(1, animated: false)
            scroll.frame = view.bounds; canvas.frame = view.bounds; scroll.contentSize = size
        }
        let width = size.width / CGFloat(max(1, surfaces.count))
        for (slot, surface) in surfaces.enumerated() {
            var frame = CGRect(x: CGFloat(slot) * width, y: 0, width: width, height: size.height)
            if let state, let viewport = state.viewport, viewport.isExpanded {
                if surfaces.count == 2, viewport.supportsSpread {
                    frame = slot == 0 ? viewport.companionRegion : viewport.readingRegion
                } else {
                    let wide = state.currentPage?.isWide(threshold: state.settings.widePageAspectRatioThreshold) == true
                    if viewport.divisionIsActive || !viewport.supportsSpread
                        || (state.settings.options.expandedReading == "right" && !wide) {
                        frame = viewport.readingRegion
                    }
                }
            }
            frame = state?.viewport?.avoidingOcclusions(frame) ?? frame
            surface.frame = frame
            spinners[slot].frame = frame
        }
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // At fit scale the parent pager owns drags and trackpad scrolling.
        scrollView.isScrollEnabled = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
    }
    @objc private func tapped(_ tap: UITapGestureRecognizer) { onTap?(tap.location(in: view), view.bounds.size) }
    @objc private func zoomed(_ tap: UITapGestureRecognizer) {
        guard let state, !state.settings.options.disableDoubleTap else { return }
        if scroll.zoomScale > 1 { scroll.setZoomScale(1, animated: !UIAccessibility.isReduceMotionEnabled) }
        else {
            let point = tap.location(in: canvas), scale = state.settings.zoom.doubleTapScale
            let size = CGSize(width: view.bounds.width / scale, height: view.bounds.height / scale)
            scroll.zoom(to: CGRect(x: point.x - size.width/2, y: point.y - size.height/2, width: size.width, height: size.height), animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if touch.view is UIControl { return false }
        return !renderers.contains { $0.interaction?.selectableItemsHighlighted == true }
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard state?.settings.options.disableQuickActions != true,
              let source = interaction.view as? ImageAnalysisContainerView,
              let slot = surfaces.firstIndex(of: source), renderers[slot].interaction?.selectableItemsHighlighted != true,
              let image = source.imageView.image else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self, weak source] _ in
            guard let source else { return nil }
            return self?.onQuickAction?(source.tag, image, source)
        })
    }
    static func edgeColor(_ image: CGImage) -> UIColor {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let corner = image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)) else { return .black }
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return UIColor(red: CGFloat(pixel[0])/255, green: CGFloat(pixel[1])/255, blue: CGFloat(pixel[2])/255, alpha: 1)
    }
}
