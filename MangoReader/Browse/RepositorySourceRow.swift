import MangoReaderDomain
import MangoReaderExtensions
import SwiftUI

// Presentation-only estimated activity, never measured download progress.
struct RepositoryActionProgress: Equatable {
    enum Phase: Equatable { case idle, working, finishing, succeeded, failed }
    static let estimateDuration: TimeInterval = 8
    static let estimateLimit = 0.7
    static let finishDuration: TimeInterval = 0.2
    private(set) var phase: Phase = .idle
    private(set) var operationID = UUID()
    private(set) var startedAt = Date.distantPast
    private(set) var finishedAt: Date?
    private var finishFrom = 0.0

    var isBusy: Bool { phase == .working || phase == .finishing }

    @discardableResult
    mutating func begin(at date: Date = .now) -> UUID {
        operationID = UUID()
        startedAt = date
        finishedAt = nil
        finishFrom = 0
        phase = .working
        return operationID
    }

    func fraction(at date: Date, reduceMotion: Bool = false) -> Double {
        switch phase {
        case .idle, .failed: return 0
        case .succeeded: return 1
        case .working:
            if reduceMotion { return 0.15 }
            return Self.estimateLimit * Self.easeOut(date.timeIntervalSince(startedAt) / Self.estimateDuration)
        case .finishing:
            let elapsed = date.timeIntervalSince(finishedAt ?? date) / Self.finishDuration
            return finishFrom + (1 - finishFrom) * Self.easeOut(elapsed)
        }
    }

    mutating func finish(operationID: UUID, succeeded: Bool, at date: Date = .now, reduceMotion: Bool = false) {
        guard self.operationID == operationID, phase == .working else { return }
        guard succeeded else { phase = .failed; return }
        if reduceMotion || date.timeIntervalSince(startedAt) < 0.15 {
            phase = .succeeded
        } else {
            finishFrom = fraction(at: date)
            finishedAt = date
            phase = .finishing
        }
    }

    mutating func completeTransition(operationID: UUID) {
        guard self.operationID == operationID, phase == .finishing else { return }
        phase = .succeeded
    }

    private static func easeOut(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return 1 - pow(1 - t, 3)
    }
}

private struct RepositoryInstallRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let progress: RepositoryActionProgress
    let label: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            Gauge(value: progress.fraction(at: context.date, reduceMotion: reduceMotion)) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(AppColors.action)
            .scaleEffect(0.6)
            .frame(width: 32, height: 32)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue("In progress")
        }
    }
}

enum RepositorySourceRowAction: Equatable {
    case get
    case update
    case enable
    case installed

    static func resolve(isInstalled: Bool, isEnabled: Bool, hasUpdate: Bool) -> Self {
        guard isInstalled else { return .get }
        if hasUpdate { return .update }
        return isEnabled ? .installed : .enable
    }
}

extension ExtensionAvailability {
    var sourceInteractionMessage: String? {
        switch self {
        case .available: nil
        case .serviceUnavailable: "This source is temporarily unavailable. Refresh its repository to check again."
        case .retired: "The publisher has retired this source. Choose another source to continue."
        }
    }
}

struct RepositorySourceRow: View {
    @Environment(\.openURL) private var openURL
    @State private var externalDestination: URL?
    @State private var showsConnectorSetup = false
    @State private var accessReview: RepositoryRecord?
    private enum SourceAction {
        case install
        case setEnabled(Bool)
        case restart
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var actionWidth: CGFloat = 96
    let repositoryID: String
    let entryID: String
    let showsNewFlair: Bool
    var showsRepositoryName = false
    var identifierPrefix: String? = nil
    let onRequestRemoval: (InstalledRepositorySource) -> Void
    @State private var actionState = RepositoryActionProgress()
    @State private var operationLabel = ""
    @State private var actionMessage: String?
    @State private var lastAction = SourceAction.install

    private var repository: RepositoryRecord? {
        model.sourcesModel.sourceRepositories.first { $0.id == repositoryID }
    }

    private var entry: SourceRepositoryEntry? {
        repository?.manifest.sources.first { $0.id == entryID }
    }

    private var installed: InstalledRepositorySource? {
        model.sourcesModel.installedRepositorySources.first { $0.repositoryID == repositoryID && $0.sourceID == entryID }
    }

    private var hasUpdate: Bool {
        model.sourcesModel.repositorySourceHasUpdate(repositoryID: repositoryID, entryID: entryID)
    }

    private var rowAction: RepositorySourceRowAction {
        RepositorySourceRowAction.resolve(
            isInstalled: installed != nil,
            isEnabled: installed?.isEnabled == true,
            hasUpdate: hasUpdate
        )
    }

