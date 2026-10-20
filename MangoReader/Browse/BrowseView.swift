import MangoReaderDomain
import MangoReaderExtensions
import MangoReaderSources
import Observation
import SwiftUI

struct BrowseView: View {
    @Environment(AppModel.self) private var model
    @State private var sourcesPendingDeletion: [SourceDescriptor] = []
    @State private var sourceSettings: SourceDescriptor?
    let openAddSource: () -> Void

    private static let serverKinds: [SourceKind] = [.komga, .kavita, .suwayomi, .opds]

    var body: some View {
        Group {
            if isCompletelyEmpty {
                browseEmptyState
            } else {
                sourceList
            }
        }
        .appBackground()
        .screenTitle(Text("Browse"), presentation: .expanded)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                FixedNavigationChrome {
                    Button("Add Source", action: openAddSource)
                    .accessibilityLabel("Add Source")
                    .accessibilityIdentifier("browse-add-source")
                }
            }
        }
        .sheet(item: $sourceSettings) { source in
            NavigationStack {
                SourceSettingsView(source: source)
            }
            .appFeedbackOverlay()
        }
        .alert(
            sourcesPendingDeletion.count == 1 ? "Remove Source?" : "Remove Sources?",
            isPresented: Binding(
                get: { !sourcesPendingDeletion.isEmpty },
                set: { isPresented in
                    if !isPresented { sourcesPendingDeletion = [] }
                }
            )
        ) {
            Button("Remove", role: .destructive) {
                let pending = sourcesPendingDeletion
                sourcesPendingDeletion = []
                Task {
                    for source in pending {
                        await model.removeSource(source)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                sourcesPendingDeletion = []
            }
        } message: {
            Text(
                sourceRemovalMessage
            )
        }
    }

    private var isCompletelyEmpty: Bool {
        !model.sourcesModel.sourceHealth.needsAttention
            && serverSources.isEmpty
            && serverProviders.isEmpty
            && extensionSources.isEmpty
    }

    private var browseEmptyState: some View {
        ContentUnavailableView {
            Label("No Sources Yet", systemImage: "books.vertical")
        } description: {
            Text("Use Add Source to import files or add a repository.")
        } actions: {
            Button("Add Source", systemImage: "plus", action: openAddSource)
                .buttonStyle(.borderedProminent)
                .tint(AppColors.actionFill)
                .foregroundStyle(AppColors.onAction)
                .accessibilityIdentifier("browse-empty-add-source")
        }
    }

    private var sourceList: some View {
        List {
            if model.sourcesModel.sourceHealth.needsAttention {
                Section {
                    SourceRecoveryRow(
                        title: model.sourcesModel.sourceHealth.summary,
                        detail: model.sourcesModel.sourceHealth.detail,
                        isRepairing: model.sourcesModel.isCheckingSources,
                        isDisabled: model.sourcesModel.isResettingSources
                    ) {
                        Task { await model.sourcesModel.checkAndRepairSources() }
                    }
                }
                .listRowBackground(Color.clear)
                .appFullWidthListSeparator()
            }

            if serverSources.isEmpty, serverProviders.isEmpty, extensionSources.isEmpty {
                Section {
                    Label("No Sources Yet", systemImage: "books.vertical")
                        .font(.headline)
                    Text("Use Add Source to import files or add a repository.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Add Source", systemImage: "plus", action: openAddSource)
                        .accessibilityIdentifier("browse-empty-add-source")
                }
                .listRowBackground(Color.clear)
                .appFullWidthListSeparator()
            } else {
                if !serverSources.isEmpty {
                    Section {
                        serverSourceRows
                    } header: {
                        Text("Servers")
                            .accessibilityIdentifier("browse-source-section-servers")
                    }
                    .listRowBackground(Color.clear)
                    .appFullWidthListSeparator()
                }

                if !extensionSources.isEmpty || !serverProviders.isEmpty {
                    Section {
                        extensionSourceRows
                    } header: {
                        Text("Extensions")
                            .accessibilityIdentifier("browse-source-section-extensions")
                    }
                    .listRowBackground(Color.clear)
                    .appFullWidthListSeparator()
                }
            }
        }
        .listStyle(.plain)
        .softScreenHeaderEdge()
        .scrollContentBackground(.hidden)
        .appBackground()
    }

    private var serverSources: [SourceDescriptor] {
        model.sourcesModel.sources.filter { Self.serverKinds.contains($0.kind) }
    }

    private var serverProviders: [InstalledRepositorySource] {
        model.sourcesModel.installedRepositorySources.filter { $0.kind == .content && $0.connectorKind != nil }
            .sorted { $0.descriptor.name.localizedStandardCompare($1.descriptor.name) == .orderedAscending }
    }

    private var extensionSources: [SourceDescriptor] {
        model.sourcesModel.sources.filter { $0.kind == .mangoReaderExtension }
    }

    @ViewBuilder
    private var serverSourceRows: some View {
        ForEach(serverSources) { source in
            sourceNavigationRow(source) {
                SourceRow(
                    name: source.name,
                    detail: source.kind.displayName,
                    systemImage: source.kind.symbol
                )
            }
        }
    }

    @ViewBuilder
    private var extensionSourceRows: some View {
        ForEach(serverProviders) { installed in
            let repository = model.sourcesModel.sourceRepositories.first { $0.id == installed.repositoryID }
            NavigationLink {
                InstalledSourceDetailView(installed: installed,
                    entry: repository?.manifest.sources.first { $0.id == installed.sourceID }, repository: repository)
            } label: {
                if let presentation = BrowseExtensionRowPresentation.resolve(source: installed.descriptor,
                    installedSources: model.sourcesModel.installedRepositorySources,
                    repositories: model.sourcesModel.sourceRepositories) {
                    BrowseExtensionSourceRow(presentation: presentation)
                }
            }
            .accessibilityIdentifier("browse-server-provider-\(installed.sourceID)")
        }
        ForEach(extensionSources) { source in
            sourceNavigationRow(source) {
                if let presentation = BrowseExtensionRowPresentation.resolve(
                    source: source,
                    installedSources: model.sourcesModel.installedRepositorySources,
                    repositories: model.sourcesModel.sourceRepositories
                ) {
                    BrowseExtensionSourceRow(presentation: presentation)
                } else {
                    SourceRow(
                        name: source.name,
                        detail: source.kind.displayName,
                        systemImage: source.kind.symbol
                    )
                }
            }
        }
    }

    private func sourceNavigationRow<Label: View>(
        _ source: SourceDescriptor,
        @ViewBuilder label: () -> Label
    ) -> some View {
        NavigationLink {
            if let installed = model.sourcesModel.installedRepositorySources.first(where: { $0.descriptor.id == source.id }),
               !installed.isRuntimeCompatible {
                let repository = model.sourcesModel.sourceRepositories.first { $0.id == installed.repositoryID }
                InstalledSourceDetailView(
                    installed: installed,
                    entry: repository?.manifest.sources.first { $0.id == installed.sourceID },
                    repository: repository
                )
            } else {
                SourceCatalogView(source: source)
            }
        } label: {
            label()
        }
        .accessibilityIdentifier("browse-source-\(source.id.rawValue)")
        .appFullWidthListSeparator()
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Source Settings", systemImage: "gearshape") {
                sourceSettings = source
            }
            .accessibilityLabel("Source Settings for \(source.name)")
            Button("Remove", systemImage: "trash", role: .destructive) {
                sourcesPendingDeletion = [source]
            }
            .accessibilityLabel("Remove \(source.name)")
        }
        .contextMenu {
            Button("Source Settings", systemImage: "gearshape") {
                sourceSettings = source
            }
            .accessibilityIdentifier("browse-source-settings-\(source.id.rawValue)")
            Button("Remove Source", systemImage: "trash", role: .destructive) {
                sourcesPendingDeletion = [source]
            }
        }
    }

    private var sourceRemovalMessage: String {
        let isInstalledExtension = sourcesPendingDeletion.contains { descriptor in
            model.sourcesModel.installedRepositorySources.contains { $0.descriptor.id == descriptor.id }
        }
        let object = sourcesPendingDeletion.count == 1 ? "source" : "sources"
        let storedData = isInstalledExtension
            ? "package, saved credentials, cookies, and source settings"
            : "saved credentials and catalog settings"
        return "This removes the \(object) and its \(storedData) from this device. Titles, downloads, reading progress, bookmarks, annotations, and custom covers remain in your library."
    }
}

