import MangoReaderDomain
import SwiftUI
import UIKit

enum AppColors {
    // Preserve the original light accent; use stronger variants for dark mode and Increase Contrast.
    private static let normalActionUIColor = UIColor { traits in
        switch (traits.userInterfaceStyle, traits.accessibilityContrast) {
        case (.dark, .high): UIColor(red: 1, green: 0.82, blue: 0.54, alpha: 1)
        case (.dark, _): UIColor(red: 1, green: 0.624, blue: 0.039, alpha: 1)
        case (_, .high): UIColor(red: 0.478, green: 0.188, blue: 0, alpha: 1)
        default: UIColor.systemOrange.resolvedColor(with: traits)
        }
    }
    private static let normalActionFillUIColor = UIColor { traits in
        switch (traits.userInterfaceStyle, traits.accessibilityContrast) {
        case (.dark, .high): UIColor(red: 1, green: 0.77, blue: 0.47, alpha: 1)
        case (.dark, _): UIColor(red: 1, green: 0.624, blue: 0.039, alpha: 1)
        case (_, .high): UIColor(red: 1, green: 0.68, blue: 0.2, alpha: 1)
        default: UIColor(red: 1, green: 0.584, blue: 0, alpha: 1)
        }
    }
    static let privateActionUIColor = UIColor { traits in
        if traits.accessibilityContrast == .high {
            return traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.72, green: 0.74, blue: 1, alpha: 1)
                : UIColor(red: 0.26, green: 0.25, blue: 0.66, alpha: 1)
        }
        return UIColor.systemIndigo.resolvedColor(with: traits)
    }
    static var actionUIColor: UIColor { PrivateLibraryCoordinator.shared.model == nil ? normalActionUIColor : privateActionUIColor }
    static var actionFillUIColor: UIColor { PrivateLibraryCoordinator.shared.model == nil ? normalActionFillUIColor : privateActionUIColor }
    static var action: Color { Color(uiColor: actionUIColor) }
    static var actionFill: Color { Color(uiColor: actionFillUIColor) }
    static var onAction: Color {
        if PrivateLibraryCoordinator.shared.model != nil { return .white }
        return Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? .black : .white })
    }
    static let information = Color.blue
    static let success = Color.green
    static let warning = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .systemYellow
            : UIColor(red: 0.5, green: 0.333, blue: 0, alpha: 1)
    })
    static let danger = Color.red
    static let privacy = Color.indigo
    static let link = Color(uiColor: .link)

    static let background = Color(uiColor: .systemBackground)
    static let secondaryBackground = Color(uiColor: .secondarySystemBackground)
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let groupedSurface = Color(uiColor: .secondarySystemGroupedBackground)
    static let tertiaryFill = Color(uiColor: .tertiarySystemFill)
    static let separator = Color(uiColor: .separator)
}

enum AppLayout {
    static let pageMargin: CGFloat = 16
    static let sectionSpacing: CGFloat = 18
    static let cardPadding: CGFloat = 14
    static let cardCornerRadius: CGFloat = 18
}

enum AppDynamicTypeSizing {
    static let navigationSize = DynamicTypeSize.large
    static let navigationSearchHeight: CGFloat = 44
    static let navigationLayoutPickerWidth: CGFloat = 92
    static let minimumControlDimension: CGFloat = 44
    static let maximumControlDimension: CGFloat = 72
    static let iconControlDimension: CGFloat = 44
    static let compactChromeRange = DynamicTypeSize.xSmall ... DynamicTypeSize.xxxLarge

    static func controlDimension(scaledDimension: CGFloat) -> CGFloat {
        min(
            max(scaledDimension, minimumControlDimension),
            maximumControlDimension
        )
    }

    static func contentLineLimit(
        _ standardLimit: Int,
        for dynamicTypeSize: DynamicTypeSize
    ) -> Int? {
        dynamicTypeSize.isAccessibilitySize ? nil : standardLimit
    }
}

private struct AppContentDynamicTypeSizeKey: EnvironmentKey {
    static let defaultValue: DynamicTypeSize? = nil
}

extension EnvironmentValues {
    var appContentDynamicTypeSize: DynamicTypeSize? {
        get { self[AppContentDynamicTypeSizeKey.self] }
        set { self[AppContentDynamicTypeSizeKey.self] = newValue }
    }
}

/// Only bar content is fixed. Menus can restore the incoming content size.
struct FixedNavigationChrome<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.appContentDynamicTypeSize) private var contentTextSize
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .environment(\.appContentDynamicTypeSize, contentTextSize ?? textSize)
            .dynamicTypeSize(AppDynamicTypeSizing.navigationSize)
    }
}

