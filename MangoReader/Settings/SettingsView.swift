import CoreTransferable
import MangoReaderData
import MangoReaderDomain
import MangoReaderExtensions
import MangoReaderReaders
import MangoReaderSources
import MangoReaderSync
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var transfers = model.transfersModel
        let backupExportURL = model.transfersModel.backupExport?.url

        NavigationStack {
            settingsList
        }
            .fileExporter(
                isPresented: $transfers.isExportingBackup,
                item: model.transfersModel.backupExport,
                contentTypes: [.mangoReaderBackup],
                defaultFilename: BackupExportItem.defaultFilename
            ) { result in
                switch result {
                case .success:
                    model.transfersModel.finishBackupExport(url: backupExportURL, completed: true)
                case let .failure(error):
                    model.transfersModel.finishBackupExport(url: backupExportURL, error: error)
                }
            } onCancellation: {
                model.transfersModel.finishBackupExport(url: backupExportURL)
            }
            .fileImporter(
                isPresented: $transfers.isRestoringBackup,
                allowedContentTypes: [.mangoReaderBackup, .zip],
                allowsMultipleSelection: false
            ) { result in
                Task { await model.transfersModel.inspectBackup(result) }
            }
            .sheet(isPresented: $transfers.isSelectingBackupContents, onDismiss: {
                if transfers.backupExport != nil { transfers.isExportingBackup = true }
            }) {
                BackupExportSelectionView()
            }
            .sheet(item: $transfers.stagedRestore, onDismiss: {
                Task { await model.transfersModel.discardRestore() }
            }) { staged in
                RestorePreviewView(staged: staged)
            }
    }

    private var settingsList: some View {
        List {
            Section("Preferences") {
                Picker("Appearance", selection: Binding(
                    get: { model.settingsSyncModel.preferredAppearance },
                    set: { model.setAppearance($0) }
                )) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .accessibilityIdentifier("settings-appearance")

                Button {
                    model.readerSetup.reopen()
                } label: {
                    SettingsNavigationLabel(title: "Reader Setup")
                }
                .accessibilityIdentifier("settings-reader-setup")

                NavigationLink {
                    ReaderSettingsView()
                } label: {
                    SettingsNavigationLabel(title: "Reader Controls")
                }
                .accessibilityIdentifier("settings-reader-controls")
            }
            .appFullWidthListSeparator()

            Section {
                Toggle(
                    "Incognito Reading",
                    isOn: Binding(get: { model.settingsSyncModel.incognitoMode }, set: { model.settingsSyncModel.setIncognito($0) })
                )
                .accessibilityIdentifier("settings-incognito")
            }
            .appFullWidthListSeparator()

            Section("Downloads & Automation") {
                NavigationLink {
                    DownloadSettingsView()
                } label: {
                    SettingsNavigationLabel(title: "Downloads & Storage")
                }
                .accessibilityIdentifier("settings-downloads-storage")

                NavigationLink {
                    AutomationRulesView()
                } label: {
                    SettingsNavigationLabel(title: "Automation Rules")
                }
                .accessibilityIdentifier("settings-automation-rules")
            }
            .appFullWidthListSeparator()

            Section {
                NavigationLink {
                    RepositoryManagerView(presentationContext: .settings)
                } label: {
                    SettingsNavigationLabel(title: "Repositories")
                }
                .accessibilityIdentifier("settings-repositories")

                NavigationLink {
                    SourceTroubleshootingView()
                } label: {
                    SettingsNavigationLabel(title: "Source Troubleshooting")
                }
                .accessibilityIdentifier("settings-source-troubleshooting")

                NavigationLink {
                    TrackerSettingsView()
                } label: {
                    SettingsNavigationLabel(title: "Trackers")
                }
                .disabled(model.isPrivate)
                .accessibilityIdentifier("settings-trackers")

                NavigationLink {
                    SyncBackupSettingsView()
                } label: {
                    SettingsNavigationLabel(title: "Sync & Backup")
                }
                .accessibilityIdentifier("settings-sync-backup")

            } header: {
                Text("Services & Data")
            } footer: {
                Text("version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unavailable")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .textCase(nil)
                    .accessibilityIdentifier("settings-version")
            }
            .appFullWidthListSeparator()
        }
        .listStyle(.insetGrouped)
        .screenTitle(Text("Settings"), presentation: .expanded)
    }
}

struct SourceTroubleshootingView: View {
    @Environment(AppModel.self) private var model
    @State private var showsResetConfirmation = false

    var body: some View {
        Form {
            Section {
                Button(model.sourcesModel.isCheckingSources ? "Repairing Extensions…" : "Repair Extensions") {
                    Task { await model.sourcesModel.checkAndRepairSources() }
                }
                .accessibilityIdentifier("source-troubleshooting-repair")
            } footer: {
                Text("Check and restore missing or damaged extension files.")
            }
            .appFullWidthListSeparator()

            Section {
                Button("Reset Sources and Trackers", role: .destructive) {
                    showsResetConfirmation = true
                }
                .accessibilityIdentifier("source-troubleshooting-reset")
            } footer: {
                Text("Remove all source and tracker setup from this device.")
            }
            .appFullWidthListSeparator()
        }
        .disabled(model.sourcesModel.isCheckingSources || model.sourcesModel.isResettingSources)
        .navigationTitle("Source Troubleshooting")
        .navigationBarTitleDisplayMode(.inline)
        .appNativeNavigationChrome()
        .alert("Reset sources and trackers?", isPresented: $showsResetConfirmation) {
            Button("Reset", role: .destructive) {
                Task { await model.resetAllSources() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes repositories, extensions, server and tracker connections, and their settings and sign-in data from this device. Your library titles, downloads, and reading data remain.")
        }
    }
}
