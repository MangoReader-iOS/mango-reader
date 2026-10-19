import MankoDomain
import MankoExtensions
import MankoReaders
import MankoSources
import Observation
import PhotosUI
import SwiftUI

struct SourceMigrationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    let work: Work

    @State private var selectedSourceID: SourceID?
    @State private var query: String
    @State private var results: [Work] = []
    @State private var selectedTarget: Work?
    @State private var plan: SourceMigrationPlan?
    @State private var isSearching = false
    @State private var isPlanning = false
    @State private var isApplying = false
    @State private var searchEmptyMessage: String?
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var planningTask: Task<Void, Never>?
    @State private var applyTask: Task<Void, Never>?
    @State private var searchGate = LatestOperationGate()
    @State private var planningGate = LatestOperationGate()

    init(work: Work) {
        self.work = work
        _query = State(initialValue: work.title)
    }

    private var destinations: [SourceDescriptor] {
        model.sourcesModel.sources.filter {
            $0.isEnabled && $0.kind != .local && $0.id != work.sourceID
        }
    }

    private var selectedSource: SourceDescriptor? {
        guard let selectedSourceID else { return nil }
        return destinations.first { $0.id == selectedSourceID }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Destination") {
                    if destinations.isEmpty {
                        ContentUnavailableView(
                            "No other sources",
                            systemImage: "server.rack"
                        )
                    } else {
                        Picker("Source", selection: $selectedSourceID) {
                            ForEach(destinations) { descriptor in
                                Text(descriptor.name).tag(Optional(descriptor.id))
                            }
                        }
                        .accessibilityIdentifier("migration-source-picker")

                        TextField("Title or author", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { search() }
                            .accessibilityIdentifier("migration-search-field")

                        Button("Search Source", systemImage: "magnifyingglass") {
                            search()
                        }
                        .disabled(
                            isSearching
                                || selectedSource == nil
                                || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        .accessibilityIdentifier("migration-search")

                    }
                }
                .appFullWidthListSeparator()

                if isSearching {
                    Section("Results") {
                        SourceMigrationResultsSkeletonContent()
                            .sourceSkeletonContainer(accessibilityLabel: "Searching source")
                    }
                    .appFullWidthListSeparator()
                } else if !results.isEmpty {
                    Section("Results") {
                        ForEach(results) { result in
                            let isSelected = selectedTarget?.id == result.id
                            Button {
                                preview(result)
                            } label: {
                                SourceMigrationResultRowLayout(
                                    title: result.title,
                                    authors: result.authors.isEmpty
                                        ? nil
                                        : result.authors.joined(separator: ", "),
                                    cover: RemoteCover(work: result),
                                    trailing: Group {
                                        if isSelected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(AppColors.action)
                                        } else {
                                            Image(systemName: "circle")
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(isSelected ? "Selected" : "Not selected")
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                            .accessibilityIdentifier("migration-result-\(result.id.rawValue.uuidString)")
                        }
                    }
                    .appFullWidthListSeparator()
                } else if let searchEmptyMessage {
                    Section("Results") {
                        ContentUnavailableView(
                            "No matching titles",
                            systemImage: "magnifyingglass",
                            description: Text(searchEmptyMessage)
                        )
                        .accessibilityIdentifier("migration-empty-results")
                    }
                    .appFullWidthListSeparator()
                }

                if isPlanning {
                    Section("Migration Preview") {
                        SourceSummaryMetricsSkeletonContent(
                            labels: [
                                "Matched",
                                "New at destination",
                                "Kept from current source",
                                "Ambiguous",
                            ]
                        )
                        .sourceSkeletonContainer(accessibilityLabel: "Comparing installments")
                    }
                    .appFullWidthListSeparator()
                } else if let plan {
                    Section("Migration Preview") {
                        SourceSummaryMetricsLayout(
                            metrics: [
                                SourceSummaryMetric(
                                    label: "Matched",
                                    value: plan.matches.count.formatted()
                                ),
                                SourceSummaryMetric(
                                    label: "New at destination",
                                    value: plan.unmatchedTargetInstallments.count.formatted()
                                ),
                                SourceSummaryMetric(
                                    label: "Kept from current source",
                                    value: plan.unmatchedExistingInstallments.count.formatted()
                                ),
                                SourceSummaryMetric(
                                    label: "Ambiguous",
                                    value: plan.ambiguousMatches.count.formatted()
                                ),
                            ]
                        )

                        if !plan.ambiguousMatches.isEmpty {
                            Label(
                                "This migration cannot be applied because some installments have more than one possible match.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.footnote)
                            .foregroundStyle(AppColors.warning)
                        }

                        Button("Apply Migration", systemImage: "arrow.triangle.swap") {
                            apply(plan)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppColors.actionFill)
                        .foregroundStyle(AppColors.onAction)
                        .disabled(isApplying || !plan.ambiguousMatches.isEmpty)
                        .accessibilityIdentifier("apply-source-migration")

                        if isApplying {
                            ProgressView("Migrating…")
                        }
                    }
                    .accessibilityIdentifier("migration-preview")
                    .appFullWidthListSeparator()
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .foregroundStyle(AppColors.danger)
                            .accessibilityIdentifier("migration-error")
                    }
                    .appFullWidthListSeparator()
                }
            }
            .navigationTitle("Migrate Source")
            .navigationBarTitleDisplayMode(.inline)
            .appNativeNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    FixedNavigationChrome {
                        Button("Cancel") { cancelAndDismiss() }
                            .disabled(isApplying)
                    }
                }
            }
            .task {
                if selectedSourceID == nil {
                    selectedSourceID = destinations.first?.id
                }
            }
            .onChange(of: selectedSourceID) { _, _ in
                cancelSearchAndPlanning()
                results = []
                selectedTarget = nil
                plan = nil
                searchEmptyMessage = nil
                errorMessage = nil
            }
            .onChange(of: query) { _, _ in
                cancelSearchAndPlanning()
                results = []
                selectedTarget = nil
                plan = nil
                searchEmptyMessage = nil
                errorMessage = nil
            }
            .onDisappear {
                searchTask?.cancel()
                planningTask?.cancel()
            }
        }
        .appFeedbackOverlay()
        .interactiveDismissDisabled(isApplying)
        .presentationDetents([.large])
    }

    private func search() {
        guard let selectedSource else { return }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }

        cancelSearchAndPlanning()
        let generation = searchGate.begin()
        isSearching = true
        selectedTarget = nil
        plan = nil
        searchEmptyMessage = nil
        errorMessage = nil
        searchTask = Task {
            defer {
                if searchGate.accepts(generation) {
                    isSearching = false
                    searchTask = nil
                }
            }
            do {
                let page = try await model.sourcesModel.browse(
                    selectedSource,
                    text: trimmedQuery,
                    kinds: [work.kind]
                )
                guard !Task.isCancelled, searchGate.accepts(generation) else { return }
                results = page.items
                if results.isEmpty {
                    searchEmptyMessage = "No titles matched your search on \(selectedSource.name)."
                }
            } catch is CancellationError {
                return
            } catch {
                guard searchGate.accepts(generation) else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func preview(_ target: Work) {
        planningTask?.cancel()
        let generation = planningGate.begin()
        selectedTarget = target
        plan = nil
        searchEmptyMessage = nil
        errorMessage = nil
        isPlanning = true
        planningTask = Task {
            defer {
                if planningGate.accepts(generation) {
                    isPlanning = false
                    planningTask = nil
                }
            }
            do {
                let proposedPlan = try await model.libraryModel.planSourceMigration(from: work, to: target)
                guard
                    !Task.isCancelled,
                    planningGate.accepts(generation),
                    selectedTarget?.id == target.id
                else { return }
                plan = proposedPlan
            } catch is CancellationError {
                return
            } catch {
                guard planningGate.accepts(generation) else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func apply(_ plan: SourceMigrationPlan) {
        searchTask?.cancel()
        planningTask?.cancel()
        isApplying = true
        errorMessage = nil
        applyTask = Task {
            do {
                try await model.libraryModel.applySourceMigration(plan, to: work)
                isApplying = false
                applyTask = nil
                dismiss()
            } catch is CancellationError {
                isApplying = false
                applyTask = nil
            } catch {
                errorMessage = error.localizedDescription
                isApplying = false
                applyTask = nil
            }
        }
    }

    private func cancelSearchAndPlanning() {
        searchTask?.cancel()
        planningTask?.cancel()
        searchTask = nil
        planningTask = nil
        searchGate.invalidate()
        planningGate.invalidate()
        isSearching = false
        isPlanning = false
    }

    private func cancelAndDismiss() {
        guard !isApplying else { return }
        cancelSearchAndPlanning()
        applyTask?.cancel()
        applyTask = nil
        dismiss()
    }
}
