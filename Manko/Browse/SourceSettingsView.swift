import MankoDomain
import MankoExtensions
import SwiftUI

struct SourceSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: SourceDescriptor

    @State private var configuration: SourceSearchConfiguration?
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?
    @State private var isAwaitingVerification = false
    @State private var isChangingConnector = false
    @State private var connectorError: String?

    var body: some View {
        List {
            Section {
                Text(source.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .browseFullWidthListRow()

            if [.opds, .komga, .kavita, .suwayomi].contains(source.kind) {
                Section {
                    Picker("Connector", selection: Binding(
                        get: { model.sourcesModel.sourceOptions[source.id.rawValue]?["connectorExtensionID"] ?? "" },
                        set: { providerID in
                            isChangingConnector = true
                            connectorError = nil
                            Task {
                                defer { isChangingConnector = false }
                                do { try await model.sourcesModel.setConnector(providerID.isEmpty ? nil : providerID, for: source) }
                                catch { connectorError = error.localizedDescription }
                            }
                        }
                    )) {
                        Text("Connector required").tag("").disabled(true)
                        ForEach(model.sourcesModel.availableConnectors(for: source.kind)) { installed in
                            Text("\(installed.descriptor.name) · \(installed.version)").tag(installed.id)
                        }
                        if let id = model.sourcesModel.sourceOptions[source.id.rawValue]?["connectorExtensionID"],
                           !model.sourcesModel.availableConnectors(for: source.kind).contains(where: { $0.id == id }) {
                            Text("Unavailable connector").tag(id)
                        }
                    }
                    .disabled(isChangingConnector)
                    .accessibilityIdentifier("source-settings-connector")
                    if isChangingConnector { ProgressView("Testing server connection…") }
                    if let connectorError { Text(connectorError).foregroundStyle(.red) }
                } footer: {
                    Text("Changing the connector preserves this server’s library, downloads, reading progress and credentials.")
                }
                .browseFullWidthListRow()
            }

            if source.kind == .mankoExtension {
                Section {
                    Picker("Request Speed", selection: Binding(
                        get: { model.sourcesModel.requestSpeed(for: source) },
                        set: { model.sourcesModel.setRequestSpeed($0, for: source) }
                    )) {
                        Text("Standard").tag(ExtensionRequestSpeed.standard)
                        Text("Slow").tag(ExtensionRequestSpeed.slow)
                        Text("Very Slow").tag(ExtensionRequestSpeed.verySlow)
                    }
                    .accessibilityIdentifier("source-settings-request-speed")
                } footer: {
                    Text("Standard uses the source’s default pace. Slow and Very Slow pause at least 2 and 5 seconds between catalog requests. Server cooldowns may take longer.")
                }
                .browseFullWidthListRow()
            }

            if supportsExclusions || savedExclusionCount > 0 {
                Section {
                    NavigationLink {
                        SourcePersistentExclusionsView(source: source, configuration: configuration)
                    } label: {
                        LabeledContent("Always Exclude", value: savedExclusionCount.formatted())
                    }
                    .accessibilityHint("Manage tags this source should always hide")
                    .accessibilityIdentifier("source-settings-exclusions")
                } footer: {
                    Text("Saved rules apply while browsing and searching this source.")
                }
                .browseFullWidthListRow()
            } else if hasLoaded, !isLoading, errorMessage == nil {
                Section {
                    Text("This source does not support saved exclusions.")
                        .foregroundStyle(.secondary)
                }
                .browseFullWidthListRow()
            }

            if !hasLoaded || isLoading {
                Section {
                    ProgressView("Loading source settings…")
                }
                .browseFullWidthListRow()
            } else if let errorMessage {
                Section {
                    AppInlineStatus(
                        title: "Source settings unavailable",
                        message: errorMessage,
                        actionTitle: isAwaitingVerification ? "Retry Verification" : "Retry"
                    ) {
                        Task { await loadConfiguration(force: true) }
                    }
                }
                .browseFullWidthListRow()
            }
        }
        .browseInsetGroupedList()
        .appBackground()
        .navigationTitle("Source Settings")
        .navigationBarTitleDisplayMode(.inline)
        .appNativeNavigationChrome()
        .toolbar {
            ToolbarItem(id: "source-settings-done", placement: .confirmationAction) {
                FixedNavigationChrome {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: source.id) { await loadConfiguration() }
        .onChange(of: model.sourcesModel.cloudflareVerificationRevision) { _, _ in
            if isAwaitingVerification {
                Task { await loadConfiguration(force: true) }
            }
        }
    }

    private var savedExclusionCount: Int {
        model.sourcesModel.persistentSearchExclusions(for: source).count
    }

    private var supportsExclusions: Bool {
        configuration?.fields.contains(where: \.supportsExclusion) == true
    }

    private func loadConfiguration(force: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        isAwaitingVerification = false
        defer { isLoading = false; hasLoaded = true }
        do {
            let loaded = try await model.sourcesModel.sourceSearchConfiguration(for: source, force: force) { cached in
                configuration = cached
            }
            try Task.checkCancellation()
            configuration = loaded
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            isAwaitingVerification = model.sourcesModel.handleCloudflareHandoff(error)
            errorMessage = isAwaitingVerification
                ? "Complete source verification to load its settings."
                : error.localizedDescription
        }
    }
}
