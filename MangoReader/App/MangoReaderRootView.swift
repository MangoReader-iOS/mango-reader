import MangoReaderDomain
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SourceMetadataSearchRoute: Hashable {
    let requestID: UUID
    let source: SourceDescriptor
    let query: String
    let selections: [SourceSearchSelection]

    init(
        source: SourceDescriptor,
        query: String = "",
        selections: [SourceSearchSelection] = [],
        requestID: UUID = UUID()
    ) {
        self.requestID = requestID
        self.source = source
        self.query = query
        self.selections = selections
    }
}

struct OpenSourceMetadataSearchAction {
    private let handler: (SourceMetadataSearchRoute) -> Void

    init(handler: @escaping (SourceMetadataSearchRoute) -> Void = { _ in }) {
        self.handler = handler
    }

    func callAsFunction(_ route: SourceMetadataSearchRoute) {
        handler(route)
    }
}

enum PrimaryDestination: Hashable {
    case library
    case browse
    case activity
    case search
    case settings
}

enum BrowseNavigationDestination: Hashable {
    case addSource
    case repositories
}

enum ContinueReadingAccessoryVisibilityPolicy {
    static func isEnabled(
        destination: PrimaryDestination,
        isBrowseSetupVisible: Bool = false,
        isPresentingSetup: Bool = false,
        isSelectingTitles: Bool = false,
        isWorkDetailVisible: Bool = false
    ) -> Bool {
        destination != .settings
            && !(destination == .browse && isBrowseSetupVisible)
            && !isPresentingSetup
            && !isSelectingTitles
            && !isWorkDetailVisible
    }
}

struct WorkDetailAccessoryPreference: PreferenceKey {
    nonisolated static let defaultValue = false

    nonisolated static func reduce(value: inout Bool, nextValue: () -> Bool) {
        let next = nextValue()
        value = value || next
    }
}

private struct BrowseSetupAccessoryPreference: PreferenceKey {
    nonisolated static let defaultValue = false

    nonisolated static func reduce(value: inout Bool, nextValue: () -> Bool) {
        let next = nextValue()
        value = value || next
    }
}

struct MangoReaderRootView: View {
    @Environment(\.dynamicTypeSize) private var contentTextSize
    @Environment(AppModel.self) private var model
    @Environment(PrivateLibraryCoordinator.self) private var libraryContext
    @Environment(ReaderPresentationCoordinator.self) private var readerCoordinator
    @State private var selection: PrimaryDestination = .library
    @State private var browsePath = NavigationPath()
    @State private var browseNavigationReset = 0
    @State private var continueReadingDetailWork: Work?
    @State private var readerPreparation = WorkDetailReaderPreparation()
    @State private var isLibrarySelectingTitles = false
    @State private var isBrowseSetupVisible = false
    @State private var isLibraryInspectorVisible = false
    @State private var workDetailVisibilityByDestination: [PrimaryDestination: Bool] = [:]

    init() {
        #if DEBUG
        if ServerLabFixture.isEnabled { _selection = State(initialValue: .browse) }
        if ExtensionAuditFixture.isEnabled {
            // Preview recordings may start on a useful production destination.
            switch ProcessInfo.processInfo.environment["MANGOREADER_EXTENSION_AUDIT_TAB"] {
            case "library": _selection = State(initialValue: .library)
            case "search": _selection = State(initialValue: .search)
            default: _selection = State(initialValue: .browse)
            }
        }
        if ProcessInfo.processInfo.environment["MANGOREADER_BACKUP_FIXTURE"] != nil {
            _selection = State(initialValue: .settings)
        }
        if MangoReaderScreenshotMode.scene == "activity" {
            _selection = State(initialValue: .activity)
        }
        #endif
    }

