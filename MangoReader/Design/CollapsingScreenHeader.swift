import SwiftUI
import UIKit

enum ScreenHeaderCollapsePolicy {
    nonisolated static func allowsCollapse(for idiom: UIUserInterfaceIdiom) -> Bool {
        idiom != .pad
    }
}

enum ScreenHeaderPlatform {
    static var allowsCollapse: Bool {
        ScreenHeaderCollapsePolicy.allowsCollapse(for: UIDevice.current.userInterfaceIdiom)
    }

    /// Holds the real collapsed presentation for manual checks when simulator scrolling is unavailable.
    static var verifiesCollapsedHeader: Bool {
#if DEBUG
        allowsCollapse && ProcessInfo.processInfo.arguments.contains("--mangoreader-verify-collapsed-header")
#else
        false
#endif
    }

    static var usesNativeControls: Bool {
#if targetEnvironment(macCatalyst)
        false
#else
        if #available(iOS 26.0, *) { true } else { false }
#endif
    }
}

/// Toolbar controls occupy the content column, reserving only the native icon Back row when needed.
enum HeaderSearchToolbarLayout {
    nonisolated static func width(containerWidth: CGFloat, hasBackButton: Bool) -> CGFloat {
        max(0, containerWidth - 32 - (hasBackButton ? 52 : 0))
    }
}

enum ScreenTitlePresentation: Equatable {
    case expanded
    case navigation
    case hidden
}

private struct ScreenTitle: ViewModifier {
    let title: Text
    let presentation: ScreenTitlePresentation

    @ViewBuilder
    func body(content: Content) -> some View {
#if targetEnvironment(macCatalyst)
        content
            .navigationTitle(presentation == .hidden ? Text("") : title)
            .toolbarTitleDisplayMode(presentation == .expanded ? .inlineLarge : .inline)
            .appNativeNavigationChrome()
#else
        content
            .navigationTitle(presentation == .navigation ? title : Text(""))
            .toolbarTitleDisplayMode(.inline)
            .appNativeNavigationChrome()
            .toolbar {
                if presentation == .expanded {
                    expandedTitleToolbar
                }
            }
            .nativeScreenHeader(isEditing: false, minimizesOnScroll: false)
#endif
    }

    private var expandedTitle: some View {
        title
            .font(.largeTitle.bold())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .appFixedNavigationChrome()
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("screen-expanded-title")
            .transaction {
                $0.animation = nil
                $0.disablesAnimations = true
            }
    }

    @ToolbarContentBuilder
    private var expandedTitleToolbar: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading) { FixedNavigationChrome { expandedTitle } }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) { FixedNavigationChrome { expandedTitle } }
        }
    }
}

extension ToolbarContent {
    @ToolbarContentBuilder
    func searchFieldToolbarBackground() -> some ToolbarContent {
#if !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) { self.sharedBackgroundVisibility(.hidden) }
        else { self }
#else
        self
#endif
    }
}

/// A direction-aware header that ignores restoration, layout changes, and small scroll reversals.
struct CollapsingScreenHeaderState: Equatable {
    static let collapseDistance: CGFloat = 32

    struct Geometry: Equatable {
        var offset: CGFloat
        var contentHeight: CGFloat
        var viewportHeight: CGFloat
        var topInset: CGFloat = 0

        var scrollableRange: CGFloat { max(0, contentHeight - viewportHeight) }
        var clampedOffset: CGFloat { min(max(0, offset), scrollableRange) }
        // Treat all top chrome as removable, giving collapse a conservative viewport budget.
        var compactViewportHeight: CGFloat { viewportHeight + max(0, topInset) }
        var compactScrollableRange: CGFloat { max(0, contentHeight - compactViewportHeight) }

        init(offset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat, topInset: CGFloat = 0) {
            self.offset = offset
            self.contentHeight = contentHeight
            self.viewportHeight = viewportHeight
            self.topInset = topInset
        }

        init(_ geometry: ScrollGeometry) {
            offset = geometry.contentOffset.y + geometry.contentInsets.top
            contentHeight = geometry.contentSize.height
            // ScrollGeometry already excludes the content insets from its container size.
            viewportHeight = max(0, geometry.containerSize.height)
            topInset = geometry.contentInsets.top
        }
    }