struct NavigationMenuContent<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.appContentDynamicTypeSize) private var contentTextSize
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().environment(\.dynamicTypeSize, contentTextSize ?? textSize)
    }
}

extension View {
    func appFixedNavigationChrome() -> some View {
        FixedNavigationChrome { self }
    }

    /// Native bars are siblings of page content; constrain those views only.
    func appNativeNavigationChrome() -> some View {
        background(NativeNavigationChromeSizing())
    }
}

struct NativeNavigationChromeSizing: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.updateBars()
    }

    final class Controller: UIViewController {
        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            updateBars()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            updateBars()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            updateBars()
        }

        func updateBars() {
            guard let navigation = navigationController else { return }
            Self.fix(navigation.navigationBar)
            Self.fix(navigation.toolbar)
            // Expanded search can move out of the navigation bar into its own
            // container. Match only public search-control types in this stack.
            Self.fixSearchFields(in: navigation.view)
            if let search = navigation.topViewController?.navigationItem.searchController {
                Self.fix(search.searchBar)
                Self.fixSearchFields(in: search.searchBar)
            }
        }

        private static func fixSearchFields(in view: UIView) {
            if view is UISearchBar { fix(view) }
            if let field = view as? UISearchTextField {
                fix(field)
                field.adjustsFontForContentSizeCategory = false
                let traits = UITraitCollection(traitsFrom: [field.traitCollection,
                    UITraitCollection(preferredContentSizeCategory: .large)])
                let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
                if field.font != font { field.font = font }
            }
            for child in view.subviews { fixSearchFields(in: child) }
        }

        private static func fix(_ view: UIView) {
            if view.minimumContentSizeCategory != .large { view.minimumContentSizeCategory = .large }
            if view.maximumContentSizeCategory != .large { view.maximumContentSizeCategory = .large }
            if !view.traitOverrides.contains(UITraitPreferredContentSizeCategory.self)
                || view.traitOverrides.preferredContentSizeCategory != .large {
                view.traitOverrides.preferredContentSizeCategory = .large
            }
            view.updateTraitsIfNeeded()
        }
    }
}

enum GlassCapsuleLayout {
    static let effectContainerSpacing: CGFloat = 0
    static let compactSpacing: CGFloat = 12
}

private struct AppIconControlFrame: ViewModifier {
    var dimension = AppDynamicTypeSizing.iconControlDimension
    func body(content: Content) -> some View {
        content
            .dynamicTypeSize(AppDynamicTypeSizing.navigationSize)
            .frame(
                width: dimension,
                height: dimension
            )
            .contentShape(Rectangle())
    }
}

private struct AppFluidControlValueTransition<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let value: Value

    func body(content: Content) -> some View {
        content
            .contentTransition(accessibilityReduceMotion ? .identity : .opacity)
            .animation(
                accessibilityReduceMotion
                    ? nil
                    : .smooth(duration: 0.22, extraBounce: 0),
                value: value
            )
    }
}

struct GlassCapsuleGroup<Content: View>: View {
    let spacing: CGFloat
    private let content: Content

    init(
        spacing: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
#if targetEnvironment(macCatalyst)
        content
#else
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
#endif
    }
}

struct NativeMenuPicker<Selection: Hashable>: UIViewRepresentable {
    @Environment(\.legibilityWeight) private var legibilityWeight
    @ScaledMetric(relativeTo: .body) private var scaledFontSize: CGFloat = 17
    let title: String
    @Binding var selection: Selection
    let options: [(title: String, value: Selection)]
    var visibleTitle: String? = nil

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        button.changesSelectionAsPrimaryAction = true
        button.contentHorizontalAlignment = .leading
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.changesSelectionAsPrimaryAction = visibleTitle == nil
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        let selectedTitle = options.first { $0.value == selection }?.title
        configuration.title = visibleTitle ?? selectedTitle
        configuration.titleLineBreakMode = .byWordWrapping
        let font = UIFont.systemFont(ofSize: scaledFontSize, weight: legibilityWeight == .bold ? .semibold : .regular)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = font
            return attributes
        }
        button.configuration = configuration
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.menu = UIMenu(options: .singleSelection, children: options.map { option in
            UIAction(title: option.title, state: option.value == selection ? .on : .off) { _ in
                selection = option.value
            }
        })
        button.accessibilityLabel = title
        button.accessibilityValue = selectedTitle
        button.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        let width = min(uiView.intrinsicContentSize.width, proposal.width ?? .greatestFiniteMagnitude)
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(
            width: width,
            height: max(44, size.height)
        )
    }
}

