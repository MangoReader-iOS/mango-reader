import MankoDomain
import MankoExtensions
import SwiftUI

struct AddRepositoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let initialKindFilter: ExtensionKind?
    let presentationContext: RepositoryPresentationContext
    @State private var address = ""
    @State private var record: RepositoryRecord?
    @State private var linkRequest: RepositoryLinkRequest?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var loadTask: Task<Void, Never>?

    init(
        initialKindFilter: ExtensionKind? = nil,
        presentationContext: RepositoryPresentationContext = .browse
    ) {
        self.initialKindFilter = initialKindFilter
        self.presentationContext = presentationContext
    }

    var body: some View {
        Form {
            Section("Repository Address") {
                TextField("https://example.com/repository/", text: $address)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("repository-url")
                    .disabled(isLoading)
                Button("Load Repository") { load() }
                    .disabled(isLoading || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("repository-load")
            }
            .browseListRow(enabled: presentationContext.usesBrowsePalette)
        }
        .browseGroupedForm(enabled: presentationContext.usesBrowsePalette)
        .navigationTitle("Add Repository")
        .navigationBarTitleDisplayMode(.inline)
        .appNativeNavigationChrome()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                FixedNavigationChrome {
                    Button("Cancel") {
                        loadTask?.cancel()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("repository-add-cancel")
                }
            }
        }
        .navigationDestination(item: $record) { record in
            RepositoryCatalogView(
                record: record,
                initialKindFilter: initialKindFilter,
                presentationContext: presentationContext
            )
        }
        .sheet(item: $linkRequest) { request in
            RepositoryLinkFlowView(request: request, onSourcesInstalled: { dismiss() })
        }
        .overlay {
            if isLoading { AppContentSkeleton(kind: .textRows, count: 3, label: String(localized: "Loading repository…")) }
        }
        .onDisappear { loadTask?.cancel() }
        .alert("Couldn’t add repository", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("Try Again") { load() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Try again.")
        }
    }

    private func load() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        let enteredAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        loadTask = Task {
            defer {
                isLoading = false
                loadTask = nil
            }
            do {
                try Task.checkCancellation()
                let action = try RepositoryDeepLinkParser().parseInput(enteredAddress)
                switch action {
                case let .add(url) where URL(string: enteredAddress)?.scheme?.lowercased() != "manko":
                    let loaded = try await model.sourcesModel.addRepository(at: url)
                    try Task.checkCancellation()
                    record = loaded
                case let .add(url):
                    linkRequest = RepositoryLinkRequest(repositoryURL: url, sourceIDs: [])
                case let .install(url, sourceIDs):
                    linkRequest = RepositoryLinkRequest(repositoryURL: url, sourceIDs: sourceIDs)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct RepositoryLinkFlowView: View {
    private enum Phase {
        case loading
        case review(RepositoryRecord, [SourceRepositoryEntry])
        case working
        case results(RepositoryRecord, [SourceRepositoryEntry], [RepositoryInstallResult])
        case catalog(RepositoryRecord)
        case failed(String)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: RepositoryLinkRequest
    let onSourcesInstalled: () -> Void
    @State private var phase: Phase = .loading
    @State private var progress = RepositoryLinkInstallProgress()
    @State private var operationTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            content
            .appBackground()
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .appNativeNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    FixedNavigationChrome {
                        Button(isReviewPhase ? "Cancel" : "Close") {
                            close()
                        }
                        .disabled(isWorking)
                        .accessibilityIdentifier("repository-link-cancel")
                    }
                }
                if case .review = phase {
                    ToolbarItem(placement: .confirmationAction) {
                        FixedNavigationChrome {
                            Button(primaryActionTitle) {
                                confirm()
                            }
                            .accessibilityIdentifier("repository-link-confirm")
                        }
                    }
                }
            }
        }
        .appFeedbackOverlay()
        .interactiveDismissDisabled(isWorking || !progress.results.isEmpty)
        .onDisappear { operationTask?.cancel() }
        .task(id: request.id) {
            await loadPreview()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            AppContentSkeleton(kind: .textRows, count: 3, label: String(localized: "Checking repository…"))
                .accessibilityIdentifier("repository-link-loading")
        case let .review(record, entries):
            reviewList(record: record, entries: entries)
        case .working:
            ProgressView(request.sourceIDs.isEmpty ? "Saving repository…" : "Installing extensions…")
                .accessibilityIdentifier("repository-link-working")
        case let .results(record, entries, results):
            resultsList(record: record, entries: entries, results: results)
        case let .catalog(record):
            RepositoryCatalogView(repositoryID: record.id, fallbackRecord: record, initialKindFilter: nil)
        case let .failed(message):
            ContentUnavailableView {
                Text("Couldn’t review link")
                    .font(.title2.bold())
            } description: {
                Text(message)
            } actions: {
                Button("Try Again", systemImage: "arrow.clockwise") {
                    operationTask = Task { await loadPreview() }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.actionFill)
                .foregroundStyle(AppColors.onAction)
                .accessibilityIdentifier("repository-link-retry")
            }
        }
    }

    @ViewBuilder
    private func reviewList(record: RepositoryRecord, entries: [SourceRepositoryEntry]) -> some View {
        List {
            ExtensionAccessReviewSections(record: record, entries: entries)
            Section("Repository") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.manifest.repository.name)
                        .font(.headline)
                    Text(record.manifest.repository.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Publisher", value: record.manifest.repository.publisher.name)
                LabeledContent("Website", value: record.repositoryURL.host ?? record.repositoryURL.absoluteString)
            }
            .browseFullWidthListRow()

            if !entries.isEmpty {
                Section(entries.count == 1 ? "Selected Extension" : "Selected Extensions") {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.name)
                                .font(.headline)
                            Text("v\(entry.version) · \(languageSummary(entry.languages)) · \(maturitySummary(entry.maturityRating))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(permissionSummary(entry.permissions.values))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .accessibilityIdentifier("repository-link-source-\(entry.id)")
                    }
                }
                .browseFullWidthListRow()

                Section {
                    Label(
                        "This repository will be retained so Manko can verify these extensions and check for updates.",
                        systemImage: "checkmark.shield"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .browseFullWidthListRow()
            } else {
                Section {
                    Text("Adding this repository makes its extensions available in the catalog. Nothing is installed automatically.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .browseFullWidthListRow()
            }
        }
        .browseInsetGroupedList()
        .accessibilityIdentifier("repository-link-review")
    }

    @ViewBuilder
    private func resultsList(
        record: RepositoryRecord,
        entries: [SourceRepositoryEntry],
        results: [RepositoryInstallResult]
    ) -> some View {
        List {
            Section("Results") {
                ForEach(results) { result in
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.sourceName)
                            Text(result.message)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: result.installed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(result.installed ? Color.green : AppColors.warning)
                    }
                    .accessibilityIdentifier("repository-link-result-\(result.sourceID)")
                }
            }
            .browseFullWidthListRow()

            if results.contains(where: { !$0.installed }) {
                Section {
                    Button("Retry Failed", systemImage: "arrow.clockwise") {
                        retryFailed(record: record, entries: entries, previousResults: results)
                    }
                    .accessibilityIdentifier("repository-link-retry-failed")
                }
                .browseFullWidthListRow()
            }
        }
        .browseInsetGroupedList()
        .accessibilityIdentifier("repository-link-results")
    }

    private var navigationTitle: String {
        switch phase {
        case .review where request.sourceIDs.isEmpty: "Add Repository"
        case .review: "Install Extensions"
        case .results: "Installation Results"
        case .catalog: "Repository"
        default: "Repository Link"
        }
    }

    private var isReviewPhase: Bool {
        if case .review = phase { return true }
        return false
    }

    private var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    private var primaryActionTitle: String {
        guard !request.sourceIDs.isEmpty else {
            if case let .review(record, _) = phase,
               model.sourcesModel.sourceRepositories.contains(where: { $0.id == record.id }) {
                return "Update"
            }
            return "Add"
        }
        return "Install"
    }

    private func loadPreview() async {
        phase = .loading
        do {
            let record = try await model.previewRepositoryLink(at: request.repositoryURL)
            let entries = try model.validatedRepositoryLinkEntries(in: record, sourceIDs: request.sourceIDs)
            try Task.checkCancellation()
            progress.entries = entries
            phase = .review(record, progress.pendingEntries)
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func confirm() {
        guard case let .review(record, entries) = phase else { return }
        phase = .working
        operationTask = Task {
            do {
                try Task.checkCancellation()
                let saved = try await model.persistRepositoryLinkPreview(record)
                if entries.isEmpty {
                    phase = .catalog(saved)
                    return
                }
                let approvals = try Dictionary(uniqueKeysWithValues: entries.map { ($0.id, try ExtensionAccessGrant(entry: $0, record: record)) })
                let results = await model.sourcesModel.installRepositorySources(entries.map(\.id), from: saved, approvals: approvals)
                progress.merge(results)
                phase = .results(saved, progress.entries, progress.results)
            } catch is CancellationError {
                return
            } catch {
                if !progress.results.isEmpty {
                    progress.merge(entries.map {
                        RepositoryInstallResult(sourceID: $0.id, sourceName: $0.name, installed: false,
                                                message: error.localizedDescription)
                    })
                    phase = .results(record, progress.entries, progress.results)
                } else {
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func retryFailed(
        record: RepositoryRecord,
        entries: [SourceRepositoryEntry],
        previousResults: [RepositoryInstallResult]
    ) {
        let failedIDs = previousResults.filter { !$0.installed }.map(\.sourceID)
        guard !failedIDs.isEmpty else { return }
        phase = .review(record, entries.filter { failedIDs.contains($0.id) })
    }

    private func close() {
        operationTask?.cancel()
        if progress.hasInstalledContent { onSourcesInstalled() }
        dismiss()
    }

    private func languageSummary(_ languages: [String]) -> String {
        languages.isEmpty ? "All languages" : languages.map { $0.uppercased() }.joined(separator: ", ")
    }

    private func maturitySummary(_ rating: RepositoryMaturityRating) -> String {
        switch rating {
        case .safe: "All ages"
        case .mature: "17+"
        case .adult: "18+"
        }
    }

    private func permissionSummary(_ permissions: Set<ExtensionPermission>) -> String {
        guard !permissions.isEmpty else { return "No additional permissions" }
        return permissions.map(permissionName).sorted().joined(separator: ", ")
    }

    private func permissionName(_ permission: ExtensionPermission) -> String {
        switch permission {
        case .network: "Network access"
        case .cookies: "Cookies"
        case .state: "Local settings"
        case .secureState: "Secure storage"
        case .rateLimiting: "Rate limiting"
        case .redactedLogging: "Redacted diagnostics"
        case .challengeHandoff: "Challenge handoff"
        case .authenticationHandoff: "Authentication handoff"
        case .managedCollections: "Managed collections"
        case .trackerUpdates: "Tracker updates"
        case .webExecution: "Website code"
        }
    }
}
