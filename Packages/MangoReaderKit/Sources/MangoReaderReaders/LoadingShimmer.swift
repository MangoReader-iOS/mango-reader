import SwiftUI
import UIKit

private enum LoadingShimmerTiming {
    static let duration: TimeInterval = 1.5
    static let delay: TimeInterval = 0.25
}

/// Uses a quiet sweep for content placeholders.
public extension View {
    func loadingShimmer(active: Bool = true) -> some View {
        modifier(LoadingShimmerModifier(active: active))
    }
}

struct LoadingShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let active: Bool
    var reduceMotionOverride: Bool? = nil

    func body(content: Content) -> some View {
        if active && !(reduceMotionOverride ?? reduceMotion) {
            content.modifier(AnimatedLoadingShimmerModifier())
        } else {
            content
        }
    }
}

private struct AnimatedLoadingShimmerModifier: ViewModifier {
    @State private var isAtEnd = false

    func body(content: Content) -> some View {
        content.modifier(LoadingShimmerPhaseModifier(phase: isAtEnd ? 1 : 0))
            .task { isAtEnd = true }
    }
}

/// Separate phase rendering keeps the animation confined to the gradient mask.
struct LoadingShimmerPhaseModifier: ViewModifier {
    let phase: CGFloat

    func body(content: Content) -> some View {
        // Only the mask animates; the placeholder's layout stays fixed.
        content.mask {
            LoadingShimmerMask(phase: phase)
                .animation(
                    .linear(duration: LoadingShimmerTiming.duration)
                        .delay(LoadingShimmerTiming.delay)
                        .repeatForever(autoreverses: false),
                    value: phase
                )
        }
    }
}

private nonisolated struct LoadingShimmerMask: View, Animatable {
    @Environment(\.layoutDirection) private var layoutDirection
    var phase: CGFloat

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    var body: some View {
        LinearGradient(
            colors: [.black.opacity(0.3), .black, .black.opacity(0.3)],
            startPoint: point(from: -0.3, to: 1),
            endPoint: point(from: 0, to: 1.3)
        )
        // Interpolate the phase above, never the gradient's proposed bounds.
        .transaction { $0.animation = nil }
    }

    private func point(from start: CGFloat, to end: CGFloat) -> UnitPoint {
        let position = start + (end - start) * phase
        return UnitPoint(x: layoutDirection == .rightToLeft ? 1 - position : position, y: position)
    }
}

/// Indeterminate loading feedback. Real percentage progress uses ProgressView.
public struct ReaderLoadingIndicator: View {
    @Environment(\.controlSize) private var controlSize
    @Environment(\.font) private var labelFont
    private let title: Text?
    private let compact: Bool

    @_disfavoredOverload
    public init(_ title: String? = nil, compact: Bool = false) {
        self.title = title.map { Text($0) }
        self.compact = compact
    }

    public init(_ title: LocalizedStringKey, compact: Bool = false) {
        self.title = Text(title)
        self.compact = compact
    }

    private var isCompact: Bool {
        compact || controlSize == .small || controlSize == .mini
    }

    public var body: some View {
        Group {
            if let title { ProgressView { title } }
            else { ProgressView() }
        }
        .controlSize(isCompact ? .small : controlSize)
        .font(labelFont)
    }
}