    private(set) var isCollapsed = false
    private(set) var hasScrolledContent = false
    private var previousGeometry: Geometry?
    private var directionalDistance: CGFloat = 0

    mutating func observe(
        _ geometry: Geometry,
        isUserScrolling: Bool,
        minimumRemainingSpaceAfterCollapse: CGFloat? = nil,
        allowsShortContentExpansion: Bool = true
    ) {
        defer { previousGeometry = geometry }
        hasScrolledContent = geometry.clampedOffset > 8
        let isShortContent = geometry.scrollableRange <= 1
            || minimumRemainingSpaceAfterCollapse.map {
                geometry.compactScrollableRange < Self.collapseDistance + $0
            } == true
        if isShortContent {
            if allowsShortContentExpansion { isCollapsed = false }
            directionalDistance = 0
            return
        }
        guard geometry.clampedOffset > 8 else {
            isCollapsed = false
            directionalDistance = 0
            return
        }
        guard isUserScrolling, let previousGeometry,
              abs(previousGeometry.viewportHeight - geometry.viewportHeight) < 1,
              abs(previousGeometry.topInset - geometry.topInset) < 1 else {
            directionalDistance = 0
            return
        }

        let delta = geometry.clampedOffset - previousGeometry.clampedOffset
        guard abs(delta) > 0.25 else { return }
        if (delta > 0) != (directionalDistance > 0) { directionalDistance = 0 }
        directionalDistance += delta
        if !isCollapsed, directionalDistance >= Self.collapseDistance,
           minimumRemainingSpaceAfterCollapse.map({
               geometry.compactScrollableRange - geometry.clampedOffset >= $0
           }) ?? true {
            isCollapsed = true
            directionalDistance = 0
        }
    }

    mutating func reset() { self = Self() }

    func matchesPresentation(of other: Self) -> Bool {
        isCollapsed == other.isCollapsed && hasScrolledContent == other.hasScrolledContent
    }

    mutating func rebase(_ geometry: Geometry) {
        previousGeometry = geometry
        directionalDistance = 0
        hasScrolledContent = geometry.clampedOffset > 8
    }
}

enum AppSelectionTransition {
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.26, extraBounce: 0)
    }

    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }
}

/// The phase must be shared synchronously by both callbacks, including a gesture's final geometry.
final class CollapsingScreenHeaderObservation {
    // Keep geometry bookkeeping outside SwiftUI state; only visible changes need a render.
    var trackedState = CollapsingScreenHeaderState()
    private(set) var phase = ScrollPhase.idle
    private var gestureStart: CollapsingScreenHeaderState.Geometry?
    private var gestureStartedCollapsed = false
    private var visibilityChangedInGesture = false
    private var latestGeometry: CollapsingScreenHeaderState.Geometry?
    private var transitionGeneration: UInt64 = 0
    private var transitionTargetCollapsed: Bool?
    private(set) var activeTransition: UInt64?
    private let minimumRemainingSpaceAfterCollapse: CGFloat?

    init(minimumRemainingSpaceAfterCollapse: CGFloat? = nil) {
        self.minimumRemainingSpaceAfterCollapse = minimumRemainingSpaceAfterCollapse
    }

    var isUserScrolling: Bool { Self.isUserPhase(phase) }

    @discardableResult
    func prepareTransition(isCollapsed: Bool) -> UInt64 {
        if let activeTransition, transitionTargetCollapsed == isCollapsed { return activeTransition }
        transitionGeneration &+= 1
        activeTransition = transitionGeneration
        transitionTargetCollapsed = isCollapsed
        if phase != .idle { visibilityChangedInGesture = true }
        return transitionGeneration
    }

    @discardableResult
    func finishTransition(_ token: UInt64, state: inout CollapsingScreenHeaderState, isEnabled: Bool = true) -> Bool {
        guard activeTransition == token else { return false }
        activeTransition = nil
        transitionTargetCollapsed = nil
        guard phase == .idle else { return true }
        visibilityChangedInGesture = false
        gestureStart = nil
        if let latestGeometry {
            if isEnabled { observeState(latestGeometry, state: &state, isUserScrolling: false) }
            else { state.rebase(latestGeometry) }
        }
        return true
    }

