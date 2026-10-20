import MangoReaderDomain
import MangoReaderSources
import SwiftUI
import UIKit

struct SourceSearchFilterCapsules: View {
    let selections: [SourceSearchSelection]
    let configuration: SourceSearchConfiguration?
    let persistentExclusions: [SourceSearchSelection]
    let onChange: (SourceSearchSelection, SourceSearchPolarity?) -> Void

    var body: some View {
        if !selections.isEmpty {
            LibraryCategoryFlowLayout(spacing: 8) {
                ForEach(selections) { selection in
                    capsule(selection)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func capsule(_ selection: SourceSearchSelection) -> some View {
        let field = configuration?.fields.first { $0.id == selection.fieldID }
        let savedExclusion = SourceSearchFilterPolicy.isPersistentlyExcluded(selection, in: persistentExclusions)
        let effectivePolarity: SourceSearchPolarity = savedExclusion ? .exclude : selection.polarity
        return Menu {
            Section(selection.title) {
                Button { onChange(selection, .include) } label: {
                    if effectivePolarity == .include { Label("Include", systemImage: "checkmark") }
                    else { Text("Include") }
                }
                .disabled(field == nil || savedExclusion)
                if field?.supportsExclusion == true {
                    Button { onChange(selection, .exclude) } label: {
                        if effectivePolarity == .exclude { Label("Exclude", systemImage: "checkmark") }
                        else { Text("Exclude") }
                    }
                    .disabled(field?.supportsExclusion != true || savedExclusion)
                }
            }
            if savedExclusion {
                Text("Excluded in source settings")
                Button("Remove Temporary Filter") { onChange(selection, nil) }
            } else {
                Button("Remove Filter") { onChange(selection, nil) }
            }
        } label: {
            GlassCapsuleLabel(title: capsuleTitle(for: selection), allowsMultiline: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title(selection, field: field, polarity: effectivePolarity))
        .accessibilityValue(savedExclusion ? String(localized: "Excluded in source settings") : "")
        .accessibilityHint("Opens filter actions")
        .accessibilityIdentifier("source-search-filter-\(selection.fieldID)-\(selection.value)")
    }

    func capsuleTitle(for selection: SourceSearchSelection) -> String {
        let excluded = selection.polarity == .exclude
            || SourceSearchFilterPolicy.isPersistentlyExcluded(selection, in: persistentExclusions)
        let title = SourceCatalogFilterPolicy.chipTitle(for: selection, configuration: configuration)
        return excluded ? "-\(title)" : title
    }

    private func title(_ selection: SourceSearchSelection, field: SourceSearchField?, polarity: SourceSearchPolarity) -> String {
        if selection.fieldID == "tag" {
            return polarity == .include
                ? String(localized: "Include: \(selection.title)")
                : String(localized: "Exclude: \(selection.title)")
        }
        let fieldTitle = field?.title ?? selection.fieldID
        return polarity == .include
            ? String(localized: "Include \(fieldTitle): \(selection.title)")
            : String(localized: "Exclude \(fieldTitle): \(selection.title)")
    }
}

struct SourceSearchSuggestionRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let subtitle: String?

    var body: some View {
        #if targetEnvironment(macCatalyst)
        // Native Mac suggestion menus extract a single text title from a row.
        Text(subtitle.map { "\(title) · \($0)" } ?? title)
        #else
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))

        layout {
            Text(title)
                .lineLimit(AppDynamicTypeSizing.contentLineLimit(1, for: dynamicTypeSize))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(AppDynamicTypeSizing.contentLineLimit(1, for: dynamicTypeSize))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(
                        maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                        alignment: .leading
                    )
            }
        }
        .accessibilityElement(children: .combine)
        #endif
    }
}

/// The system owns text entry, suggestion placement and keyboard traversal.
struct SourceNativeSearch<Suggestions: View>: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var text: String
    @Binding var isPresented: Bool
    @Binding var isComposing: Bool
    let focus: FocusState<Bool>.Binding
    let placement: SearchFieldPlacement
    let prompt: String
    let suggestions: Suggestions
    @State private var draft: String

    init(text: Binding<String>, isPresented: Binding<Bool>, isComposing: Binding<Bool>,
         focus: FocusState<Bool>.Binding, placement: SearchFieldPlacement, prompt: String,
         suggestions: Suggestions) {
        _text = text; _isPresented = isPresented
        _isComposing = isComposing
        self.focus = focus; self.placement = placement; self.prompt = prompt
        self.suggestions = suggestions
        _draft = State(initialValue: text.wrappedValue)
    }

    func body(content: Content) -> some View {
        focusedNativeSearch(nativeSearch(content))
            .searchSuggestions { suggestions }
            .modifier(SourceSearchToolbarBehavior(isCompact: horizontalSizeClass == .compact))
            .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidChangeNotification)) { notification in
                guard focus.wrappedValue || isPresented, let field = notification.object as? UISearchTextField else { return }
                isComposing = field.markedTextRange != nil
            }