    var body: some View {
        @Bindable var transfers = model.transfersModel
        @Bindable var localBooks = model
        @Bindable var sources = model.sourcesModel

        TabView(selection: $selection) {
            Tab("Library", systemImage: "books.vertical.fill", value: .library) {
                LibraryScene(
                    isSelectingTitles: $isLibrarySelectingTitles,
                    openBrowse: openBrowse
                )
                .onPreferenceChange(WorkDetailAccessoryPreference.self) {
                    workDetailVisibilityByDestination[.library] = $0
                }
                .onPreferenceChange(LibraryInspectorVisibilityPreference.self) {
                    isLibraryInspectorVisible = $0
                }
                .environment(\.dynamicTypeSize, contentTextSize)
            }
            Tab("Browse", systemImage: "safari.fill", value: .browse) {
                NavigationStack(path: $browsePath) {
                    BrowseView {
                        browsePath.append(BrowseNavigationDestination.addSource)
                    }
                        .navigationDestination(for: BrowseNavigationDestination.self) { destination in
                            switch destination {
                            case .addSource:
                                AddSourceCatalogView {
                                    browsePath.append(BrowseNavigationDestination.repositories)
                                }
                                .preference(key: BrowseSetupAccessoryPreference.self, value: true)
                            case .repositories:
                                RepositoryManagerView()
                                    .preference(key: BrowseSetupAccessoryPreference.self, value: true)
                            }
                        }
                }
                .id(browseNavigationReset)
                .onPreferenceChange(BrowseSetupAccessoryPreference.self) {
                    isBrowseSetupVisible = $0
                }
                .onPreferenceChange(WorkDetailAccessoryPreference.self) {
                    workDetailVisibilityByDestination[.browse] = $0
                }
                .environment(\.dynamicTypeSize, contentTextSize)
            }
            Tab("Activity", systemImage: "chart.bar.xaxis", value: .activity) {
                NavigationStack { ActivityView() }
                    .onPreferenceChange(WorkDetailAccessoryPreference.self) {
                        workDetailVisibilityByDestination[.activity] = $0
                    }
                .environment(\.dynamicTypeSize, contentTextSize)
            }
            Tab("Search", systemImage: "magnifyingglass", value: .search) {
                NavigationStack { SearchView() }
                    .onPreferenceChange(WorkDetailAccessoryPreference.self) {
                        workDetailVisibilityByDestination[.search] = $0
                    }
                .environment(\.dynamicTypeSize, contentTextSize)
            }
            Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                SettingsView()
                .environment(\.dynamicTypeSize, contentTextSize)
            }
        }
        .appFixedNavigationChrome()
#if targetEnvironment(macCatalyst)
        .tabViewStyle(.sidebarAdaptable)
#else
        .tabViewStyle(.tabBarOnly)
#endif
        .appFeedbackOverlay(isEnabled: readerCoordinator.launch == nil && (selection != .library || !isLibraryInspectorVisible))
        .mangoReaderContinueReadingAccessory(
            item: model.libraryModel.continueReadingItem,
            isPreparing: readerPreparation.isPreparing && readerPreparation.workID == model.libraryModel.continueReadingItem?.work.id,
            isEnabled: ContinueReadingAccessoryVisibilityPolicy.isEnabled(
                destination: selection,
                isBrowseSetupVisible: isBrowseSetupVisible,
                isPresentingSetup: sources.pendingRepositoryLink != nil
                    || sources.pendingCloudflareHandoff != nil
                    || transfers.isImporting,
                isSelectingTitles: isLibrarySelectingTitles,
                isWorkDetailVisible: workDetailVisibilityByDestination[selection] == true
                    || continueReadingDetailWork != nil
            ),
            openDetail: { continueReadingDetailWork = $0.work },
            play: playContinueReading
        )
        .appBackground()
        #if !targetEnvironment(macCatalyst)
        .background(LibraryTabTapObserver {
            Task { await libraryContext.toggle(readingDefaults: (model.defaults as? ProtectedLibraryDefaults)?.readingDefaults ?? model.defaults, feedback: model.feedback) }
        })
        #endif
        .onChange(of: model.settingsSyncModel.incognitoMode) { _, enabled in
            if enabled { model.importedFilePrefetchTask?.cancel() }
        }
        .sheet(item: $localBooks.importedBookRecovery, onDismiss: {
            if let prepared = model.recoveredImportedBook {
                model.recoveredImportedBook = nil
                readerCoordinator.present(prepared)
            }
        }) { request in
            ImportedBookRecoveryView(request: request)
        }
        .onChange(of: selection) { previousSelection, newSelection in
            readerPreparation.cancel()
            if previousSelection == .library, newSelection != .library {
                isLibrarySelectingTitles = false
            }
        }
        .onChange(of: model.readerSetup.isActive) { wasActive, active in
            if wasActive && !active { selection = .library }
        }
        .onDisappear { readerPreparation.cancel() }
        .fileImporter(
            isPresented: $transfers.isImporting,
            allowedContentTypes: Self.importTypes,
            allowsMultipleSelection: true
        ) { result in
            model.beginImport(result)
        }
        .sheet(item: $sources.pendingRepositoryLink) { request in
            RepositoryLinkFlowView(request: request) {
                repositoryInstallDidComplete()
            }
        }
        .sheet(item: $sources.pendingCloudflareHandoff, onDismiss: {
            model.sourcesModel.cloudflareHandoffDidDismiss()
        }) { request in
            CloudflareHandoffView(request: request)
        }
        .sheet(item: $continueReadingDetailWork) { work in
            ContinueReadingDetailSheet(work: work)
        }
        .alert(item: Binding(
            get: { readerCoordinator.launch == nil ? model.feedback.alert : nil },
            set: { model.feedback.alert = $0 }
        )) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onChange(of: model.feedback.statusMessage?.id) { _, newID in
            guard
                readerCoordinator.launch == nil,
                let newID,
                model.feedback.claimStatusAnnouncement(newID),
                let message = model.feedback.statusMessage?.message
            else {
                return
            }
            UIAccessibility.post(notification: .announcement, argument: message)
        }
        .background {
            SyncedSettingsDefaultsObserver()
        }
        .environment(readerPreparation)
    }

    private func playContinueReading(_ item: ContinueReadingItem) {
        let requestedUptime = ProcessInfo.processInfo.systemUptime
        readerPreparation.start(workID: item.work.id, installmentID: item.installment.id) {
            await model.prepareToResume(item)
        } present: { prepared in
            readerCoordinator.present(prepared, requestedUptime: requestedUptime)
        }
    }

    private func repositoryInstallDidComplete() {
        browsePath = NavigationPath()
        selection = .browse
    }

    private func openBrowse() {
        browsePath = NavigationPath()
        browseNavigationReset += 1
        selection = .browse
    }

    private static let importTypes: [UTType] = [
        UTType(filenameExtension: "epub") ?? .data,
        .pdf,
        UTType(filenameExtension: "cbz") ?? .zip,
        .zip,
    ]

}