/// Keeps native segment selection and accessibility while scaling image-only controls.
struct NativeIconSegmentedPicker<Selection: Hashable>: UIViewRepresentable {
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var scaledDimension: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var scaledSymbolSize: CGFloat = 17

    let title: String
    @Binding var selection: Selection
    let options: [(title: String, systemImage: String, value: Selection)]

    private var dimension: CGFloat {
        AppDynamicTypeSizing.controlDimension(scaledDimension: scaledDimension)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl()
        control.addTarget(context.coordinator, action: #selector(Coordinator.selectSegment(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.picker = self
        if control.numberOfSegments != options.count {
            control.removeAllSegments()
            for index in options.indices {
                control.insertSegment(withTitle: nil, at: index, animated: false)
            }
        }
        let configuration = UIImage.SymbolConfiguration(
            // Native segments need room for their symbol's optical bounds and vertical padding.
            pointSize: min(scaledSymbolSize, dimension - 24),
            weight: legibilityWeight == .bold ? .semibold : .regular
        )
        for (index, option) in options.enumerated() {
            let image = UIImage(systemName: option.systemImage, withConfiguration: configuration)
            image?.accessibilityLabel = option.title
            control.setImage(image, forSegmentAt: index)
            control.setWidth(dimension, forSegmentAt: index)
        }
        control.selectedSegmentIndex = options.firstIndex { $0.value == selection } ?? UISegmentedControl.noSegment
        control.tintColor = .label
        control.isEnabled = isEnabled
        control.accessibilityLabel = title
        control.accessibilityValue = options.first { $0.value == selection }?.title
        control.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        // UIKit rounds the native segment height up by one point at the upper bound.
        CGSize(
            width: dimension * CGFloat(options.count),
            height: min(dimension, AppDynamicTypeSizing.maximumControlDimension - 1)
        )
    }

    final class Coordinator: NSObject {
        var picker: NativeIconSegmentedPicker

        init(_ picker: NativeIconSegmentedPicker) { self.picker = picker }

        @objc func selectSegment(_ control: UISegmentedControl) {
            guard picker.options.indices.contains(control.selectedSegmentIndex) else { return }
            let option = picker.options[control.selectedSegmentIndex]
            control.accessibilityValue = option.title
            picker.selection = option.value
        }
    }
}

enum GlassCapsuleLabelSize {
    case standard
    case metadataCompact

    var font: Font {
        switch self {
        case .standard:
            .subheadline.weight(.semibold)
        case .metadataCompact:
            .caption.weight(.semibold)
        }
    }

    var minimumHeight: CGFloat {
        switch self {
        case .standard: 44
        case .metadataCompact: 32
        }
    }

}

struct GlassCapsuleLabel: View {
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var scaledStandardHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .caption) private var scaledMetadataHeight: CGFloat = 32
    @ScaledMetric(relativeTo: .subheadline) private var scaledStandardPadding: CGFloat = 12
    @ScaledMetric(relativeTo: .caption) private var scaledMetadataPadding: CGFloat = 10
    @ScaledMetric(relativeTo: .caption2) private var scaledBadgeDimension: CGFloat = 20
    @ScaledMetric(relativeTo: .caption2) private var scaledBadgePadding: CGFloat = 6

    var title: String? = nil
    var badgeCount: Int? = nil
    var systemImage: String? = nil
    var active = false
    var tint = AppColors.action
    var showsChevron = false
    var trailingSystemImage: String? = nil
    var isInteractive = true
    var allowsMultiline = false
    var size: GlassCapsuleLabelSize = .standard
    var usesSolidFill = false
    var usesSolidActiveFill = false

