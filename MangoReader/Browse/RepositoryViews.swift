import MangoReaderDomain
import MangoReaderExtensions
import SwiftUI

func repositoryMetadataURL(_ value: String, relativeTo baseURL: URL) -> URL? {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    return try? RepositoryURLPolicy.resolvedURL(value, relativeTo: baseURL)
}

struct RepositoryLinkRequest: Identifiable, Equatable {
    let id = UUID()
    var repositoryURL: URL
    var sourceIDs: [String]
}

extension SourceRepositoryManifestV2 {
    func sources(matching kind: ExtensionKind?) -> [SourceRepositoryEntry] {
        guard let kind else { return sources }
        return sources.filter { $0.kind == kind }
    }
}

struct AggregateRepositoryEntry: Identifiable, Sendable {
    let repository: RepositoryRecord
    let entry: SourceRepositoryEntry

    nonisolated var id: String { "\(repository.id)::\(entry.id)" }
}

enum RepositoryExtensionSearch {
    nonisolated static func results(
        in items: [AggregateRepositoryEntry],
        query: String,
        language: String?,
        maturityRating: RepositoryMaturityRating?,
        availability: ExtensionAvailability?
    ) -> [AggregateRepositoryEntry] {
        let term = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))

        return items.compactMap { item -> (rank: Int, item: AggregateRepositoryEntry)? in
            let entry = item.entry
            if let language, !entry.languages.contains(language) { return nil }
            guard maturityRating == nil || entry.maturityRating == maturityRating else { return nil }
            guard availability == nil || entry.availability == availability else { return nil }

            guard !term.isEmpty else { return (0, item) }
            guard let rank = relevanceRank(for: item, term: term) else { return nil }
            return (rank, item)
        }
        .sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }

            let nameOrder = lhs.item.entry.name.localizedStandardCompare(rhs.item.entry.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }

            let repositoryOrder = lhs.item.repository.manifest.repository.name.localizedStandardCompare(
                rhs.item.repository.manifest.repository.name
            )
            if repositoryOrder != .orderedSame { return repositoryOrder == .orderedAscending }
            return lhs.item.id < rhs.item.id
        }
        .map(\.item)
    }

    private nonisolated static func relevanceRank(
        for item: AggregateRepositoryEntry,
        term: String
    ) -> Int? {
        let entry = item.entry
        let name = normalized(entry.name)
        if name == term { return 0 }
        if name.hasPrefix(term) { return 1 }
        if name.contains(term) { return 2 }

        let repository = item.repository.manifest.repository
        let publisherFields = [repository.name, repository.publisher.name]
            + entry.developers.map(\.name)
        if publisherFields.contains(where: { normalized($0).contains(term) }) { return 3 }
        if entry.languages.contains(where: { normalized($0).contains(term) }) { return 4 }
        if normalized(entry.description).contains(term) { return 5 }
        return nil
    }

    private nonisolated static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
    }
}

enum RepositoryPresentationContext: Equatable {
    case browse
    case trackerSettings
    case settings

    var usesBrowsePalette: Bool { self == .browse }
    func showsRefreshSummary(failedCount: Int) -> Bool {
        failedCount > 0
    }
}

struct RepositoryEmptyState: View {
    let buttonIdentifier: String
    let addRepository: () -> Void

    var body: some View {
        SettingsEmptyCardContent {
            Text("Add a repository to browse extensions.")
        } action: {
            Button("Add Repository", action: addRepository)
                .accessibilityIdentifier(buttonIdentifier)
        }
    }
}

protocol RepositoryFilterDisplayable {
    nonisolated var repositoryFilterDisplayName: String { get }
}

extension ExtensionAvailability: RepositoryFilterDisplayable {
    nonisolated var repositoryFilterDisplayName: String {
        switch self {
        case .available: "Available"
        case .serviceUnavailable: "Service unavailable"
        case .retired: "Retired"
        }
    }
}

extension ExtensionKind: RepositoryFilterDisplayable {
    nonisolated var repositoryFilterDisplayName: String {
        switch self {
        case .content: "Content"
        case .tracker: "Tracker"
        }
    }
}

extension RepositoryMaturityRating: RepositoryFilterDisplayable {
    nonisolated var repositoryFilterDisplayName: String {
        switch self {
        case .safe: "Safe"
        case .mature: "Mature"
        case .adult: "Adult"
        }
    }
}