struct ContinueReadingDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var readerCoordinator = ReaderPresentationCoordinator()
    @State private var readerPreparation = WorkDetailReaderPreparation()
    let work: Work

    var body: some View {
        NavigationStack {
            WorkDetailView(work: work)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        FixedNavigationChrome {
                            Button("Close", systemImage: "xmark") { dismiss() }
                        }
                    }
                }
        }
        .appFeedbackOverlay()
        .background { ReaderPresentationHost(coordinator: readerCoordinator) }
        .environment(readerCoordinator)
        .environment(readerPreparation)
        .onDisappear { readerPreparation.cancel() }
    }
}

private extension View {
    @ViewBuilder
    func mangoReaderContinueReadingAccessory(
        item: ContinueReadingItem?,
        isPreparing: Bool,
        isEnabled: Bool,
        openDetail: @escaping (ContinueReadingItem) -> Void,
        play: @escaping (ContinueReadingItem) -> Void
    ) -> some View {
#if targetEnvironment(macCatalyst)
        self
#else
        if #available(iOS 26.1, *) {
            self
                .tabBarMinimizeBehavior(.onScrollDown)
                .tabViewBottomAccessory(isEnabled: isEnabled && item != nil) {
                    if let item {
                        ContinueReadingAccessoryView(
                            item: item,
                            isPreparing: isPreparing,
                            openDetail: { openDetail(item) },
                            play: { play(item) }
                        )
                    }
                }
        } else if #available(iOS 26.0, *) {
            self
                .tabBarMinimizeBehavior(.onScrollDown)
                .tabViewBottomAccessory {
                    if isEnabled, let item {
                        ContinueReadingAccessoryView(
                            item: item,
                            isPreparing: isPreparing,
                            openDetail: { openDetail(item) },
                            play: { play(item) }
                        )
                    }
                }
        } else {
            self
        }
#endif
    }
}