private struct SourceRecoveryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let detail: String?
    let isRepairing: Bool
    let isDisabled: Bool
    let repair: () -> Void

    var body: some View {
        HStack(alignment: rowAlignment, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColors.warning)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("source-recovery-card")

                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if dynamicTypeSize.isAccessibilitySize {
                    repairControl
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !dynamicTypeSize.isAccessibilitySize {
                repairControl
            }
        }
        .padding(.vertical, 4)
    }

    private var rowAlignment: VerticalAlignment {
        dynamicTypeSize.isAccessibilitySize ? .top : .center
    }

    private var repairControl: some View {
        Group {
            if isRepairing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Fixing sources")
            } else {
                Button(action: repair) {
                    Text("Fix")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.bordered)
                    .disabled(isDisabled)
                    .accessibilityLabel("Fix sources")
            }
        }
        .accessibilityIdentifier("source-recovery-repair")
    }
}

struct BrowseExtensionRowPresentation: Equatable {
    let title: String
    let installedVersion: String
    let author: String
    let maturity: RepositoryMaturityFlairContent
    let repositoryID: String
    let entryID: String
    let iconIdentity: String
    let availabilityText: String?

    var metadataText: String {
        "v\(installedVersion) · \(author)"
    }

    var accessibilityLabel: String {
        "\(title), version \(installedVersion), by \(author)"
            + (availabilityText.map { ", \($0)" } ?? "")
    }

