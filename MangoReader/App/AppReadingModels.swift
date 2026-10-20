import Foundation
import ImageIO
import MangoReaderData
import MangoReaderDomain
import MangoReaderExtensions
import MangoReaderReaders
import MangoReaderSources
import MangoReaderSync
import Observation
import OSLog
import SwiftUI
import WebKit

struct ReaderMarksSnapshot: Sendable {
    var bookmarks: [Bookmark]
    var annotations: [Annotation]

    static let empty = ReaderMarksSnapshot(bookmarks: [], annotations: [])
}

struct WorkDetailSnapshot: Identifiable, Sendable {
    let id: WorkID
    var work: Work
    var installments: [Installment]
    var isInLibrary: Bool
    var progressByInstallmentID: [InstallmentID: ReadingProgress]

    init(
        work: Work,
        installments: [Installment] = [],
        isInLibrary: Bool = false,
        progressByInstallmentID: [InstallmentID: ReadingProgress] = [:]
    ) {
        id = work.id
        self.work = work
        self.installments = installments
        self.isInLibrary = isInLibrary
        self.progressByInstallmentID = progressByInstallmentID
    }
}

struct PreparedReaderContent: Sendable {
    var chapters: [Installment] = []
    var chaptersAreComplete = false
    var progressivePublication: ProgressivePublicationSession? = nil
    var remotePublication: RemoteImagePublication? = nil
    var work: Work
    var installment: Installment
    /// Private generated publications are owned by the reader session, never
    /// written into durable installment records or retained after dismissal.
    var temporaryPublicationURL: URL? = nil
}

struct ReaderOpenRequest: Sendable {
    enum Target: Sendable {
        case installment(Installment, chapters: [Installment]?)
        case continuation(chapters: [Installment]?)
        case history(ReadingSession)
    }
    var work: Work
    var target: Target
    var installment: Installment? {
        if case let .installment(value, _) = target { return value }
        return nil
    }
}

enum ReaderPreparationFailure: Error, LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case let .unavailable(message): message }
    }
}

/// Device-local availability, never synced or included in a backup.
enum ImportedFileAvailability: Equatable {
    case checking, ready, downloading, waitingForCloud, syncDisabled, failed(String)

    var title: String {
        switch self {
        case .checking: "Preparing file…"
        case .ready: "Ready on this device"
        case .downloading: "Downloading…"
        case .waitingForCloud: "Waiting for iCloud"
        case .syncDisabled: "File sync is off"
        case .failed: "Couldn’t download this file"
        }
    }
    var canRetry: Bool {
        switch self {
        case .waitingForCloud, .failed: true
        default: false
        }
    }

    var isWorking: Bool {
        self == .checking || self == .downloading
    }

    var symbol: String {
        switch self {
        case .checking, .downloading: "arrow.down.circle"
        case .ready: "checkmark.circle"
        case .waitingForCloud: "icloud"
        case .syncDisabled: "icloud.slash"
        case .failed: "exclamationmark.triangle"
        }
    }

    var explanation: String? {
        switch self {
        case .waitingForCloud:
            "The original may still be uploading from your other device. Your reading position is saved."
        case .syncDisabled:
            "This original isn’t on this device. Choose Sync Original below, or enable imported-file sync in File Sync Settings."
        case let .failed(message): message
        default: nil
        }
    }
}

enum ImportedOriginalPrefetchPolicy {
    static func select(
        progresses: [ReadingProgress], references: [ImportedOriginalReference], now: Date = .now
    ) -> [InstallmentID] {
        let references = Dictionary(references.map { ($0.installmentID, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<WorkID> = []
        return Array(progresses.sorted {
            $0.modifiedAt == $1.modifiedAt
                ? $0.installmentID.description < $1.installmentID.description
                : $0.modifiedAt > $1.modifiedAt
        }.filter { progress in
            let age = now.timeIntervalSince(progress.modifiedAt)
            guard age >= 0, age < 7 * 86_400,
                  let reference = references[progress.installmentID],
                  reference.sourceID == .local, reference.workID == progress.workID
            else { return false }
            return seen.insert(progress.workID).inserted
        }.prefix(3).map(\.installmentID))
    }
}

/// Unlike a task-group race, this deadline doesn't wait for the shared cloud
/// task to exit. The fetch continues and can offer a later handoff to the reader.
@MainActor
final class ReadingSyncDeadline {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    private var observer: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    static func wait(
        for operation: Task<Void, Never>,
        timeout: Duration = .seconds(2),
        sleep: @escaping @MainActor @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async {
        let deadline = ReadingSyncDeadline()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                deadline.continuation = continuation
                if deadline.finished || Task.isCancelled {
                    deadline.finish()
                    return
                }
                deadline.observer = Task {
                    await operation.value
                    deadline.finish()
                }
                deadline.timer = Task {
                    do { try await sleep(timeout) } catch { return }
                    deadline.finish()
                }
            }
        } onCancel: {
            Task { @MainActor in deadline.finish() }
        }
    }

    private func finish() {
        finished = true
        observer?.cancel(); timer?.cancel()
        observer = nil; timer = nil
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

struct ImportedBookRecovery: Identifiable {
    var id: InstallmentID { installment.id }
    let work: Work
    let installment: Installment
}

struct ImportedBookRecoveryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var retryTask: Task<Void, Never>?
    @State private var isPreparing = false
    let request: ImportedBookRecovery
    var onRecovered: ((PreparedReaderContent) -> Void)? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(request.work.title).font(.headline) }
                ImportedBookAvailabilitySection(
                    state: model.importedFileAvailability[request.id] ?? .waitingForCloud,
                    isPreparing: isPreparing,
                    retry: retry, cancel: { retryTask?.cancel(); dismiss() }
                )
                ImportedFileSyncSection(work: request.work, isBusy: isPreparing) {
                    await model.inspectImportedBookAvailability(request.installment, refresh: true)
                }
            }
            .formStyle(.grouped)
            .accessibilityIdentifier("imported-book-recovery-form")
            .navigationTitle("Open Book")
            .navigationBarTitleDisplayMode(.inline)
            .appNativeNavigationChrome()
            .toolbar { ToolbarItem(placement: .cancellationAction) { FixedNavigationChrome { Button("Close") { dismiss() } } } }
        }
        .appFeedbackOverlay()
        .onDisappear { retryTask?.cancel() }
    }

    private func retry() {
        guard !isPreparing else { return }
        isPreparing = true
        retryTask = Task {
            defer { isPreparing = false }
            if let prepared = await model.prepareToRead(
                work: request.work, installment: request.installment, announcesFailure: false
            ), !Task.isCancelled {
                if let onRecovered { onRecovered(prepared) }
                else {
                    model.recoveredImportedBook = prepared
                    dismiss()
                }
            }
        }
    }
}