    func invalidateTransition() {
        transitionGeneration &+= 1
        activeTransition = nil
        transitionTargetCollapsed = nil
    }

    func observePhase(
        from oldPhase: ScrollPhase,
        to newPhase: ScrollPhase,
        geometry: CollapsingScreenHeaderState.Geometry,
        state: inout CollapsingScreenHeaderState,
        isEnabled: Bool = true
    ) {
        phase = newPhase
        latestGeometry = geometry
        if newPhase == .idle, visibilityChangedInGesture {
            visibilityChangedInGesture = false
            gestureStart = nil
            if isEnabled, activeTransition == nil { observeState(geometry, state: &state, isUserScrolling: false) }
            else { state.rebase(geometry) }
            return
        }
        defer {
            if newPhase == .idle { visibilityChangedInGesture = false }
        }
        let beginsGesture = newPhase == .tracking
            || (newPhase == .interacting && oldPhase != .tracking && oldPhase != .interacting)
        if beginsGesture { visibilityChangedInGesture = activeTransition != nil }
        guard isEnabled else {
            gestureStart = nil
            state.rebase(geometry)
            return
        }
        if beginsGesture {
            gestureStart = geometry
            gestureStartedCollapsed = state.isCollapsed
            state.rebase(geometry)
            return
        }
        guard !visibilityChangedInGesture, activeTransition == nil else {
            // Folding the header changes the viewport and clamps the offset during the same coast.
            // Hold visibility until both the scroll and header animation have finished.
            state.rebase(geometry)
            return
        }
        let wasCollapsed = state.isCollapsed
        // Geometry may be coalesced until the phase callback that ends a short gesture.
        let finishesUserScroll = newPhase == .idle && Self.isUserPhase(oldPhase)
        observeState(geometry, state: &state, isUserScrolling: isUserScrolling || finishesUserScroll)
        if (isUserScrolling || finishesUserScroll),
           let gestureStart,
           state.isCollapsed == gestureStartedCollapsed,
           abs(geometry.viewportHeight - gestureStart.viewportHeight) <= 88,
           abs(geometry.topInset - gestureStart.topInset) <= 88,
           abs(geometry.contentHeight - gestureStart.contentHeight) < 1 {
            // A native title can contract in the same coalesced sample as the entire gesture.
            // Retain that explicit movement, but exclude keyboard/window and content resizing.
            var baseline = geometry
            baseline.offset = gestureStart.clampedOffset
            state.rebase(baseline)
            observeState(geometry, state: &state, isUserScrolling: true)
        }
        if state.isCollapsed != wasCollapsed { visibilityChangedInGesture = true }
        if newPhase == .idle {
            state.rebase(geometry)
            gestureStart = nil
        } else if newPhase == .animating {
            gestureStart = nil
        }
    }

    func observeGeometry(
        _ geometry: CollapsingScreenHeaderState.Geometry,
        state: inout CollapsingScreenHeaderState,
        isEnabled: Bool = true
    ) {
        latestGeometry = geometry
        guard isEnabled, !visibilityChangedInGesture, activeTransition == nil else {
            state.rebase(geometry)
            return
        }
        let wasCollapsed = state.isCollapsed
        observeState(geometry, state: &state, isUserScrolling: isUserScrolling)
        if isUserScrolling, state.isCollapsed != wasCollapsed { visibilityChangedInGesture = true }
    }

    func reconcile(state: inout CollapsingScreenHeaderState, isEnabled: Bool, appearing: Bool = false) {
        if appearing {
            invalidateTransition()
            phase = .idle
            gestureStart = nil
            visibilityChangedInGesture = false
        }
        guard isEnabled, let latestGeometry else { return }
        observeGeometry(latestGeometry, state: &state, isEnabled: isEnabled)
    }

    private static func isUserPhase(_ phase: ScrollPhase) -> Bool {
        phase == .tracking || phase == .interacting || phase == .decelerating
    }

