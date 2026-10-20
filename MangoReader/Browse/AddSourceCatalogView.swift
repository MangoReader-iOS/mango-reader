import MangoReaderDomain
import MangoReaderExtensions
import SwiftUI
import UIKit

struct AddSourceCatalogView: View {
    @Environment(AppModel.self) private var model
    let openRepositories: () -> Void
    @State private var searchText = ""
    @State private var isSearchingExtensions = false
    @State private var showsAddRepository = false
    @State private var sourcePendingRemoval: InstalledRepositorySource?


    var body: some View {
        ScrollViewReader { scrollProxy in
        List {
            if !isSearchingExtensions {
            Section("Local Files") {
                acquisitionButton(
                    title: "Import Local Files",
                    detail: "EPUB, PDF, CBZ, and ZIP",
                    identifier: "browse-import-local"
                ) {
                    model.transfersModel.isImporting = true
                }
                .id("source-acquisition")
            }
            .listRowBackground(Color.clear)
            .appFullWidthListSeparator()

            }

            Section {
                InlineExtensionSearchField(text: $searchText, isSearching: $isSearchingExtensions)
                    .id("extension-search")
                    .listRowSeparator(.hidden)
            } header: {
                Text("Extensions")
                    .accessibilityIdentifier("add-source-extensions")
            }
            .id("extension-search-section")
            .listRowBackground(Color.clear)

            if !updateItems.isEmpty {
                Section("Updates") {
                    ForEach(updateItems) { item in extensionRow(item) }
                }
                .accessibilityIdentifier("add-source-updates")
                .listRowBackground(Color.clear)
                .appFullWidthListSeparator()
            }

            Section {
                if model.sourcesModel.sourceRepositories.isEmpty {
                    RepositoryEmptyState(buttonIdentifier: "add-source-manual-repository") {
                        showsAddRepository = true
                    }
                } else if searchItems.isEmpty {
                    if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        AppInlineStatus(
                            title: "No matching extensions",
                            message: "Try a different extension name or publisher.",
                            systemImage: "magnifyingglass"
                        )
                    } else {
                        Text("No extensions").foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(otherItems) { item in extensionRow(item) }
                }
            }
            .listRowBackground(Color.clear)
            .appFullWidthListSeparator()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .appBackground()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Add Source")
        .navigationBarTitleDisplayMode(.inline)
        .appNativeNavigationChrome()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                FixedNavigationChrome {
                    if isSearchingExtensions {
                        Button("Cancel") {
                            searchText = ""
                            isSearchingExtensions = false
                        }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("add-source-extension-search-cancel")
                    } else {
                        Button("Repositories", action: openRepositories)
                            .accessibilityIdentifier("add-source-manage-repositories")
                    }
                }
            }
        }
        .onChange(of: isSearchingExtensions) { _, isSearching in
            scrollProxy.scrollTo(isSearching ? "extension-search" : "source-acquisition", anchor: .top)
        }
        .scrollBounceBehavior(.always, axes: .vertical)
        .refreshable { await model.sourcesModel.refreshRepositories() }
        .accessibilityAction(named: Text("Refresh repositories")) {
            Task { await model.sourcesModel.refreshRepositories() }
        }
        .sheet(isPresented: $showsAddRepository) {
            NavigationStack { AddRepositoryView(initialKindFilter: .content) }
            .appFeedbackOverlay()
        }
        .alert("Remove \(sourcePendingRemovalName)?", isPresented: Binding(
            get: { sourcePendingRemoval != nil },
            set: { if !$0 { sourcePendingRemoval = nil } }
        )) {
            Button("Remove", role: .destructive) {
                guard let sourcePendingRemoval else { return }
                Task { await model.removeInstalledRepositorySource(sourcePendingRemoval) }
                self.sourcePendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the source, package, saved credentials, cookies, and source settings from this device. Titles, downloads, reading progress, bookmarks, annotations, and custom covers remain in your library.")
        }
        }
    }

    private var allItems: [AggregateRepositoryEntry] {
        model.sourcesModel.sourceRepositories
            .filter { !$0.isBlocked }
            .flatMap { repository in
                repository.manifest.sources.compactMap { entry in
                    guard entry.kind == .content else { return nil }
                    return AggregateRepositoryEntry(repository: repository, entry: entry)
                }
            }
            .sorted {
                let nameOrder = $0.entry.name.localizedStandardCompare($1.entry.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                let repositoryOrder = $0.repository.manifest.repository.name.localizedStandardCompare(
                    $1.repository.manifest.repository.name
                )
                return repositoryOrder == .orderedSame
                    ? $0.id < $1.id
                    : repositoryOrder == .orderedAscending
            }
    }

    private var searchItems: [AggregateRepositoryEntry] {
        RepositoryExtensionSearch.results(
            in: allItems,
            query: searchText,
            language: nil,
            maturityRating: nil,
            availability: nil
        )
    }

    private var updateItems: [AggregateRepositoryEntry] {
        searchItems.filter {
            model.sourcesModel.repositorySourceHasUpdate(repositoryID: $0.repository.id, entryID: $0.entry.id)
        }
    }

    private var otherItems: [AggregateRepositoryEntry] {
        let updateIDs = Set(updateItems.map(\.id))
        return searchItems.filter { !updateIDs.contains($0.id) }
    }

    private var sourcePendingRemovalName: String {
        guard let sourcePendingRemoval else { return "Source" }
        return allItems.first(where: {
            $0.repository.id == sourcePendingRemoval.repositoryID && $0.entry.id == sourcePendingRemoval.sourceID
        })?.entry.name ?? sourcePendingRemoval.descriptor.name
    }

    private func acquisitionButton(
        title: String,
        detail: String? = nil,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: detail == nil ? 0 : 8, leading: AppLayout.pageMargin, bottom: detail == nil ? 0 : 8, trailing: AppLayout.pageMargin))
        .accessibilityIdentifier(identifier)
    }

    private func extensionRow(_ item: AggregateRepositoryEntry) -> some View {
        RepositorySourceRow(
            repositoryID: item.repository.id,
            entryID: item.entry.id,
            showsNewFlair: item.repository.isNewSource(item.entry.id),
            showsRepositoryName: model.sourcesModel.sourceRepositories.filter { !$0.isBlocked }.count > 1,
            identifierPrefix: "add-source-\(item.repository.id)",
            onRequestRemoval: { sourcePendingRemoval = $0 }
        )
    }
}

private struct InlineExtensionSearchField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isSearching: Bool

    func makeUIView(context: Context) -> UISearchTextField {
        let field = UISearchTextField(frame: .zero)
        field.placeholder = String(localized: "Search Extensions")
        field.accessibilityLabel = String(localized: "Search Extensions")
        field.accessibilityIdentifier = "add-source-extension-search-field"
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .search
        field.clearButtonMode = .whileEditing
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UISearchTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isSearching = $isSearching
        if field.text != text { field.text = text }
        if !isSearching, field.isFirstResponder { field.resignFirstResponder() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISearchTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: max(44, (uiView.font?.lineHeight ?? 20) + 16))
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, isSearching: $isSearching) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var isSearching: Binding<Bool>

        init(text: Binding<String>, isSearching: Binding<Bool>) {
            self.text = text
            self.isSearching = isSearching
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !isSearching.wrappedValue { isSearching.wrappedValue = true }
        }

        @objc func changed(_ field: UISearchTextField) {
            text.wrappedValue = field.text ?? ""
        }

        func textFieldShouldClear(_ textField: UITextField) -> Bool {
            text.wrappedValue = ""
            return true
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }
}