struct ImportedFileSummaryRow: View {
    let state: ImportedFileAvailability
    let showDetails: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: showDetails) {
                HStack(spacing: 12) {
                    Image(systemName: "doc")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Original File").font(.subheadline)
                        Text(state.title).font(.footnote).foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if state.isWorking {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                    }
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Original File")
            .accessibilityValue(state.title)
            .accessibilityHint("Shows file availability and iCloud options")
            .accessibilityIdentifier("imported-file-summary")
            if state.isWorking {
                Button(action: cancel) {
                    Text("Cancel")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Cancel file preparation")
                .accessibilityIdentifier("imported-file-cancel")
            }
        }
    }
}

struct ImportedFileStatusLabel: View {
    let state: ImportedFileAvailability

    var body: some View {
        HStack(spacing: 12) {
            if state.isWorking {
                ProgressView().accessibilityHidden(true)
            } else {
                Image(systemName: state.symbol).accessibilityHidden(true)
            }
            Text(state.title).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("imported-book-availability")
    }
}

struct ImportedBookAvailabilitySection: View {
    let state: ImportedFileAvailability
    let isPreparing: Bool
    let retry: () -> Void
    let cancel: () -> Void

    var body: some View {
        Section {
            ImportedFileStatusLabel(state: state)
            if state.isWorking || isPreparing {
                Button("Cancel", action: cancel)
                    .accessibilityIdentifier("imported-file-cancel")
            } else if state == .ready {
                Button("Read", action: retry)
                    .accessibilityIdentifier("imported-file-read")
            } else if state.canRetry {
                Button("Retry", action: retry)
                    .accessibilityIdentifier("imported-file-retry")
            }
        } header: {
            Text("Availability")
        } footer: {
            if let explanation = state.explanation { Text(explanation) }
        }
    }
}

struct ImportedFileSyncSection: View {
    @Environment(AppModel.self) private var model
    let work: Work
    var isBusy = false
    var onPolicyChange: () async -> Void = {}
    @State private var policy: CloudFilePolicy = .inheritGlobal
    @State private var isLoaded = false
    @State private var isSaving = false

    var body: some View {
        Section {
            Picker("Original file in iCloud", selection: Binding(
                get: { policy },
                set: { value in
                    guard !isSaving, !isBusy else { return }
                    policy = value
                    isSaving = true
                    Task {
                        defer { isSaving = false }
                        let didSave = await model.setCloudFilePolicy(value, for: work)
                        if !didSave {
                            policy = await model.settingsSyncModel.cloudFilePolicy(for: work.id)
                        }
                        await onPolicyChange()
                    }
                }
            )) {
                ForEach(CloudFilePolicy.allCases, id: \.self) { policy in
                    Text(policy.displayName(syncImportedFiles: model.settingsSyncModel.syncImportedFiles))
                        .tag(policy)
                }
            }
            .pickerStyle(.navigationLink)
            .disabled(!isLoaded || isBusy || isSaving || model.libraryModel.isPerformingSelectionAction)
            .accessibilityIdentifier("imported-file-policy")
            if isSaving { ProgressView("Updating iCloud preference…") }
            NavigationLink("File Sync Settings") { SyncBackupSettingsView() }
                .disabled(isBusy || isSaving)
                .accessibilityIdentifier("imported-file-settings")
        } header: {
            Text("iCloud")
        } footer: {
            Text("Default follows File Sync Settings. Sync Original makes this title’s original available to your other devices.")
        }
        .task {
            guard !isLoaded else { return }
            policy = await model.settingsSyncModel.cloudFilePolicy(for: work.id)
            isLoaded = true
        }
        .onChange(of: model.settingsSyncModel.isUpdatingImportedFileSync) { _, updating in
            if !updating { Task { await onPolicyChange() } }
        }
    }
}

private extension CloudFilePolicy {
    func displayName(syncImportedFiles: Bool) -> String {
        switch self {
        case .inheritGlobal: syncImportedFiles ? "Default (Sync)" : "Default (Device Only)"
        case .localOnly: "Keep on This Device"
        case .syncOriginal: "Sync Original"
        }
    }
}

enum ReadingHandoffPolicy {
    static func shouldOffer(
        _ remote: ReadingProgress, currentDeviceID: String, baseline: Date?,
        lastLocalChange: Date?, lastOffered: Date?
    ) -> Bool {
        remote.deviceID != currentDeviceID
            && remote.modifiedAt > (baseline ?? .distantPast)
            && remote.modifiedAt > (lastLocalChange ?? .distantPast)
            && remote.modifiedAt > (lastOffered ?? .distantPast)
    }
}