    private func observeState(
        _ geometry: CollapsingScreenHeaderState.Geometry,
        state: inout CollapsingScreenHeaderState,
        isUserScrolling: Bool
    ) {
        state.observe(
            geometry,
            isUserScrolling: isUserScrolling,
            minimumRemainingSpaceAfterCollapse: minimumRemainingSpaceAfterCollapse,
            allowsShortContentExpansion: minimumRemainingSpaceAfterCollapse == nil || phase == .idle
        )
    }
}

enum HeaderSearchQueryRetentionPolicy {
    static func shouldApply(
        proposedText: String,
        currentText: String,
        isFocused: Bool,
        isPresented: Bool
    ) -> Bool {
        // FocusState can still read true while SwiftUI tears down a dismissed search field.
        !proposedText.isEmpty || currentText.isEmpty || (isFocused && isPresented)
    }
}

enum HeaderSearchFieldPolicy {
    static func usesInlineField(isCollapsed: Bool, editingFieldIsInline: Bool?) -> Bool {
        editingFieldIsInline ?? isCollapsed
    }
}

private struct NativeHeaderSearchAnchor: View {
    @Binding private var text: String
    @Binding private var isPresented: Bool
    private let focus: FocusState<Bool>.Binding
    private let placement: SearchFieldPlacement
    private let prompt: String
    @State private var draft: String

    init(
        text: Binding<String>,
        isPresented: Binding<Bool>,
        focus: FocusState<Bool>.Binding,
        placement: SearchFieldPlacement,
        prompt: String
    ) {
        _text = text
        _isPresented = isPresented
        self.focus = focus
        self.placement = placement
        self.prompt = prompt
        _draft = State(initialValue: text.wrappedValue)
    }

    var body: some View {
        Color.clear
            .searchable(text: $draft, isPresented: $isPresented, placement: placement, prompt: prompt)
            .searchFocused(focus)
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .onChange(of: draft) { _, proposedText in
                if HeaderSearchQueryRetentionPolicy.shouldApply(
                    proposedText: proposedText,
                    currentText: text,
                    isFocused: focus.wrappedValue,
                    isPresented: isPresented
                ) {
                    text = proposedText
                } else {
                    // Restore the local field value too; keeping only the model leaves UIKit blank.
                    draft = text
                }
            }
            .onChange(of: text) { _, newText in
                if text == newText, draft != newText { draft = newText }
            }
    }
}

private struct CollapsingScreenHeaderObserver: ViewModifier {
    @Binding var state: CollapsingScreenHeaderState
    var isEnabled: Bool
    var onUserScroll: () -> Void
    var animationObservation: CollapsingScreenHeaderObservation?
    @State private var fallbackObservation: CollapsingScreenHeaderObservation

    init(
        state: Binding<CollapsingScreenHeaderState>,
        isEnabled: Bool,
        onUserScroll: @escaping () -> Void,
        animationObservation: CollapsingScreenHeaderObservation?,
        minimumRemainingSpaceAfterCollapse: CGFloat?
    ) {
        _state = state
        self.isEnabled = isEnabled
        self.onUserScroll = onUserScroll
        self.animationObservation = animationObservation
        _fallbackObservation = State(initialValue: CollapsingScreenHeaderObservation(
            minimumRemainingSpaceAfterCollapse: minimumRemainingSpaceAfterCollapse
        ))
    }