#if !targetEnvironment(macCatalyst)
@available(iOS 26.0, *)
private struct ContinueReadingAccessoryView: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let item: ContinueReadingItem
    let isPreparing: Bool
    let openDetail: () -> Void
    let play: () -> Void

    var body: some View {
        if #available(iOS 27.1, *) {
            DuoContinueReadingAccessory { vertical in accessoryContent(vertical: vertical) }
        } else { accessoryContent(vertical: false) }
    }

    private func accessoryContent(vertical: Bool) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            Button(action: openDetail) {
                HStack(spacing: 10) {
                    RemoteCover(work: item.work, style: .miniPlayer)
                        .frame(width: 28, height: 42)

                    if !vertical {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.work.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if placement != .inline {
                        Text(item.installment.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(item.work.title) details")

            Button(action: play) {
                Group {
                    if isPreparing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .appIconControlFrame()
            }
            .buttonStyle(.plain)
            .tint(.primary)
            .disabled(isPreparing)
            .accessibilityLabel("Continue reading \(item.work.title), \(item.installment.title)")
            .accessibilityIdentifier("continue-reading-play")
        }
        .padding(.horizontal, vertical ? 0 : 12)
        .appFixedNavigationChrome()
        .accessibilityIdentifier("continue-reading-accessory")
    }
}

@available(iOS 27.1, *)
private struct DuoContinueReadingAccessory<Content: View>: View {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    @ViewBuilder let content: (Bool) -> Content
    var body: some View { content(verticalEdge != nil) }
}

#endif

/// Shared message content for floating banners and reader confirmations.
struct AppStatusContent: View {
    let status: AppStatusMessage?
    var isQueuingDownloads = false

    var body: some View {
        VStack(spacing: 4) {
            if isQueuingDownloads {
                ProgressView("Preparing downloads…")
                    .controlSize(.small)
                    .accessibilityIdentifier("app-status-progress")
            }
            if let status {
                Label(status.message, systemImage: status.systemImage)
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits([.isStaticText, .updatesFrequently])
                    .accessibilityIdentifier("app-status-message")
            }
        }
    }
}

struct AppStatusBanner: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let status: AppStatusMessage?
    var isQueuingDownloads = false

    var body: some View {
        AppStatusContent(status: status, isQueuingDownloads: isQueuingDownloads)
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: 680)
            .background {
                if reduceTransparency {
                    bannerShape.fill(AppColors.secondaryBackground)
                } else {
                    bannerShape.fill(.regularMaterial)
                }
            }
            .overlay {
                bannerShape.stroke(
                    .secondary.opacity(contrast == .increased ? 0.7 : 0.25),
                    lineWidth: contrast == .increased ? 1 : 0.5
                )
            }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private var bannerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }
}

struct AppStatusOverlayModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var topChromeInset: CGFloat = 0
    let status: AppStatusMessage?
    var isQueuingDownloads = false
    var isEnabled = true

    func body(content: Content) -> some View {
        content
            .background(AppStatusChromeReader(topInset: $topChromeInset))
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    if isEnabled, status != nil || isQueuingDownloads {
                        AppStatusBanner(status: status, isQueuingDownloads: isQueuingDownloads)
                            .padding(.horizontal, 16)
                            .padding(.top, topChromeInset + 8)
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    }
                }
                .allowsHitTesting(false)
                .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.22), value: status?.id)
                .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.22), value: isQueuingDownloads)
                .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.22), value: isEnabled)
            }
    }
}

/// Container overlays don't inherit NavigationStack's internal safe area.
/// Measure visible native navigation bars so top tabs and navigation actions
/// remain clear, including in sheets, inspectors and resized iPad windows.
private struct AppStatusChromeReader: UIViewRepresentable {
    @Binding var topInset: CGFloat

    func makeUIView(context: Context) -> ChromeMeasurementView {
        ChromeMeasurementView()
    }

    func updateUIView(_ view: ChromeMeasurementView, context: Context) {
        view.insetDidChange = { inset in
            if topInset != inset { topInset = inset }
        }
        view.setNeedsLayout()
    }

    final class ChromeMeasurementView: UIView {
        var insetDidChange: ((CGFloat) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Deliver after SwiftUI finishes the current layout transaction.
            DispatchQueue.main.async { [weak self] in
                guard let self, let root = self.window?.rootViewController?.view else { return }
                self.insetDidChange?(self.navigationInset(in: root))
            }
        }

        private func navigationInset(in view: UIView) -> CGFloat {
            guard !view.isHidden, view.alpha > 0 else { return 0 }
            if let bar = view as? UINavigationBar {
                let frame = bar.convert(bar.bounds, to: self)
                guard frame.intersects(bounds), frame.minY < bounds.midY else { return 0 }
                return max(0, frame.maxY)
            }
            return view.subviews.map { navigationInset(in: $0) }.max() ?? 0
        }
    }
}

