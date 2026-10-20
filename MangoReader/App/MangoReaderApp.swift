import Foundation
import MangoReaderDomain
import MangoReaderReaders
import MangoReaderSources
import OSLog
import SwiftUI
#if DEBUG && targetEnvironment(macCatalyst)
import UniformTypeIdentifiers
#endif

@main
struct MangoReaderApp: App {
    @UIApplicationDelegateAdaptor(MangoReaderAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if MangoReaderTestEnvironment.isUnitTesting {
                Color.clear
            } else {
                MangoReaderSceneView()
            }
            #else
            MangoReaderSceneView()
            #endif
        }
        .commands {
            MangoReaderCommands()
        }
    }
}

private struct MangoReaderSceneView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.scenePhase) private var scenePhase
    @State private var normalModel: AppModel
    @State private var libraryContext = PrivateLibraryCoordinator.shared
    private var model: AppModel { libraryContext.model ?? normalModel }
    @State private var readerCoordinator = ReaderPresentationCoordinator()
    @State private var startupURLQueue = StartupURLQueue()
    @State private var setupSceneID = UUID()
    #if DEBUG && targetEnvironment(macCatalyst)
    @State private var screenshotInputPicker = false
    @State private var screenshotInputError: String?
    @State private var screenshotInputsReady = !MangoReaderScreenshotMode.isEnabled ||
        FileManager.default.fileExists(atPath: MangoReaderScreenshotMode.inputDirectory.appendingPathComponent("books.json").path)
    #endif

    init() {
        #if DEBUG
        if ServerLabFixture.isEnabled {
            _normalModel = State(initialValue: ServerLabFixture.makeModel())
            return
        }
        if MangoReaderDemoMode.isEnabled {
            _normalModel = State(initialValue: AppModel(defaults: MangoReaderDemoMode.defaults()))
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--mangoreader-reader-setup-verification") {
            let suite = "manko.reader-setup-verification"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let verificationModel = AppModel(defaults: defaults)
            verificationModel.readerSetup.reopen()
            verificationModel.readerSetup.draft = ReaderSetupDraft(defaults: defaults)
            defaults.removeObject(forKey: ReaderSetupCoordinator.completedKey)
            _normalModel = State(initialValue: verificationModel)
            return
        }
        if ExtensionAuditFixture.isEnabled {
            _normalModel = State(initialValue: AppModel(defaults: ExtensionAuditFixture.defaults()))
            return
        }
        if MangoReaderScreenshotMode.isEnabled {
            _normalModel = State(initialValue: AppModel(defaults: MangoReaderScreenshotMode.defaults()))
            return
        }
        if AppFixtures.isVerifyingReaderOpening {
            let defaults = UserDefaults(suiteName: "manko.reader-opening-verification")!
            defaults.set(true, forKey: "incognitoMode")
            _normalModel = State(initialValue: AppModel(defaults: defaults))
            return
        }
        #endif
        _normalModel = State(initialValue: AppModel())
    }

    var body: some View {
        ZStack {
            #if DEBUG && targetEnvironment(macCatalyst)
            if !screenshotInputsReady {
                VStack(spacing: 20) {
                    Text("Screenshot fixtures").font(.title)
                    Text("Select the generated AppStoreScreenshots inputs folder.")
                    Button("Select screenshot inputs") { screenshotInputPicker = true }
                }
                .fileImporter(isPresented: $screenshotInputPicker, allowedContentTypes: [.folder]) { result in
                    do {
                        try MangoReaderScreenshotMode.stageInputs(from: result.get())
                        screenshotInputsReady = true
                        Task { await model.bootstrap() }
                    } catch {
                        screenshotInputError = error.localizedDescription
                    }
                }
                .alert("Screenshot inputs unavailable", isPresented: Binding(
                    get: { screenshotInputError != nil },
                    set: { if !$0 { screenshotInputError = nil } }
                )) {
                    Button("OK") { screenshotInputError = nil }
                } message: {
                    Text(screenshotInputError ?? "")
                }
            } else { startupContent }
            #else
            startupContent
            #endif
        }
            .id(model.deviceID)
            .environment(libraryContext)
            .background(PrivateLibraryPrivacyShield(isPrivate: model.isPrivate))
            .environment(model)
            .defaultAppStorage(model.defaults)
            .environment(readerCoordinator)
            .environment(\.dynamicTypeSize, effectiveDynamicTypeSize)
            .environment(\.layoutDirection, effectiveLayoutDirection)
            .focusedSceneValue(\.mangoReaderModel, model)
            .task(id: model.deviceID) {
                #if DEBUG && targetEnvironment(macCatalyst)
                guard screenshotInputsReady else { return }
                #endif
                await model.bootstrap()
                model.updateSceneIsActive(scenePhase == .active)
            }
            .onChange(of: scenePhase) { _, phase in
                model.searchModel.updateScenePhase(phase)
                model.updateSceneIsActive(phase == .active)
                if phase == .background { libraryContext.lock() }
                guard phase == .active else { return }
                Task { await model.performForegroundLibraryMaintenance() }
            }
            .onChange(of: model.bootstrapPhase) { _, phase in
                guard phase == .ready else { return }
                replayPendingOpenURLs()
            }
            .onChange(of: libraryContext.revision) { _, _ in
                _ = readerCoordinator.completeDismissal()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                libraryContext.lock()
            }
            .onOpenURL(perform: receiveOpenURL)
            .animation(
                accessibilityReduceMotion ? nil : .easeOut(duration: 0.2),
                value: model.bootstrapPhase.presentation
            )
            .tint(AppColors.action)
            .toggleStyle(SwitchToggleStyle(tint: AppColors.actionFill))
            .preferredColorScheme(model.settingsSyncModel.preferredColorScheme)
    }

    @ViewBuilder
    private var startupContent: some View {
        ZStack {
            // Keep native navigation mounted so iPad starts with the correct tab-bar inset.
#if DEBUG
            if !ProcessInfo.processInfo.arguments.contains("--mangoreader-loading-verification") {
                appContent
                    .allowsHitTesting(model.isReadyForInteraction)
                    .accessibilityHidden(!model.isReadyForInteraction)
            }
#else
            appContent
                .allowsHitTesting(model.isReadyForInteraction)
                .accessibilityHidden(!model.isReadyForInteraction)
#endif
            switch model.bootstrapPhase.presentation {
                case .loading:
                    StartupLoadingView()
                        .transition(.opacity)
                case .content:
#if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--mangoreader-loading-verification") {
                        NavigationStack { LoadingVerificationView() }
                    }
#else
                    EmptyView()
#endif
                case .failure:
                    StartupFailureView {
                        Task { await model.bootstrap() }
                    }
                    .transition(.opacity)
            }
        }
    }

    private var appContent: some View {
        ZStack(alignment: .topLeading) {
#if DEBUG
            if SourcePerformanceAudit.enabled, ProcessInfo.processInfo.environment["MANGOREADER_WEBSITE_TIMING"] == "1" {
                if model.isReadyForInteraction { SourceWebsiteTimingView().ignoresSafeArea() }
            } else {
                MangoReaderRootView()
                    .allowsHitTesting(!model.readerSetup.isActive)
                    .accessibilityHidden(model.readerSetup.isActive)
            }
#else
            MangoReaderRootView()
                .allowsHitTesting(!model.readerSetup.isActive)
                .accessibilityHidden(model.readerSetup.isActive)
#endif
            ReaderPresentationHost(coordinator: readerCoordinator)
                .allowsHitTesting(!model.readerSetup.isActive)
                .accessibilityHidden(model.readerSetup.isActive)
            if model.isReadyForInteraction, model.readerSetup.isActive {
                if model.readerSetup.owner == nil || model.readerSetup.owner == setupSceneID {
                    ReaderSetupView(setup: model.readerSetup,
                        importProgress: model.transfersModel.publicationImportProgress,
                        importResult: { model.beginImport($0) },
                        completed: { Task { await model.settingsSyncModel.persistSyncedSettingsIfChanged() } })
                } else {
                    ContentUnavailableView {
                        Label("Reader setup is open", systemImage: "books.vertical")
                    } description: {
                        Text("Continue in your other Mango Reader window, or bring setup here.")
                    } actions: {
                        Button("Continue here") { model.readerSetup.owner = setupSceneID }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(AppColors.background)
                }
            }
        }
        .onAppear { model.readerSetup.claim(setupSceneID) }
        .onDisappear { model.readerSetup.release(setupSceneID) }
        .onChange(of: model.readerSetup.isActive) { _, active in
            if active { model.readerSetup.claim(setupSceneID) }
            else { replayPendingOpenURLs() }
        }
        .onChange(of: model.readerSetup.owner) { _, owner in
            if owner == nil, scenePhase == .active { model.readerSetup.claim(setupSceneID) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.readerSetup.claim(setupSceneID) }
            else { model.readerSetup.release(setupSceneID) }
        }
        #if DEBUG
        .onChange(of: model.isReadyForInteraction, initial: true) { _, isReady in
            guard isReady else { return }
            if AppFixtures.isVerifyingReaderOpening { readerCoordinator.open(AppFixtures.openingVerificationRequest) }
            if MangoReaderScreenshotMode.isEnabled {
                #if targetEnvironment(macCatalyst)
                MangoReaderScreenshotMode.prepareWindowForCapture()
                #endif
                Task { await MangoReaderScreenshotMode.presentReaderIfNeeded(model: model, coordinator: readerCoordinator) }
            }
        }
        #endif
    }

    private func receiveOpenURL(_ url: URL) {
        libraryContext.lock()
        guard model.isReadyForInteraction else {
            startupURLQueue.append(url)
            return
        }
        Task { await handleOpenURL(url) }
    }

    private func replayPendingOpenURLs() {
        guard model.isReadyForInteraction else { return }
        let urls = startupURLQueue.drain()
        guard !urls.isEmpty else { return }
        Task {
            for url in urls {
                await handleOpenURL(url)
            }
        }
    }

    private func handleOpenURL(_ url: URL) async {
        if url.scheme?.lowercased() == "manko" {
            if normalModel.readerSetup.isActive { startupURLQueue.append(url); return }
            normalModel.sourcesModel.openRepositoryLink(url)
            return
        }
        guard url.isFileURL,
              Self.supportedImportExtensions.contains(url.pathExtension.lowercased())
        else {
            normalModel.feedback.alert = AppAlert(
                title: url.scheme?.lowercased() == "manko" ? "Link unavailable" : "Unsupported link",
                message: url.scheme?.lowercased() == "manko"
                    ? "This Mango Reader link does not match a configured tracker connection."
                    : "Mango Reader only opens local DRM-free EPUB, PDF, CBZ, and ZIP files."
            )
            return
        }
        await normalModel.importFiles(.success([url]))
    }

    private static let supportedImportExtensions: Set<String> = ["epub", "pdf", "cbz", "zip"]

    private var effectiveDynamicTypeSize: DynamicTypeSize {
        if ProcessInfo.processInfo.arguments.contains("--mangoreader-ui-test-accessibility-dynamic-type") {
            return .accessibility5
        }
        #if DEBUG
        if MangoReaderScreenshotMode.isEnabled { return .large }
        #endif
        return dynamicTypeSize
    }

    private var effectiveLayoutDirection: LayoutDirection {
        ProcessInfo.processInfo.arguments.contains(
            "--mangoreader-ui-test-rtl"
        ) ? .rightToLeft : layoutDirection
    }
}