    var body: some View {
        Group {
            if usesSolidFill {
                solidLabel
            } else if active, usesSolidActiveFill {
                solidActiveLabel
            } else if accessibilityReduceTransparency {
                solidLabel
            } else {
#if targetEnvironment(macCatalyst)
                materialLabel
#else
                if #available(iOS 26.0, *) {
                    labelContent
                        .glassEffect(glass, in: .capsule)
                } else {
                    materialLabel
                }
#endif
            }
        }
        .appFluidControlValueTransition(value: transitionState)
    }

    @available(iOS 26.0, *)
    private var glass: Glass {
        let base = active
            ? Glass.regular.tint(tint.opacity(activeFillOpacity))
            : Glass.regular
        return isInteractive ? base.interactive() : base
    }

    private var labelContent: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.semibold))
            }
            titleLabel
            if let badgeCount, badgeCount > 0 {
                Text(badgeCount.formatted())
                    .font(.caption2.bold())
                    .contentTransition(.numericText(value: Double(badgeCount)))
                    .foregroundStyle(AppColors.onAction)
                    .padding(.horizontal, min(scaledBadgePadding, 12))
                    .frame(
                        minWidth: min(scaledBadgeDimension, 36),
                        minHeight: min(scaledBadgeDimension, 36)
                    )
                    .background(AppColors.actionFill, in: Capsule())
                    .accessibilityHidden(true)
            }
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .font(size.font)
        .foregroundStyle(active && usesSolidActiveFill ? AppColors.onAction : active ? tint : Color.primary)
        .padding(
            .horizontal,
            title == nil && badgeCount == nil ? 0 : horizontalPadding
        )
        .frame(minWidth: minimumHeight, minHeight: minimumHeight)
        .contentShape(Capsule())
    }

    @ViewBuilder
    private var titleLabel: some View {
        if let title {
            if allowsMultiline || (size == .metadataCompact && dynamicTypeSize.isAccessibilitySize) {
                Text(title)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(title)
                    .lineLimit(1)
            }
        }
    }

    private var materialLabel: some View {
        labelContent
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(borderColor, lineWidth: borderWidth)
            }
    }

    private var solidLabel: some View {
        labelContent
            .background(
                active
                    ? tint.opacity(activeFillOpacity)
                    : AppColors.secondaryBackground,
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(borderColor, lineWidth: borderWidth)
            }
    }

    private var solidActiveLabel: some View {
        labelContent
            .background(AppColors.actionFill, in: Capsule())
    }

    private var activeFillOpacity: Double {
        colorSchemeContrast == .increased ? 0.28 : colorScheme == .light ? 0.12 : 0.18
    }

    private var borderColor: Color {
        if active {
            tint.opacity(colorSchemeContrast == .increased ? 1 : 0.7)
        } else if colorSchemeContrast == .increased {
            Color.primary.opacity(0.55)
        } else {
            AppColors.tertiaryFill
        }
    }

    private var borderWidth: CGFloat {
        colorSchemeContrast == .increased ? 1.5 : 1
    }

    private var transitionState: TransitionState {
        TransitionState(
            title: title,
            badgeCount: badgeCount,
            systemImage: systemImage,
            active: active
        )
    }

    private var minimumHeight: CGFloat {
        let scaledHeight = switch size {
        case .standard:
            scaledStandardHeight
        case .metadataCompact:
            scaledMetadataHeight
        }
        let minimum = isInteractive
            ? AppDynamicTypeSizing.minimumControlDimension
            : size.minimumHeight
        return min(max(scaledHeight, minimum), AppDynamicTypeSizing.maximumControlDimension)
    }

    private struct TransitionState: Equatable {
        let title: String?
        let badgeCount: Int?
        let systemImage: String?
        let active: Bool
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .standard:
            min(scaledStandardPadding, 24)
        case .metadataCompact:
            min(scaledMetadataPadding, 20)
        }
    }
}