    private var observation: CollapsingScreenHeaderObservation {
        animationObservation ?? fallbackObservation
    }

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { oldPhase, newPhase, context in
                var next = observation.trackedState
                observation.observePhase(
                    from: oldPhase,
                    to: newPhase,
                    geometry: CollapsingScreenHeaderState.Geometry(context.geometry),
                    state: &next,
                    isEnabled: isEnabled
                )
                apply(next)
                if newPhase == .interacting { onUserScroll() }
            }
            .onScrollGeometryChange(for: CollapsingScreenHeaderState.Geometry.self) {
                CollapsingScreenHeaderState.Geometry($0)
            } action: { _, geometry in
                var next = observation.trackedState
                observation.observeGeometry(geometry, state: &next, isEnabled: isEnabled)
                apply(next)
            }
            .onAppear {
                observation.trackedState = state
                reconcile(appearing: true)
            }
            .onChange(of: isEnabled) { _, _ in reconcile() }
            .onChange(of: ObjectIdentifier(observation)) { _, _ in
                observation.trackedState = state
                reconcile(appearing: true)
            }
            .onChange(of: state) { _, next in
                if next.isCollapsed != observation.trackedState.isCollapsed {
                    observation.invalidateTransition()
                }
                observation.trackedState = next
            }
            .onDisappear { observation.invalidateTransition() }
    }

    private func reconcile(appearing: Bool = false) {
        var next = observation.trackedState
        observation.reconcile(state: &next, isEnabled: isEnabled, appearing: appearing)
        apply(next)
    }

    private func apply(_ next: CollapsingScreenHeaderState) {
        observation.trackedState = next
        guard !next.matchesPresentation(of: state) else { return }
        if next.isCollapsed != state.isCollapsed {
            animationObservation?.prepareTransition(isCollapsed: next.isCollapsed)
        }
        // Native title and toolbar placement commit once, outside the controls' animation.
        withTransaction(Transaction(animation: nil)) { state = next }
    }
}

struct CollapsingScreenHeader<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isExpanded: Bool
    private let observation: CollapsingScreenHeaderObservation?
    private let onTransitionFinished: (UInt64) -> Void
    private let content: () -> Content
    @State private var presentedExpanded: Bool

    init(
        isExpanded: Bool,
        observation: CollapsingScreenHeaderObservation? = nil,
        onTransitionFinished: @escaping (UInt64) -> Void = { _ in },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isExpanded = isExpanded
        self.observation = observation
        self.onTransitionFinished = onTransitionFinished
        self.content = content
        _presentedExpanded = State(initialValue: isExpanded)
    }

    var body: some View {
        VStack(spacing: 0) {
            if presentedExpanded {
                content()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .allowsHitTesting(isExpanded)
        .accessibilityHidden(!isExpanded)
        .onChange(of: isExpanded) { _, expanded in
            let token = observation?.prepareTransition(isCollapsed: !expanded)
            withAnimation(AppSelectionTransition.animation(reduceMotion: reduceMotion), completionCriteria: .removed) {
                presentedExpanded = expanded
            } completion: {
                if let token { onTransitionFinished(token) }
            }
        }
        .onAppear {
            // A newly mounted header is already at its target and needs no animation.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { presentedExpanded = isExpanded }
            if let token = observation?.activeTransition { onTransitionFinished(token) }
        }
        .onDisappear { observation?.invalidateTransition() }
    }
}

private struct ScreenHeaderSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background(
            reduceTransparency
                ? AnyShapeStyle(AppColors.background)
                : AnyShapeStyle(Material.ultraThin)
        )
    }
}

private struct ScreenHeaderNavigationBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let isScrolled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if ScreenHeaderPlatform.usesNativeControls {
            content
        } else {
            content
                .toolbarBackground(
                    reduceTransparency
                        ? AnyShapeStyle(AppColors.background)
                        : AnyShapeStyle(Material.ultraThin),
                    for: .navigationBar
                )
                .toolbarBackground(isScrolled ? .visible : .automatic, for: .navigationBar)
        }
    }
}

extension View {
    func screenTitle(_ title: Text, presentation: ScreenTitlePresentation) -> some View {
        modifier(ScreenTitle(title: title, presentation: presentation))
    }