struct StartupURLQueue {
    private(set) var urls: [URL] = []

    mutating func append(_ url: URL) {
        urls.append(url)
    }

    mutating func drain() -> [URL] {
        defer { urls.removeAll(keepingCapacity: true) }
        return urls
    }
}

enum StartupVersionText {
    static func format(marketingVersion: String?) -> String {
        guard let version = marketingVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty
        else { return "Version unavailable" }
        return "Version \(version)"
    }

    static var current: String {
        format(marketingVersion: Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String)
    }
}

private struct StartupLoadingView: View {
    var body: some View {
        StartupSurface {
            VStack(spacing: 20) {
                StartupArtwork()
                ProgressView()
                    .accessibilityLabel("Starting Mango Reader")
                    .accessibilityIdentifier("startup-progress")
            }
        }
        .overlay(alignment: .topLeading) {
            StartupAutomationMarker(identifier: "startup-loading")
        }
    }
}

private struct StartupFailureView: View {
    let retry: () -> Void

    var body: some View {
        StartupSurface {
            VStack(spacing: 16) {
                StartupArtwork()
                    .padding(.bottom, 4)
                Text("Unable to Start")
                    .font(.title2.bold())
                Text("Mango Reader couldn’t finish loading its library.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry", action: retry)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("startup-retry")
            }
            .padding(.horizontal, AppLayout.pageMargin)
        }
        .overlay(alignment: .topLeading) {
            StartupAutomationMarker(identifier: "startup-failure")
        }
    }
}