private struct AppFeedbackOverlayModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.modifier(AppStatusOverlayModifier(
            status: model.feedback.statusMessage,
            isQueuingDownloads: model.transfersModel.isQueuingDownloads,
            isEnabled: isEnabled
        ))
    }
}

extension View {
    func appFeedbackOverlay(isEnabled: Bool = true) -> some View {
        modifier(AppFeedbackOverlayModifier(isEnabled: isEnabled))
    }
}

/// Keeps confirmations in reader chrome without revealing hidden page controls.
struct ReaderFeedbackControls<Controls: View>: View {
    let showsControls: Bool
    let status: AppStatusMessage?
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        VStack(spacing: 8) {
            if showsControls { controls() }
            if let status {
                AppStatusContent(status: status)
                    .font(.footnote)
                    .padding(.horizontal)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// AppStorage is still the single live bridge used by both publication reader
/// surfaces. This zero-size observer captures those writes at the app root so
/// they also reach the durable settings record. A remote apply emits the same
/// notification, but AppModel compares preference values and suppresses that
/// writeback before it reaches CKSyncEngine.
private struct SyncedSettingsDefaultsObserver: View {
    @AppStorage(ReaderAdditionalPreferences.storageKey) private var readerAdditionalData = Data()
    @Environment(AppModel.self) private var model

    @AppStorage("libraryLayout") private var libraryLayout = "grid"
    @AppStorage("librarySort") private var librarySort = LibrarySort.recentlyAdded.rawValue
    @AppStorage("preferredAppearance") private var preferredAppearance = "system"
    @AppStorage("readerDirection") private var direction = "vertical"
    @AppStorage("epubScroll") private var epubScroll = true
    @AppStorage("publisherStyles") private var publisherStyles = true
    @AppStorage("verticalWriting") private var verticalWriting = false
    @AppStorage("publicationTheme") private var publicationTheme = "system"
    @AppStorage("readerFontPreset") private var fontPreset = "publisher"
    @AppStorage("readerFontScale") private var fontScale = 1.0
    @AppStorage("readerFontWeight") private var fontWeight = 1.0
    @AppStorage("readerLineHeight") private var lineHeight = 1.4
    @AppStorage("readerParagraphSpacing") private var paragraphSpacing = 0.5
    @AppStorage("readerParagraphIndent") private var paragraphIndent = 0.0
    @AppStorage("readerPageMargins") private var pageMargins = 1.0
    @AppStorage("readerWordSpacing") private var wordSpacing = 0.0
    @AppStorage("readerLetterSpacing") private var letterSpacing = 0.0
    @AppStorage("readerHyphenation") private var hyphenation = true
    @AppStorage("readerTextNormalization") private var textNormalization = false
    @AppStorage("readerTextAlignment") private var textAlignment = "publisher"
    @AppStorage("readerColumnCount") private var columnCount = "automatic"
    @AppStorage("pdfDoublePage") private var pdfDoublePage = false
    @AppStorage("pdfContinuous") private var pdfContinuous = true
    @AppStorage("reduceReaderTransitions") private var reduceTransitions = false
    @AppStorage("imageReaderPageSpread") private var imagePageSpread = "single"
    @AppStorage("imageReaderWidePageBehavior") private var imageWidePageBehavior = "fit"
    @AppStorage("imageReaderCropMargins") private var imageCropMargins = false
    @AppStorage("imageReaderLiveText") private var imageLiveText = false
    @AppStorage("imageReaderTransition") private var imageTransition = "slide"
    @AppStorage("imageReaderTapLeadingAction") private var imageTapLeadingAction = ""
    @AppStorage("imageReaderTapCenterAction") private var imageTapCenterAction = ""
    @AppStorage("imageReaderTapTrailingAction") private var imageTapTrailingAction = ""

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: observedPreferences, initial: true) { _, _ in
                model.syncedSettingsDefaultsDidChange()
            }
    }

    private var observedPreferences: ObservedSyncedSettingsDefaults {
        ObservedSyncedSettingsDefaults(
            library: SyncedLibraryPreferences(
                layout: libraryLayout,
                sort: LibrarySort(rawValue: librarySort) ?? .recentlyAdded
            ),
            appearance: SyncedAppearancePreferences(mode: preferredAppearance),
            reader: SyncedReaderPreferences(
                additional: (try? JSONDecoder().decode(ReaderAdditionalPreferences.self, from: readerAdditionalData)) ?? ReaderAdditionalPreferences.read(from: .standard),
                direction: direction,
                epubScroll: epubScroll,
                publisherStyles: publisherStyles,
                verticalWriting: verticalWriting,
                publicationTheme: publicationTheme,
                fontPreset: fontPreset,
                fontScale: fontScale,
                fontWeight: fontWeight,
                lineHeight: lineHeight,
                paragraphSpacing: paragraphSpacing,
                paragraphIndent: paragraphIndent,
                pageMargins: pageMargins,
                wordSpacing: wordSpacing,
                letterSpacing: letterSpacing,
                hyphenation: hyphenation,
                textNormalization: textNormalization,
                textAlignment: textAlignment,
                columnCount: columnCount,
                pdfDoublePage: pdfDoublePage,
                pdfContinuous: pdfContinuous,
                reduceTransitions: reduceTransitions,
                imagePageSpread: imagePageSpread,
                imageWidePageBehavior: imageWidePageBehavior,
                imageCropMargins: imageCropMargins,
                imageLiveText: imageLiveText,
                imageTransition: imageTransition,
                imageTapLeadingAction: imageTapLeadingAction,
                imageTapCenterAction: imageTapCenterAction,
                imageTapTrailingAction: imageTapTrailingAction
            )
        )
    }
}

private struct ObservedSyncedSettingsDefaults: Hashable {
    var library: SyncedLibraryPreferences
    var appearance: SyncedAppearancePreferences
    var reader: SyncedReaderPreferences
}

/// Preserve native tab selection, including repeated taps on the selected tab.
private struct LibraryTabTapObserver: UIViewControllerRepresentable {
    let onTripleTap: () -> Void
    func makeUIViewController(context: Context) -> Controller { Controller(onTripleTap: onTripleTap) }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onTripleTap = onTripleTap
        controller.attach()
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.detach() }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var onTripleTap: () -> Void
        private weak var tabs: UITabBarController?
        private lazy var tap: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(tripleTapped))
            recognizer.numberOfTapsRequired = 3
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            return recognizer
        }()
        init(onTripleTap: @escaping () -> Void) { self.onTripleTap = onTripleTap; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); attach() }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); attach() }

        func attach() {
            func find(_ controller: UIViewController) -> UITabBarController? {
                if let controller = controller as? UITabBarController { return controller }
                for child in controller.children { if let result = find(child) { return result } }
                return nil
            }
            guard let root = view.window?.rootViewController, let controller = find(root) else { return }
            guard tabs !== controller else { return }
            detach()
            tabs = controller
            controller.tabBar.addGestureRecognizer(tap)
        }
        func detach() {
            tap.view?.removeGestureRecognizer(tap)
            tabs = nil
        }
        @objc private func tripleTapped() { onTripleTap() }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let bar = tabs?.tabBar, let items = bar.items, !items.isEmpty else { return false }
            let point = touch.location(in: bar)
            let width = bar.bounds.width / CGFloat(items.count)
            let firstRange = bar.effectiveUserInterfaceLayoutDirection == .rightToLeft
                ? (bar.bounds.maxX - width)...bar.bounds.maxX : bar.bounds.minX...(bar.bounds.minX + width)
            return bar.bounds.contains(point) && firstRange.contains(point.x)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }

}

/// Window-level cover also obscures full-screen readers and sheets in app snapshots.
struct PrivateLibraryPrivacyShield: UIViewControllerRepresentable {
    let isPrivate: Bool
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.isPrivate = isPrivate; controller.refresh() }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.removeShield() }

    final class Controller: UIViewController {
        var isPrivate = false
        private var shield: UIView?
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewDidLoad() {
            super.viewDidLoad()
            NotificationCenter.default.addObserver(self, selector: #selector(willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        }
        @objc private func willResignActive() { refresh(forceHidden: true) }
        @objc private func didBecomeActive() { removeShield() }
        func refresh(forceHidden: Bool = false) {
            guard isPrivate, forceHidden || UIApplication.shared.applicationState != .active else {
                if UIApplication.shared.applicationState == .active { removeShield() }
                return
            }
            guard let window = view.window else { return }
            if let shield { window.bringSubviewToFront(shield); return }
            let cover = UIView(frame: window.bounds)
            cover.backgroundColor = .systemBackground
            cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cover.accessibilityViewIsModal = true
            window.addSubview(cover)
            shield = cover
        }
        func removeShield() { shield?.removeFromSuperview(); shield = nil }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
