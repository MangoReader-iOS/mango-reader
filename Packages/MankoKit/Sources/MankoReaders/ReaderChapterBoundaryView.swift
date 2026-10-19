import MankoDomain
import SwiftUI
import UIKit

/// A small edge cue overlays the final content without becoming a page or
/// a progress locator. The navigator remains available for the next gesture.
@MainActor
final class ChapterBoundarySurface: UIView {
    private let backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let stack = UIStackView()
    private let contextLabel = UILabel()
    private let neighborLabel = UILabel()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let button = UIButton(type: .system)
    private var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 20; clipsToBounds = true
        addSubview(backdrop)
        stack.axis = .vertical; stack.alignment = .center; stack.spacing = 4
        for label in [contextLabel, neighborLabel, statusLabel] {
            label.numberOfLines = 2; label.lineBreakMode = .byTruncatingTail; label.textAlignment = .center; label.adjustsFontForContentSizeCategory = true
            label.font = .preferredFont(forTextStyle: .body)
            stack.addArrangedSubview(label)
        }
        contextLabel.font = .preferredFont(forTextStyle: .headline)
        stack.addArrangedSubview(spinner)
        var config = UIButton.Configuration.plain(); config.cornerStyle = .capsule
        button.configuration = config
        button.addTarget(self, action: #selector(performAction), for: .touchUpInside)
        stack.addArrangedSubview(button)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let minimumButtonHeight = button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        minimumButtonHeight.priority = .defaultHigh
        minimumButtonHeight.isActive = true
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20)
        ])
        accessibilityIdentifier = "reader-chapter-boundary"
    }
    required init?(coder: NSCoder) { nil }
    override func layoutSubviews() { super.layoutSubviews(); backdrop.frame = bounds }
    func configure(current: Installment, direction: ReaderChapterDirection, state: ReaderChapterBoundaryState,
                   actionTitle: String? = nil, compact: Bool = true, darkBackground: Bool, action: @escaping () -> Void) {
        self.action = action
        backdrop.overrideUserInterfaceStyle = darkBackground ? .dark : .light
        backdrop.effect = UIAccessibility.isReduceTransparencyEnabled ? nil : UIBlurEffect(style: .systemUltraThinMaterial)
        backdrop.backgroundColor = UIAccessibility.isReduceTransparencyEnabled
            ? (darkBackground ? .secondarySystemBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
                              : .secondarySystemBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))) : .clear
        let color: UIColor = darkBackground ? .white : .black
        contextLabel.textColor = color; neighborLabel.textColor = color; statusLabel.textColor = color.withAlphaComponent(0.7)
        stack.spacing = compact ? 4 : 10
        contextLabel.font = .preferredFont(forTextStyle: compact ? .subheadline : .headline)
        neighborLabel.font = .preferredFont(forTextStyle: compact ? .subheadline : .body)
        statusLabel.font = .preferredFont(forTextStyle: compact ? .caption1 : .body)
        if direction == .previous, let previous = state.neighbor {
            contextLabel.text = "Current: \(current.title)"
            neighborLabel.text = "Previous: \(previous.title)"
        } else {
            contextLabel.text = direction == .next ? "Finished: \(current.title)" : "Current: \(current.title)"
            neighborLabel.text = state.neighbor.map { "Next: \($0.title)" }
        }
        spinner.stopAnimating(); button.isHidden = true
        contextLabel.isHidden = compact; neighborLabel.isHidden = state.neighbor == nil
        switch state {
        case .absent:
            contextLabel.isHidden = true
            statusLabel.text = direction == .previous ? "No previous chapter" : "No next chapter"
        case .loading:
            statusLabel.text = state.neighbor == nil ? "Loading chapters…" : "Loading chapter…"
            spinner.startAnimating()
        case .available:
            statusLabel.text = compact ? "Swipe again to continue" : "Continue reading"
            if !compact, let actionTitle { button.configuration?.title = actionTitle; button.isHidden = false }
        case let .failed(message, _):
            statusLabel.text = message
            button.configuration?.title = "Retry"; button.isHidden = false
        }
        invalidateIntrinsicContentSize()
        accessibilityCustomActions = compact && state.neighbor != nil
            ? [UIAccessibilityCustomAction(name: direction == .next ? "Next Chapter" : "Previous Chapter", target: self, selector: #selector(accessibilityContinue))]
            : nil
        statusLabel.accessibilityCustomActions = accessibilityCustomActions
    }
    @objc private func performAction() { action?() }
    @objc private func accessibilityContinue() -> Bool { action?(); return true }
}

