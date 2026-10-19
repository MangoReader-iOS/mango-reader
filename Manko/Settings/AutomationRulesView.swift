import CoreTransferable
import MankoData
import MankoDomain
import MankoExtensions
import MankoReaders
import MankoSources
import MankoSync
import SwiftUI
import UniformTypeIdentifiers

struct AutomationRulesDraft {
    var rules: LibraryAutomationRules = .disabled
    private(set) var isLoaded = false

    mutating func loadIfNeeded(_ savedRules: LibraryAutomationRules) {
        guard !isLoaded else { return }
        rules = savedRules
        isLoaded = true
    }
}

struct AutomationRulesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var draft = AutomationRulesDraft()
    @State private var isSaving = false
    @State private var savedConfirmation = false
    @State private var isConfirmingDiscard = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Automatic maintenance") {
                    if model.settingsSyncModel.isRunningAutomation || model.settingsSyncModel.isRequestingAutomation {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Running…")
                        }
                    } else if model.settingsSyncModel.automationIsEnabled {
                        Text("Active")
                    } else {
                        Text("Off")
                    }
                }

                if let report = model.settingsSyncModel.lastAutomationRun {
                    LabeledContent("Last run") {
                        Text(report.finishedAt, format: .dateTime.month().day().hour().minute())
                    }
                    Text(
                        "Checked \(report.checkedWorkCount), updated \(report.updatedWorkCount), queued \(report.queuedDownloadCount), deleted \(report.deletedDownloadCount), failed \(report.failureCount)."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                if let error = model.settingsSyncModel.automationLastError {
                    SettingsSemanticLabel(
                        title: error,
                        systemImage: "exclamationmark.triangle.fill",
                        color: AppColors.warning,
                        font: .footnote
                    )
                }

                Button("Run Saved Rules Now", systemImage: "play.fill") {
                    Task { _ = await model.runAutomationNow() }
                }
                .foregroundStyle(canRunSavedRules ? AppColors.action : Color.secondary)
                .tint(canRunSavedRules ? AppColors.action : Color.secondary)
                .disabled(!canRunSavedRules)
                if let error = model.settingsSyncModel.automationScheduleError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Status")
            } footer: {
                if isDirty {
                    Text("Save your changes before running these rules.")
                } else if !model.settingsSyncModel.automationIsEnabled {
                    Text("Enable update checks or cleanup, then save, to run automation.")
                }
            }
            .appFullWidthListSeparator()

            Section("Update & Download") {
                Toggle("Check configured sources for updates", isOn: $draft.rules.checksForUpdates)
                Toggle("Download new installments", isOn: $draft.rules.downloadsNewInstallments)
                    .disabled(!draft.rules.checksForUpdates)
            }
            .appFullWidthListSeparator()

            Section {
                Toggle("Delete completed downloads after reading", isOn: $draft.rules.deletesCompletedDownloads)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Keep completed downloads for")
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 8) {
                            retentionValueField
                            retentionStepper
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    } else {
                        HStack(spacing: 12) {
                            retentionValueField
                            Spacer(minLength: 12)
                            retentionStepper
                        }
                    }
                }
                .disabled(!draft.rules.deletesCompletedDownloads)
            } header: {
                Text("Cleanup")
            } footer: {
                if isSaving {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Saving rules…")
                    }
                } else if isDirty {
                    Text("Unsaved changes")
                        .foregroundStyle(AppColors.warning)
                } else {
                    Text(
                        savedConfirmation
                            ? "Saved on this device"
                            : "No unsaved changes"
                    )
                }
            }
            .appFullWidthListSeparator()
        }
        .navigationTitle("Automation Rules")
        .navigationBarTitleDisplayMode(.inline)
        .appNativeNavigationChrome()
        .navigationBarBackButtonHidden(isDirty || isSaving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                FixedNavigationChrome {
                    if isDirty || isSaving {
                        Button {
                            requestDismissal()
                        } label: {
                            Label("Settings", systemImage: "chevron.backward")
                        }
                        .disabled(isSaving)
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                FixedNavigationChrome {
                    if isDirty || isSaving {
                        Button {
                            save()
                        } label: {
                            if isSaving {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel("Saving rules")
                            } else {
                                Text("Save")
                            }
                        }
                        .disabled(!isDirty || isSaving)
                        .accessibilityLabel("Save Rules")
                    }
                }
            }
        }
        .onAppear {
            draft.loadIfNeeded(model.settingsSyncModel.automationRules)
        }
        .onChange(of: draft.rules) { _, newDraft in
            if newDraft != model.settingsSyncModel.automationRules {
                savedConfirmation = false
            }
        }
        .confirmationDialog(
            "Discard Unsaved Changes?",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) {
                draft.rules = model.settingsSyncModel.automationRules
                dismiss()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your automation rules have not been saved.")
        }
    }

    private var isDirty: Bool {
        draft.rules != model.settingsSyncModel.automationRules
    }

    private var canRunSavedRules: Bool {
        !model.settingsSyncModel.isRunningAutomation
            && !model.settingsSyncModel.isRequestingAutomation
            && model.settingsSyncModel.automationIsEnabled
            && !isDirty
    }

    private var retentionDaysBinding: Binding<Int> {
        Binding(
            get: { draft.rules.deleteDelayDays },
            set: { draft.rules.deleteDelayDays = min(max($0, 0), 365) }
        )
    }

    private var retentionValueField: some View {
        HStack(spacing: 6) {
            TextField("Retention days", value: retentionDaysBinding, format: .number)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: dynamicTypeSize.isAccessibilitySize ? 96 : 64)
                .accessibilityLabel("Retention days")
            if draft.rules.deleteDelayDays == 1 {
                Text("day")
                    .foregroundStyle(.secondary)
            } else {
                Text("days")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var retentionStepper: some View {
        Stepper(
            "Adjust retention days",
            value: retentionDaysBinding,
            in: 0 ... 365,
            step: 1
        )
        .labelsHidden()
        .accessibilityLabel("Adjust retention days")
        .accessibilityValue(
            "\(draft.rules.deleteDelayDays) day\(draft.rules.deleteDelayDays == 1 ? "" : "s")"
        )
        .frame(minHeight: 44)
    }

    private func requestDismissal() {
        guard !isSaving else { return }
        if isDirty {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func save() {
        guard isDirty, !isSaving else { return }
        isSaving = true
        Task { @MainActor in
            let didSave = await model.settingsSyncModel.saveAutomationRules(draft.rules)
            isSaving = false
            if didSave {
                draft.rules = model.settingsSyncModel.automationRules
                savedConfirmation = true
            }
        }
    }
}