    static func resolve(
        source: SourceDescriptor,
        installedSources: [InstalledRepositorySource],
        repositories: [RepositoryRecord]
    ) -> Self? {
        guard let installed = installedSources.first(where: { $0.descriptor.id == source.id }) else {
            return nil
        }
        let repository = repositories.first { $0.id == installed.repositoryID }
        let entry = repository?.manifest.sources.first { $0.id == installed.sourceID }
        let developerNames = entry?.developers
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            ?? []
        let publisherName = repository?.manifest.repository.publisher.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let author = developerNames.isEmpty
            ? publisherName.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Unknown author")
            : developerNames.joined(separator: ", ")

        return Self(
            title: source.name,
            installedVersion: installed.version,
            author: author,
            maturity: RepositoryMaturityFlairContent(rating: entry?.maturityRating),
            repositoryID: installed.repositoryID,
            entryID: installed.sourceID,
            iconIdentity: "\(entry?.icon ?? "")::\(repository?.checkedAt.timeIntervalSinceReferenceDate ?? 0)",
            availabilityText: installed.isRuntimeCompatible ? nil
                : entry.map { RepositoryVersion.hasUpdate(entry: $0, installed: installed) ? "Update Required" : "Unavailable" } ?? "Unavailable"
        )
    }
}

private struct BrowseExtensionSourceRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let presentation: BrowseExtensionRowPresentation

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
            RepositoryIconView(
                repositoryID: presentation.repositoryID,
                entryID: presentation.entryID,
                iconIdentity: presentation.iconIdentity,
                dimension: 46
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(.headline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(presentation.metadataText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)

                if let availability = presentation.availabilityText {
                    Text(availability).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}

struct SourceRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var scaledIconSize: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var scaledIconColumnWidth: CGFloat = 28
    let name: String
    let detail: String?
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: min(scaledIconSize, 36), weight: .regular))
                .foregroundStyle(AppColors.action)
                .frame(width: min(scaledIconColumnWidth, 48))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

extension SourceKind {
    var displayName: String {
        switch self {
        case .local: "Local Files"
        case .opds: "OPDS"
        case .komga: "Komga"
        case .kavita: "Kavita"
        case .suwayomi: "Suwayomi"
        case .mangoReaderExtension: "Mango Reader Extension"
        }
    }

    var symbol: String {
        switch self {
        case .local: "folder"
        case .opds: "network"
        case .komga: "books.vertical"
        case .kavita: "book.pages"
        case .suwayomi: "rectangle.stack"
        case .mangoReaderExtension: "shippingbox.fill"
        }
    }
}

private extension SourceCapability {
    var displayName: String {
        switch self {
        case .browse: "Browse"
        case .search: "Search"
        case .filters: "Filters"
        case .authentication: "Authentication"
        case .acquisition: "Downloads"
        case .imageSequence: "Page streaming"
        case .progressSync: "Progress sync"
        case .updates: "Update checks"
        case .discover: "Discover sections"
        case .managedCollections: "Managed collections"
        }
    }

    var symbol: String {
        switch self {
        case .browse: "rectangle.grid.2x2"
        case .search: "magnifyingglass"
        case .filters: "line.3.horizontal.decrease"
        case .authentication: "key"
        case .acquisition: "arrow.down.circle"
        case .imageSequence: "photo.stack"
        case .progressSync: "arrow.triangle.2.circlepath"
        case .updates: "sparkles"
        case .discover: "safari"
        case .managedCollections: "rectangle.stack.badge.plus"
        }
    }
}
