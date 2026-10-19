import MankoData
import SwiftUI

struct RestorePreviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let staged: StagedBackupRestore
    @State private var selection: BackupRestoreSelection
    @State private var mode: BackupRestoreMode = .merge
    @State private var isCommitting = false
    @State private var isDiscarding = false
    @State private var confirmsReplace = false

    private var isBusy: Bool { isCommitting || isDiscarding }

    init(staged: StagedBackupRestore) {
        self.staged = staged
        _selection = State(initialValue: staged.defaultSelection)
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = model.transfersModel.backupFailure {
                    Section("Import failed") { Text(error) }
                        .foregroundStyle(AppColors.danger)
                        .accessibilityIdentifier("backup-import-error")
                }
                Section("Backup") {
                    LabeledContent("Created", value: staged.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Format", value: "Version \(staged.manifest.formatVersion)")
                }
                .appFullWidthListSeparator()
                Section {
                    if dynamicTypeSize.isAccessibilitySize {
                        Picker("Import Method", selection: $mode) { modeOptions }
                            .pickerStyle(.menu)
                    } else {
                        Picker("Import Method", selection: $mode) { modeOptions }
                            .pickerStyle(.segmented)
                    }
                } header: {
                    Text("Import Method")
                } footer: {
                    Text(mode == .merge
                         ? "Add missing items. Keep your existing data and settings."
                         : "Replace the selected sections with this backup. Items missing from the backup may be removed.")
                }
                .disabled(isBusy)
                .appFullWidthListSeparator()
                BackupContentsToggles(selection: $selection, manifest: staged.manifest, isBusy: isBusy)
                Section {
                    Text("Sign-in details and offline downloads aren’t imported. New extensions need to be installed and approved before use.")
                    if mode == .replace, selection.contains(.library) {
                        Text("Replacing Library can also remove progress, history, organization, and annotations for titles no longer present, including in unchecked sections.")
                    }
                    if mode == .replace, selection.contains(.importedMedia) {
                        Text("Imported Publications replaces the current imported-file folder.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .appFullWidthListSeparator()
                if isBusy {
                    ProgressView(isDiscarding ? "Cancelling import…" : "Importing selected sections…")
                        .accessibilityIdentifier("backup-operation-progress")
                }
            }
            .navigationTitle("Import Backup")
            .navigationBarTitleDisplayMode(.inline)
            .appNativeNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    FixedNavigationChrome {
                        Button("Cancel") {
                            isDiscarding = true
                            Task {
                                await model.transfersModel.discardRestore(staged)
                                dismiss()
                            }
                        }
                        .disabled(isBusy)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    FixedNavigationChrome {
                        if mode == .replace {
                            Button("Replace", role: .destructive) { confirmsReplace = true }
                                .disabled(selection.isEmpty || isBusy)
                        } else {
                            Button("Import") { commit() }
                                .disabled(selection.isEmpty || isBusy)
                        }
                    }
                }
            }
            .confirmationDialog("Replace the selected sections?", isPresented: $confirmsReplace, titleVisibility: .visible) {
                Button("Replace Selected Sections", role: .destructive) { commit() }
            } message: {
                Text(selection.contains(.library)
                     ? "Selected sections will be replaced. Unchecked records linked to removed titles may also be removed. This can’t be undone."
                     : "Selected sections will be replaced with this backup. This can’t be undone.")
            }
        }
        .appFeedbackOverlay()
        .interactiveDismissDisabled(isBusy)
        .onDisappear { Task { await model.transfersModel.discardRestore(staged) } }
    }

    private var modeOptions: some View {
        Group {
            Text("Merge").tag(BackupRestoreMode.merge)
            Text("Replace").tag(BackupRestoreMode.replace)
        }
    }

    private func commit() {
        guard !isBusy else { return }
        isCommitting = true
        Task {
            let didImport = await model.commitRestore(selection: selection, mode: mode)
            isCommitting = false
            if didImport { dismiss() }
        }
    }
}

