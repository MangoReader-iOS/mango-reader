import CoreTransferable
import MangoReaderData
import MangoReaderDomain
import MangoReaderExtensions
import MangoReaderReaders
import MangoReaderSources
import MangoReaderSync
import SwiftUI
import UniformTypeIdentifiers

enum TrackerPendingSummaryPolicy {
    static func text(for count: Int) -> String {
        count == 1 ? "1 pending update" : "\(count) pending updates"
    }
}

struct TrackerSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var detailedTracker: InstalledRepositorySource?
    @State private var trackerPendingRemoval: InstalledRepositorySource?

    private var installedTrackers: [InstalledRepositorySource] {
        model.sourcesModel.installedRepositorySources
            .filter { $0.entryType == .mangoReaderExtension && $0.kind == .tracker }
            .sorted {
                let comparison = $0.descriptor.name.localizedStandardCompare($1.descriptor.name)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
    }

    var body: some View {
        Group {
            if installedTrackers.isEmpty {
                List {
                    Section {
                        SettingsEmptyCardContent {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Add a tracker extension from one of your repositories.")
                                if model.trackingModel.trackerPendingCount > 0 {
                                    Label(
                                        TrackerPendingSummaryPolicy.text(for: model.trackingModel.trackerPendingCount),
                                        systemImage: "arrow.triangle.2.circlepath"
                                    )
                                    .font(.footnote)
                                }
                            }
                        } action: {
                            NavigationLink {
                                RepositoryManagerView(
                                    initialKindFilter: .tracker,
                                    presentationContext: .trackerSettings
                                )
                            } label: {
                                Text("Add Tracker")
                            }
                            .accessibilityIdentifier("tracker-add-empty")
                        }
                    }
                    .appFullWidthListSeparator()
                }
            } else {
                List {
                    if model.trackingModel.trackerPendingCount > 0 {
                        Section("Delivery") {
                            LabeledContent("Pending updates", value: "\(model.trackingModel.trackerPendingCount)")
                            if model.settingsSyncModel.incognitoMode {
                                Label("Delivery is paused while Incognito Reading is on.", systemImage: "eye.slash")
                                    .font(.footnote)
                            }
                            ForEach(model.trackingModel.trackerPendingUpdates) { update in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(trackerName(for: update)).font(.headline)
                                    if let tracker = installedTracker(for: update), !tracker.isRuntimeCompatible {
                                        Text("Delivery is paused until this tracker has a compatible update.")
                                    } else if let tracker = installedTracker(for: update), !tracker.isEnabled {
                                        Text("This tracker is disabled. Enable it from the tracker’s options to resume delivery.")
                                    }
                                    switch update.deliveryState {
                                    case .awaitingReauthentication:
                                        Text(update.lastError ?? "Sign in again to resume delivery.")
                                        if let tracker = installedTracker(for: update) {
                                            Button("Open Tracker Account") { detailedTracker = tracker }
                                                .buttonStyle(.borderless)
                                        }
                                    case .awaitingReview:
                                        Text("Review this title’s tracking values before sending this update.")
                                    case .permanentlyFailed:
                                        Text("The tracker rejected this update. Review this title’s tracking settings before sending a new update.")
                                    case .ready:
                                        if update.nextAttemptAt > .now {
                                            Text("Retry after \(update.nextAttemptAt.formatted(date: .omitted, time: .shortened)).")
                                        } else {
                                            Text(update.lastError ?? "Ready to send.")
                                        }
                                    }
                                }
                                .font(.footnote)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if model.trackingModel.isDeliveringTrackerUpdates {
                                ProgressView("Delivering tracker updates…")
                            } else {
                                Button("Retry Ready Updates", systemImage: "arrow.clockwise") {
                                    Task { await model.trackingModel.retryTrackerDelivery() }
                                }
                                .disabled(model.settingsSyncModel.incognitoMode)
                            }
                        }
                        .appFullWidthListSeparator()
                    }
                    Section("Tracker Extensions") {
                        ForEach(installedTrackers) { tracker in
                            Button {
                                detailedTracker = tracker
                            } label: {
                                TrackerExtensionRow(
                                    tracker: tracker,
                                    hasUpdate: repositoryEntry(for: tracker).map {
                                        RepositoryVersion.hasUpdate(entry: $0, installed: tracker)
                                    } ?? false
                                )
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    trackerPendingRemoval = tracker
                                }
                                .accessibilityLabel("Remove \(tracker.descriptor.name)")
                            }
                            .contextMenu {
                                Button("Retry", systemImage: "arrow.clockwise") {
                                    Task { await model.sourcesModel.retryInstalledRepositorySource(tracker) }
                                }
                                .disabled(!tracker.isRuntimeCompatible)
                                Button(
                                    tracker.isEnabled ? "Disable" : "Enable",
                                    systemImage: tracker.isEnabled ? "pause.circle" : "play.circle"
                                ) {
                                    Task {
                                        await model.sourcesModel.setInstalledRepositorySource(
                                            tracker,
                                            isEnabled: !tracker.isEnabled
                                        )
                                    }
                                }
                                .disabled(!tracker.isRuntimeCompatible && !tracker.isEnabled)
                                Divider()
                                Button("Remove Tracker", systemImage: "trash", role: .destructive) {
                                    trackerPendingRemoval = tracker
                                }
                            }
                            .accessibilityIdentifier("tracker-extension-\(tracker.sourceID)")
                        }
                    }
                    .appFullWidthListSeparator()
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Trackers")
        .navigationBarTitleDisplayMode(.inline)
        .appNativeNavigationChrome()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                FixedNavigationChrome {
                    NavigationLink {
                        RepositoryManagerView(
                            initialKindFilter: .tracker,
                            presentationContext: .trackerSettings
                        )
                    } label: {
                        Label("Add Tracker", systemImage: "plus")
                    }
                    .accessibilityIdentifier("tracker-add-toolbar")
                }
            }
        }
        .sheet(item: $detailedTracker) { tracker in
            NavigationStack {
                InstalledSourceDetailView(
                    installed: tracker,
                    entry: repositoryEntry(for: tracker),
                    repository: repository(for: tracker),
                    showsCloseButton: true
                )
            }
            .appFeedbackOverlay()
        }
        .alert("Remove \(trackerPendingRemoval?.descriptor.name ?? "Tracker")?", isPresented: Binding(
            get: { trackerPendingRemoval != nil },
            set: { if !$0 { trackerPendingRemoval = nil } }
        )) {
            Button("Remove", role: .destructive) {
                guard let trackerPendingRemoval else { return }
                if detailedTracker?.id == trackerPendingRemoval.id {
                    detailedTracker = nil
                }
                Task { await model.removeInstalledRepositorySource(trackerPendingRemoval) }
                self.trackerPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the tracker package, account credentials, cookies, settings, and queued tracker updates from this device. Titles, downloads, reading progress, bookmarks, annotations, and custom covers remain in your library.")
        }
        .task { await model.trackingModel.refreshTrackerQueueStatus() }
        .onChange(of: model.trackingModel.trackerPendingCount) { _, _ in
            Task { await model.trackingModel.refreshTrackerQueueStatus() }
        }
    }

    private func installedTracker(for update: QueuedTrackerUpdate) -> InstalledRepositorySource? {
        installedTrackers.first { model.trackingModel.trackerID(for: $0) == update.progress.trackerID }
    }

    private func trackerName(for update: QueuedTrackerUpdate) -> String {
        installedTracker(for: update)?.descriptor.name ?? "Unavailable tracker"
    }

    private func repository(for tracker: InstalledRepositorySource) -> RepositoryRecord? {
        model.sourcesModel.sourceRepositories.first { $0.id == tracker.repositoryID }
    }

    private func repositoryEntry(for tracker: InstalledRepositorySource) -> SourceRepositoryEntry? {
        repository(for: tracker)?.manifest.sources.first { $0.id == tracker.sourceID }
    }
}

private struct TrackerExtensionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let tracker: InstalledRepositorySource
    let hasUpdate: Bool

    private var status: String {
        guard tracker.isRuntimeCompatible else { return hasUpdate ? "Update Required" : "Unavailable" }
        return switch tracker.availability {
        case .available:
            tracker.isEnabled ? "Enabled" : "Disabled"
        case .serviceUnavailable:
            "Service Unavailable"
        case .retired:
            "Retired"
        }
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            RepositoryIconView(
                repositoryID: tracker.repositoryID, entryID: tracker.sourceID,
                iconIdentity: model.sourcesModel.repositoryIconIdentity(repositoryID: tracker.repositoryID, entryID: tracker.sourceID),
                dimension: 46
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(tracker.descriptor.name)
                    .font(.headline)
                Text("Version \(tracker.version)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(status)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