private struct StartupSurface<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            AppColors.background
                .ignoresSafeArea()
            content
            VStack {
                Spacer()
                Text(StartupVersionText.current)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .dynamicTypeSize(AppDynamicTypeSizing.compactChromeRange)
                    .padding(.bottom, 24)
                    .accessibilityIdentifier("startup-version")
            }
        }
    }
}

private struct StartupArtwork: View {
    var body: some View {
        Image("MangoReaderStartupArtwork")
            .resizable()
            .scaledToFit()
            .frame(width: 128, height: 128)
            .clipShape(.rect(cornerRadius: 28, style: .continuous))
            .accessibilityLabel("Mango Reader")
            .accessibilityIdentifier("startup-artwork")
    }
}

private struct StartupAutomationMarker: View {
    let identifier: String

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel("")
            .accessibilityIdentifier(identifier)
    }
}

struct WorkDetailReaderLaunch: Identifiable {
    let id = UUID()
    var prepared: PreparedReaderContent? = nil
    let work: Work
    let installment: Installment?
    var request: ReaderOpenRequest? = nil
    let requestedAt = ContinuousClock.now
    var requestedUptime = ProcessInfo.processInfo.systemUptime
}

@MainActor @Observable
final class ReaderPresentationCoordinator {
    private let cacheActivityID = UUID()
    deinit {
        let id = cacheActivityID
        Task { @MainActor in SourceCacheRefresh.shared.readers.remove(id) }
    }
    var launch: WorkDetailReaderLaunch?
    var lastPresentedWorkID: WorkID?
    var lastDismissedWorkID: WorkID?
    var dismissalRevision = 0

