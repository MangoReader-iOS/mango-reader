import CoreTransferable
import MangoReaderData
import MangoReaderDomain
import MangoReaderExtensions
import MangoReaderReaders
import MangoReaderSources
import MangoReaderSync
import SwiftUI
import UniformTypeIdentifiers

struct CompletedCBZExportItem: Transferable, Sendable {
    let url: URL
    let defaultFilename: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { item in
            SentTransferredFile(item.url)
        }
        .suggestedFileName { $0.defaultFilename }
    }
}

struct DownloadSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("contentCacheLimit") private var cacheLimit = ContentCache.defaultLimit
    @State private var cacheBytes = 0
    @State private var clearingCache = false

    private var storedBytes: Int64 {
        model.transfersModel.downloads
            .filter { $0.state == .completed }
            .reduce(0) { $0 + ($1.totalBytes ?? $1.completedBytes) }
    }

    var body: some View {
        @Bindable var transfers = model.transfersModel

        Form {
            Section("Automatic Cache") {
                Picker("Storage limit", selection: $cacheLimit) {
                    Text("256 MB").tag(256 * 1_024 * 1_024)
                    Text("512 MB").tag(512 * 1_024 * 1_024)
                    Text("1 GB").tag(ContentCache.defaultLimit)
                    Text("3 GB").tag(3 * ContentCache.defaultLimit)
                }
                LabeledContent("Used", value: Int64(cacheBytes).formatted(.byteCount(style: .file)))
                Button(clearingCache ? "Clearing…" : "Clear Cache") {
                    clearingCache = true
                    model.sourcesModel.cacheVisitGeneration = UUID()
                    model.sourcesModel.clearSourceSuggestionMemory()
                    Task {
                        await model.sourcesModel.contentCache.clear()
                        await model.sourcesModel.contentCache.flush()
                        model.sourcesModel.coverImageCache.clear()
                        PublicationImageCache.clearMemory()
                        for source in model.sourcesModel.sources { model.sourcesModel.workDetailCache.invalidate(sourceID: source.id) }
                        model.sourcesModel.cacheVisits = []
                        model.sourcesModel.defaults.removeObject(forKey: "sourceCacheVisits")
                        cacheBytes = await model.sourcesModel.contentCache.usage()
                        clearingCache = false
                    }
                }
                .disabled(clearingCache)
            }
            .appFullWidthListSeparator()
            HStack(spacing: 12) {
                Toggle(
                    "Download on Wi-Fi only",
                    isOn: Binding(
                        get: { model.settingsSyncModel.wifiOnlyDownloads },
                        set: { enabled in Task { await model.transfersModel.setWiFiOnlyDownloads(enabled) } }
                    )
                )
                .disabled(model.transfersModel.isUpdatingWiFiOnlyDownloads)
                .accessibilityValue(
                    model.transfersModel.isUpdatingWiFiOnlyDownloads
                        ? "Applying change"
                        : (model.settingsSyncModel.wifiOnlyDownloads ? "On" : "Off")
                )
                if model.transfersModel.isUpdatingWiFiOnlyDownloads {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Applying download network setting")
                }
            }
            .appFullWidthListSeparator()
            Section("Queue") {
                if model.transfersModel.isQueuingDownloads {
                    ProgressView("Preparing download requests…")
                }
                LabeledContent(
                    "Active",
                    value: "\(model.transfersModel.downloads.filter { $0.state == .downloading || $0.state == .queued }.count)"
                )
                LabeledContent("Stored offline", value: storedBytes.formatted(.byteCount(style: .file)))

                ForEach(model.transfersModel.downloads) { snapshot in
                    DownloadSettingsRow(snapshot: snapshot)
                }

                if model.transfersModel.downloads.isEmpty {
                    Text("No queued or completed downloads")
                        .foregroundStyle(.secondary)
                }
            }
            .appFullWidthListSeparator()
        }
        .navigationTitle("Downloads & Storage")
        .navigationBarTitleDisplayMode(.inline)
        .appNativeNavigationChrome()
        .task { cacheBytes = await model.sourcesModel.contentCache.usage() }
        .onChange(of: cacheLimit) { _, bytes in
            Task { await model.sourcesModel.contentCache.setLimit(bytes); cacheBytes = await model.sourcesModel.contentCache.usage() }
        }
        .fileExporter(
            isPresented: $transfers.isExportingCompletedCBZ,
            item: model.transfersModel.completedCBZExport,
            contentTypes: [.zip],
            defaultFilename: model.transfersModel.completedCBZExport?.defaultFilename ?? "Mango Reader Comic"
        ) { result in
            switch result {
            case .success:
                model.transfersModel.finishCompletedCBZExport()
            case let .failure(error):
                model.transfersModel.finishCompletedCBZExport(error: error)
            }
        } onCancellation: {
            model.transfersModel.finishCompletedCBZExport()
        }
    }
}

