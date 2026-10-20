import MangoReaderDomain
import MangoReaderExtensions
import SwiftUI

struct RepositoryCatalogView: View {
    @Environment(AppModel.self) private var model
    let repositoryID: String
    let fallbackRecord: RepositoryRecord
    let initialKindFilter: ExtensionKind?
    let presentationContext: RepositoryPresentationContext
    let scopedSourceIDs: Set<String>?
    @State private var searchText = ""
    @State private var refreshError: String?
    @State private var sourcePendingRemoval: InstalledRepositorySource?

    init(
        record: RepositoryRecord,
        initiallySelectedSourceIDs: Set<String> = [],
        initialKindFilter: ExtensionKind? = nil,
        presentationContext: RepositoryPresentationContext = .browse
    ) {
        repositoryID = record.id
        fallbackRecord = record
        self.initialKindFilter = initialKindFilter
        self.presentationContext = presentationContext
        scopedSourceIDs = initiallySelectedSourceIDs.isEmpty ? nil : initiallySelectedSourceIDs
    }

    init(
        repositoryID: String,
        fallbackRecord: RepositoryRecord,
        initialKindFilter: ExtensionKind? = nil,
        presentationContext: RepositoryPresentationContext = .browse
    ) {
        self.repositoryID = repositoryID
        self.fallbackRecord = fallbackRecord
        self.initialKindFilter = initialKindFilter
        self.presentationContext = presentationContext
        scopedSourceIDs = nil
    }

    private var record: RepositoryRecord {
        model.sourcesModel.sourceRepositories.first(where: { $0.id == repositoryID }) ?? fallbackRecord
    }

    private var visibleEntries: [SourceRepositoryEntry] {
        record.manifest.sources(matching: initialKindFilter).filter { entry in
            guard scopedSourceIDs?.contains(entry.id) ?? true else { return false }
            let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return true }
            return entry.name.localizedCaseInsensitiveContains(term)
                || entry.description.localizedCaseInsensitiveContains(term)
                || entry.languages.contains(where: { $0.localizedCaseInsensitiveContains(term) })
                || entry.developers.contains(where: { $0.name.localizedCaseInsensitiveContains(term) })
        }
    }

    var body: some View {
        List {
            Section {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 5) {
                        if !record.manifest.repository.description.isEmpty {
                            Text(record.manifest.repository.description)
                                .font(.subheadline)
                        }
                        Text(record.manifest.repository.publisher.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let url = repositoryMetadataURL(
                        record.manifest.repository.privacyURL,
                        relativeTo: record.repositoryURL
                    ) {
                        Link("Privacy Policy", destination: url)
                            .accessibilityIdentifier("repository-publisher-privacy")
                    }
                } label: {
                    Text("About")
                        .accessibilityIdentifier("repository-about")
                }
            }
            .browseFullWidthListRow()

            if let refreshError {
                Section {
                    Text(refreshError)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        Task { await refresh() }
                    }
                    .disabled(model.sourcesModel.isRefreshingRepositories)
                    .accessibilityIdentifier("repository-catalog-refresh-retry")
                }
                .browseFullWidthListRow()
            }

            Section("Extensions") {
                if visibleEntries.isEmpty {
                    AppInlineStatus(
                        title: record.manifest.sources.isEmpty ? "No extensions" : "No matching extensions",
                        message: record.manifest.sources.isEmpty
                            ? (record.manifest.repository.description.isEmpty
                               ? "This repository has not published any extensions."
                               : record.manifest.repository.description)
                            : (searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                               ? "This repository has no extensions in this category."
                               : "Try a different extension name or publisher."),
                        systemImage: record.manifest.sources.isEmpty ? "shippingbox" : "magnifyingglass"
                    )
                } else {
                    ForEach(visibleEntries) { entry in
                        RepositorySourceRow(
                            repositoryID: repositoryID,
                            entryID: entry.id,
                            showsNewFlair: record.isNewSource(entry.id),
                            onRequestRemoval: { sourcePendingRemoval = $0 }
                        )
                    }
                }
            }
            .browseFullWidthListRow()
            let unavailable = model.sourcesModel.installedRepositorySources.filter { installed in
                installed.repositoryID == repositoryID && !record.manifest.sources.contains { $0.id == installed.sourceID }
            }
            if !unavailable.isEmpty {
                Section("Unavailable Extensions") {
                    ForEach(unavailable) { installed in
                        RepositorySourceRow(repositoryID: repositoryID, entryID: installed.sourceID,
                            showsNewFlair: false, onRequestRemoval: { sourcePendingRemoval = $0 })
                    }
                }
                .browseFullWidthListRow()
            }
        }
        .browseInsetGroupedList()
        .navigationTitle(record.manifest.repository.name)
        .navigationBarTitleDisplayMode(.inline)
        .appNativeNavigationChrome()
        .searchable(text: $searchText, prompt: "Search Extensions")
        .scrollBounceBehavior(.always, axes: .vertical)
        .refreshable { await refresh() }
        .accessibilityAction(named: Text("Refresh repository")) {
            Task { await refresh() }
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

    private var sourcePendingRemovalName: String {
        guard let sourcePendingRemoval else { return "Source" }
        return record.manifest.sources.first(where: { $0.id == sourcePendingRemoval.sourceID })?.name
            ?? sourcePendingRemoval.descriptor.name
    }

    private func refresh() async {
        let summary = await model.sourcesModel.refreshRepositories(repositoryIDs: [repositoryID])
        refreshError = summary.failures.first(where: { $0.repositoryID == repositoryID })?.message
    }

}