    func present(work: Work, installment: Installment) {
        present(PreparedReaderContent(work: work, installment: installment))
    }

    func present(_ prepared: PreparedReaderContent, requestedUptime: TimeInterval? = nil) {
        let work = prepared.work, installment = prepared.installment
        guard launch?.work.id != work.id || launch?.installment?.id != installment.id else { return }
        lastPresentedWorkID = work.id
        launch = WorkDetailReaderLaunch(prepared: prepared, work: work, installment: installment)
        if let requestedUptime { launch?.requestedUptime = requestedUptime }
        SourceCacheRefresh.shared.readers.insert(cacheActivityID)
    }

    func open(_ request: ReaderOpenRequest) {
        guard launch == nil else { return }
        lastPresentedWorkID = request.work.id
        launch = WorkDetailReaderLaunch(work: request.work, installment: request.installment, request: request)
        SourceCacheRefresh.shared.readers.insert(cacheActivityID)
        os_signpost(.event, log: OSLog(subsystem: "com.k800k.manko", category: "ReaderOpening"), name: "ReadRequested")
    }

    func completeDismissal() -> WorkID? {
        guard let workID = lastPresentedWorkID else { return nil }
        launch = nil
        SourceCacheRefresh.shared.readers.remove(cacheActivityID)
        lastPresentedWorkID = nil
        lastDismissedWorkID = workID
        dismissalRevision &+= 1
        return workID
    }
}

struct ReaderPresentationHost: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var coordinator: ReaderPresentationCoordinator

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .fullScreenCover(item: $coordinator.launch, onDismiss: {
                guard coordinator.completeDismissal() != nil else { return }
                Task {
                    await model.refreshAfterReaderDismissal()
                }
            }) { launch in
                ReaderSessionView(launch: launch)
                    .environment(model)
                    .environment(coordinator)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
            }
    }
}

