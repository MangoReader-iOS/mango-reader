import MangoReaderReaders
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ReaderSetupView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Bindable var setup: ReaderSetupCoordinator
    @State var gestureHints = ReaderSetupGestureHints()
    @State private var bookReady = false
    @State private var comicReady = false
    @State private var hasBookPreview = false
    @State private var hasComicPreview = false
    @State private var sheet: Sheet?
    @State private var isImporting = false
    @State private var comicNavigation = ImageReaderController()
    @State private var bookNavigation = ReadiumReaderController()
    // Defaults to system accessibility; injectable for previews and window rendering checks.
    var gestureAccessibility: (reduceMotion: Bool, voiceOver: Bool)?
    var importProgress = PublicationImportProgress()
    var importResult: (Result<[URL], Error>) -> Void = { _ in }
    var completed: () -> Void = {}
    var bookSampleURL: URL? = Bundle.main.url(forResource: "ReaderSetupSample", withExtension: "epub")
    var comicSampleURL: URL? = Bundle.main.url(forResource: "ReaderSetupComic", withExtension: "cbz")

    enum Sheet: String, Identifiable {
        case typography, gestures, sampleInfo
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .typography: "More Options"
            case .gestures: "Gestures"
            case .sampleInfo: "About this sample"
            }
        }
    }
    private var step: ReaderSetupStep { setup.draft.step.canonical }
    private var isPreview: Bool { step.isEPUB || step.isImageSetup }

    private var gestureMode: ReaderSetupGestureMode {
        step.isImageSetup ? .comic(setup.draft.imageMode) : .book(scroll: setup.draft.epubScroll)
    }
    private var gestureReduceMotion: Bool { gestureAccessibility?.reduceMotion ?? reduceMotion }
    private var gestureVoiceOver: Bool { gestureAccessibility?.voiceOver ?? voiceOverEnabled }
    private var sampleReady: Bool {
        step.isImageSetup ? comicReady : bookReady && bookNavigation.restoredReadingLocator != nil
    }
    private var hintRequest: ReaderSetupGestureHints.Request {
        .init(mode: isPreview && setup.isActive && sampleReady && sheet == nil && !gestureVoiceOver ? gestureMode : nil,
              replay: gestureHints.replayID, reduceMotion: gestureReduceMotion)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if step != .welcome { pageHeading }
                ZStack {
                    // Stable reader identities preserve position across controls and Back.
                    if hasBookPreview || hasComicPreview {
                        previewWorkspace
                            .opacity(isPreview ? 1 : 0)
                            .allowsHitTesting(isPreview)
                            .accessibilityHidden(!isPreview)
                    }
                    if !isPreview {
                        switch step {
                        case .welcome: welcomeContent
                        case .content: contentSelection
                        default: importContent
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .appNativeNavigationChrome()
            .toolbar {
                if setup.canGoBack {
                    ToolbarItem(placement: .topBarLeading) {
                        FixedNavigationChrome {
                            Button("Back", systemImage: "chevron.backward") { setup.back() }
                                .labelStyle(.iconOnly)
                                .accessibilityIdentifier("reader-setup-back")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    FixedNavigationChrome {
                        Button(setup.isReopened ? "Cancel" : step == .welcome ? "Skip Setup" : "Finish Setup") {
                            finish(discard: setup.isReopened || step == .welcome)
                        }
                        .accessibilityIdentifier("reader-setup-defaults")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .sheet(item: $sheet) { presentedSheet in
                NavigationStack {
                    Group {
                        switch presentedSheet {
                        case .typography: typographyPreferences
                        case .gestures: gestureHelp
                        case .sampleInfo: sampleInfo
                        }
                    }
                        .navigationTitle(presentedSheet.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .appNativeNavigationChrome()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                FixedNavigationChrome {
                                    Button("Done") { sheet = nil }
                                        .accessibilityIdentifier("reader-setup-appearance-done")
                                }
                            }
                        }
                }
                .presentationDetents(textSize.isAccessibilitySize ? [.large] : [.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: Self.importTypes,
                          allowsMultipleSelection: true, onCompletion: importResult)
        }
        .tint(AppColors.action)
        .task(id: hintRequest) { await gestureHints.present(hintRequest) }
        .onDisappear { gestureHints.cancel() }
        .onAppear { preparePreview() }
        .onChange(of: step) { _, _ in preparePreview() }
        .onChange(of: setup.isActive) { _, active in if !active { sheet = nil } }
    }

    private func preparePreview() {
        if step.isEPUB { hasBookPreview = true }
        if step.isImageSetup { hasComicPreview = true }
        sheet = nil
    }

    private static var importTypes: [UTType] {
        [UTType(filenameExtension: "epub") ?? .data, .pdf,
         UTType(filenameExtension: "cbz") ?? .zip, .zip]
    }

    private var pageHeading: some View {
        VStack(spacing: 6) {
            Text(step == .content ? "Choose what you read" : step == .imports ? "Add your first book" :
                step.isImageSetup ? "Set up your comic reader" : "Set up your book reader")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("reader-setup-title")
            Text(step == .content ? "Select the formats you enjoy." : step == .imports ?
                "Import a file, or open your library and add one later." : step.isImageSetup ?
                "Choose how pages move, then try the sample." : "Choose a reading mode, text size, and theme.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var welcomeContent: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    Image("ReaderSetupIcon")
                        .resizable().scaledToFit()
                        .frame(width: 88, height: 88)
                        .clipShape(.rect(cornerRadius: 20))
                        .accessibilityHidden(true)
                    Text("Welcome to Mango Reader")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("reader-setup-title")
                    Text("Your books and comics, your way.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("reader-setup-description")
                }
                .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 24) {
                    feature("Read your way", detail: "Manga, comics, webtoons, EPUB books, and PDFs. A reader that feels right for each one.", symbol: "book.pages")
                    feature("Keep your place", detail: "Organize your library and pick up where you left off.", symbol: "books.vertical")
                    feature("Bring your favorites", detail: "Import your files or connect sources to build your own collection.", symbol: "square.and.arrow.down")
                }
                Text("Mango Reader is a reader. You bring the books.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 460)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private func feature(_ title: LocalizedStringKey, detail: LocalizedStringKey, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 27, weight: .regular))
                .foregroundStyle(AppColors.action)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var contentSelection: some View {
        Form {
            Section {
                ForEach(ReaderSetupContent.allCases) { content in
                    let selected = setup.draft.content.contains(content)
                    Button {
                        if selected { setup.draft.content.remove(content) }
                        else { setup.draft.content.insert(content) }
                    } label: {
                        HStack {
                            Label { Text(LocalizedStringKey(content.title)) } icon: {
                                Image(systemName: content.symbol).foregroundStyle(AppColors.action)
                            }
                            .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? AppColors.action : Color.secondary)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 38)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityValue(selected ? "Selected" : "Not selected")
                    .accessibilityIdentifier("reader-setup-content-" + content.rawValue)
                }
            } footer: {
                Text("Choose any that you enjoy. This only tailors setup — you can always read every supported format. You can also continue with the defaults.")
            }
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
    }

    private var previewWorkspace: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 720 && !textSize.isAccessibilitySize
            let layout = wide ? AnyLayout(HStackLayout(spacing: 24)) : AnyLayout(VStackLayout(spacing: 12))
            layout {
                VStack(spacing: 0) {
                    ZStack {
                        if hasBookPreview {
                            bookPreview
                                .opacity(step.isEPUB ? 1 : 0)
                                .allowsHitTesting(step.isEPUB)
                                .accessibilityHidden(!step.isEPUB)
                        }
                        if hasComicPreview {
                            comicPreview
                                .opacity(step.isImageSetup ? 1 : 0)
                                .allowsHitTesting(step.isImageSetup)
                                .accessibilityHidden(!step.isImageSetup)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(.rect(cornerRadius: 16))
                    .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.08)) }
                    .overlay(alignment: .bottom) {
                        ReaderSetupGestureCue(hints: gestureHints, reduceMotion: gestureReduceMotion)
                            .padding(12)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .overlay(alignment: .topTrailing) {
                        if step.isImageSetup, comicSampleURL != nil {
                            Button("About this sample", systemImage: "info.circle") { sheet = .sampleInfo }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .font(.body)
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                                .modifier(ReaderGlassCircleStyle())
                                .accessibilityIdentifier("reader-setup-comic-info")
                                .padding(8)
                        }
                    }
                    Button("Gestures", systemImage: "hand.draw") {
                        if gestureVoiceOver { sheet = .gestures }
                        else { gestureHints.replay(gestureMode) }
                    }
                    .font(.subheadline)
                    .frame(minHeight: 44)
                    .disabled(!sampleReady)
                    .accessibilityHint("Show instructions for the current reading mode")
                    .accessibilityIdentifier("reader-setup-gestures")
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if step.isImageSetup { comicPreferences }
                        else { bookPreferences }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 12)
                }
                .frame(width: wide ? 300 : nil,
                       height: wide ? nil : min(geometry.size.height * (textSize.isAccessibilitySize ? 0.56 : 0.48), textSize.isAccessibilitySize ? 360 : step.isImageSetup ? 160 : 235))
            }
        }
        .frame(maxWidth: 1100)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }

    private var comicPreferences: some View {
        Group {
            Picker("Page movement", selection: Binding(get: { setup.draft.verticalImages }, set: {
                setup.chooseImageAxis(vertical: $0)
            })) {
                Text("Side to side").tag(false)
                Text("Up and down").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("reader-setup-image-axis")
            capsuleMenu(setup.draft.verticalImages ? "Scrolling" : "Reading direction",
                        value: imageModeTitle, identifier: "reader-setup-image-detail") {
                Picker(setup.draft.verticalImages ? "Scrolling" : "Reading direction", selection: Binding(
                    get: { setup.draft.imageMode }, set: { setup.chooseImageMode($0) }
                )) {
                    if setup.draft.verticalImages {
                        Text("Continuous").tag(setup.draft.imageMode == "continuous" ? "continuous" : "webtoon")
                        Text("One page at a time").tag("verticalPaged")
                    } else {
                        Text("Left to right").tag("ltr")
                        Text("Right to left").tag("rtl")
                    }
                }
                .pickerStyle(.inline)
            }
            Text("This is your default. You can change it for individual titles anytime.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var bookPreferences: some View {
        Group {
            Picker("Reading mode", selection: preference(\.epubScroll, key: "epubScroll")) {
                Text("Scroll").tag(true)
                Text("Pages").tag(false)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("reader-setup-epub-mode")
            VStack(spacing: 2) {
                LabeledContent("Text size", value: setup.draft.fontScale.formatted(.percent.precision(.fractionLength(0))))
                    .font(.subheadline)
                Slider(value: preference(\.fontScale, key: "readerFontScale"), in: 0.5...3, step: 0.1)
                    .accessibilityLabel("Text size")
                    .accessibilityValue(setup.draft.fontScale.formatted(.percent.precision(.fractionLength(0))))
                    .accessibilityIdentifier("reader-setup-text-size")
            }
            capsuleMenu("Theme", value: themeTitle, identifier: "reader-setup-theme") {
                Picker("Theme", selection: preference(\.theme, key: "publicationTheme")) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Paper").tag("sepia")
                    Text("Black").tag("black")
                }
                .pickerStyle(.inline)
            }
            Button("More Options", systemImage: "textformat") { sheet = .typography }
                .frame(minHeight: 44)
                .accessibilityIdentifier("reader-setup-appearance")
        }
    }

    private var imageModeTitle: LocalizedStringKey {
        switch setup.draft.imageMode {
        case "rtl": "Right to left"
        case "verticalPaged": "One page at a time"
        case "continuous", "webtoon": "Continuous"
        default: "Left to right"
        }
    }

    private var themeTitle: LocalizedStringKey {
        switch setup.draft.theme {
        case "light": "Light"
        case "sepia": "Paper"
        case "black": "Black"
        default: "System"
        }
    }

    private func capsuleMenu<Options: View>(
        _ title: LocalizedStringKey, value: LocalizedStringKey, identifier: String,
        @ViewBuilder options: () -> Options
    ) -> some View {
        let menu = Menu(content: options) {
            HStack(spacing: 8) {
                Text(value).multilineTextAlignment(.leading)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .contentShape(Capsule())
            .modifier(ReaderSetupMenuCapsule())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .controlSize(.regular)
        .tint(AppColors.action)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value))
        .accessibilityIdentifier(identifier)

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(title).fixedSize().accessibilityHidden(true)
                Spacer(minLength: 0)
                menu.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).accessibilityHidden(true)
                menu.fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var gestureHelp: some View {
        List {
            Label(LocalizedStringKey(gestureMode.instruction), systemImage: gestureMode.arrow)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(LocalizedStringKey(gestureMode.instruction)))
                .accessibilityIdentifier("reader-setup-gesture-swipe")
            if gestureMode.isComic {
                Label("Double-tap to zoom.", systemImage: "hand.tap")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Double-tap to zoom.")
                    .accessibilityIdentifier("reader-setup-gesture-zoom")
            }
        }
        .listStyle(.plain)
    }

    private var sampleInfo: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: "Give My Regards to Black Jack\nSHUHO SATO")
                    .font(.headline)
                    .accessibilityIdentifier("reader-setup-comic-credit")
                Text("This sample is used under the creator’s free secondary-use terms.")
                    .foregroundStyle(.secondary)
                Link("View source and usage terms", destination: URL(string: "https://densho810.com/free/")!)
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("reader-setup-comic-source")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private var typographyPreferences: some View {
        Form {
            Section {
                Picker("Font", selection: Binding(get: { setup.draft.fontPreset }, set: {
                    setup.draft.fontPreset = $0
                    setup.draft.fontFamily = nil
                    setup.draft.changedKeys.insert("readerFontPreset")
                })) {
                    ForEach(PublicationFontPreset.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .accessibilityIdentifier("reader-setup-font")
                VStack(alignment: .leading) {
                    LabeledContent("Line spacing", value: setup.draft.lineHeight.formatted(.number.precision(.fractionLength(1))) + "×")
                    Slider(value: Binding(get: { setup.draft.lineHeight }, set: {
                        setup.draft.lineHeight = $0
                        setup.draft.publisherStyles = false
                        setup.draft.changedKeys.formUnion(["readerLineHeight", "publisherStyles"])
                    }), in: 1...2, step: 0.1)
                    .accessibilityLabel("Line spacing")
                    .accessibilityIdentifier("reader-setup-line-spacing")
                }
                VStack(alignment: .leading) {
                    Text("Page margins")
                    Slider(value: preference(\.margins, key: "readerPageMargins"), in: 0...4, step: 0.25)
                        .accessibilityLabel("Page margins")
                        .accessibilityIdentifier("reader-setup-margins")
                }
            } footer: {
                Text("Changes appear in the sample. Close this sheet to keep trying the reader.")
            }
        }
    }

    private var importContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(AppColors.action)
                    .accessibilityHidden(true)
                Text("Bring a favorite along")
                    .font(.title3.bold())
                Text("Choose EPUB, PDF, CBZ, or ZIP files from Files. You can also connect sources later in Browse.")
                    .foregroundStyle(.secondary)
                Button("Import Files", systemImage: "square.and.arrow.down") { isImporting = true }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(importProgress.isRunning)
                    .accessibilityIdentifier("reader-setup-import")
                if importProgress.total > 0 { importStatus }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            ReaderSetupPageControl(numberOfPages: setup.route.count, currentPage: setup.stepIndex,
                                   selectPage: { setup.selectPage(at: $0) })
                .frame(height: 44)
            Button {
                if setup.advance() { finish() }
            } label: {
                Text(step == .welcome ? "Get Started" : step == .imports ? "Open Library" : setup.isLastStep ? "Save Preferences" : "Continue")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .accessibilityIdentifier("reader-setup-continue")
        }
        .frame(maxWidth: 460)
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
    }

    private func preference<Value>(_ path: WritableKeyPath<ReaderSetupDraft, Value>, key: String) -> Binding<Value> {
        Binding(get: { setup.draft[keyPath: path] }, set: {
            setup.draft[keyPath: path] = $0
            setup.draft.changedKeys.insert(key)
        })
    }

    @ViewBuilder private var bookPreview: some View {
        if let url = bookSampleURL {
            ReadiumPublicationReaderView(sourceURL: url, format: .epub,
                textPreferences: setup.draft.previewPreferences(darkAppearance: colorScheme == .dark), expandedReading: "fullWidth",
                // The existing controller becomes ready after the first readable location,
                // later than publication opening, without recording library progress.
                controller: bookNavigation,
                onPhaseChange: { bookReady = $0 == .ready })
                .accessibilityIdentifier("reader-setup-epub-preview")
        } else { sampleUnavailable }
    }

    @ViewBuilder private var comicPreview: some View {
        if let url = comicSampleURL {
            LocalCBZReaderView(sourceURL: url, settings: setup.draft.previewImageSettings,
                maximumCachedPages: 3, navigation: comicNavigation,
                onPhaseChange: { comicReady = $0 == .ready })
                .accessibilityIdentifier("reader-setup-comic-preview")
                .accessibilityAction(named: Text("Next page")) { comicNavigation.moveForward() }
                .accessibilityAction(named: Text("Previous page")) { comicNavigation.moveBackward() }
        } else { sampleUnavailable }
    }

    private var sampleUnavailable: some View {
        ContentUnavailableView("Sample unavailable", systemImage: "book",
            description: Text("You can still choose your preferences and continue."))
            .accessibilityIdentifier("reader-setup-sample-unavailable")
    }

    private func finish(discard: Bool = false) {
        sheet = nil
        setup.finish(useDefaults: discard)
        completed()
    }

    private var importStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if importProgress.isRunning {
                ProgressView(value: Double(importProgress.processed), total: Double(importProgress.total))
            }
            Text(importProgress.message).font(.footnote)
            if !importProgress.failures.isEmpty {
                DisclosureGroup("Import details") {
                    ForEach(Array(importProgress.failures.enumerated()), id: \.offset) { entry in
                        Text(entry.element).font(.footnote)
                    }
                }
            }
        }
        .accessibilityIdentifier("reader-setup-import-status")
    }
}

// Onboarding-only state: no reader preferences or library records are involved.
enum ReaderSetupGestureMode: CaseIterable {
    case comicRight, comicLeft, comicUp, comicScroll, bookPages, bookScroll

    static func comic(_ mode: String) -> Self {
        switch mode {
        case "rtl": .comicRight
        case "verticalPaged": .comicUp
        case "webtoon", "continuous": .comicScroll
        default: .comicLeft
        }
    }

    static func book(scroll: Bool) -> Self { scroll ? .bookScroll : .bookPages }
    var isComic: Bool { self != .bookPages && self != .bookScroll }
    var instruction: String {
        switch self {
        case .comicRight: "Swipe right for the next page"
        case .comicLeft, .bookPages: "Swipe left for the next page"
        case .comicUp: "Swipe up for the next page"
        case .comicScroll, .bookScroll: "Swipe up to keep reading"
        }
    }
    var arrow: String {
        switch self {
        case .comicRight: "arrow.right"
        case .comicLeft, .bookPages: "arrow.left"
        default: "arrow.up"
        }
    }
    func offset(advanced: Bool) -> CGSize {
        let distance: CGFloat = advanced ? 12 : -12
        switch self {
        case .comicRight: return CGSize(width: distance, height: 0)
        case .comicLeft, .bookPages: return CGSize(width: -distance, height: 0)
        default: return CGSize(width: 0, height: -distance)
        }
    }
}

@MainActor @Observable
final class ReaderSetupGestureHints {
    struct Request: Equatable {
        var mode: ReaderSetupGestureMode?
        var replay = 0
        var reduceMotion = false
    }
    private(set) var mode: ReaderSetupGestureMode?
    private(set) var phase = 0
    private(set) var replayID = 0
    private(set) var seen: Set<ReaderSetupGestureMode> = []
    private var generation = UUID()
    private let wait: @MainActor (Duration) async throws -> Void

    init(wait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.wait = wait
    }

    func replay(_ mode: ReaderSetupGestureMode) {
        seen.remove(mode)
        replayID += 1
    }

    func cancel() {
        generation = UUID()
        mode = nil
        phase = 0
    }

    // SwiftUI owns this task. Changing the request cancels its pending waits.
    func present(_ request: Request) async {
        cancel()
        guard let next = request.mode, !seen.contains(next), !Task.isCancelled else { return }
        let run = generation
        seen.insert(next)
        mode = next
        defer { if generation == run { mode = nil; phase = 0 } }
        do {
            if request.reduceMotion {
                try await wait(.seconds(3))
            } else {
                for (index, duration) in [Duration.milliseconds(200), .milliseconds(600),
                                          .milliseconds(200), .milliseconds(600), .milliseconds(1400)].enumerated() {
                    try await wait(duration)
                    try Task.checkCancellation()
                    guard generation == run else { return }
                    phase = index + 1
                }
            }
        } catch { /* Cancellation dismisses the cue without affecting the reader. */ }
    }
}

private struct ReaderSetupPageControl: UIViewRepresentable {
    let numberOfPages: Int
    let currentPage: Int
    let selectPage: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(selectPage: selectPage) }

    func makeUIView(context: Context) -> UIPageControl {
        let control = UIPageControl()
        control.backgroundStyle = .minimal
        control.accessibilityLabel = String(localized: "Setup progress")
        control.accessibilityIdentifier = "reader-setup-progress"
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UIPageControl, context: Context) {
        context.coordinator.selectPage = selectPage
        control.numberOfPages = numberOfPages
        control.currentPage = currentPage
        control.currentPageIndicatorTintColor = UIColor(AppColors.action)
        control.pageIndicatorTintColor = .tertiaryLabel
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIPageControl, context: Context) -> CGSize? {
        CGSize(width: min(uiView.intrinsicContentSize.width, proposal.width ?? .greatestFiniteMagnitude), height: 44)
    }

    @MainActor final class Coordinator: NSObject {
        var selectPage: (Int) -> Void
        init(selectPage: @escaping (Int) -> Void) { self.selectPage = selectPage }
        @objc func changed(_ control: UIPageControl) { selectPage(control.currentPage) }
    }
}

private struct ReaderSetupMenuCapsule: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
#if !targetEnvironment(macCatalyst)
        if reduceTransparency {
            content.background(AppColors.background, in: Capsule())
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
#else
        content.background(
            reduceTransparency ? AnyShapeStyle(AppColors.background) : AnyShapeStyle(Material.regular),
            in: Capsule()
        )
#endif
    }
}

private struct ReaderSetupGestureCue: View {
    let hints: ReaderSetupGestureHints
    let reduceMotion: Bool

    var body: some View {
        Group {
            if let mode = hints.mode {
                HStack(spacing: 14) {
                    VStack(spacing: 5) {
                        Image(systemName: "hand.draw.fill")
                            .font(.title2)
                            .offset(reduceMotion ? .zero : mode.offset(advanced: hints.phase == 1 || hints.phase >= 3))
                            .animation(hints.phase == 1 || hints.phase == 3 ? .easeInOut(duration: 0.6) : nil, value: hints.phase)
                        Image(systemName: mode.arrow).font(.caption.bold())
                    }
                    .foregroundStyle(AppColors.action)
                    .frame(width: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey(mode.instruction)).font(.subheadline.weight(.medium))
                        if mode.isComic { Text("Double-tap to zoom.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .padding(14)
                .background(Color(.systemBackground).opacity(0.96), in: .rect(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.1)) }
                .frame(maxWidth: 360)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: hints.mode)
    }
}
