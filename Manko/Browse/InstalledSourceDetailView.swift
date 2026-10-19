import MankoDomain
import MankoExtensions
import SwiftUI

struct InstalledSourceDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let installed: InstalledRepositorySource
    let entry: SourceRepositoryEntry?
    let repository: RepositoryRecord?
    var showsCloseButton = false
    @State private var trackerIsAuthenticated = false
    @State private var isCheckingAccount = true
    @State private var isAuthenticating = false
    @State private var authenticationError: String?
    @State private var authenticationProgress = "Signing in…"
    @State private var authenticationTask: Task<Void, Never>?
    @State private var oauthSession: TrackerOAuthSession?
    @State private var isUpdating = false
    @State private var showsAccessReview = false
    @State private var updateError: String?
    @State private var showsConnectorSetup = false
    @State private var signOutConfirmation = TrackerSignOutConfirmation()

    private var currentInstallation: InstalledRepositorySource {
        model.sourcesModel.installedRepositorySources.first { $0.id == installed.id } ?? installed
    }

    var body: some View {
        List {
            Section {
                ExtensionDetailHeading(
                    name: entry?.name ?? currentInstallation.descriptor.name,
                    kind: currentInstallation.connectorKind != nil ? String(localized: "Server Connector") : (currentInstallation.kind?.repositoryFilterDisplayName ?? String(localized: "Source")),
                    version: currentInstallation.version,
                    summary: entry?.description ?? ""
                ) {
                    RepositoryIconView(repositoryID: installed.repositoryID, entryID: installed.sourceID,
                        iconIdentity: model.sourcesModel.repositoryIconIdentity(repositoryID: installed.repositoryID, entryID: installed.sourceID), dimension: 60)
                }
                .listRowBackground(Color.clear)
            }

            if !currentInstallation.isRuntimeCompatible || hasUpdate || !currentInstallation.isEnabled || currentInstallation.availability != .available {
                Section {
                    if !currentInstallation.isRuntimeCompatible {
                        Label("Update Required", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(AppColors.warning)
                        Text("Update this extension to keep using it.").foregroundStyle(.secondary)
                    } else if !currentInstallation.isEnabled {
                        Label("Extension Disabled", systemImage: "pause.circle").foregroundStyle(.secondary)
                    }
                    if currentInstallation.availability != .available {
                        Label(currentInstallation.availability.repositoryFilterDisplayName, systemImage: "exclamationmark.circle")
                            .foregroundStyle(AppColors.warning)
                    }
                    if let entry, repository != nil, hasUpdate {
                        Button("Update Extension", systemImage: "arrow.down.circle") {
                            showsAccessReview = true
                        }
                        .disabled(isUpdating || isAuthenticating || entry.availability != .available)
                    } else if !currentInstallation.isRuntimeCompatible {
                        Text("A compatible update is not available.").foregroundStyle(.secondary)
                    }
                    if isUpdating { ProgressView("Updating extension…") }
                    if let updateError { Text(updateError).foregroundStyle(.red) }
                }
                .appFullWidthListRow()
            }

            if let kind = currentInstallation.connectorKind {
                Section {
                    Button("Connect a Server", systemImage: "server.rack") { showsConnectorSetup = true }
                        .disabled(!currentInstallation.isEnabled || !currentInstallation.isRuntimeCompatible || currentInstallation.availability != .available)
                        .accessibilityIdentifier("extension-connect-server")
                } header: {
                    Text("Server Connections")
                } footer: {
                    Text("Add a \(kind.displayName) connection or choose this connector in an existing server’s Source Settings.")
                }
                .appFullWidthListRow()
            }

            if installed.kind == .tracker {
                Section("Tracker Account") {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(!currentInstallation.isRuntimeCompatible ? "Unavailable" : isCheckingAccount ? "Checking Account…" : trackerIsAuthenticated ? "Signed In" : "Not Signed In")
                                .font(.headline)
                            Text(trackerIsAuthenticated ? "Your account is connected for reading updates." : "Connect your account to sync your reading.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: trackerIsAuthenticated ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    if isAuthenticating { ProgressView(authenticationProgress) }
                    if let authenticationError {
                        Label(authenticationError, systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(AppColors.warning)
                    }
                    if trackerIsAuthenticated {
                        Button("Sign Out", role: .destructive) { signOutConfirmation.request() }
                            .accessibilityIdentifier("tracker-sign-out")
                            .confirmationDialog("Sign out of \(currentInstallation.descriptor.name)?",
                                isPresented: $signOutConfirmation.isPresented, titleVisibility: .visible) {
                                Button("Sign Out", role: .destructive) { signOutConfirmation.confirm { signOut() } }
                                Button("Cancel", role: .cancel) { signOutConfirmation.cancel() }
                            } message: {
                                Text("This removes the account credentials from this device. Sign in again to sync. Your library progress and linked titles will remain.")
                            }
                    } else {
                        Button("Sign In") { signIn() }
                            .disabled(!currentInstallation.isEnabled || !currentInstallation.isRuntimeCompatible)
                        if !currentInstallation.isEnabled || !currentInstallation.isRuntimeCompatible {
                            Text(currentInstallation.isRuntimeCompatible ? "Enable this tracker to sign in." : "Update this tracker to sign in.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(isAuthenticating || isCheckingAccount || isUpdating)
                .appFullWidthListRow()
            }

            Section("About This Extension") {
                if let repository {
                    LabeledContent("Repository", value: repository.manifest.repository.name)
                }
                if let entry, !entry.developers.isEmpty {
                    LabeledContent("Developer", value: entry.developers.map(\.name).joined(separator: ", "))
                }
                LabeledContent("Version", value: currentInstallation.version)
            }
            .appFullWidthListRow()
        }
        .appInsetGroupedList()
        .navigationTitle(entry?.name ?? installed.descriptor.name)
        .navigationBarTitleDisplayMode(.inline)
        .appNativeNavigationChrome()
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    FixedNavigationChrome {
                        Button("Close") {
                            cancelAuthentication()
                            dismiss()
                        }
                    }
                }
            }
        }
        .task(id: currentInstallation) {
            guard installed.kind == .tracker else { return }
            isCheckingAccount = true
            defer { isCheckingAccount = false }
            let authenticated = await model.sourcesModel.trackerIsAuthenticated(currentInstallation)
            guard !Task.isCancelled, !isAuthenticating else { return }
            trackerIsAuthenticated = authenticated
        }
        .sheet(isPresented: $showsAccessReview) {
            if let entry, let repository {
                ExtensionAccessReviewView(record: repository, entries: [entry]) { grants in
                    showsAccessReview = false
                    isUpdating = true
                    updateError = nil
                    Task {
                        defer { isUpdating = false }
                        let result = await model.sourcesModel.installRepositorySource(entry.id, fromRepositoryID: repository.id, approval: grants[entry.id])
                        if !result.installed { updateError = result.message }
                    }
                }
            }
        }
        .sheet(isPresented: $showsConnectorSetup) {
            if let kind = currentInstallation.connectorKind {
                AddSourceView(initialKind: kind, initialConnectorID: currentInstallation.id)
            }
        }
        .onDisappear { cancelAuthentication() }
    }

    private var hasUpdate: Bool {
        entry.map { RepositoryVersion.hasUpdate(entry: $0, installed: currentInstallation) } ?? false
    }

    private func signIn() {
        guard !isAuthenticating else { return }
        let installation = currentInstallation
        isAuthenticating = true
        authenticationError = nil
        authenticationProgress = "Signing in…"
        authenticationTask = Task {
            defer {
                oauthSession = nil
                authenticationTask = nil
                isAuthenticating = false
            }
            do {
                let descriptor = try await model.sourcesModel.trackerAuthenticationDescriptor(for: installation)
                try Task.checkCancellation()
                let session = TrackerOAuthSession()
                oauthSession = session
                let credential = try await session.authorize(descriptor: descriptor)
                try Task.checkCancellation()
                authenticationProgress = "Saving account…"
                try await model.storeTrackerOAuthCredentials(
                    for: installation,
                    accessToken: credential.accessToken,
                    refreshToken: credential.refreshToken,
                    tokenType: credential.tokenType,
                    expiresAt: credential.expiresAt
                )
                try Task.checkCancellation()
                trackerIsAuthenticated = true
            } catch is CancellationError {
                // Cancelling the browser is not an error that needs an alert.
            } catch {
                guard !Task.isCancelled else { return }
                authenticationError = error.localizedDescription
            }
        }
    }

    private func signOut() {
        guard !isAuthenticating else { return }
        let installation = currentInstallation
        isAuthenticating = true
        authenticationError = nil
        authenticationProgress = "Signing out…"
        authenticationTask = Task {
            defer {
                authenticationTask = nil
                isAuthenticating = false
            }
            do {
                try Task.checkCancellation()
                let trackerID = model.trackingModel.trackerID(for: installation)
                try await model.trackingModel.beginAccountChange(trackerID: trackerID)
                defer { model.trackingModel.finishAccountChange(trackerID: trackerID) }
                try await model.sourcesModel.signOutTracker(installation)
                try Task.checkCancellation()
                trackerIsAuthenticated = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                authenticationError = error.localizedDescription
            }
        }
    }

    private func cancelAuthentication() {
        authenticationTask?.cancel()
        oauthSession?.cancel()
    }
}


struct TrackerSignOutConfirmation {
    var isPresented = false
    private var isRequested = false

    mutating func request() { isRequested = true; isPresented = true }
    mutating func cancel() { isRequested = false; isPresented = false }
    mutating func confirm(_ action: () -> Void) {
        guard isRequested else { return }
        cancel()
        action()
    }
}

struct ExtensionDetailHeading<Icon: View>: View {
    let name: String
    let kind: String
    let version: String
    let summary: String
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                icon()
                VStack(alignment: .leading, spacing: 5) {
                    Text(name).font(.title2.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("extension-detail-name")
                    Text(kind).font(.subheadline).foregroundStyle(.secondary)
                    Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !summary.isEmpty {
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}