struct IncognitoStatusIndicator: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @ScaledMetric(relativeTo: .caption) private var scaledDimension: CGFloat = 32

    var body: some View {
        Image(systemName: "eye.slash.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(AppColors.privacy)
            .frame(
                width: min(scaledDimension, 44),
                height: min(scaledDimension, 44)
            )
            .background(AppColors.privacy.opacity(
                colorSchemeContrast == .increased ? 0.24 : 0.14
            ), in: Circle())
            .overlay {
                Circle()
                    .stroke(
                        AppColors.privacy.opacity(colorSchemeContrast == .increased ? 0.9 : 0.45),
                        lineWidth: colorSchemeContrast == .increased ? 1.5 : 0.5
                    )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Incognito Reading On")
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier("incognito-status-indicator")
    }
}

struct AppInlineStatus: View {
    let title: String
    let message: String
    var systemImage: String? = nil
    var tint: Color? = nil
    var actionTitle: String? = nil
    var actionSystemImage: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
                .font(.headline)
                .foregroundStyle(tint ?? Color.primary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                if let actionSystemImage {
                    Button(actionTitle, systemImage: actionSystemImage, action: action)
                        .buttonStyle(.bordered)
                } else {
                    Button(actionTitle, action: action)
                        .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum PublicationGridLayout {
    static let contentMargin = AppLayout.pageMargin
    static let horizontalSpacing: CGFloat = 12
    static let verticalSpacing: CGFloat = 16
    static let compactMinimumWidth: CGFloat = 100
    static let compactAccessibilityMinimumWidth: CGFloat = 145

    static func minimumWidth(
        for dynamicTypeSize: DynamicTypeSize,
        horizontalSizeClass: UserInterfaceSizeClass?,
        regularMinimumWidth: CGFloat
    ) -> CGFloat {
        guard horizontalSizeClass == .compact else { return regularMinimumWidth }
        return dynamicTypeSize.isAccessibilitySize
            ? compactAccessibilityMinimumWidth
            : compactMinimumWidth
    }

    static func columns(
        for dynamicTypeSize: DynamicTypeSize,
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> [GridItem] {
        let minimumWidth = minimumWidth(
            for: dynamicTypeSize,
            horizontalSizeClass: horizontalSizeClass,
            regularMinimumWidth: dynamicTypeSize.isAccessibilitySize ? 200 : 150
        )
        let size: GridItem.Size = dynamicTypeSize.isAccessibilitySize
            ? .adaptive(minimum: minimumWidth)
            : .adaptive(minimum: minimumWidth, maximum: 210)
        return [GridItem(size, spacing: horizontalSpacing, alignment: .top)]
    }
}

struct PublicationGridTitle: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    var lineLimit = 2

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(title)
                    .lineLimit(lineLimit, reservesSpace: true)
                    .truncationMode(.tail)
            }
        }
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    func appFluidControlValueTransition<Value: Equatable>(value: Value) -> some View {
        modifier(AppFluidControlValueTransition(value: value))
    }

    func appIconControlFrame(dimension: CGFloat = AppDynamicTypeSizing.iconControlDimension) -> some View {
        modifier(AppIconControlFrame(dimension: dimension))
    }

    func appBackground() -> some View {
        background(AppColors.background.ignoresSafeArea())
    }

    func appInsetGroupedList() -> some View {
        listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .appBackground()
    }

    func appGroupedForm() -> some View {
        scrollContentBackground(.hidden)
            .appBackground()
    }

    func appFullWidthListSeparator() -> some View {
        alignmentGuide(.listRowSeparatorLeading) { dimensions in
            dimensions[.leading]
        }
    }

    func appListRow() -> some View {
        listRowBackground(AppColors.secondaryBackground)
    }

    func appFullWidthListRow() -> some View {
        appListRow()
            .appFullWidthListSeparator()
    }

    @ViewBuilder
    func browseInsetGroupedList(enabled: Bool = true) -> some View {
        if enabled {
            listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(AppColors.groupedBackground.ignoresSafeArea())
        } else {
            appInsetGroupedList()
        }
    }

    @ViewBuilder
    func browseGroupedForm(enabled: Bool = true) -> some View {
        if enabled {
            scrollContentBackground(.hidden)
                .background(AppColors.groupedBackground.ignoresSafeArea())
        } else {
            appGroupedForm()
        }
    }

    @ViewBuilder
    func browseListRow(enabled: Bool = true) -> some View {
        if enabled {
            listRowBackground(AppColors.groupedSurface)
        } else {
            appListRow()
        }
    }

    func browseFullWidthListRow(enabled: Bool = true) -> some View {
        browseListRow(enabled: enabled)
            .appFullWidthListSeparator()
    }

    func appCard() -> some View {
        padding(AppLayout.cardPadding)
            .background(
                AppColors.secondaryBackground,
                in: RoundedRectangle(
                    cornerRadius: AppLayout.cardCornerRadius,
                    style: .continuous
                )
            )
    }
}

struct CoverPlaceholder: View {
    let work: Work

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            VStack(spacing: width * 0.075) {
                Text(title)
                    .font(.system(size: max(5, min(width * 0.16, 30)), weight: .medium, design: .serif))
                    .foregroundStyle(.primary)
                    .lineLimit(5)
                    .minimumScaleFactor(0.65)
                    .layoutPriority(1)

                if width >= 64, !authorNames.isEmpty {
                    Rectangle()
                        .fill(.primary.opacity(0.18))
                        .frame(width: width * 0.2, height: 1)
                    Text(authorNames)
                        .font(.system(size: max(5, min(width * 0.075, 13)), design: .serif))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
            }
            .multilineTextAlignment(.center)
            .padding(width * 0.12)
            .frame(width: width, height: geometry.size.height)
            .background(AppColors.secondaryBackground)
            .clipped()
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var title: String {
        let title = work.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "Untitled") : title
    }

    private var authorNames: String {
        work.authors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
