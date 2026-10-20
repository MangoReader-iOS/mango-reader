import MangoReaderDomain
import MangoReaderSources
import SwiftUI

struct BulkSourceMigrationRoute: Identifiable {
    let id = UUID()
    let works: [Work]
}

struct BulkSourceMigrationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    let works: [Work]
    let onApplied: () -> Void

    @State private var selectedSourceID: SourceID?
    @State private var preview: BulkSourceMigrationPreview?
    @State private var isPlanning = false
    @State private var isApplying = false
    @State private var isConfirmingApply = false
    @State private var workflowAlert: BulkSourceMigrationViewAlert?
    @State private var planningTask: Task<Void, Never>?
    @State private var applyTask: Task<Void, Never>?
    @State private var planningGeneration = UUID()

    private var destinations: [SourceDescriptor] {
        model.sourcesModel.sources.filter { descriptor in
            descriptor.isEnabled
                && descriptor.kind != .local
                && works.contains { $0.sourceID != descriptor.id }
        }
    }

    private var selectedSource: SourceDescriptor? {
        guard let selectedSourceID else { return nil }
        return destinations.first { $0.id == selectedSourceID }
    }

    private var readyCount: Int { preview?.readyCount ?? 0 }
    private var skippedCount: Int { preview?.skippedCount ?? 0 }

    var body: some View {
        NavigationStack {
            List {
                Section("Destination") {
                    if destinations.isEmpty {
                        ContentUnavailableView(
                            "No destination sources",
                            systemImage: "server.rack"
                        )
                    } else {
                        Picker("Source", selection: $selectedSourceID) {
                            ForEach(destinations) { descriptor in
                                Text(descriptor.name).tag(Optional(descriptor.id))
                            }
                        }
                        .accessibilityIdentifier("bulk-source-migration-destination")

                        LabeledContent(
                            "Selected",
                            value: "\(works.count) title\(works.count == 1 ? "" : "s")"
                        )

                        if works.count > 50 {
                            Label(
                                "Choose no more than 50 titles for one migration.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.footnote)
                            .foregroundStyle(AppColors.warning)
                        }

                        Button("Find Exact Matches", systemImage: "magnifyingglass") {
                            startPlanning()
                        }
                        .disabled(
                            selectedSource == nil
                                || works.isEmpty
                                || works.count > 50
                                || isPlanning
                                || isApplying
                        )
                        .accessibilityIdentifier("bulk-source-migration-plan")

                    }
                }
                .appFullWidthListSeparator()

                if isPlanning {
                    Section("Preview") {
                        SourceSummaryMetricsSkeletonContent(labels: ["Ready", "Skipped"])
                            .sourceSkeletonContainer(
                                accessibilityLabel: "Checking source migration matches"
                            )
                    }
                    .appFullWidthListSeparator()

                    Section("Titles") {
                        ForEach(Array(works.prefix(planningSkeletonRowCount))) { work in
                            SourceBulkStatusRowLayout(
                                title: work.title,
                                statusTitle: "Checking match",
                                statusDetail: "Comparing source installments",
                                isStatusPlaceholder: true,
                                cover: RemoteCover(work: work)
                            )
                            .sourceSkeletonContainer(
                                accessibilityLabel: "Checking \(work.title)"
                            )
                        }
                    }
                    .appFullWidthListSeparator()
                } else if let preview {
                    Section("Preview") {
                        SourceSummaryMetricsLayout(
                            metrics: [
                                SourceSummaryMetric(
                                    label: "Ready",
                                    value: readyCount.formatted()
                                ),
                                SourceSummaryMetric(
                                    label: "Skipped",
                                    value: skippedCount.formatted()
                                ),
                            ]
                        )

                    }
                    .accessibilityIdentifier("bulk-source-migration-preview")
                    .appFullWidthListSeparator()

                    Section("Titles") {
                        ForEach(preview.items) { item in
                            BulkSourceMigrationStatusRow(item: item)
                        }
                    }
                    .appFullWidthListSeparator()
                }
            }
            .navigationTitle("Migrate Sources")
            .navigationBarTitleDisplayMode(.inline)
            .appNativeNavigationChrome()
            .accessibilityIdentifier("bulk-source-migration")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    FixedNavigationChrome {
                        Button("Cancel") {
                            cancelOperations()
                            dismiss()
                        }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isApplying)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    FixedNavigationChrome {
                        Button {
                            isConfirmingApply = true
                        } label: {
                            if isApplying {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Apply")
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(
                            readyCount == 0
                                || isPlanning
                                || isApplying
                                || model.libraryModel.isApplyingBulkSourceMigration
                        )
                        .accessibilityLabel(
                            isApplying
                                ? "Applying source migrations"
                                : "Apply \(readyCount) ready source migration\(readyCount == 1 ? "" : "s")"
                        )
                        .accessibilityIdentifier("bulk-source-migration-apply")
                    }
                }
            }
        }
        .appFeedbackOverlay()
        .interactiveDismissDisabled(isApplying)
        .task {
            if selectedSourceID == nil {
                selectedSourceID = destinations.first?.id
            }
        }
        .onChange(of: selectedSourceID) { _, _ in
            cancelPlanning()
            preview = nil
            workflowAlert = nil
        }
        .onDisappear {
            cancelOperations()
        }
        .confirmationDialog(
            "Apply ready source migrations?",
            isPresented: $isConfirmingApply,
            titleVisibility: .visible
        ) {
            Button("Migrate \(readyCount) Title\(readyCount == 1 ? "" : "s")") {
                applyPreview()
            }
        } message: {
            Text(applyConfirmationMessage)
        }
        .alert(item: $workflowAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var applyConfirmationMessage: String {
        let skippedSentence = skippedCount == 0
            ? "No titles will be skipped."
            : "The \(skippedCount) skipped title\(skippedCount == 1 ? "" : "s") will remain unchanged."
        return skippedSentence + " Every ready title is preflighted before the batch is committed."
    }

    private var planningSkeletonRowCount: Int {
        min(max(works.count, 3), 6)
    }

    private func startPlanning() {
        guard let selectedSource else { return }
        cancelPlanning()
        preview = nil
        workflowAlert = nil
        isPlanning = true
        let generation = UUID()
        planningGeneration = generation
        planningTask = Task {
            do {
                let proposedPreview = try await model.libraryModel.planBulkSourceMigration(
                    works: works,
                    to: selectedSource
                )
                guard !Task.isCancelled, planningGeneration == generation else { return }
                preview = proposedPreview
                isPlanning = false
                planningTask = nil
            } catch is CancellationError {
                guard planningGeneration == generation else { return }
                isPlanning = false
                planningTask = nil
            } catch {
                guard planningGeneration == generation else { return }
                isPlanning = false
                planningTask = nil
                workflowAlert = BulkSourceMigrationViewAlert(
                    title: "Couldn’t Create Preview",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func applyPreview() {
        guard let preview, !isApplying else { return }
        isApplying = true
        workflowAlert = nil
        applyTask = Task {
            do {
                _ = try await model.applyBulkSourceMigration(preview)
                guard !Task.isCancelled else { return }
                isApplying = false
                applyTask = nil
                onApplied()
                dismiss()
            } catch is CancellationError {
                isApplying = false
                applyTask = nil
            } catch {
                isApplying = false
                applyTask = nil
                workflowAlert = BulkSourceMigrationViewAlert(
                    title: "Couldn’t Migrate Sources",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func cancelPlanning() {
        planningGeneration = UUID()
        planningTask?.cancel()
        planningTask = nil
        isPlanning = false
    }

    private func cancelOperations() {
        cancelPlanning()
        applyTask?.cancel()
        applyTask = nil
    }
}

private struct BulkSourceMigrationStatusRow: View {
    let item: BulkSourceMigrationPreviewItem

    private var status: BulkSourceMigrationDisplayStatus {
        switch item.outcome {
        case let .ready(targetWork, _):
            BulkSourceMigrationDisplayStatus(
                title: "Ready",
                detail: "Exact match: \(targetWork.title)",
                systemImage: "checkmark.circle.fill",
                color: AppColors.success
            )
        case .localSourceUnsupported:
            BulkSourceMigrationDisplayStatus(
                title: "Needs per-title review",
                detail: "Local titles cannot be migrated in a remote-source batch.",
                systemImage: "externaldrive.badge.exclamationmark",
                color: AppColors.warning
            )
        case .alreadyUsesDestination:
            BulkSourceMigrationDisplayStatus(
                title: "Already on this source",
                detail: "No change is needed.",
                systemImage: "checkmark.circle",
                color: .secondary
            )
        case .noExactMatch:
            BulkSourceMigrationDisplayStatus(
                title: "No exact match",
                detail: "Use per-title migration to choose a result.",
                systemImage: "questionmark.circle",
                color: AppColors.warning
            )
        case let .multipleExactMatches(count):
            BulkSourceMigrationDisplayStatus(
                title: "\(count) exact matches",
                detail: "Use per-title migration to choose the correct result.",
                systemImage: "square.stack.3d.up.badge.a",
                color: AppColors.warning
            )
        case let .duplicateDestinationMatch(count):
            BulkSourceMigrationDisplayStatus(
                title: "Shared destination match",
                detail: "\(count) selected titles matched this publication. Review them individually.",
                systemImage: "rectangle.on.rectangle.badge.exclamationmark",
                color: AppColors.warning
            )
        case let .ambiguousInstallments(count):
            BulkSourceMigrationDisplayStatus(
                title: "\(count) ambiguous installment match\(count == 1 ? "" : "es")",
                detail: "Use per-title migration to review the installments.",
                systemImage: "exclamationmark.triangle.fill",
                color: AppColors.warning
            )
        case .failed:
            BulkSourceMigrationDisplayStatus(
                title: "Couldn’t check",
                detail: "Retry the batch or use per-title migration.",
                systemImage: "xmark.circle",
                color: AppColors.danger
            )
        }
    }

    var body: some View {
        SourceBulkStatusRowLayout(
            title: item.existingWork.title,
            statusTitle: status.title,
            statusDetail: status.detail,
            statusSystemImage: status.systemImage,
            statusColor: status.color,
            cover: RemoteCover(work: item.existingWork)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.existingWork.title), \(status.title)")
        .accessibilityValue(status.detail)
        .accessibilityIdentifier("bulk-source-migration-status-\(item.id.rawValue.uuidString)")
    }
}

private struct BulkSourceMigrationDisplayStatus {
    let title: String
    let detail: String
    let systemImage: String
    let color: Color
}

private struct BulkSourceMigrationViewAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