struct RepositoryManagerView: View {
    @Environment(AppModel.self) private var model
    let initialKindFilter: ExtensionKind?
    let presentationContext: RepositoryPresentationContext
    @State private var showsAddRepository = false
    @State private var removal: RepositoryRecord?

    init(
        initialKindFilter: ExtensionKind? = nil,
        presentationContext: RepositoryPresentationContext = .browse
    ) {
        self.initialKindFilter = initialKindFilter
        self.presentationContext = presentationContext
    }

    var body: some View {
        List {
            if let summary = model.sourcesModel.repositoryRefreshSummary,
               presentationContext.showsRefreshSummary(failedCount: summary.failedCount) {
                Section("Last Refresh") {
                    Text(model.sourcesModel.repositoryRefreshSummaryText)
                        .foregroundStyle(AppColors.warning)
                        .accessibilityIdentifier("repository-refresh-summary")
                    if summary.failedCount > 0 {
                        Button("Try Again") {
                            Task { await model.sourcesModel.retryFailedRepositoryRefreshes() }
                        }
                        .disabled(model.sourcesModel.isRefreshingRepositories)
                        .accessibilityIdentifier("repository-refresh-retry")
                    }
                }
                .browseFullWidthListRow()
            }

            Section {
                if model.sourcesModel.sourceRepositories.isEmpty {
                    RepositoryEmptyState(buttonIdentifier: "repository-manual-add") {
                        showsAddRepository = true
                    }
                } else {
                    ForEach(model.sourcesModel.sourceRepositories) { record in
                        NavigationLink {
                            RepositoryCatalogView(
                                repositoryID: record.id,
                                fallbackRecord: record,
                                initialKindFilter: initialKindFilter,
                                presentationContext: presentationContext
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(record.manifest.repository.name)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                let count = record.manifest.sources(matching: initialKindFilter).count
                                Text(count == 1 ? "1 extension" : "\(count) extensions")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Remove", role: .destructive) {
                                removal = record
                            }
                            .accessibilityLabel("Remove \(record.manifest.repository.name)")
                        }
                        .contextMenu {
                            Button("Remove Repository", role: .destructive) {
                                removal = record
                            }
                        }
                    }
                }
            }
            .browseFullWidthListRow()
        }
        .browseInsetGroupedList()
        .accessibilityIdentifier("repository-manager")
        .accessibilityValue(initialKindFilter?.rawValue ?? "all")
        .navigationTitle(initialKindFilter == .tracker ? "Tracker Repositories" : "Repositories")
        .navigationBarTitleDisplayMode(.inline)
        .appNativeNavigationChrome()
        .scrollBounceBehavior(.always, axes: .vertical)
        .refreshable {
            await model.sourcesModel.refreshRepositories()
        }
        .accessibilityAction(named: Text("Refresh repositories")) {
            Task { await model.sourcesModel.refreshRepositories() }
        }
        .toolbar {
            if !model.sourcesModel.sourceRepositories.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    FixedNavigationChrome {
                        Button("Add") { showsAddRepository = true }
                            .accessibilityLabel("Add Repository")
                            .accessibilityIdentifier("repository-manual-add")
                    }
                }
            }
        }
        .sheet(isPresented: $showsAddRepository) {
            NavigationStack {
                AddRepositoryView(
                    initialKindFilter: initialKindFilter,
                    presentationContext: presentationContext
                )
            }
            .appFeedbackOverlay()
        }
        .alert("Remove repository?", isPresented: Binding(
            get: { removal != nil },
            set: { if !$0 { removal = nil } }
        )) {
            Button("Remove", role: .destructive) {
                guard let removal else { return }
                Task { await model.removeRepository(removal) }
                self.removal = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(repositoryRemovalMessage)
        }
    }

    private var repositoryRemovalMessage: String {
        guard let removal else {
            return "Installed sources are removed from this device. Titles already saved in your library remain."
        }
        let count = model.sourcesModel.installedRepositorySources.filter { $0.repositoryID == removal.id }.count
        let sourceText = count == 1 ? "1 installed source" : "\(count) installed sources"
        return "This removes \(removal.manifest.repository.name) and \(sourceText) from this device. Titles, downloads, reading progress, bookmarks, annotations, and custom covers remain in your library."
    }

}
