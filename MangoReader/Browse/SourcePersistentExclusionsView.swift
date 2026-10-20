import MangoReaderDomain
import MangoReaderExtensions
import MangoReaderSources
import Observation
import SwiftUI

struct SourcePersistentExclusionsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    let source: SourceDescriptor
    let configuration: SourceSearchConfiguration?

    @State private var query = ""
    @State private var draft: [SourceSearchSelection] = []
    @State private var original: [SourceSearchSelection] = []
    @State private var suggestionLoader = SourceSuggestionLoader()
    @State private var didLoad = false
    @State private var validationMessage: String?
    @State private var suggestionRetryRevision = 0
    @State private var isConfirmingDiscard = false

    var body: some View {
        Group {
            if !didLoad {
                AppContentSkeleton(kind: .textRows, count: 3, label: String(localized: "Loading exclusions…"))
            } else if draft.isEmpty {
                ContentUnavailableView(
                    "No saved exclusions",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text(fields.isEmpty
                        ? "Adding saved rules requires this source’s supported search fields."
                        : "Search for a tag or other supported field to hide it while browsing \(source.name).")
                )
            } else {
                exclusionsList
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let validationMessage { Text(validationMessage).foregroundStyle(AppColors.warning).padding() }
        }
        .appBackground()
        .navigationTitle("Always Exclude")
        .navigationBarTitleDisplayMode(.inline)
        .appNativeNavigationChrome()
        .navigationBarBackButtonHidden()
        .modifier(SourceExclusionSearch(text: $query, isEnabled: !fields.isEmpty, suggestions: suggestionRows))
        .task(id: source.id) {
            guard !didLoad else { return }
            draft = model.sourcesModel.persistentSearchExclusions(for: source)
            original = draft
            didLoad = true
        }
        .task(id: "\(suggestionIdentity)|\(suggestionRetryRevision)") {
            if !fields.isEmpty { await loadSuggestions() }
        }
        .onChange(of: model.sourcesModel.cloudflareVerificationRevision) { _, _ in
            if suggestionLoader.isAwaitingVerification { suggestionRetryRevision &+= 1 }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                FixedNavigationChrome {
                    Button("Cancel") {
                        if draft != original { isConfirmingDiscard = true }
                        else { dismiss() }
                    }
                }
            }
            ToolbarItem(id: "source-settings-done", placement: .confirmationAction) {
                FixedNavigationChrome {
                    Button("Save") {
                        do {
                            try SourcePersistentExclusionPolicy.validateEdits(draft, original: original, configuration: configuration)
                            model.sourcesModel.setPersistentSearchExclusions(draft, for: source)
                            dismiss()
                        } catch { validationMessage = error.localizedDescription }
                    }
                    .accessibilityIdentifier("source-exclusions-save")
                }
            }
        }
        .interactiveDismissDisabled(draft != original)
        .confirmationDialog("Discard changes?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) { }
        }
    }

    private var exclusionsList: some View {
        List {
            Section("Always Exclude") {
                ForEach(draft) { selection in
                    HStack {
                        Label(selection.title, systemImage: "minus.circle.fill")
                            .foregroundStyle(AppColors.danger)
                        Spacer()
                        Text(fieldTitle(for: selection))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .swipeActions {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            draft.removeAll { $0.id == selection.id }
                        }
                    }
                    .contextMenu {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            draft.removeAll { $0.id == selection.id }
                        }
                    }
                }
            }
            .browseFullWidthListRow()
        }
        .browseInsetGroupedList()
    }

    private var fields: [SourceSearchField] {
        configuration?.fields.filter(\.supportsExclusion) ?? []
    }

    private var context: SourceCatalogQueryContext {
        SourceCatalogQueryParser.context(in: query, fields: fields)
    }

    private var suggestionIdentity: String {
        "\(context.field?.id ?? "all")|\(context.value)|\(draft.map(\.id).sorted().joined(separator: "&"))"
    }

    @ViewBuilder
    private var suggestionRows: some View {
        if context.field == nil, context.value.isEmpty {
            ForEach(fields) { field in
                Button {
                    query = "-\(field.queryPrefix)"
                } label: {
                    SourceSearchSuggestionRow(
                        title: "−\(field.queryPrefix)…",
                        subtitle: field.placeholder
                    )
                }
            }
        } else {
            ForEach(valueSuggestions) { suggestion in
                Button {
                    add(suggestion)
                } label: {
                    SourceSearchSuggestionRow(
                        title: SourceCatalogSuggestionPolicy.completionTitle(
                            for: suggestion,
                            configuration: exclusionConfiguration,
                            excluding: true
                        ),
                        subtitle: suggestion.subtitle
                    )
                }
            }
            if suggestionLoader.isLoading {
                Label("Loading suggestions…", systemImage: "ellipsis")
            } else if let suggestionError = suggestionLoader.errorMessage {
                Text(suggestionError)
                Button("Retry Suggestions") { suggestionRetryRevision &+= 1 }
            } else if !context.value.isEmpty, valueSuggestions.isEmpty {
                Text("No matching suggestions")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var exclusionConfiguration: SourceSearchConfiguration? {
        configuration.map { configuration in SourceSearchConfiguration(
            id: configuration.id,
            title: configuration.title,
            fields: fields,
            sortOptions: configuration.sortOptions,
            defaultSortID: configuration.defaultSortID
        ) }
    }

    private var valueSuggestions: [SourceSearchSuggestion] {
        SourceCatalogSuggestionPolicy.mergedSuggestions(
            context: context,
            configuration: exclusionConfiguration,
            remote: suggestionLoader.suggestions
        )
    }

    private func add(_ suggestion: SourceSearchSuggestion) {
        guard let exclusionConfiguration else { return }
        let proposed = SourceCatalogSuggestionPolicy.selecting(
            suggestion,
            configuration: exclusionConfiguration,
            excluding: true,
            current: draft
        )
        do {
            try SourcePersistentExclusionPolicy.validateEdits(proposed, original: original, configuration: configuration)
            draft = proposed
            validationMessage = nil
            query = ""
            suggestionLoader.clearSuggestions()
        } catch { validationMessage = error.localizedDescription }
    }

    private func loadSuggestions() async {
        let identity = suggestionIdentity
        await suggestionLoader.load(
            request: SourceSearchSuggestionRequest(
                fieldID: context.field?.id,
                query: context.value,
                selections: draft,
                limit: 20
            ),
            isCurrent: { suggestionIdentity == identity },
            fetch: { request in
                try await model.sourcesModel.sourceSearchSuggestions(for: source, request: request)
            },
            handleVerification: { model.sourcesModel.handleCloudflareHandoff($0) }
        )
    }

    private func fieldTitle(for selection: SourceSearchSelection) -> String {
        fields.first(where: { $0.id == selection.fieldID })?.title ?? selection.fieldID
    }
}

enum SourcePersistentExclusionPolicy {
    static func validateEdits(
        _ draft: [SourceSearchSelection],
        original: [SourceSearchSelection],
        configuration: SourceSearchConfiguration?
    ) throws {
        // Removing existing rules remains possible when the source is offline or changes its fields.
        guard draft.contains(where: { !original.contains($0) }) else { return }
        guard let configuration else {
            throw SourceSearchValidationError("Load source settings before adding saved exclusions.")
        }
        try configuration.validate(selections: draft)
    }
}

private struct SourceExclusionSearch<Suggestions: View>: ViewModifier {
    @Binding var text: String
    let isEnabled: Bool
    let suggestions: Suggestions

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Tag or filter")
                .searchSuggestions { suggestions }
        } else {
            content
        }
    }
}