/// Switching chapters keeps the presentation window and its geometry intact.
private struct ReaderSessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var opening: ReaderOpeningState
    @State private var shellAppearanceUptime: TimeInterval?
    @State private var chapterStart: ReaderChapterStart = .resume
    @State private var catalog: ReaderChapterCatalog?
    @State private var recovery: ImportedBookRecovery?
    let launch: WorkDetailReaderLaunch

    init(launch: WorkDetailReaderLaunch) {
        self.launch = launch
        _opening = State(initialValue: ReaderOpeningState(prepared: launch.prepared))
    }

    var body: some View {
        Group {
            if let content = opening.content, let catalog {
                PublicationReaderScene(work: content.work, installment: content.installment,
                    chapterStart: chapterStart, preparedRemotePublication: content.remotePublication, progressivePublication: content.progressivePublication, chapterCatalog: catalog) { prepared, start in
                    chapterStart = start
                    opening.replace(prepared)
                }
                .id([content.work.id.description, content.installment.id.description])
            } else if let recovery {
                ImportedBookRecoveryView(request: recovery) { prepared in
                    self.recovery = nil
                    opening.replace(prepared)
                    opening.retry()
                }
            } else { openingShell }
        }
        .overlay(alignment: .topLeading) {
#if DEBUG
            if ProcessInfo.processInfo.environment["MANGOREADER_SOURCE_AUDIT"] == "1" {
                VStack(spacing: 0) {
                    Text(" ").accessibilityLabel("lnori-read-request").accessibilityIdentifier("lnori-read-request").accessibilityValue(String(launch.requestedUptime))
                    Text(" ").accessibilityLabel("reader-shell-ready").accessibilityIdentifier("reader-shell-ready").accessibilityValue(String(shellAppearanceUptime ?? launch.requestedUptime))
                }.font(.system(size: 1)).foregroundStyle(.clear).frame(width: 1, height: 1).allowsHitTesting(false)
            }
#endif
        }
        .onAppear {
            if shellAppearanceUptime == nil { shellAppearanceUptime = ProcessInfo.processInfo.systemUptime }
            let elapsed = launch.requestedAt.duration(to: .now)
            Logger(subsystem: "com.k800k.manko", category: "ReaderOpening").debug("Reader shell presented after \(String(describing: elapsed), privacy: .public)")
        }
        .task(id: opening.attempt) {
            if let request = launch.request { await opening.load { try await model.prepareReader(request) } }
            if opening.failure != nil, let request = launch.request {
                recovery = await model.importedBookRecovery(for: request)
            }
            guard !Task.isCancelled, let content = opening.content, catalog == nil else { return }
            let work = content.work
            var chapters = content.chapters
            if !chapters.contains(where: { $0.id == content.installment.id }) { chapters.append(content.installment) }
            let catalog = ReaderChapterCatalog(chapters: chapters, isComplete: content.chaptersAreComplete) {
                if work.sourceID == .local { return try await model.libraryModel.workDetailSnapshot(for: work).installments }
                guard model.sourcesModel.sources.contains(where: { $0.id == work.sourceID && $0.isEnabled }) else { throw SourceError.notFound }
                let refreshed = try await model.libraryModel.refreshWorkDetailSnapshot(for: work)
                return model.sourcesModel.workDetailCache.cached(model.sourcesModel.detailCacheKey(for: work))?.installments ?? refreshed.installments
            }
            self.catalog = catalog
        }
        .onDisappear { catalog?.cancel(); opening.cancel() }
    }

    private var openingShell: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { opening.cancel(); dismiss() } label: {
                    Image(systemName: "xmark").appIconControlFrame(dimension: 44)
                }
                .accessibilityLabel("Close reader")
                .accessibilityIdentifier("reader-close")
                VStack(alignment: .leading, spacing: 2) {
                    Text(launch.work.title).font(.headline).lineLimit(2)
                    if let title = launch.installment?.title { Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
            }
            .padding(.horizontal)
            .appFixedNavigationChrome()
            if let failure = opening.failure {
                ContentUnavailableView {
                    Label("Couldn’t open book", systemImage: "exclamationmark.book.closed")
                } description: { Text(failure) } actions: {
                    Button("Retry") { opening.retry() }.buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("reader-preparation-retry")
                }
                .accessibilityIdentifier("reader-preparation-error")
            } else {
                ReaderContentSkeleton(layout: launch.work.kind == .lightNovel || launch.work.kind == .book ? .text : .page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Opening book")
                    .accessibilityIdentifier("reader-preparation-loading")
            }
        }
        .background(Color(uiColor: .systemBackground))
        .accessibilityAction(.escape) { opening.cancel(); dismiss() }
    }
}

private struct MangoReaderModelFocusedValueKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var mangoReaderModel: AppModel? {
        get { self[MangoReaderModelFocusedValueKey.self] }
        set { self[MangoReaderModelFocusedValueKey.self] = newValue }
    }
}

@MainActor
struct MangoReaderReaderCommandActions {
    let canNavigate: Bool
    let controlsAreVisible: Bool
    let previousPage: @MainActor () -> Void
    let nextPage: @MainActor () -> Void
    let toggleControls: @MainActor () -> Void
    let closeReader: @MainActor () -> Void
}

private struct MangoReaderReaderCommandsFocusedValueKey: FocusedValueKey {
    typealias Value = MangoReaderReaderCommandActions
}

extension FocusedValues {
    var mangoReaderReaderCommands: MangoReaderReaderCommandActions? {
        get { self[MangoReaderReaderCommandsFocusedValueKey.self] }
        set { self[MangoReaderReaderCommandsFocusedValueKey.self] = newValue }
    }
}

struct MangoReaderCommands: Commands {
    @FocusedValue(\.mangoReaderModel) private var model
    @FocusedValue(\.mangoReaderReaderCommands) private var reader

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import Publications…") {
                model?.transfersModel.isImporting = true
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(model?.isReadyForInteraction != true)
        }

        CommandMenu("Library") {
            Button("Check Library for Updates") {
                guard let model else { return }
                Task { _ = await model.refreshLibraryFromSources() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(
                model == nil
                    || model?.isReadyForInteraction != true
                    || model?.libraryModel.isCheckingLibraryUpdates == true
                    || model?.settingsSyncModel.isRunningAutomation == true
            )

            Toggle("Incognito Reading", isOn: Binding(
                get: { model?.settingsSyncModel.incognitoMode ?? false },
                set: { model?.settingsSyncModel.setIncognito($0) }
            ))
            .disabled(model?.isReadyForInteraction != true)
        }

        #if DEBUG
        CommandMenu("Reader Verification") {
            Button("Add Three-Chapter Samples") {
                guard let model else { return }
                Task {
                    do { try await AppFixtures.seedReaderChapterSamples(model: model) }
                    catch { model.feedback.alert = AppAlert(title: "Fixture preparation failed", message: error.localizedDescription) }
                }
            }
            .disabled(model?.isReadyForInteraction != true)
            Button("Fail Chapter 2 Loading") { AppFixtures.readerFixtureShouldFail = true }
            Button("Allow Chapter 2 Loading") { AppFixtures.readerFixtureShouldFail = false }
            Divider()
            Button("Add Cache Sample Source") {
                guard let model else { return }
                if !model.sourcesModel.sources.contains(where: { $0.id == CacheVerificationSource.descriptor.id }) {
                    model.sourcesModel.sources.append(CacheVerificationSource.descriptor)
                    model.sourcesModel.saveSources()
                }
            }
            Button("Update Cache Sample") {
                guard let model else { return }
                Task { await CacheVerificationSource.shared.advance(); await AppFixtures.expireCacheVerification(model: model) }
            }
            Button("Fail Cache Sample Requests") {
                guard let model else { return }
                Task { await CacheVerificationSource.shared.setFailure(true); await AppFixtures.expireCacheVerification(model: model) }
            }
            Button("Allow Cache Sample Requests") { Task { await CacheVerificationSource.shared.setFailure(false) } }
        }
        #endif

        CommandMenu("Reader") {
            Button("Previous Page") {
                reader?.previousPage()
            }
            .disabled(reader?.canNavigate != true)

            Button("Next Page") {
                reader?.nextPage()
            }
            .disabled(reader?.canNavigate != true)

            Divider()

            Button(reader?.controlsAreVisible == true ? "Hide Reader Controls" : "Show Reader Controls") {
                reader?.toggleControls()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(reader == nil)

            Button("Close Reader") {
                reader?.closeReader()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(reader == nil)
        }
    }
}

/// XCUITest launches the application separately, without this runner variable.
enum MangoReaderTestEnvironment {
    static var isUnitTesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
        false
        #endif
    }
}