struct BackupExportSelectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection = BackupRestoreSelection.exportDefault
    @State private var confirmsPersonalData = false
    @State private var isPreparing = false

    var body: some View {
        NavigationStack {
            List {
                if let error = model.transfersModel.backupFailure {
                    Section("Couldn’t create backup") { Text(error) }
                        .foregroundStyle(AppColors.danger)
                        .accessibilityIdentifier("backup-export-error")
                }
                BackupContentsToggles(selection: $selection, manifest: nil, isBusy: isPreparing)
                Section {
                    Text("Passwords, API keys, cookies, and sign-in sessions aren’t included.")
                    if selection.includesPersonalData {
                        Text("The selected sections contain private reading information, personal server addresses, or publication files. Only share this backup with people you trust.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .appFullWidthListSeparator()
                if isPreparing { ProgressView("Preparing backup…") }
            }
            .navigationTitle("Export Backup")
            .navigationBarTitleDisplayMode(.inline)
            .appNativeNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    FixedNavigationChrome {
                        Button("Cancel") { dismiss() }.disabled(isPreparing)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    FixedNavigationChrome {
                        Button("Export") {
                            if selection.includesPersonalData { confirmsPersonalData = true }
                            else { prepare() }
                        }
                        .disabled(selection.isEmpty || isPreparing)
                    }
                }
            }
            .confirmationDialog("Share personal data?", isPresented: $confirmsPersonalData, titleVisibility: .visible) {
                Button("Continue Export") { prepare() }
            } message: {
                Text("This backup contains personal data. Only share it with people you trust.")
            }
        }
        .appFeedbackOverlay()
        .interactiveDismissDisabled(isPreparing)
    }

    private func prepare() {
        guard !isPreparing else { return }
        isPreparing = true
        Task {
            await model.transfersModel.prepareBackup(selection: selection)
            isPreparing = false
            if model.transfersModel.backupExport != nil { dismiss() }
        }
    }
}

struct BackupContentsToggles: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var selection: BackupRestoreSelection
    let manifest: BackupManifest?
    let isBusy: Bool

    var body: some View {
        contents("Reading Data", groups: [.library, .readingActivity, .organization, .bookmarksAndAnnotations, .downloadMetadata])
        contents("Setup", groups: [.extensions, .servers, .readerPreferences, .settings])
        contents("Files", groups: [.importedMedia])
    }

    private func contents(_ title: String, groups: [BackupRestoreGroup]) -> some View {
        Section {
            ForEach(groups) { group in
                Toggle(isOn: Binding(get: { selection.contains(group) }, set: { enabled in
                    selection.set(group, isEnabled: enabled)
                    if let manifest { selection = selection.normalized(for: manifest) }
                })) {
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                        : AnyLayout(HStackLayout())
                    layout {
                        Text(group.transferTitle).frame(maxWidth: .infinity, alignment: .leading)
                        if let manifest {
                            Text(group.isAvailable(in: manifest) ? group.countDescription(in: manifest) : "Not included")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("backup-section-\(group.rawValue)")
                .disabled(isBusy || manifest.map { !group.isAvailable(in: $0) } == true)
            }
        } header: {
            Text(title)
        } footer: {
            if title == "Reading Data" {
                Text("Progress, organization, annotations, download metadata, and imported publications require Library. Turning Library off also turns those sections off.")
            }
        }
        .appFullWidthListSeparator()
    }
}

extension BackupRestoreGroup {
    var transferTitle: String {
        switch self {
        case .library: "Library"
        case .readingActivity: "Progress & History"
        case .organization: "Categories & Filters"
        case .bookmarksAndAnnotations: "Bookmarks & Annotations"
        case .downloadMetadata: "Download Metadata"
        case .extensions: "Extensions & Repositories"
        case .servers: "Personal Servers"
        case .readerPreferences: "Reader Preferences"
        case .settings: "App Settings"
        case .importedMedia: "Imported Publications"
        }
    }

    func countDescription(in manifest: BackupManifest) -> String {
        switch self {
        case .settings, .extensions, .servers, .readerPreferences, .importedMedia: "Included"
        default: "\(recordCount(in: manifest)) records"
        }
    }
}