public struct ReaderChapterBoundaryPanel: UIViewRepresentable {
    public let current: Installment
    public let direction: ReaderChapterDirection
    public let state: ReaderChapterBoundaryState
    public let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    public init(current: Installment, direction: ReaderChapterDirection,
                state: ReaderChapterBoundaryState, action: @escaping () -> Void) {
        self.current = current; self.direction = direction; self.state = state; self.action = action
    }
    public func makeUIView(context: Context) -> UIView { ChapterBoundarySurface() }
    public func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? ChapterBoundarySurface)?.configure(current: current, direction: direction, state: state,
            darkBackground: colorScheme == .dark, action: action)
    }
    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        let width = min(460, proposal.width ?? 320)
        let fitting = uiView.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return CGSize(width: width, height: max(68, fitting.height))
    }
}

struct ChapterPresentationItem: Hashable {
    enum Content: Hashable {
        case page(ImageReaderPosition)
        case boundary(ReaderChapterDirection)
    }
    let chapterID: InstallmentID
    let content: Content

    var imagePosition: ImageReaderPosition? {
        guard case let .page(position) = content else { return nil }
        return position
    }

    static func chapterPages(id: InstallmentID, positions: [ImageReaderPosition], includesBoundaries: Bool) -> [Self] {
        let pages = positions.map { Self(chapterID: id, content: .page($0)) }
        guard includesBoundaries, !pages.isEmpty else { return pages }
        return [Self(chapterID: id, content: .boundary(.previous))] + pages
            + [Self(chapterID: id, content: .boundary(.next))]
    }
}