    @ViewBuilder
    func nativeScreenHeader(isEditing: Bool, minimizesOnScroll: Bool = true) -> some View {
#if !targetEnvironment(macCatalyst)
        if #available(iOS 27.0, *) {
            self.toolbarMinimizationBehavior(isEditing || !minimizesOnScroll ? .never : .onScrollDown, for: .navigationBar)
        } else { self }
#else
        self
#endif
    }

    func observesCollapsingHeader(
        _ state: Binding<CollapsingScreenHeaderState>,
        isEnabled: Bool = true,
        animationObservation: CollapsingScreenHeaderObservation? = nil,
        minimumRemainingSpaceAfterCollapse: CGFloat? = nil,
        onUserScroll: @escaping () -> Void = {}
    ) -> some View {
        modifier(CollapsingScreenHeaderObserver(
            state: state,
            isEnabled: isEnabled && ScreenHeaderPlatform.allowsCollapse,
            onUserScroll: onUserScroll,
            animationObservation: animationObservation,
            minimumRemainingSpaceAfterCollapse: minimumRemainingSpaceAfterCollapse
        ))
        .softScreenHeaderEdge()
    }

    func screenHeaderBackground(isScrolled: Bool) -> some View {
        modifier(ScreenHeaderNavigationBackground(isScrolled: isScrolled))
    }

    func screenHeaderSurface() -> some View {
        modifier(ScreenHeaderSurface())
    }

    /// Extends the system scroll-edge treatment beneath the screen's expanded controls.
    @ViewBuilder
    func screenHeaderBar<Header: View>(@ViewBuilder content: () -> Header) -> some View {
#if !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            self.safeAreaBar(edge: .top, spacing: 0, content: content)
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self.safeAreaInset(edge: .top, spacing: 0) {
                content().screenHeaderSurface()
            }
        }
#else
        self.safeAreaInset(edge: .top, spacing: 0) {
            content().screenHeaderSurface()
        }
#endif
    }

    @ViewBuilder
    func softScreenHeaderEdge() -> some View {
#if !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) { self.scrollEdgeEffectStyle(.soft, for: .top) }
        else { self }
#else
        self
#endif
    }

    /// Toggling the search anchor leaves the content and its scroll identity intact.
    func nativeHeaderSearch(
        isEnabled: Bool,
        text: Binding<String>,
        isPresented: Binding<Bool>,
        focus: FocusState<Bool>.Binding,
        placement: SearchFieldPlacement,
        prompt: String
    ) -> some View {
        background {
            if isEnabled {
                NativeHeaderSearchAnchor(
                    text: text,
                    isPresented: isPresented,
                    focus: focus,
                    placement: placement,
                    prompt: prompt
                )
            }
        }
    }
}

/// A real editable search field for compact navigation bars, beside the system Back button.
struct CompactHeaderSearchField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let prompt: String
    let accessibilityIdentifier: String
    let onSubmit: () -> Void

    func makeUIView(context: Context) -> UISearchTextField {
        let field = UISearchTextField(frame: .zero)
        field.font = .preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        field.adjustsFontForContentSizeCategory = false
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .search
        field.clearButtonMode = .whileEditing
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UISearchTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isFocused = $isFocused
        context.coordinator.onSubmit = onSubmit
        // Match the navigation row at every system text size.
        let contentSizeCategory = UIContentSizeCategory.large
        field.traitOverrides.preferredContentSizeCategory = contentSizeCategory
        field.font = .preferredFont(
            forTextStyle: .body,
            compatibleWith: UITraitCollection(traitsFrom: [
                UITraitCollection(preferredContentSizeCategory: contentSizeCategory),
                UITraitCollection(legibilityWeight: context.environment.legibilityWeight == .bold ? .bold : .regular)
            ])
        )
        field.placeholder = prompt
        field.accessibilityLabel = prompt
        field.accessibilityIdentifier = accessibilityIdentifier
        if field.markedTextRange == nil, field.text != text { field.text = text }
        if isFocused, !field.isFirstResponder, field.window != nil { field.becomeFirstResponder() }
        if !isFocused, field.isFirstResponder { field.resignFirstResponder() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISearchTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: width, height: AppDynamicTypeSizing.navigationSearchHeight)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>
        var onSubmit: () -> Void

        init(text: Binding<String>, isFocused: Binding<Bool>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.isFocused = isFocused
            self.onSubmit = onSubmit
        }

        func textFieldDidBeginEditing(_ textField: UITextField) { isFocused.wrappedValue = true }
        func textFieldDidEndEditing(_ textField: UITextField) { isFocused.wrappedValue = false }

        @objc func changed(_ field: UISearchTextField) {
            guard field.markedTextRange == nil else { return }
            text.wrappedValue = field.text ?? ""
        }

        func textFieldShouldClear(_ textField: UITextField) -> Bool {
            text.wrappedValue = ""
            return true
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            onSubmit()
            return false
        }
    }
}