#if !targetEnvironment(macCatalyst)
            .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidEndEditingNotification)) { notification in
                guard isPresented, notification.object is UISearchTextField else { return }
                isComposing = false
                isPresented = false
            }
#endif
            .onChange(of: isComposing) { _, composing in
                if !composing, acceptsEditingChanges { text = draft }
            }
            .onChange(of: draft) { _, proposed in
                guard !isComposing else { return }
#if targetEnvironment(macCatalyst)
                text = proposed
#else
                if !proposed.isEmpty || text.isEmpty || isPresented {
                    text = proposed
                } else {
                    // Restoring a dismissed native field here can reopen search.
                    // Keep the model query and restore the draft when editing resumes.
                    focus.wrappedValue = false
                    isPresented = false
                }
#endif
            }
            .onChange(of: text) { _, value in if draft != value { draft = value } }
            .onChange(of: focus.wrappedValue) { _, focused in
#if targetEnvironment(macCatalyst)
                if focused { restoreSearchDraft() }
#endif
            }
            .onChange(of: isPresented) { _, presented in
                if presented { restoreSearchDraft() }
            }
    }

    @ViewBuilder
    private func focusedNativeSearch<Content: View>(_ content: Content) -> some View {
#if targetEnvironment(macCatalyst)
        content.searchFocused(focus)
#else
        content
#endif
    }

    private func restoreSearchDraft() {
        if draft != text { draft = text }
    }

    private var acceptsEditingChanges: Bool {
#if targetEnvironment(macCatalyst)
        focus.wrappedValue
#else
        isPresented
#endif
    }

    @ViewBuilder
    private func nativeSearch<Content: View>(_ content: Content) -> some View {
#if targetEnvironment(macCatalyst)
        // Mac toolbar fields remain visible and retain their text without a search controller binding.
        content.searchable(text: $draft, placement: placement, prompt: prompt)
#else
        content.searchable(text: $draft, isPresented: $isPresented, placement: placement, prompt: prompt)
#endif
    }

}

private struct SourceSearchToolbarBehavior: ViewModifier {
    let isCompact: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
#if targetEnvironment(macCatalyst)
        content
#else
        if #available(iOS 26.0, *) {
            content.searchToolbarBehavior(isCompact ? .minimize : .automatic)
        } else {
            content
        }
#endif
    }
}

struct SourceSearchResultsHeader: View {
    @Binding var selection: SourceSearchResultsLayout

    var body: some View {
        HStack(spacing: 8) {
            Text("Search Results")
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Search Results")
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("source-search-results-heading")
            Picker("Results Layout", selection: $selection) {
                Label("Grid", systemImage: "square.grid.2x2")
                    .labelStyle(.iconOnly).tag(SourceSearchResultsLayout.grid)
                Label("List", systemImage: "list.bullet")
                    .labelStyle(.iconOnly).tag(SourceSearchResultsLayout.list)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Results Layout")
            .accessibilityValue(selection == .grid ? Text("Grid") : Text("List"))
            .tint(.primary)
            .frame(width: AppDynamicTypeSizing.navigationLayoutPickerWidth)
            .accessibilityIdentifier("source-search-layout-picker")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appFixedNavigationChrome()
    }
}

struct SourceSearchWorkGrid: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ScaledMetric(relativeTo: .body)
    private var scaledMinimumCoverWidth = SourceCatalogCoverLayoutPolicy.baseMinimumWidth
    let works: [Work]

    var body: some View {
        LazyVGrid(
            columns: SourceCatalogCoverLayoutPolicy.columns(
                minimumCoverWidth: minimumCoverWidth,
                dynamicTypeSize: dynamicTypeSize,
                horizontalSizeClass: horizontalSizeClass
            ),
            alignment: .leading,
            spacing: PublicationGridLayout.verticalSpacing
        ) {
            ForEach(works) { work in
                NavigationLink {
                    WorkDetailView(work: work)
                } label: {
                    SourceLatestTile(work: work, presentation: .sourceSearch)
                }
                .buttonStyle(.plain)
                .id(work.id)
            }
        }
        .scrollTargetLayout()
    }

    private var minimumCoverWidth: CGFloat {
        SourceCatalogCoverLayoutPolicy.minimumCoverWidth(
            scaledWidth: scaledMinimumCoverWidth
        )
    }
}

struct SourceSearchWorkList: View {
    let works: [Work]

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(works) { work in
                NavigationLink {
                    WorkDetailView(work: work)
                } label: {
                    SourceSearchWorkListRow(work: work)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .id(work.id)

                Divider()
            }
        }
        .scrollTargetLayout()
    }
}

private struct SourceSearchWorkListRow: View {
    let work: Work

    var body: some View {
        SourceDenseWorkRowLayout(
            title: work.title,
            latestChapterTitle: work.latestChapterTitle,
            languageCode: work.languageCode,
            cover: RemoteCover(work: work)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens title details")
    }

    private var accessibilityLabel: String {
        SourceSearchResultAccessibilityPolicy.label(for: work)
    }
}
