import CoreTransferable
import MangoReaderData
import MangoReaderDomain
import MangoReaderExtensions
import MangoReaderReaders
import MangoReaderSources
import MangoReaderSync
import SwiftUI
import UniformTypeIdentifiers

struct SyncBackupSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("iCloud") {
                syncStatus
                if model.settingsSyncModel.isCloudSyncing {
                    HStack {
                        ProgressView()
                        Text("Synchronizing…")
                    }
                } else {
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath.icloud") {
                        Task { await model.synchronizeCloud() }
                    }
                }

                Toggle("Sync imported files to iCloud Drive", isOn: Binding(
                    get: { model.settingsSyncModel.syncImportedFiles },
                    set: { model.setSyncImportedFiles($0) }
                ))
                .disabled(model.settingsSyncModel.isUpdatingImportedFileSync)
                if model.settingsSyncModel.isUpdatingImportedFileSync {
                    ProgressView("Applying file sync preference…")
                }
                if let status = model.settingsSyncModel.importedFileSyncStatus {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if model.settingsSyncModel.importedFileSyncNeedsRetry {
                    Button("Retry File Sync", systemImage: "arrow.clockwise") {
                        model.setSyncImportedFiles(model.settingsSyncModel.syncImportedFiles)
                    }
                    .disabled(model.settingsSyncModel.isUpdatingImportedFileSync)
                }
            }
            .appFullWidthListSeparator()

            Section("Backup") {
                Button("Export Backup", systemImage: "square.and.arrow.up") {
                    model.transfersModel.backupFailure = nil
                    model.transfersModel.isSelectingBackupContents = true
                }
                .disabled(model.transfersModel.isBackupBusy)
                Button("Restore Backup", systemImage: "arrow.counterclockwise") {
                    model.transfersModel.isRestoringBackup = true
                }
                .disabled(model.transfersModel.isBackupBusy)
                if let operation = model.transfersModel.backupOperation {
                    ProgressView(operation.rawValue)
                        .accessibilityIdentifier("backup-operation-progress")
                }
            }
            .appFullWidthListSeparator()
        }
        .disabled(model.isPrivate)
        .navigationTitle("Sync & Backup")
        .navigationBarTitleDisplayMode(.inline)
        .appNativeNavigationChrome()
    }

    @ViewBuilder
    private var syncStatus: some View {
        switch model.settingsSyncModel.cloudSyncAvailability {
        case .available:
            Text(model.settingsSyncModel.cloudSyncAvailability.settingsDescription)
        case .stopped:
            Text(model.settingsSyncModel.cloudSyncAvailability.settingsDescription)
                .foregroundStyle(.secondary)
        case .signedOut, .switchedAccount:
            SettingsSemanticLabel(
                title: model.settingsSyncModel.cloudSyncAvailability.settingsDescription,
                systemImage: model.settingsSyncModel.cloudSyncAvailability.settingsSymbol,
                color: AppColors.warning
            )
        case .unavailable, .failed:
            SettingsSemanticLabel(
                title: model.settingsSyncModel.cloudSyncAvailability.settingsDescription,
                systemImage: model.settingsSyncModel.cloudSyncAvailability.settingsSymbol,
                color: AppColors.danger
            )
        }
    }
}

private extension CloudSyncAvailability {
    var settingsDescription: String {
        switch self {
        case .stopped: "Not started"
        case .available: "iCloud is available"
        case .signedOut: "Sign in to iCloud to sync"
        case .switchedAccount: "iCloud account changed; sync again"
        case let .unavailable(message), let .failed(message): message
        }
    }

    var settingsSymbol: String {
        switch self {
        case .available: "checkmark.icloud"
        case .stopped: "icloud"
        case .signedOut: "person.crop.circle.badge.exclamationmark"
        case .switchedAccount: "arrow.triangle.2.circlepath.icloud"
        case .unavailable, .failed: "exclamationmark.icloud"
        }
    }

}
