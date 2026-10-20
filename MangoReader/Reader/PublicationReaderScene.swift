import MangoReaderDomain
import MangoReaderReaders
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ReaderChapterStart { case resume, beginning, end }

private struct ReaderPresentedAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct PublicationReaderScene: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var accessibilityVoiceOverEnabled
    @Environment(\.accessibilitySwitchControlEnabled) private var accessibilitySwitchControlEnabled
    @AppStorage("epubScroll") private var epubScroll = true
    @AppStorage("publisherStyles") private var publisherStyles = true
    @AppStorage("verticalWriting") private var verticalWriting = false
    @AppStorage("publicationTheme") private var publicationTheme = "system"
    @AppStorage("readerFontScale") private var readerFontScale = 1.0
    @AppStorage("readerFontPreset") private var readerFontPreset: PublicationFontPreset = .publisher
    @AppStorage("readerFontWeight") private var readerFontWeight = 1.0
    @AppStorage("readerLineHeight") private var readerLineHeight = 1.4
    @AppStorage("readerParagraphSpacing") private var readerParagraphSpacing = 0.5
    @AppStorage("readerParagraphIndent") private var readerParagraphIndent = 0.0
    @AppStorage("readerPageMargins") private var readerPageMargins = 1.0
    @AppStorage("readerWordSpacing") private var readerWordSpacing = 0.0
    @AppStorage("readerLetterSpacing") private var readerLetterSpacing = 0.0
    @AppStorage("readerHyphenation") private var readerHyphenation = true
    @AppStorage("readerTextNormalization") private var readerTextNormalization = false
    @AppStorage("readerTextAlignment") private var readerTextAlignment: PublicationTextAlignment = .publisher
    @AppStorage("readerColumnCount") private var readerColumnCount: PublicationColumnCount = .automatic
    @AppStorage("pdfDoublePage") private var pdfDoublePage = false
    @AppStorage("pdfContinuous") private var pdfContinuous = true
    @AppStorage("reduceReaderTransitions") private var reduceReaderTransitions = false
    @AppStorage(FoldedBookCoverPreferences.enabledKey) private var showsCoverWhenFolded = false
    @AppStorage(FoldedBookCoverPreferences.pauseSpeechKey) private var pausesSpeechWhenFolded = false
    @State private var foldedCover = FoldedBookCoverState()
    @AppStorage("imageReaderWidePageBehavior") private var imageReaderWidePageBehavior: WidePageBehavior = .fit
    @AppStorage("imageReaderCropMargins") private var imageReaderCropMargins = false
    @AppStorage("imageReaderLiveText") private var imageReaderLiveText = false
    @AppStorage("imageReaderTransition") private var imageReaderTransition = ImagePageTransition.slide.rawValue
    @AppStorage("imageReaderTapLeadingAction") private var imageReaderTapLeadingAction = ""
    @AppStorage("imageReaderTapTrailingAction") private var imageReaderTapTrailingAction = ""

    @ReaderPreferencesStorage private var readerOptions
    @State private var imageController = ImageReaderController()

    let work: Work
    private let initialInstallment: Installment
    @State private var activeImageInstallment: Installment?
    private var installment: Installment { activeImageInstallment ?? initialInstallment }
    var chapterCatalog: ReaderChapterCatalog? = nil
    @State private var imageSession: ImageReaderSession?
    private struct ChapterKey: Hashable { let workID: WorkID; let installmentID: InstallmentID }
    @State private var preparedChapters: [ChapterKey: PreparedReaderContent] = [:]
    @State private var completedChapters: Set<InstallmentID> = []
    @State private var readiumBoundary: ReaderChapterDirection?
    @State private var readiumBoundaryRequestID: UUID?
    var chapterStart: ReaderChapterStart = .resume
    var progressivePublication: ProgressivePublicationSession? = nil
    var preparedRemotePublication: RemoteImagePublication? = nil
    @State private var chapterTask: Task<Void, Never>?
    var onOpenChapter: ((PreparedReaderContent, ReaderChapterStart) -> Void)? = nil
    private var chapters: [Installment] { chapterCatalog?.chapters ?? [installment] }
    @State private var showsChapters = false
    @State private var switchingChapter = false
    @State private var pendingChapter: Installment?
    @State private var pendingChapterStart: ReaderChapterStart = .beginning
    @State private var pendingChapterCompleted = false
    @State private var chapterFailure: String?
    @State private var didSetInitialPosition = false

    @State private var savedProgress: ReadingProgress?
    @State private var latestLocator: ReadingLocator?
    @State private var hasLoadedProgress = false
    @State private var sessionID = UUID()
    @State private var readerActivityID = UUID()
    @State private var sessionStartedAt = Date.now
    @State private var startProgression = 0.0
    @State private var sessionReadingUnitCount: Int?
    @State private var hasStartedSession = false
    @State private var hasFinishedSession = false
    @State private var showsControls = true
    @State private var isSelectingPage = false
    @State private var activeSince: Date?
    @State private var activeSeconds: TimeInterval = 0
    @State private var progressSaveTask: Task<Void, Never>?
    @State private var imageRestoration = ReaderProgressRestorationGate()
    @State private var lastLocalPositionChange: Date?
    @State private var pendingRemoteProgress: ReadingProgress?
    @State private var lastOfferedRemoteDate: Date?
    @State private var readerController = ReadiumReaderController()
    @State private var showsOutline = false
    @State private var showsPublicationSearch = false
    @State private var showsReaderMarks = false
    @State private var bookmarks: [Bookmark] = []
    @State private var annotations: [Annotation] = []
    @State private var annotationEditorDraft: ReaderAnnotationEditorDraft?
    @State private var imageReaderNavigationID = UUID()
    @State private var remoteImageReloadID = UUID()
    @State private var remoteImagePublication: RemoteImagePublication?
    @State private var remoteImageLoadError: String?
    @State private var showsPDFThumbnails = false
    @State private var showsImageReaderSettings = false
    @State private var isMutatingBookmark = false
    @State private var readerStatus: AppStatusMessage?
    @State private var observedStatusID: UUID?
    @State private var readerAlert: ReaderPresentedAlert?
    @State private var readiumPhase: ReadiumReaderPhase = .idle
    @State private var cbzPhase: CBZReaderPhase = .idle
    @State private var remoteImageReaderPhase: RemoteImageReaderPhase = .idle
    @State private var replacementAcquisitionURL: URL?
    @State private var isRelinkingPublication = false
    @State private var isRecoveringDownloadedPublication = false

    init(work: Work, installment: Installment, chapterStart: ReaderChapterStart = .resume,
         preparedRemotePublication: RemoteImagePublication? = nil, progressivePublication: ProgressivePublicationSession? = nil, chapterCatalog: ReaderChapterCatalog? = nil,
         onOpenChapter: ((PreparedReaderContent, ReaderChapterStart) -> Void)? = nil) {
        self.work = work; self.initialInstallment = installment; self.chapterStart = chapterStart
        self.progressivePublication = progressivePublication
        self.preparedRemotePublication = preparedRemotePublication; self.chapterCatalog = chapterCatalog
        self.onOpenChapter = onOpenChapter
    }

    private var readerChrome: some View {
        readerLayout
        .statusBarHidden(!showsControls || foldedCover.isPresented)
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if let remote = pendingRemoteProgress {
                    VStack(spacing: 8) {
                        Button("Continue from the other device") { acceptRemoteProgress(remote) }
                            .disabled(!readerCommandsCanNavigate || (isImagePublication
                                ? imageRestoration.isRestoring : readerController.isRestoringInitialLocation))
                        Button("Keep Reading") {
                            lastLocalPositionChange = .now
                            pendingRemoteProgress = nil
                            flushReadingPosition()
                        }
                    }
                    .padding().readerOverlayPanel()
                    .accessibilityIdentifier("reader-cloud-handoff")
                }
                if switchingChapter, readiumBoundary == nil { ProgressView("Opening chapter…").padding().readerOverlayPanel() }
                if let chapterFailure, readiumBoundary == nil {
                    HStack {
                        Text(chapterFailure).font(.callout)
                        Button("Retry") { if let pendingChapter { openChapter(pendingChapter, start: pendingChapterStart, completedCurrent: pendingChapterCompleted) } }
                    }.padding().readerOverlayPanel()
                }

                if showsControls, showsPDFThumbnails,
                   installment.format == .pdf,
                   readerController.isPDFThumbnailNavigationAvailable
                {
                    PDFThumbnailRail(controller: readerController) {
                        showsPDFThumbnails = false
                    }
                    .transition(overlayTransition(from: .bottom))
                }

                if showsControls, readerController.ttsState != .idle {
                    PublicationTTSControls(controller: readerController)
                        .padding(.horizontal)
                        .transition(overlayTransition(from: .bottom))
                }

                ReaderFeedbackControls(showsControls: showsControls, status: readerStatus) {
                    readerBottomControls
                }
            }
            .padding(.bottom, 10)
            .modifier(ReaderExpandedChrome(alignment: .bottom))
        }
        .overlay(alignment: autoScrollAlignment) {
            if isImagePublication, !imageLayout.isPaged, readerOptions.autoScroll {
                Button { imageController.toggleAutoScroll() } label: {
                    Image(systemName: imageController.isAutoScrolling ? "pause.fill" : "play.fill")
                        .appIconControlFrame(dimension: 48)
                }
                .background(.ultraThinMaterial, in: Circle())
                .padding(.horizontal, 20).padding(.bottom, showsControls ? 70 : 20)
                .accessibilityLabel(imageController.isAutoScrolling ? "Pause auto-scroll" : "Start auto-scroll")
            }
        }
    }

    private var readerChromeWithCover: some View {
        readerChrome
        .allowsHitTesting(!foldedCover.isPresented)
        .accessibilityHidden(foldedCover.isPresented)
        .overlay {
            if foldedCover.isPresented {
                FoldedBookCoverView(title: work.title, speech: readerController.ttsState,
                    read: { foldedCover.dismiss() }, close: { dismiss() },
                    toggleSpeech: { readerController.toggleTTS() }) {
                    FoldedBookCoverArtwork(work: work)
                }
            }
        }
        .observeBookCoverHinge {
            foldedCover.observe($0, enabled: showsCoverWhenFolded, canPresent: canPresentFoldedCover)
        }
        .onChange(of: showsCoverWhenFolded) { _, enabled in
            if !enabled { foldedCover.dismiss() }
        }
        .onChange(of: canPresentFoldedCover) { _, canPresent in
            if !canPresent { foldedCover.dismiss() }
        }
        .onChange(of: foldedCover.isPresented) { _, visible in
            if visible {
                imageController.pauseAutoScroll()
                flushReadingPosition()
                if foldedCover.shouldPauseSpeech(preference: pausesSpeechWhenFolded, speech: readerController.ttsState) {
                    readerController.toggleTTS()
                }
            }
            updateActiveReadingTime(for: scenePhase)
        }
        .onChange(of: readerController.ttsState) { _, _ in updateActiveReadingTime(for: scenePhase) }
    }

    private var presentedReader: some View {
        readerChromeWithCover
        .background { ReaderOrientationControl(orientation: readerOptions.orientation) }
        .sheet(isPresented: $showsChapters) {
            NavigationStack {
                List(ReaderChapterPolicy.ordered(chapters)) { chapter in
                    Button {
                        showsChapters = false
                        if chapter.id != installment.id {
                            if let imageSession, !chapter.format.isTextPublication { imageSession.openChapter(chapter) }
                            else { openChapter(chapter, start: .beginning) }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(chapter.title)
                                if let group = chapter.scanlators, !group.isEmpty {
                                    Text(group.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if chapter.id == installment.id { Image(systemName: "checkmark") }
                        }
                    }.disabled(switchingChapter)
                }
                .navigationTitle("Chapters")
                .appNativeNavigationChrome()
                .toolbar { ToolbarItem(placement: .confirmationAction) { FixedNavigationChrome { Button("Done") { showsChapters = false } } } }
            }
            .appFeedbackOverlay()
        }
        .sheet(isPresented: $showsOutline) {
            PublicationOutlineSheet(controller: readerController)
        }
        .sheet(isPresented: $showsPublicationSearch) {
            PublicationSearchSheet(controller: readerController)
        }
        .sheet(isPresented: $showsReaderMarks) {
            ReaderMarksSheet(
                bookmarks: $bookmarks,
                annotations: $annotations,
                format: installment.format,
                controller: readerController,
                highlightAppearanceIsDark: highlightAppearanceIsDark,
                increasedContrast: accessibilityContrast == .increased,
                onNavigate: navigate(to:)
            )
        }
        .sheet(isPresented: $showsImageReaderSettings) {
            ReaderSettingsSheet(work: work, format: installment.format, epubLayout: readerController.epubLayout)
        }
        .sheet(item: $annotationEditorDraft) { draft in
            NavigationStack {
                ReaderAnnotationEditor(
                    draft: draft,
                    highlightAppearanceIsDark: highlightAppearanceIsDark,
                    increasedContrast: accessibilityContrast == .increased
                ) { note, highlightColor in
                    guard let annotation = await model.libraryModel.addAnnotation(
                        work: work,
                        installment: installment,
                        anchor: draft.anchor,
                        note: note,
                        highlightColor: highlightColor
                    ) else {
                        return false
                    }
                    annotations.removeAll { $0.id == annotation.id }
                    annotations.insert(annotation, at: 0)
                    readerController.setAnnotations(annotations)
                    model.feedback.showStatus(
                        draft.anchor.selectedText == nil ? "Note added." : "Highlight added.",
                        systemImage: draft.anchor.selectedText == nil ? "note.text" : "highlighter"
                    )
                    return true
                }
            }
            .appFeedbackOverlay()
        }
        .fileImporter(
            isPresented: $isRelinkingPublication,
            allowedContentTypes: relinkContentTypes,
            allowsMultipleSelection: false
        ) { result in
            Task {
                guard let fileURL = await model.relinkImportedPublication(
                    result,
                    installment: installment
                ) else { return }
                replacementAcquisitionURL = fileURL
                readiumPhase = .idle
                cbzPhase = .idle
            }
        }
        .alert(item: $readerAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    var body: some View {
        presentedReader
        .onChange(of: model.feedback.statusMessage) { _, status in
            guard status?.id != observedStatusID else { return }
            observedStatusID = status?.id
            readerStatus = status
            if let status, model.feedback.claimStatusAnnouncement(status.id) {
                UIAccessibility.post(notification: .announcement, argument: status.message)
            }
        }
        .onChange(of: model.feedback.alert?.id) { _, alertID in
            guard alertID != nil, let alert = model.feedback.alert else { return }
            readerAlert = ReaderPresentedAlert(title: alert.title, message: alert.message)
            model.feedback.alert = nil
        }
        .onChange(of: readerController.toolErrorMessage) { _, message in
            guard let message else { return }
            readerAlert = ReaderPresentedAlert(title: "Reader Tool Error", message: message)
            readerController.dismissToolError()
        }
        .onChange(of: model.transfersModel.downloads) { _, _ in
            guard isRecoveringDownloadedPublication else { return }
            Task { await updateDownloadedPublicationRecovery() }
        }
        .onAppear {
            SourceCacheRefresh.shared.readers.insert(readerActivityID)
            model.readerWrites.begin(readerActivityID)
            model.importedFilePrefetchTask?.cancel()
            imageController.onBoundary = { forward in moveChapter(forward: forward, fromBoundary: true) }
            readerController.onBoundaryHint = { forward in
                readiumBoundary = forward.map { $0 ? .next : .previous }
                if forward == true { completeChapter(installment) }
                if forward == nil {
                    chapterFailure = nil
                    if readiumBoundaryRequestID != nil {
                        readiumBoundaryRequestID = nil
                        chapterTask?.cancel()
                    }
                }
                if forward != nil { Task { await chapterCatalog?.refreshIfNeeded() } }
            }
            readerController.onBoundary = { forward in
                continueReadiumBoundary(forward ? .next : .previous)
            }
            readerController.onUserNavigation = { if readerOptions.hideBarsOnSwipe { setControlsVisible(false) } }
            configureReadiumControls()
            observedStatusID = model.feedback.statusMessage?.id
            if let alert = model.feedback.alert {
                readerAlert = ReaderPresentedAlert(title: alert.title, message: alert.message)
                model.feedback.alert = nil
            }
            if isImagePublication { beginReadingSessionIfNeeded() }
        }
        .task(id: initialInstallment.id) {
            await loadInitialReadingState()
            guard !Task.isCancelled, !hasFinishedSession else { return }
            await chapterCatalog?.refreshIfNeeded()
        }
        .task(id: model.cloudReadingRevision) { await checkRemoteProgress() }
        .onChange(of: readerController.restoredReadingLocator) { _, locator in
            guard !isImagePublication, let locator else { return }
            beginReadingSessionIfNeeded()
            latestLocator = locator
            if chapterStart != .resume {
                lastLocalPositionChange = .now
                flushReadingPosition()
            }
        }
        .onChange(of: showsImageReaderSettings) { _, visible in if visible { imageController.pauseAutoScroll() } }
        .onChange(of: readerOptions) { _, _ in configureReadiumControls() }
        .onChange(of: epubScroll) { _, _ in configureReadiumControls() }
        .onChange(of: pdfContinuous) { _, _ in configureReadiumControls() }
        .onChange(of: readerController.positionCount) { _, count in
            guard count > 0 else { return }
            sessionReadingUnitCount = count
            if progressivePublication != nil { didSetInitialPosition = true; return }
            guard !didSetInitialPosition else { return }
            didSetInitialPosition = true
            if chapterStart != .resume { readerController.navigate(toPosition: chapterStart == .end ? count - 1 : 0) }
        }
        .task(id: readerAcquisitionURL) {
            if hasLoadedProgress, isImagePublication, imageSession == nil { await startImageSession() }
        }
        .onChange(of: controlsMustRemainVisible, initial: true) { _, mustRemainVisible in
            if mustRemainVisible {
                setControlsVisible(true)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                SourceCacheRefresh.shared.readers.remove(readerActivityID)
                imageController.pauseAutoScroll()
                flushReadingPosition()
            } else {
                SourceCacheRefresh.shared.readers.insert(readerActivityID)
                model.importedFilePrefetchTask?.cancel()
            }
            updateActiveReadingTime(for: phase)
        }
        .onDisappear(perform: closeReadingSession)
        .focusedSceneValue(\.mangoReaderReaderCommands, readerCommandActions)
        .accessibilityAction(.escape) {
            dismiss()
        }
    }

    private func closeReadingSession() {
        SourceCacheRefresh.shared.readers.remove(readerActivityID)
        chapterTask?.cancel()
        imageSession?.cancel()
        let feedbackID = model.feedback.statusMessage?.id
        let currentID = readerStatus?.id
        if feedbackID == currentID { model.feedback.statusMessage = nil }
        guard !hasFinishedSession else { return }
        hasFinishedSession = true
        progressSaveTask?.cancel()
        readerController.cancelSearch(clearResults: true)
        readerController.stopTTS()
        finishCurrentReadingSession()
        model.finishReaderActivity(readerActivityID, workID: work.id)
    }

    private func loadInitialReadingState() async {
        let progress = await model.libraryModel.readingProgress(
            for: work.id,
            installmentID: installment.id
        )
        guard !Task.isCancelled, !hasFinishedSession else { return }
        savedProgress = progress
        imageRestoration.begin()
        lastLocalPositionChange = nil
        latestLocator = chapterStart == .resume ? savedProgress?.resumeLocator : nil
        if isImagePublication, chapterStart != .resume {
            latestLocator = .image(page: chapterStart == .end ? Int.max : 0, total: nil, offset: chapterStart == .end ? 0.999_999 : 0)
        }
        if chapterStart != .resume { savedProgress = nil }
        startProgression = savedProgress?.currentProgression ?? 0
        hasLoadedProgress = true
        if isImagePublication { await startImageSession() }
        let marks = await model.libraryModel.readerMarks(for: installment.id)
        guard !Task.isCancelled, !hasFinishedSession else { return }
        bookmarks = marks.bookmarks
        annotations = marks.annotations
        readerController.setAnnotations(marks.annotations)
        await checkRemoteProgress()
        #if DEBUG
        Task { await AppFixtures.deliverCloudPositionIfNeeded(model: model, work: work, installment: installment) }
        #endif
    }

    private var readerLayout: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Let each reader own its gestures; an ancestor tap recognizer can
            // prevent PDFKit from forwarding otherwise unhandled center taps.
            readerSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: isImagePublication ? .all : [])
        }
        .overlay(alignment: readiumBoundary == .previous ? .top : .bottom) {
            if let readiumBoundary, !isImagePublication {
                ReaderChapterBoundaryPanel(current: installment, direction: readiumBoundary,
                    state: readiumBoundaryState(readiumBoundary)) { retryReadiumBoundary(readiumBoundary) }
                    .task(id: readiumBoundaryState(readiumBoundary)) {
                        guard readiumBoundaryState(readiumBoundary) == .absent else { return }
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled, self.readiumBoundary == readiumBoundary else { return }
                        readerController.dismissChapterBoundary()
                        self.readiumBoundary = nil
                    }
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 16)
                    .padding(.vertical, showsControls ? 76 : 12)
                    .transition(.opacity)
            }
        }
        .animation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.22), value: readiumBoundary)
        .overlay(alignment: .top) {
            ReaderTopChrome(showsControls: showsControls) {
                readerHeader
                    .transition(overlayTransition(from: .top))
            } status: {
                if let imageSession {
                    ImageReaderSessionStatusView(session: imageSession)
                }
            }
            .modifier(ReaderExpandedChrome(alignment: .top))
        }
    }

    @ViewBuilder
    private var readerSurface: some View {
        if !hasLoadedProgress {
            ReaderContentSkeleton(layout: installment.format == .epub ? .text : .page, label: String(localized: "Restoring your place…"))
                .tint(.white)
                .foregroundStyle(.white)
        } else if let imageSession {
            ImageReaderSessionView(session: imageSession, settings: imageReaderSettings, liveText: imageReaderLiveText,
                controls: controlsVisibilityBinding, navigation: imageController, showsStatusOverlay: false)
                .background(Color.black)
        } else if isLocalPublicationFileMissing {
            missingPublicationFile
        } else {
            switch installment.format {
            case .remoteImageSequence:
                remoteImageReaderSurface

            case .epub, .pdf:
                if let progressivePublication {
                    ProgressivePublicationReaderView(session: progressivePublication,
                        initialLocator: persistedReadiumLocator?.readingLocator, startAtEnd: chapterStart == .end,
                        textPreferences: textPreferences, controller: readerController,
                        controlsVisible: controlsVisibilityBinding, onPhaseChange: { readiumPhase = $0 },
                        onLocatorChange: didMove(to:))
                        .background(Color(uiColor: .systemBackground))
                } else if let url = readerAcquisitionURL {
                    ReadiumPublicationReaderView(
                        sourceURL: url,
                        format: installment.format,
                        initialLocator: persistedReadiumLocator,
                        textPreferences: textPreferences,
                        pdfPreferences: pdfPreferences,
                        expandedReading: readerOptions.expandedReading,
                        controller: readerController,
                        controlsVisible: controlsVisibilityBinding,
                        onPhaseChange: { readiumPhase = $0 },
                        onLocatorChange: didMove(to:)
                    )
                    .id(url)
                    .background(Color(uiColor: .systemBackground))
                } else {
                    downloadRequired
                }

            case .cbz:
                if let url = readerAcquisitionURL {
                    LocalCBZReaderView(
                        sourceURL: url,
                        settings: imageReaderSettings,
                        initialLocator: latestLocator,
                        navigationRequestID: imageReaderNavigationID,
                        maximumCachedPages: 12,
                        navigation: imageController,
                liveTextEnabled: imageReaderLiveText,
                        controlsVisible: controlsVisibilityBinding,
                        onPhaseChange: { cbzPhase = $0 },
                        onLocatorChange: didMove(to:)
                    )
                    .id(url)
                    .background(Color.black)
                } else {
                    downloadRequired
                }
            }
        }
    }

    @ViewBuilder
    private var remoteImageReaderSurface: some View {
        if let remoteImagePublication {
            RemoteImageReaderView(
                publication: remoteImagePublication,
                settings: imageReaderSettings,
                initialLocator: latestLocator,
                navigationRequestID: imageReaderNavigationID,
                maximumCachedPages: 12,
                navigation: imageController,
                liveTextEnabled: imageReaderLiveText,
                controlsVisible: controlsVisibilityBinding,
                onPhaseChange: { remoteImageReaderPhase = $0 },
                onLocatorChange: didMove(to:)
            )
            .id(ObjectIdentifier(remoteImagePublication))
            .background(Color.black)
        } else if remoteImageLoadError != nil {
            ReaderPublicationRecoveryView(
                presentation: .streamFailure,
                isWorking: false
            ) {
                remoteImageReloadID = UUID()
            }
        } else {
            ReaderContentSkeleton(label: String(localized: "Connecting to source…"))
                .tint(.white)
                .foregroundStyle(.white)
        }
    }

    private var downloadRequired: some View {
        ContentUnavailableView {
            Label("Download required", systemImage: "arrow.down.circle")
        }
        .foregroundStyle(.white)
    }

    private var missingPublicationFile: some View {
        let presentation: ReaderPublicationRecoveryPresentation = work.sourceID == .local
            ? .missingImport
            : .missingDownload
        return ReaderPublicationRecoveryView(
            presentation: presentation,
            isWorking: isRecoveringDownloadedPublication
        ) {
            if work.sourceID == .local {
                isRelinkingPublication = true
            } else {
                Task { await recoverDownloadedPublication() }
            }
        }
    }

    private func recoverDownloadedPublication() async {
        guard !isRecoveringDownloadedPublication else { return }
        isRecoveringDownloadedPublication = true
        guard await model.recoverMissingDownloadedPublication(
            work: work,
            installment: installment
        ) else {
            isRecoveringDownloadedPublication = false
            return
        }
        await updateDownloadedPublicationRecovery()
    }

    private func updateDownloadedPublicationRecovery() async {
        guard isRecoveringDownloadedPublication else { return }
        let snapshot = model.transfersModel.downloadSnapshot(for: installment.id)
        let recoveredURL = await model.transfersModel.downloadedPublicationURL(for: installment.id)
        switch ReaderDownloadRecoveryPolicy.resolution(
            state: snapshot?.state,
            downloadedFileExists: recoveredURL != nil
        ) {
        case .waiting:
            break
        case .ready:
            guard let recoveredURL else { return }
            replacementAcquisitionURL = recoveredURL
            readiumPhase = .idle
            cbzPhase = .idle
            isRecoveringDownloadedPublication = false
        case .failed:
            isRecoveringDownloadedPublication = false
            model.feedback.showStatus("Download failed. Try again.", systemImage: "exclamationmark.circle")
        }
    }

    private var readerAcquisitionURL: URL? {
        replacementAcquisitionURL ?? installment.acquisitionURL
    }

    private var isLocalPublicationFileMissing: Bool {
        if progressivePublication != nil { return false }
        guard let url = readerAcquisitionURL, url.isFileURL else { return false }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    private var relinkContentTypes: [UTType] {
        switch installment.format {
        case .epub:
            [UTType(filenameExtension: "epub") ?? .data]
        case .pdf:
            [.pdf]
        case .cbz:
            [UTType(filenameExtension: "cbz") ?? .zip, .zip]
        case .remoteImageSequence:
            [.data]
        }
    }

    private var persistedReadiumLocator: PersistedReadiumLocator? {
        guard let locator = savedProgress?.resumeLocator else { return nil }
        return try? PersistedReadiumLocator(readingLocator: locator)
    }

    private var textPreferences: TextReaderPreferences {
        let theme = (PublicationTheme(rawValue: publicationTheme) ?? .system)
            .resolved(forDarkAppearance: colorScheme == .dark)
        return TextReaderPreferences(
            readingMode: epubScroll ? .scroll : .paged,
            theme: theme,
            font: readerOptions.fontFamily.map(PublicationFontSelection.named) ?? readerFontPreset.selection,
            fontScale: readerFontScale,
            fontWeight: readerFontWeight,
            lineHeight: readerLineHeight,
            paragraphSpacing: readerParagraphSpacing,
            paragraphIndent: readerParagraphIndent,
            horizontalMargin: readerPageMargins,
            wordSpacing: readerWordSpacing,
            letterSpacing: readerLetterSpacing,
            usesPublisherStyles: publisherStyles,
            hyphenationEnabled: readerHyphenation,
            textNormalizationEnabled: readerTextNormalization,
            textAlignment: readerTextAlignment,
            columnCount: readerColumnCount,
            verticalWritingEnabled: verticalWriting
        )
    }

    private var highlightAppearanceIsDark: Bool {
        textPreferences.theme == .black
    }

    private var pdfPreferences: PDFReaderPreferences {
        PDFReaderPreferences(
            pageLayout: PDFPageLayout(rawValue: readerOptions.pdfPageLayout ?? "") ?? (pdfDoublePage ? .double : .single),
            scrollMode: pdfContinuous ? .continuous : .paged,
            fitMode: PDFFitMode(rawValue: readerOptions.pdfFit) ?? .width,
            readingDirection: readerOptions.pdfDirection == "rtl" ? .rightToLeft : .leftToRight,
            displaysPageBreaks: readerOptions.pdfPageBreaks
        )
    }

    private var imageReaderSettings: ImageReaderSettings {
        let transition = ImagePageTransition(rawValue: imageReaderTransition) ?? .slide
        var options = readerOptions
        options.pageOffset = options.workOverrides[work.id.description]?.pageOffset ?? options.pageOffset
        options.workOverrides = options.workOverrides[work.id.description].map { [work.id.description: $0] } ?? [:]
        return ImageReaderSettings(
            options: options,
            direction: imageDirection,
            layout: imageLayout,
            spread: ImagePageSpread(rawValue: readerOptions.pageLayout) ?? .automatic,
            widePageBehavior: imageReaderWidePageBehavior,
            widePageAspectRatioThreshold: 1,
            cropMode: imageReaderCropMargins ? .automatic : .none,
            tapZones: imageTapZoneConfiguration,
            prefetch: ImagePrefetchSettings(pagesAhead: readerOptions.preloadCount, pagesBehind: 1, maximumConcurrentRequests: 1),
            transition: transition.resolved(
                reduceMotion: accessibilityReduceMotion || reduceReaderTransitions
            )
        )
    }

    private var imageTapZoneConfiguration: TapZoneConfiguration {
        if readerOptions.tapPreset == "custom" {
            return ReaderImageTapZonePolicy.configuration(direction: imageDirection,
                leadingAction: readerOptions.invertTapZones ? imageReaderTapTrailingAction : imageReaderTapLeadingAction,
                trailingAction: readerOptions.invertTapZones ? imageReaderTapLeadingAction : imageReaderTapTrailingAction)
        }
        return .preset(readerOptions.tapPreset, direction: imageDirection, layout: imageLayout, inverted: readerOptions.invertTapZones)
    }

    private var imageDirection: ImageReadingDirection {
        readerOptions.readingMode(for: work) == "rtl" ? .rightToLeft : .leftToRight
    }

    private var imageLayout: ImageReaderLayout {
        switch readerOptions.readingMode(for: work) {
        case "verticalPaged": .verticalPaged
        case "vertical", "continuous": .vertical
        case "webtoon": .webtoon
        default: .paged
        }
    }


    @ViewBuilder
    private var readerHeader: some View {
        GlassCapsuleGroup(spacing: 8) {
            readerHeaderGroups
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .appFixedNavigationChrome()
    }

    private var readerHeaderGroups: some View {
        HStack(spacing: 12) {
            closeReaderButton

            readerTitleGroup
                .layoutPriority(1)

            readerActionsGroup
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(.primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader-header-context")
    }

    private var readerTitleGroup: some View {
        Group {
            if ReaderHeaderTitlePolicy.usesCombinedLine(for: AppDynamicTypeSizing.navigationSize) {
                Text(ReaderHeaderTitlePolicy.combinedTitle(
                    workTitle: work.title,
                    installmentTitle: installment.title
                ))
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(work.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(installment.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(
            maxWidth: .infinity,
            minHeight: 48,
            alignment: .leading
        )
        .modifier(ReaderGlassCapsuleStyle(interactive: false))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(work.title), \(installment.title)")
        .accessibilityIdentifier("reader-header-title")
    }

    private var readerActionsGroup: some View {
        HStack(spacing: 0) {
            Button { showsImageReaderSettings = true } label: {
                Image(systemName: "slider.horizontal.3").appIconControlFrame(dimension: 48)
            }
            .accessibilityLabel("Reader settings")
            .accessibilityIdentifier("reader-settings")
            publicationToolsMenu
        }
        .foregroundStyle(.primary)
        .modifier(ReaderGlassCapsuleStyle(interactive: true))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader-header-actions")
    }

    private var closeReaderButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .appIconControlFrame(dimension: 48)
        }
        .modifier(ReaderGlassCircleStyle())
        .accessibilityLabel("Close reader")
        .accessibilityIdentifier("reader-close")
    }

    private var publicationToolsMenu: some View {
        Menu {
            NavigationMenuContent {
                if isImagePublication || chapters.count > 1 {
                    Button("Chapters", systemImage: "list.bullet") { showsChapters = true }
                }
                if !isImagePublication {
                    Button("Contents", systemImage: "list.bullet.indent") { showsOutline = true }
                }
                if latestLocator != nil {
                    addBookmarkButton
                }
                Divider()
                Button {
                    showsReaderMarks = true
                } label: {
                    Text("Bookmarks & Notes")
                }
                .accessibilityIdentifier("reader-open-marks")

                if toolAvailability.canAnnotate {
                    Button {
                        beginAnnotation()
                    } label: {
                        Text("Add Highlight or Note")
                    }
                    .accessibilityIdentifier("reader-add-annotation")
                }

                if toolAvailability.showsNavigationTools {
                    Divider()

                    if toolAvailability.showsPDFThumbnails {
                        Button {
                            showsPDFThumbnails.toggle()
                        } label: {
                            Text(showsPDFThumbnails ? "Hide Page Thumbnails" : "Page Thumbnails")
                        }
                        .accessibilityIdentifier("reader-pdf-thumbnails")
                    }

                    if toolAvailability.showsSearch {
                        Button {
                            showsPublicationSearch = true
                        } label: {
                            Label("Search Publication", systemImage: "magnifyingglass")
                        }
                    }

                    if toolAvailability.showsTextToSpeech {
                        Button {
                            readerController.toggleTTS()
                        } label: {
                            Label(ttsMenuTitle, systemImage: ttsMenuSymbol)
                        }
                    }
                }
            }
        } label: {
            Group {
                if isMutatingBookmark {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "ellipsis")
                }
            }
            .appIconControlFrame(dimension: 48)
        }
        .accessibilityLabel("More")
        .accessibilityValue(isMutatingBookmark ? "Updating bookmark" : "")
        .accessibilityIdentifier("reader-publication-tools")
    }

    private var addBookmarkButton: some View {
        Button {
            toggleBookmark()
        } label: {
            Label(
                isMutatingBookmark ? "Updating Bookmark…" : (currentBookmark == nil ? "Add Bookmark" : "Remove Bookmark"),
                systemImage: currentBookmark == nil ? "bookmark" : "bookmark.fill"
            )
        }
        .disabled(isMutatingBookmark)
        .accessibilityLabel(currentBookmark == nil ? "Add bookmark" : "Remove bookmark")
        .accessibilityValue(currentBookmark == nil ? "Not bookmarked" : "Bookmarked")
        .accessibilityIdentifier("reader-add-bookmark")
    }

    private var currentBookmark: Bookmark? {
        ReaderBookmarkTogglePolicy.bookmark(at: latestLocator, in: bookmarks)
    }

    private func toggleBookmark() {
        guard !isMutatingBookmark, let latestLocator else { return }
        isMutatingBookmark = true
        let existing = currentBookmark
        Task {
            defer { isMutatingBookmark = false }
            if let existing {
                guard await model.libraryModel.deleteBookmark(existing) else { return }
                bookmarks.removeAll { $0.id == existing.id }
                model.feedback.showStatus("Bookmark removed.", systemImage: "bookmark.slash.fill")
            } else {
                guard let bookmark = await model.libraryModel.addBookmark(
                    work: work,
                    installment: installment,
                    locator: latestLocator
                ) else {
                    return
                }
                bookmarks.removeAll { $0.id == bookmark.id }
                bookmarks.insert(bookmark, at: 0)
            }
        }
    }

    private func overlayTransition(from edge: Edge) -> AnyTransition {
        if accessibilityReduceMotion || reduceReaderTransitions {
            return .opacity
        }
        return .move(edge: edge).combined(with: .opacity)
    }

    private func setControlsVisible(_ visible: Bool) {
        guard visible || !isSelectingPage else { return }
        guard visible || !controlsMustRemainVisible else { return }

        if accessibilityReduceMotion || reduceReaderTransitions {
            showsControls = visible
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                showsControls = visible
            }
        }
    }

    private var controlsVisibilityBinding: Binding<Bool> {
        Binding(
            get: { showsControls },
            set: { setControlsVisible($0) }
        )
    }

    private var controlsMustRemainVisible: Bool {
        return ReaderControlsVisibilityPolicy.mustRemainVisible(
            contentAvailability: readerContentAvailability,
            voiceOverEnabled: accessibilityVoiceOverEnabled,
            switchControlEnabled: accessibilitySwitchControlEnabled,
            imageGesturesUnavailable: false
        )
    }

    private var ttsMenuTitle: String {
        switch readerController.ttsState {
        case .idle:
            "Start Text to Speech"
        case .speaking:
            "Pause Text to Speech"
        case .paused:
            "Resume Text to Speech"
        }
    }

    private var ttsMenuSymbol: String {
        switch readerController.ttsState {
        case .idle:
            "headphones"
        case .speaking:
            "pause.fill"
        case .paused:
            "play.fill"
        }
    }

    private var isImagePublication: Bool {
        installment.format == .cbz || installment.format == .remoteImageSequence
    }

    private var toolAvailability: ReaderToolAvailability {
        ReaderToolAvailability.resolve(
            format: installment.format,
            hasLocator: latestLocator != nil,
            isPublicationReady: readerController.isPublicationReady,
            isPDFThumbnailNavigationAvailable: readerController.isPDFThumbnailNavigationAvailable,
            isSearchable: readerController.isSearchable,
            isTTSSupported: readerController.isTTSSupported
        )
    }

    private var readerContentAvailability: ReaderContentAvailability {
        guard hasLoadedProgress else { return .loading }
        if let imageSession {
            switch imageSession.phase { case .loading: return .loading; case .ready: return .ready; case .failed: return .unavailable }
        }

        switch installment.format {
        case .epub, .pdf:
            guard progressivePublication != nil || (readerAcquisitionURL != nil && !isLocalPublicationFileMissing) else { return .unavailable }
            return switch readiumPhase {
            case .idle, .loading: .loading
            case .ready: .ready
            case .failed: .unavailable
            }

        case .cbz:
            guard readerAcquisitionURL != nil, !isLocalPublicationFileMissing else { return .unavailable }
            return switch cbzPhase {
            case .idle, .loading: .loading
            case .ready: .ready
            case .failed: .unavailable
            }

        case .remoteImageSequence:
            if remoteImageLoadError != nil { return .unavailable }
            guard remoteImagePublication != nil else { return .loading }
            return switch remoteImageReaderPhase {
            case .idle, .loading: .loading
            case .ready: .ready
            case .failed: .unavailable
            }
        }
    }

    private var autoScrollAlignment: Alignment {
        switch readerOptions.autoScrollPosition { case "left": .bottomLeading; case "center": .bottom; default: .bottomTrailing }
    }

    @ViewBuilder
    private var readerBottomControls: some View {
        let count = isImagePublication ? imageController.pageCount : readerController.positionCount
        if count > 0 || progressivePublication != nil {
            ImageReaderPageControls(
                currentPageIndex: isImagePublication ? imageController.currentPageIndex : readerController.currentPosition,
                pageCount: max(1, count),
                // Readium positions are approximate text locations, not viewport
                // boundaries. Let its navigator determine whether it can move.
                isAtBeginning: isImagePublication ? imageController.isAtBeginning && adjacentChapter(forward: false) == nil : readiumBoundary == .previous && readiumBoundaryState(.previous) == .absent,
                isAtEnd: isImagePublication ? imageController.isAtEnd && adjacentChapter(forward: true) == nil : readiumBoundary == .next && readiumBoundaryState(.next) == .absent,
                direction: isImagePublication ? imageDirection : (installment.format == .pdf && readerOptions.pdfDirection == "rtl" ? .rightToLeft : .leftToRight),
                layout: bottomControlLayout,
                usesPositions: installment.format == .epub,
                showsTotal: progressivePublication?.complete ?? true,
                canSeek: readerContentAvailability == .ready && readerCommandsCanNavigate
                    && (progressivePublication?.complete ?? true)
                    && !switchingChapter && (!isImagePublication || !imageRestoration.isRestoring),
                seek: seekToPage,
                onSelectionChanged: { selecting in
                    isSelectingPage = selecting
                    if selecting {
                        imageController.pauseAutoScroll()
                        setControlsVisible(true)
                    }
                },
                moveBackward: { moveInReadingOrder(forward: false) },
                moveForward: { moveInReadingOrder(forward: true) })
                .id(installment.id)
                .disabled(switchingChapter)
                .padding(.horizontal)
        }
    }

    private func seekToPage(_ index: Int) {
        guard readerCommandsCanNavigate, readerContentAvailability == .ready, !switchingChapter,
              !isImagePublication || !imageRestoration.isRestoring else { return }
        imageController.pauseAutoScroll()
        setControlsVisible(true)
        if isImagePublication {
            imageController.move(to: index)
        } else {
            readerController.navigate(toPosition: index)
        }
    }

    private var bottomControlLayout: ImageReaderLayout {
        if isImagePublication { return imageLayout }
        let scrolls = installment.format == .pdf ? pdfContinuous : epubScroll && !verticalWriting
        return scrolls ? .vertical : .paged
    }

    private func configureReadiumControls() {
        let scroll = installment.format == .pdf ? pdfContinuous : epubScroll
        let direction: ImageReadingDirection = installment.format == .pdf && readerOptions.pdfDirection == "rtl" ? .rightToLeft : .leftToRight
        readerController.tapZones = readerOptions.tapPreset == "custom"
            ? ReaderImageTapZonePolicy.configuration(direction: direction,
                leadingAction: readerOptions.invertTapZones ? imageReaderTapTrailingAction : imageReaderTapLeadingAction,
                trailingAction: readerOptions.invertTapZones ? imageReaderTapLeadingAction : imageReaderTapTrailingAction)
            : .preset(readerOptions.tapPreset, direction: direction, layout: scroll ? .vertical : .paged, inverted: readerOptions.invertTapZones)
        readerController.scrollNavigation = scroll
        readerController.animatesNavigation = !reduceReaderTransitions && !accessibilityReduceMotion
    }

    private func adjacentChapter(forward: Bool) -> Installment? {
        chapterCatalog?.boundary(from: installment, direction: forward ? .next : .previous,
            skipDuplicates: readerOptions.skipDuplicateChapters).neighbor
    }

    private func moveChapter(forward: Bool, fromBoundary: Bool) {
        let direction: ReaderChapterDirection = forward ? .next : .previous
        if !isImagePublication, fromBoundary {
            continueReadiumBoundary(direction)
            return
        }
        guard let target = adjacentChapter(forward: forward) else { return }
        openChapter(target, start: fromBoundary && !forward ? .end : .beginning, completedCurrent: fromBoundary && forward)
    }

    private func readiumBoundaryState(_ direction: ReaderChapterDirection) -> ReaderChapterBoundaryState {
        let state = chapterCatalog?.boundary(from: installment, direction: direction, skipDuplicates: readerOptions.skipDuplicateChapters) ?? .loading(nil)
        if let chapterFailure { return .failed(chapterFailure, state.neighbor) }
        return switchingChapter ? .loading(state.neighbor) : state
    }

    private func continueReadiumBoundary(_ direction: ReaderChapterDirection) {
        guard !switchingChapter else { return }
        let requestID = UUID()
        readiumBoundaryRequestID = requestID
        Task { @MainActor in
            if chapterCatalog?.errorMessage != nil { await chapterCatalog?.refresh() }
            else { await chapterCatalog?.refreshIfNeeded() }
            guard readiumBoundaryRequestID == requestID, !hasFinishedSession,
                  let target = adjacentChapter(forward: direction.isForward) else { return }
            openChapter(target, start: direction == .previous ? .end : .beginning, completedCurrent: direction == .next)
        }
    }

    private func retryReadiumBoundary(_ direction: ReaderChapterDirection) {
        if case .failed = readiumBoundaryState(direction), readiumBoundaryRequestID == nil {
            // Retrying discovery at the first stop must not grant permission to advance.
            Task { await chapterCatalog?.refresh() }
        } else {
            continueReadiumBoundary(direction)
        }
    }

    private func openChapter(_ chapter: Installment, start: ReaderChapterStart, completedCurrent: Bool = false) {
        guard !switchingChapter, onOpenChapter != nil else { return }
        switchingChapter = true; chapterFailure = nil; pendingChapter = chapter; pendingChapterStart = start; pendingChapterCompleted = completedCurrent
        chapterTask = Task { @MainActor in
            defer { switchingChapter = false }
            guard var prepared = await preparedChapter(chapter) else {
                guard !Task.isCancelled else { return }
                chapterFailure = "Couldn’t open \(chapter.title). Your current chapter is still open."
                return
            }
            var handedOff = false
            defer { if !handedOff { ReaderOpeningState.removePrivatePublication(prepared.temporaryPublicationURL) } }
            do {
                try Task.checkCancellation()
                if prepared.installment.format == .remoteImageSequence {
                    let publication = try await model.libraryModel.remoteImagePublication(for: prepared.work, installment: prepared.installment)
                    try await publication.preparePage(at: start == .end ? publication.pages.count - 1 : 0)
                    prepared.remotePublication = publication
                } else if let url = prepared.installment.acquisitionURL, url.isFileURL {
                    _ = try await DefaultLocalPublicationValidator().validate(url, expectedFormat: prepared.installment.format)
                }
                try Task.checkCancellation()
            } catch is CancellationError { return }
            catch {
                chapterFailure = "Couldn’t open \(chapter.title): \(error.localizedDescription)"
                return
            }
            guard !hasFinishedSession else { return }
            if completedCurrent { completeChapter(installment) }
            handedOff = true
            onOpenChapter?(prepared, start)
        }
    }

    private func preparedChapter(_ chapter: Installment, announcesFailure: Bool = true) async -> PreparedReaderContent? {
        guard chapter.workID == work.id else { return nil }
        if let prepared = preparedChapters[ChapterKey(workID: work.id, installmentID: chapter.id)], prepared.work.id == work.id { return prepared }
        let prepared = await model.prepareToRead(work: work, installment: chapter, installments: chapters, announcesFailure: announcesFailure)
        if let prepared { preparedChapters[ChapterKey(workID: work.id, installmentID: chapter.id)] = prepared }
        return prepared
    }

    private func startImageSession() async {
        guard imageSession == nil, !isLocalPublicationFileMissing else { return }
        let catalog = chapterCatalog ?? ReaderChapterCatalog(chapters: [installment], isComplete: work.sourceID == .local) {
            try await model.libraryModel.refreshWorkDetailSnapshot(for: work).installments
        }
        let initial = initialInstallment
        let session = ImageReaderSession(chapter: initial, catalog: catalog, settings: imageReaderSettings, initialLocator: latestLocator) { chapter in
            if chapter.id == initial.id {
                if let preparedRemotePublication { return .remote(preparedRemotePublication) }
                if initial.format == .cbz, let url = readerAcquisitionURL { return .archive(url) }
            }
            guard let prepared = await preparedChapter(chapter, announcesFailure: false) else { throw ReaderChapterPreparationError.unavailable }
            if let publication = prepared.remotePublication { return .remote(publication) }
            if prepared.installment.format == .cbz, let url = prepared.installment.acquisitionURL { return .archive(url) }
            if prepared.installment.format == .remoteImageSequence {
                let publication = try await model.libraryModel.remoteImagePublication(for: prepared.work, installment: prepared.installment)
                return .remote(publication)
            }
            if let url = prepared.installment.acquisitionURL, url.isFileURL {
                _ = try await DefaultLocalPublicationValidator().validate(url, expectedFormat: prepared.installment.format)
            }
            return .external
        }
        session.onLocatorChange = { chapter, locator in
            guard chapter.id == installment.id else { return }
            didMove(to: locator)
        }
        session.onActiveChapterChange = { chapter, locator in activateImageChapter(chapter, locator: locator) }
        session.onChapterCompleted = { chapter in completeChapter(chapter) }
        session.onExternalChapter = { chapter, direction in
            openChapter(chapter, start: direction == .previous ? .end : .beginning)
        }
        imageSession = session
        await session.start()
        if let restored = session.currentReadingLocator {
            imageRestoration.complete(at: restored)
            latestLocator = restored
            captureImageReadingUnitCount(restored)
        }
    }

    private func activateImageChapter(_ chapter: Installment, locator: ReadingLocator) {
        guard chapter.id != installment.id else { return }
        progressSaveTask?.cancel()
        finishCurrentReadingSession()
        activeImageInstallment = chapter
        latestLocator = locator; savedProgress = nil
        sessionReadingUnitCount = nil
        captureImageReadingUnitCount(locator)
        imageRestoration.complete(at: locator)
        lastLocalPositionChange = .now
        pendingRemoteProgress = nil
        sessionID = UUID(); sessionStartedAt = .now
        startProgression = locator.progression ?? 0; activeSeconds = 0
        activeSince = countsActiveReadingTime ? .now : nil
        bookmarks = []; annotations = []
        let id = sessionID, started = sessionStartedAt
        model.readerWrites.enqueue {
            await model.libraryModel.beginReadingSession(id: id, work: work, installment: chapter, startedAt: started)
        }
        Task { @MainActor in
            let marks = await model.libraryModel.readerMarks(for: chapter.id)
            guard installment.id == chapter.id, sessionID == id, !hasFinishedSession else { return }
            bookmarks = marks.bookmarks; annotations = marks.annotations
        }
    }

    private func completeChapter(_ chapter: Installment) {
        guard completedChapters.insert(chapter.id).inserted else { return }
        let viewportLocator = chapter.id == installment.id ? latestLocator : nil
        let completedAt = Date.now
        let marksDuplicates = readerOptions.markDuplicateChapters, candidates = chapters
        model.readerWrites.enqueue {
            _ = await model.markRead(work: work, installment: chapter, announces: false, locator: viewportLocator, modifiedAt: completedAt)
            let duplicateChapters = marksDuplicates ? await AppModel.completedDuplicates(of: chapter, in: candidates) : []
            for duplicate in duplicateChapters { _ = await model.markRead(work: work, installment: duplicate, announces: false, runsAutomation: false, modifiedAt: completedAt) }
        }
    }

    private func beginReadingSessionIfNeeded() {
        guard !hasStartedSession, !hasFinishedSession else { return }
        hasStartedSession = true
        sessionStartedAt = .now
        activeSince = countsActiveReadingTime ? .now : nil
        let id = sessionID, startedAt = sessionStartedAt
        let chapter = installment
        model.readerWrites.enqueue { await model.libraryModel.beginReadingSession(id: id, work: work, installment: chapter, startedAt: startedAt) }
    }

    private func finishCurrentReadingSession() {
        guard hasStartedSession else { return }
        let id = sessionID, chapter = installment
        let changedAt = lastLocalPositionChange
        let locator = latestLocator
        let savesPosition = changedAt != nil && pendingRemoteProgress == nil
            && (isImagePublication ? !imageRestoration.isRestoring : !readerController.isRestoringInitialLocation)
        let started = sessionStartedAt, progression = startProgression
        let seconds = activeReadingSeconds(at: .now)
        let unitCount = sessionReadingUnitCount
        model.readerWrites.enqueue {
            await model.finishReadingSession(id: id, work: work, installment: chapter, startedAt: started,
                startProgression: progression, locator: locator, secondsRead: seconds, readingUnitCount: unitCount,
                progressModifiedAt: changedAt, savesPosition: savesPosition)
            Task(priority: .utility) { await model.cloudSyncEngine?.sendPendingChanges() }
        }
    }

    private var readerCommandActions: MangoReaderReaderCommandActions {
        MangoReaderReaderCommandActions(
            canNavigate: readerCommandsCanNavigate,
            controlsAreVisible: showsControls,
            previousPage: { moveInReadingOrder(forward: false) },
            nextPage: { moveInReadingOrder(forward: true) },
            toggleControls: { setControlsVisible(!showsControls) },
            closeReader: { dismiss() }
        )
    }

    private var readerCommandsCanNavigate: Bool {
        guard !foldedCover.isPresented else { return false }
        return switch installment.format {
        case .epub, .pdf:
            readerController.isPublicationReady && !readerController.isRestoringInitialLocation
        case .cbz, .remoteImageSequence:
            latestLocator != nil
        }
    }

    private func moveInReadingOrder(forward: Bool) {
        guard !foldedCover.isPresented else { return }
        if let direction = readiumBoundary, forward != direction.isForward {
            readerController.dismissChapterBoundary()
            readiumBoundary = nil
            chapterFailure = nil
        }
        switch installment.format {
        case .epub, .pdf:
            if forward {
                readerController.moveForward()
            } else {
                readerController.moveBackward()
            }

        case .cbz, .remoteImageSequence:
            if forward { imageController.moveForward() } else { imageController.moveBackward() }
        }
    }

    private func captureImageReadingUnitCount(_ locator: ReadingLocator) {
        if case let .image(_, total?, _) = locator, total > 0 { sessionReadingUnitCount = total }
    }

    private func didMove(to locator: ReadingLocator) {
        guard hasLoadedProgress else { return }
        captureImageReadingUnitCount(locator)
        if isImagePublication {
            guard imageRestoration.accepts(locator) else { return }
        } else {
            guard !readerController.isRestoringInitialLocation else { return }
            if lastLocalPositionChange == nil, locator == readerController.restoredReadingLocator {
                latestLocator = locator
                return
            }
        }
        guard locator != latestLocator else { return }
        let chapter = installment, changedAt = Date.now
        latestLocator = locator
        lastLocalPositionChange = changedAt
        pendingRemoteProgress = nil
        progressSaveTask?.cancel()
        progressSaveTask = Task {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard !Task.isCancelled else { return }
            model.readerWrites.enqueue {
                await model.recordReadingProgress(work: work, installment: chapter, locator: locator, modifiedAt: changedAt)
            }
        }
    }

    private func flushReadingPosition() {
        progressSaveTask?.cancel()
        guard hasLoadedProgress, pendingRemoteProgress == nil,
              isImagePublication ? !imageRestoration.isRestoring : !readerController.isRestoringInitialLocation,
              let locator = latestLocator, let changedAt = lastLocalPositionChange else { return }
        let chapter = installment
        model.readerWrites.enqueue {
            await model.recordReadingProgress(work: work, installment: chapter, locator: locator, modifiedAt: changedAt)
            Task(priority: .utility) { await model.cloudSyncEngine?.sendPendingChanges() }
        }
    }

    private func checkRemoteProgress() async {
        guard work.sourceID == .local, hasLoadedProgress, !model.settingsSyncModel.incognitoMode,
              let database = model.database,
              let remote = try? await database.progress(workID: work.id, installmentID: installment.id),
              ReadingHandoffPolicy.shouldOffer(remote, currentDeviceID: model.deviceID,
                baseline: savedProgress?.modifiedAt, lastLocalChange: lastLocalPositionChange,
                lastOffered: lastOfferedRemoteDate), remote.locator != latestLocator
        else { return }
        progressSaveTask?.cancel()
        pendingRemoteProgress = remote
        lastOfferedRemoteDate = remote.modifiedAt
        setControlsVisible(true)
    }

    private func acceptRemoteProgress(_ remote: ReadingProgress) {
        progressSaveTask?.cancel()
        pendingRemoteProgress = nil
        savedProgress = remote
        latestLocator = remote.resumeLocator
        lastLocalPositionChange = nil
        if isImagePublication {
            imageRestoration.begin()
            if let imageSession { imageSession.navigate(to: remote.locator) }
            else { imageReaderNavigationID = UUID() }
            imageRestoration.complete(at: remote.locator)
        } else {
            if let locator = remote.resumeLocator {
                readerController.restoreReadingPosition(locator)
            } else {
                readerController.navigate(toPosition: 0)
            }
        }
    }

    private func beginAnnotation() {
        let anchor: ReaderAnnotationAnchor?
        switch installment.format {
        case .epub, .pdf:
            anchor = readerController.annotationAnchor(fallback: latestLocator)
        case .cbz, .remoteImageSequence:
            anchor = latestLocator.map {
                ReaderAnnotationAnchor(locator: $0, selectedText: nil, kind: .currentPosition)
            }
        }
        guard let anchor else { return }
        annotationEditorDraft = .new(anchor: anchor)
    }

    private func navigate(to locator: ReadingLocator) {
        switch locator {
        case .publication:
            readerController.navigate(to: locator)
        case .image:
            if let imageSession { imageSession.navigate(to: locator) }
            else {
                latestLocator = locator
                lastLocalPositionChange = .now
                imageReaderNavigationID = UUID()
            }
        }
    }

    private var canPresentFoldedCover: Bool {
        readerContentAvailability == .ready
            && (isImagePublication ? !imageRestoration.isRestoring : readerController.restoredReadingLocator != nil)
            && !switchingChapter && chapterFailure == nil && pendingRemoteProgress == nil
            && !showsChapters && !showsOutline && !showsPublicationSearch && !showsReaderMarks
            && !showsImageReaderSettings && annotationEditorDraft == nil && !isRelinkingPublication
            && readerAlert == nil
    }

    private var countsActiveReadingTime: Bool {
        foldedCover.countsReadingTime(sceneIsActive: scenePhase == .active,
                                     sessionStarted: hasStartedSession, speech: readerController.ttsState)
    }

    private func updateActiveReadingTime(for phase: ScenePhase) {
        let now = Date.now
        if foldedCover.countsReadingTime(sceneIsActive: phase == .active,
                                        sessionStarted: hasStartedSession, speech: readerController.ttsState) {
            activeSince = activeSince ?? now
        } else if let activeSince {
            activeSeconds += max(0, now.timeIntervalSince(activeSince))
            self.activeSince = nil
        }
    }

    private func activeReadingSeconds(at date: Date) -> TimeInterval {
        activeSeconds + (activeSince.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

}

private struct ReaderPublicationRecoveryView: View {
    let presentation: ReaderPublicationRecoveryPresentation
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(presentation.title)
                .font(.title2.bold())

            if let message = presentation.message {
                Text(message)
                    .foregroundStyle(.secondary)
            }

            if isWorking {
                ProgressView().controlSize(.small)
                    .tint(.white)
                    .accessibilityLabel("Downloading publication")
            } else {
                Button(presentation.actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.actionFill)
                    .foregroundStyle(AppColors.onAction)
                    .accessibilityIdentifier("reader-publication-recovery-action")
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .padding(AppLayout.pageMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum ReaderChapterPreparationError: LocalizedError {
    case unavailable
    var errorDescription: String? { "The chapter could not be prepared. Check the source or download it, then retry." }
}