    var body: some View {
        if let entry {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            VStack(alignment: .leading, spacing: 6) {
                layout {
                    accessibleDescription(for: entry)
                    actionButton(entry: entry)
                }
                if let installed, installed.connectorKind != nil {
                    Button("Connect a Server", systemImage: "server.rack") { showsConnectorSetup = true }
                        .disabled(!installed.isEnabled || !installed.isRuntimeCompatible || installed.availability != .available)
                        .accessibilityIdentifier("\(rowIdentifier(entry))-connect")
                }
                if let message = actionMessage ?? migrationMessage ?? entry.availability.sourceInteractionMessage {
                    Label(message, systemImage: actionState.phase == .failed ? "exclamationmark.circle" : "info.circle")
                        .font(.footnote)
                        .foregroundStyle(actionState.phase == .failed ? AppColors.danger : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("\(rowIdentifier(entry))-result")
                }
            }
            .task(id: actionState.phase) {
                guard actionState.phase == .finishing, let finishedAt = actionState.finishedAt else { return }
                let operationID = actionState.operationID
                let remaining = max(0, RepositoryActionProgress.finishDuration - Date().timeIntervalSince(finishedAt))
                if !reduceMotion { try? await Task.sleep(for: .seconds(remaining)) }
                guard !Task.isCancelled else { return }
                actionState.completeTransition(operationID: operationID)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .accessibilityIdentifier(rowIdentifier(entry))
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if let installed {
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        onRequestRemoval(installed)
                    }
                    .accessibilityLabel("Remove \(entry.name)")
                }
            }
            .contextMenu {
                if let repository {
                    if let url = repositoryMetadataURL(
                        repository.manifest.repository.privacyURL,
                        relativeTo: repository.repositoryURL
                    ) {
                        Button { externalDestination = url } label: {
                            Label("Publisher Privacy Policy", systemImage: "hand.raised")
                        }
                    }
                    if let url = repositoryMetadataURL(entry.reportURL, relativeTo: repository.repositoryURL) {
                        Button { externalDestination = url } label: {
                            Label("Report a Source Issue", systemImage: "exclamationmark.bubble")
                        }
                    }
                }
                if let installed {
                    Button("Restart Session", systemImage: "arrow.clockwise") {
                        retry(installed)
                    }
                    .disabled(!installed.isRuntimeCompatible)
                    Button(
                        installed.isEnabled ? "Disable" : "Enable",
                        systemImage: installed.isEnabled ? "pause.circle" : "play.circle"
                    ) {
                        toggle(installed)
                    }
                    Divider()
                    Button("Remove Source", systemImage: "trash", role: .destructive) {
                        onRequestRemoval(installed)
                    }
                }
            }
            .confirmationDialog("Open Publisher Website?", isPresented: Binding(
                get: { externalDestination != nil }, set: { if !$0 { externalDestination = nil } }
            ), titleVisibility: .visible) {
                if let url = externalDestination { Button("Open in Browser") { openURL(url); externalDestination = nil } }
                Button("Cancel", role: .cancel) { externalDestination = nil }
            } message: { Text(externalDestination?.absoluteString ?? "") }
            .sheet(item: $accessReview) { record in
                if let reviewedEntry = record.manifest.sources.first(where: { $0.id == entryID }) {
                    ExtensionAccessReviewView(record: record, entries: [reviewedEntry]) { grants in
                        accessReview = nil
                        performInstall(approval: grants[entryID])
                    }
                }
            }
            .sheet(isPresented: $showsConnectorSetup) {
                if let installed, let kind = installed.connectorKind {
                    AddSourceView(initialKind: kind, initialConnectorID: installed.id)
                }
            }
        } else if let installed {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(installed.descriptor.name).font(.headline)
                    Text("Unavailable").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Remove", systemImage: "trash", role: .destructive) { onRequestRemoval(installed) }
            }
        }
    }

    private var migrationMessage: String? {
        if installed?.isRuntimeCompatible == false {
            return hasUpdate ? "Update required for this version of Mango Reader." : "This extension is unavailable. Its library content is retained."
        }
        if entry?.entryType == .mangoReaderExtension, entry?.mangoReaderExtension?.isExecutable != true {
            return "This extension uses an unsupported runtime."
        }
        return nil
    }