private struct DownloadSettingsRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let snapshot: DownloadSnapshot

    private var progress: Double? {
        guard let total = snapshot.totalBytes, total > 0 else { return nil }
        return min(1, Double(snapshot.completedBytes) / Double(total))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 12))

            layout {
                downloadMetadata
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    if isMovable {
                        queueActions
                    }
                    downloadAction
                    if let removalAction = snapshot.state.queueRemovalAction {
                        Menu {
                            Button(removalAction.title, systemImage: removalAction.systemImage, role: .destructive) {
                                Task {
                                    switch removalAction {
                                    case .cancel: await model.transfersModel.cancelDownload(snapshot)
                                    case .remove: _ = await model.removeDownload(snapshot)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .appIconControlFrame()
                        }
                        .accessibilityLabel("Options for \(snapshot.transfer.suggestedFilename)")
                        .accessibilityIdentifier("download-options-\(accessibilityID)")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(model.transfersModel.isDownloadOperationPending(snapshot.id))
                if model.transfersModel.pendingDownloadIDs.contains(snapshot.id) {
                    ProgressView().controlSize(.small).accessibilityLabel("Updating download")
                }
            }
            if let progress, snapshot.state == .downloading {
                ProgressView(value: progress)
                    .accessibilityLabel("Download progress")
                    .accessibilityValue(Text(progress, format: .percent))
            }
            if snapshot.state != .cancelled, let error = snapshot.lastError?.localizedDescription {
                SettingsSemanticLabel(
                    title: error,
                    systemImage: "exclamationmark.circle.fill",
                    color: AppColors.danger,
                    font: .caption
                )
            }
        }
    }

    private var downloadMetadata: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.transfer.suggestedFilename)
                .font(.subheadline.weight(.medium))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)
            Text(snapshot.state.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var isMovable: Bool {
        [.queued, .paused, .failed].contains(snapshot.state)
    }

    private var isCompletedCBZ: Bool {
        guard snapshot.state == .completed, snapshot.localRelativePath != nil else { return false }
        return snapshot.transfer.expectedFormat == .cbz
            || snapshot.transfer.expectedFormat == .remoteImageSequence
    }

    private var accessibilityID: String {
        snapshot.id.uuidString.lowercased()
    }

    private var queueActions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.transfersModel.moveDownloadUp(snapshot) }
            } label: {
                Label("Move earlier", systemImage: "arrow.up").labelStyle(.iconOnly).appIconControlFrame()
            }
            .disabled(!model.transfersModel.canMoveDownloadUp(snapshot))
            .accessibilityIdentifier("download-move-up-\(accessibilityID)")

            Button {
                Task { await model.transfersModel.moveDownloadDown(snapshot) }
            } label: {
                Label("Move later", systemImage: "arrow.down").labelStyle(.iconOnly).appIconControlFrame()
            }
            .disabled(!model.transfersModel.canMoveDownloadDown(snapshot))
            .accessibilityIdentifier("download-move-down-\(accessibilityID)")
        }
    }

    @ViewBuilder
    private var downloadAction: some View {
        switch snapshot.state {
        case .queued, .downloading:
            Button {
                Task { await model.transfersModel.pauseDownload(snapshot) }
            } label: {
                Label("Pause", systemImage: "pause.circle").labelStyle(.iconOnly).appIconControlFrame()
            }
            .accessibilityIdentifier("download-pause-\(accessibilityID)")
        case .paused:
            Button {
                Task { await model.transfersModel.resumeDownload(snapshot) }
            } label: {
                Label("Resume", systemImage: "play.circle").labelStyle(.iconOnly).appIconControlFrame()
            }
            .accessibilityIdentifier("download-resume-\(accessibilityID)")
        case .failed, .cancelled:
            Button {
                Task { await model.transfersModel.retryDownload(snapshot) }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise.circle").labelStyle(.iconOnly).appIconControlFrame()
            }
            .accessibilityIdentifier("download-retry-\(accessibilityID)")
        case .completed:
            HStack(spacing: 8) {
                if isCompletedCBZ {
                    if model.transfersModel.preparingCBZExportID == snapshot.id {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Preparing comic archive export")
                            .accessibilityIdentifier("download-export-progress-\(accessibilityID)")
                    } else {
                        Button {
                            Task { await model.transfersModel.prepareCompletedCBZExport(snapshot) }
                        } label: {
                            Label("Export CBZ or ZIP", systemImage: "square.and.arrow.up").labelStyle(.iconOnly).appIconControlFrame()
                        }
                        .disabled(model.isPrivate || model.transfersModel.preparingCBZExportID != nil)
                        .accessibilityIdentifier("download-export-\(accessibilityID)")
                    }
                }
                Button(role: .destructive) {
                    Task { await model.removeDownload(snapshot) }
                } label: {
                    Label("Remove", systemImage: "trash").labelStyle(.iconOnly).appIconControlFrame()
                }
                .accessibilityIdentifier("download-remove-\(accessibilityID)")
            }
        }
    }
}

enum DownloadQueueRemovalAction: Equatable {
    case cancel
    case remove

    var title: String {
        self == .cancel ? "Cancel Download" : "Remove from Queue"
    }

    var systemImage: String {
        self == .cancel ? "xmark.circle" : "trash"
    }
}

extension DownloadState {
    var queueRemovalAction: DownloadQueueRemovalAction? {
        switch self {
        case .queued, .downloading, .paused: .cancel
        case .failed, .cancelled: .remove
        case .completed: nil
        }
    }

    var displayName: String {
        switch self {
        case .queued: "Queued"
        case .downloading: "Downloading"
        case .paused: "Paused"
        case .completed: "Available offline"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}