/// UIKit shimmer primitive retained for compatibility.
@MainActor
public final class ReaderLoadingShimmerView: UIView {
    private let sweep = CAGradientLayer()
    private var isLoading = false
    private var animationDirection: UIUserInterfaceLayoutDirection?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondaryLabel.withAlphaComponent(0.35)
        sweep.colors = [UIColor.black.withAlphaComponent(0.3).cgColor,
                        UIColor.black.cgColor,
                        UIColor.black.withAlphaComponent(0.3).cgColor]
        layer.cornerRadius = 4
        layer.masksToBounds = true
        isHidden = true
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Loading")
        accessibilityTraits.insert(.updatesFrequently)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(motionPreferenceChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ReaderLoadingShimmerView, _: UITraitCollection) in
            view.backgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.35)
        }
    }

    public required init?(coder: NSCoder) { nil }

    public override var intrinsicContentSize: CGSize { CGSize(width: 72, height: 8) }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // A hidden arranged subview can legitimately have zero height. Changing
        // its bounds here fights UIStackView and can prevent layout from settling.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sweep.frame = bounds
        CATransaction.commit()
        updateAnimation()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAnimation()
    }

    public func startAnimating() {
        isLoading = true
        isHidden = false
        if bounds.isEmpty { bounds.size = intrinsicContentSize }
        setNeedsLayout()
        updateAnimation()
    }

    public func stopAnimating() {
        isLoading = false
        isHidden = true
        updateAnimation()
    }

    @objc private func motionPreferenceChanged() { updateAnimation() }

    private func updateAnimation() {
        guard isLoading, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            sweep.removeAllAnimations()
            animationDirection = nil
            layer.mask = nil
            return
        }
        let direction = effectiveUserInterfaceLayoutDirection
        guard animationDirection != direction || sweep.animation(forKey: "loadingSweep") == nil else { return }
        animationDirection = direction
        let rtl = direction == .rightToLeft
        let start = rtl ? CGPoint(x: 1.3, y: -0.3) : CGPoint(x: -0.3, y: -0.3)
        let end = rtl ? CGPoint(x: 1, y: 0) : CGPoint(x: 0, y: 0)
        sweep.startPoint = start
        sweep.endPoint = end
        layer.mask = sweep

        let startAnimation = CABasicAnimation(keyPath: "startPoint")
        startAnimation.fromValue = start
        startAnimation.toValue = rtl ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 1)
        startAnimation.duration = LoadingShimmerTiming.duration
        let endAnimation = CABasicAnimation(keyPath: "endPoint")
        endAnimation.fromValue = end
        endAnimation.toValue = rtl ? CGPoint(x: -0.3, y: 1.3) : CGPoint(x: 1.3, y: 1.3)
        endAnimation.duration = LoadingShimmerTiming.duration
        let group = CAAnimationGroup()
        group.animations = [startAnimation, endAnimation]
        group.duration = LoadingShimmerTiming.duration
        group.beginTime = CACurrentMediaTime() + LoadingShimmerTiming.delay
        group.repeatCount = .infinity
        sweep.add(group, forKey: "loadingSweep")
    }
}


/// A placeholder occupying the same bounds as a reader page, never a progress locator.
public struct ReaderContentSkeleton: View {
    public enum Layout { case page, text }
    private let layout: Layout
    private let label: String

    public init(layout: Layout = .page, label: String = String(localized: "Loading page")) {
        self.layout = layout
        self.label = label
    }

    public var body: some View {
        GeometryReader { geometry in
            Group {
                switch layout {
                case .page:
                    Rectangle().fill(.secondary.opacity(0.16))
                case .text:
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(0..<max(1, Int(geometry.size.height / 32)), id: \.self) { index in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.secondary.opacity(0.2))
                                .frame(width: max(0, geometry.size.width - 48) * (index.isMultiple(of: 5) ? 0.65 : 1), height: 12)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(24)
                }
            }
            .loadingShimmer()
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// A compact native activity indicator. Percentages describe downloaded bytes;
/// queued work and final decoding deliberately have no percentage.
@MainActor
final class ReaderPageLoadingView: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let percentage = UILabel()
    private let panel = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        spinner.color = .white
        percentage.textColor = .white
        percentage.font = UIFont.preferredFont(forTextStyle: .caption1)
        percentage.adjustsFontForContentSizeCategory = true
        percentage.textAlignment = .center
        percentage.isHidden = true
        panel.axis = .vertical
        panel.alignment = .center
        panel.spacing = 8
        panel.isLayoutMarginsRelativeArrangement = true
        panel.directionalLayoutMargins = .init(top: 16, leading: 16, bottom: 16, trailing: 16)
        panel.backgroundColor = .black
        panel.layer.cornerRadius = 12
        panel.addArrangedSubview(spinner)
        panel.addArrangedSubview(percentage)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "reader-page-loading"
        accessibilityTraits.insert(.updatesFrequently)
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func configure(state: ImagePageLoadingState, pageIndex: Int, pageCount: Int) {
        guard state != .failed else { stopAnimating(); return }
        accessibilityLabel = String(localized: "Loading page \(pageIndex + 1) of \(pageCount)")
        let fraction: Double?
        if case let .downloading(progress) = state { fraction = progress.fractionCompleted }
        else { fraction = nil }
        let value = fraction.map { (($0 * 100).rounded(.down) / 100).formatted(.percent.precision(.fractionLength(0))) }
        percentage.text = value
        percentage.isHidden = value == nil
        accessibilityValue = value
        isHidden = false
        spinner.startAnimating()
    }

    func stopAnimating() {
        spinner.stopAnimating()
        percentage.text = nil
        percentage.isHidden = true
        accessibilityValue = nil
        isHidden = true
    }
}