    @ViewBuilder
    private func accessibleDescription(for entry: SourceRepositoryEntry) -> some View {
        if let installed {
            description(for: entry)
                .accessibilityAction(named: "Restart session for \(entry.name)") {
                    retry(installed)
                }
                .accessibilityAction(named: "\(installed.isEnabled ? "Disable" : "Enable") \(entry.name)") {
                    toggle(installed)
                }
                .accessibilityAction(named: "Remove \(entry.name)") {
                    onRequestRemoval(installed)
                }
        } else {
            description(for: entry)
        }
    }

    private func description(for entry: SourceRepositoryEntry) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            RepositoryIconView(
                repositoryID: repositoryID,
                entryID: entryID,
                iconIdentity: "\(entry.icon)::\(repository?.checkedAt.timeIntervalSinceReferenceDate ?? 0)",
                dimension: 46
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(.headline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(metadataSummary(entry))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)

                if showsRepositoryName, let repository {
                    Text(repository.manifest.repository.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 5) { flairContent(entry: entry) }
                } else {
                    HStack(spacing: 5) { flairContent(entry: entry) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 68, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func flairContent(entry: SourceRepositoryEntry) -> some View {
        if showsNewFlair {
            RepositoryFlair(text: "NEW", color: AppColors.information)
        }

    }

    private func actionButton(entry: SourceRepositoryEntry) -> some View {
        Group {
            if installed?.isRuntimeCompatible == false && !hasUpdate {
                Text("Unavailable").foregroundStyle(.secondary)
            } else if actionState.isBusy {
                RepositoryInstallRing(progress: actionState, label: operationLabel)
            } else if rowAction != .installed || actionState.phase == .failed {
                Button { performAction() } label: {
                    Text(actionState.phase == .failed ? "Try Again" : rowActionTitle)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .frame(minHeight: 30)
                        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: actionAlignment)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(entry.availability == .available ? AppColors.action : Color.secondary)
                .disabled(entry.availability != .available || (entry.entryType == .mangoReaderExtension && entry.mangoReaderExtension?.isExecutable != true))
                .accessibilityLabel("\(actionState.phase == .failed ? "Try Again" : rowActionTitle) \(entry.name)")
                .accessibilityIdentifier(actionIdentifier(entry))
            } else {
                Text("Installed")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline.weight(.semibold))
        .frame(width: min(actionWidth, 196), alignment: actionAlignment)
        .frame(minHeight: 44)
    }

    private var actionAlignment: Alignment {
        dynamicTypeSize.isAccessibilitySize ? .leading : .trailing
    }

    private func retry(_ installed: InstalledRepositorySource) {
        guard let operationID = beginAction(.restart) else { return }
        Task {
            let restarted = await model.sourcesModel.retryInstalledRepositorySource(installed)
            finishAction(operationID, succeeded: restarted, message: "The source session could not be restarted. Try again.")
        }
    }

    private func toggle(_ installed: InstalledRepositorySource) {
        setEnabled(installed, isEnabled: !installed.isEnabled)
    }

    private var rowActionTitle: String {
        switch rowAction {
        case .get: "Install"
        case .update: "Update"
        case .enable: "Enable"
        case .installed: "Installed"
        }
    }

    private func performAction() {
        if actionState.phase == .failed, let installed {
            switch lastAction {
            case .restart:
                retry(installed)
                return
            case let .setEnabled(isEnabled):
                setEnabled(installed, isEnabled: isEnabled)
                return
            case .install: break
            }
        }
        if rowAction == .enable, let installed {
            setEnabled(installed, isEnabled: true)
        } else {
            install()
        }
    }

    private func setEnabled(_ installed: InstalledRepositorySource, isEnabled: Bool) {
        guard let operationID = beginAction(.setEnabled(isEnabled)) else { return }
        Task {
            let changed = await model.sourcesModel.setInstalledRepositorySource(installed, isEnabled: isEnabled)
            finishAction(operationID, succeeded: changed, message: "The source could not be updated. Try again.")
        }
    }

    private func install() {
        accessReview = repository
    }

    private func performInstall(approval: ExtensionAccessGrant?) {
        guard let operationID = beginAction(.install) else { return }
        Task {
            let result = await model.sourcesModel.installRepositorySource(entryID, fromRepositoryID: repositoryID, approval: approval)
            finishAction(operationID, succeeded: result.installed, message: result.message)
        }
    }

    private func beginAction(_ action: SourceAction) -> UUID? {
        guard !actionState.isBusy else { return nil }
        let name = entry?.name ?? "source"
        switch action {
        case .install: operationLabel = rowAction == .update ? "Updating \(name)" : "Installing \(name)"
        case let .setEnabled(enabled): operationLabel = enabled ? "Enabling \(name)" : "Disabling \(name)"
        case .restart: operationLabel = "Restarting \(name)"
        }
        lastAction = action
        actionMessage = nil
        return actionState.begin()
    }

    private func finishAction(_ operationID: UUID, succeeded: Bool, message: String) {
        guard actionState.operationID == operationID else { return }
        actionMessage = succeeded ? nil : message
        actionState.finish(operationID: operationID, succeeded: succeeded, reduceMotion: reduceMotion)
    }

    private func languageSummary(_ languages: [String]) -> String {
        if languages.isEmpty { return "All languages" }
        if languages.count > 3 { return "\(languages.count) languages" }
        return languages.map { $0.uppercased() }.joined(separator: ", ")
    }

    private func metadataSummary(_ entry: SourceRepositoryEntry) -> String {
        "v\(entry.version) · \(languageSummary(entry.languages))"
    }

    private func rowIdentifier(_ entry: SourceRepositoryEntry) -> String {
        if let identifierPrefix { return "\(identifierPrefix)-source-\(entry.id)" }
        return "repository-source-\(entry.id)"
    }

    private func actionIdentifier(_ entry: SourceRepositoryEntry) -> String {
        if let identifierPrefix { return "\(identifierPrefix)-action-\(entry.id)" }
        return "repository-source-action-\(entry.id)"
    }
}


/// One native review for the immutable catalog snapshot about to be installed.
struct ExtensionAccessReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let record: RepositoryRecord
    let entries: [SourceRepositoryEntry]
    let onApprove: ([String: ExtensionAccessGrant]) -> Void
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                ExtensionAccessReviewSections(record: record, entries: entries)
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .browseInsetGroupedList()
            .navigationTitle("Review Access")
            .navigationBarTitleDisplayMode(.inline)
            .appNativeNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { FixedNavigationChrome { Button("Cancel") { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    FixedNavigationChrome {
                        Button("Install") {
                            do {
                                let grants = try Dictionary(uniqueKeysWithValues: entries.map {
                                    ($0.id, try ExtensionAccessGrant(entry: $0, record: record))
                                })
                                onApprove(grants)
                            } catch { self.error = error.localizedDescription }
                        }
                        .accessibilityLabel("Allow access and install")
                        .disabled(entries.isEmpty)
                    }
                }
            }
        }
    }
}

struct ExtensionAccessReviewSections: View {
    let record: RepositoryRecord
    let entries: [SourceRepositoryEntry]
    var body: some View {
        Section("Publisher") {
            Text(record.repositoryURL.absoluteString).textSelection(.enabled)
            Text("Mango Reader hasn’t verified this publisher. Only install extensions and approve websites you trust.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(entries) { entry in
            Section(entry.name + " · " + entry.version) {
                ForEach((entry.mangoReaderExtension?.allowedHTTPSHosts ?? []).sorted(), id: \.self) { host in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("https://" + host).textSelection(.enabled)
                        if host.hasPrefix("*.") {
                            Text("Allows every subdomain of " + host.dropFirst(2) + ".")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if entry.mangoReaderExtension?.connectorKind != nil {
                    Text("Server access is limited to the exact address you configure for each connection.")
                }
                if let account = entry.mangoReaderExtension?.accountPolicy {
                    if let url = account.authentication.authorizationURL {
                        LabeledContent("Sign-in page") { Text(url.absoluteString).textSelection(.enabled) }
                    }
                    if let url = account.authentication.tokenURL {
                        LabeledContent("Token endpoint") { Text(url.absoluteString).textSelection(.enabled) }
                    }
                    ForEach(Array(account.requests.enumerated()), id: \.offset) { _, rule in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.origin + rule.pathPrefix).textSelection(.enabled)
                            Text(Set(rule.operations.map { operation in
                                switch operation {
                                case "trackerSearch": "Search titles"
                                case "progress", "progressBatch": "Read your progress"
                                case "update": "Update your list"
                                case "collections": "Read your lists"
                                default: operation
                                }
                            }).sorted().joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if account.requests.contains(where: { $0.operations.contains("update") }) {
                        Text("This extension can make changes to your account lists and progress.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("This extension can read account responses and perform the listed actions. Mango Reader keeps your tokens out of extension code.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if entry.permissions.values.contains(.state) || entry.permissions.values.contains(.secureState) {
                    Text("Store this extension’s settings and data on your device.")
                }
                if entry.permissions.values.contains(.cookies) || entry.permissions.values.contains(.challengeHandoff) {
                    Text("Use a separate website session for sign-in or verification.")
                }
                Text("Website operators can see requests, your IP address, and information the extension sends. Only approve websites you trust.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