/// Chapter transitions belong to the page flow, with the same background as its images.
@MainActor
final class ImageChapterBoundaryPage: UIView {
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let currentLabel = UILabel()
    private let neighborLabel = UILabel()
    private let statusLabel = UILabel()
    private let shimmer = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private var retry: (() -> Void)?
    private var continueChapter: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "image-reader-chapter-transition-page"
        scroll.alwaysBounceVertical = false
        addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let container = UIView()
        scroll.addSubview(container)
        container.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical; stack.alignment = .center; stack.spacing = 16
        for label in [currentLabel, neighborLabel, statusLabel] {
            label.numberOfLines = 0; label.textAlignment = .center
            label.adjustsFontForContentSizeCategory = true
            stack.addArrangedSubview(label)
        }
        currentLabel.font = .preferredFont(forTextStyle: .headline)
        neighborLabel.font = .preferredFont(forTextStyle: .title2)
        statusLabel.font = .preferredFont(forTextStyle: .body)
        neighborLabel.accessibilityTraits.insert(.header)
        stack.addArrangedSubview(shimmer)
        retryButton.configuration = .plain()
        retryButton.configuration?.title = "Retry"
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        stack.addArrangedSubview(retryButton)
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let center = stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        center.priority = .defaultHigh
        let retryHeight = retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        retryHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            container.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            container.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            container.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor), center,
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: 32),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -32),
            retryHeight
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.layoutIfNeeded()
        // Normal transition pages hand their swipe to the reader; only overflowing
        // accessibility text needs its own scroll area.
        let canScroll = scroll.contentSize.height > scroll.bounds.height + 1
        if scroll.isScrollEnabled != canScroll { scroll.isScrollEnabled = canScroll }
    }

    func configure(current: Installment, direction: ReaderChapterDirection, state: ReaderChapterBoundaryState,
                   background: UIColor, retry: @escaping () -> Void, continueChapter: @escaping () -> Void) {
        self.retry = retry; self.continueChapter = continueChapter
        backgroundColor = background
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        let light = background.resolvedColor(with: traitCollection).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            && red * 0.2126 + green * 0.7152 + blue * 0.0722 > 0.5
        let color: UIColor = light ? .black : .white
        currentLabel.textColor = color.withAlphaComponent(0.7); neighborLabel.textColor = color
        statusLabel.textColor = color.withAlphaComponent(0.7); retryButton.tintColor = color
        currentLabel.text = "\(direction == .next ? "Finished" : "Current"): \(current.title)"
        neighborLabel.text = state.neighbor.map { "\(direction == .next ? "Next" : "Previous"): \($0.title)" }
        neighborLabel.isHidden = state.neighbor == nil
        shimmer.stopAnimating(); retryButton.isHidden = true
        statusLabel.isHidden = false
        switch state {
        case .absent:
            statusLabel.text = direction == .next ? "End of available chapters" : "No previous chapter"
        case .loading:
            statusLabel.text = state.neighbor == nil ? "Loading chapters…" : "Loading chapter…"
            shimmer.startAnimating()
        case .available:
            statusLabel.text = nil
            statusLabel.isHidden = true
        case let .failed(message, _):
            statusLabel.text = message; retryButton.isHidden = false
        }
        neighborLabel.accessibilityCustomActions = state.neighbor == nil ? nil
            : [UIAccessibilityCustomAction(name: direction == .next ? "Next Chapter" : "Previous Chapter",
                                           target: self, selector: #selector(accessibilityContinue))]
    }
    /// Scrolling dividers fit their text; paged transitions still fill their page.
    func compactHeight(for width: CGFloat) -> CGFloat {
        let textWidth = max(1, min(600, width - 48))
        let size = stack.systemLayoutSizeFitting(
            CGSize(width: textWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return ceil(size.height) + 64
    }

    @objc private func retryTapped() { retry?() }
    @objc private func accessibilityContinue() -> Bool { continueChapter?(); return true }
}

@MainActor
final class ImageChapterBoundaryController: UIViewController {
    let item: ChapterPresentationItem
    let page = ImageChapterBoundaryPage()
    var onTap: ((CGPoint, CGSize) -> Void)?
    init(item: ChapterPresentationItem) { self.item = item; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }
    override func loadView() {
        view = page
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false; view.addGestureRecognizer(tap)
    }
    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        var target = tap.view?.hitTest(tap.location(in: tap.view), with: nil)
        while let current = target { if current is UIControl { return }; target = current.superview }
        onTap?(tap.location(in: view), view.bounds.size)
    }
}

@MainActor
final class ImageChapterBoundaryCell: UICollectionViewCell {
    let page = ImageChapterBoundaryPage()
    override init(frame: CGRect) { super.init(frame: frame); contentView.addSubview(page) }
    required init?(coder: NSCoder) { nil }
    override func layoutSubviews() { super.layoutSubviews(); page.frame = contentView.bounds }
}

/// A boundary reached in one gesture can only be crossed by a fresh gesture.
/// Coasting, duplicate callbacks, and asynchronous chapter loading cannot grant
/// continuation. Chapter identity changes, jumps, and viewport changes discard
/// an old arm before any new chapter can continue.
struct ReaderChapterGestureGate<ChapterIdentity: Hashable> {
    enum Decision: Equatable { case stop, continueChapter, ignored }
    private(set) var armedDirection: ReaderChapterDirection?
    private var chapterID: ChapterIdentity?
    private var permittedDirection: ReaderChapterDirection?
    private var isInteracting = false
    private var consumed = false

    mutating func beginInteraction(chapterID: ChapterIdentity) {
        if self.chapterID != chapterID {
            reset()
            self.chapterID = chapterID
        }
        permittedDirection = armedDirection
        isInteracting = true
        consumed = false
    }

    mutating func attempt(_ direction: ReaderChapterDirection, chapterID: ChapterIdentity) -> Decision {
        guard self.chapterID == chapterID else { reset(); return .ignored }
        guard isInteracting, !consumed else { return .ignored }
        if permittedDirection == direction {
            consumed = true
            armedDirection = nil
            return .continueChapter
        }
        armedDirection = direction
        return .stop
    }

    mutating func noteMovement(_ direction: ReaderChapterDirection) {
        if let armedDirection, armedDirection != direction {
            self.armedDirection = nil
            permittedDirection = nil
        }
    }

    mutating func clearArm() {
        armedDirection = nil
        permittedDirection = nil
    }

    mutating func endInteraction() {
        isInteracting = false
        permittedDirection = nil
    }

    mutating func reset() { self = Self() }
}
