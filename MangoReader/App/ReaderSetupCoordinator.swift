import Foundation
import MangoReaderData
import MangoReaderDomain
import MangoReaderReaders
import Observation

// Local setup state deliberately stays outside synchronized reader preferences.
enum ReaderSetupContent: String, Codable, CaseIterable, Identifiable {
    case manga, comics, webtoons, epub, pdf
    var id: String { rawValue }
    var title: String {
        switch self {
        case .manga: "Manga"
        case .comics: "Comics"
        case .webtoons: "Webtoons"
        case .epub: "EPUB books"
        case .pdf: "PDFs"
        }
    }
    var symbol: String {
        switch self {
        case .manga: "book.closed"
        case .comics: "square.grid.2x2"
        case .webtoons: "rectangle.portrait"
        case .epub: "book"
        case .pdf: "doc.richtext"
        }
    }
    var isImage: Bool { self == .manga || self == .comics || self == .webtoons }
}

enum ReaderSetupStep: String, Codable {
    case welcome, imports, content, imageAxis, imageDetail, epubMode
    case textSize, font, lineSpacing, margins, theme
    var isEPUB: Bool { self == .epubMode || isTypography }
    var isImageSetup: Bool { self == .imageAxis || self == .imageDetail }
    var isTypography: Bool { [.textSize, .font, .lineSpacing, .margins, .theme].contains(self) }
    var canonical: Self {
        if isEPUB { return .epubMode }
        if isImageSetup { return .imageAxis }
        return self
    }
    var title: String {
        switch self {
        case .welcome: "Welcome to Mango Reader"
        case .imports: "Import your books"
        case .content: "What do you usually read?"
        case .imageAxis: "How do you move through pages?"
        case .imageDetail: "Make it feel familiar"
        case .epubMode: "How do you read books?"
        case .textSize: "Text size"
        case .font: "Font"
        case .lineSpacing: "Line spacing"
        case .margins: "Margins"
        case .theme: "Theme"
        }
    }
}

struct ReaderSetupDraft: Codable, Equatable {
    // Optional so synthesized decoding also accepts drafts saved before this flow.
    var flowVersion: Int? = 3
    var isTryingSample: Bool?
    var step: ReaderSetupStep = .welcome
    var content: Set<ReaderSetupContent> = []
    var imageMode: String
    var imageModeWasChosen = false
    var epubScroll: Bool
    var fontScale: Double
    var fontPreset: String
    var fontFamily: String?
    var lineHeight: Double
    var publisherStyles: Bool
    var margins: Double
    var theme: String
    var changedKeys: Set<String> = []
    var originalText: TextReaderPreferences
    var startingLineHeight: Double
    var startingPublisherStyles: Bool

    init(defaults: UserDefaults) {
        let options = ReaderAdditionalPreferences.read(from: defaults)
        imageMode = options.imageMode
        epubScroll = defaults.object(forKey: "epubScroll") as? Bool ?? true
        fontScale = defaults.object(forKey: "readerFontScale") as? Double ?? 1
        fontPreset = defaults.string(forKey: "readerFontPreset") ?? "publisher"
        fontFamily = options.fontFamily
        lineHeight = defaults.object(forKey: "readerLineHeight") as? Double ?? 1.4
        publisherStyles = defaults.object(forKey: "publisherStyles") as? Bool ?? true
        margins = defaults.object(forKey: "readerPageMargins") as? Double ?? 1
        theme = (PublicationTheme(rawValue: defaults.string(forKey: "publicationTheme") ?? "system") ?? .system).rawValue
        originalText = TextReaderPreferences(
            fontWeight: defaults.object(forKey: "readerFontWeight") as? Double ?? 1,
            paragraphSpacing: defaults.object(forKey: "readerParagraphSpacing") as? Double ?? 0.5,
            paragraphIndent: defaults.object(forKey: "readerParagraphIndent") as? Double ?? 0,
            wordSpacing: defaults.object(forKey: "readerWordSpacing") as? Double ?? 0,
            letterSpacing: defaults.object(forKey: "readerLetterSpacing") as? Double ?? 0,
            hyphenationEnabled: defaults.object(forKey: "readerHyphenation") as? Bool ?? true,
            textNormalizationEnabled: defaults.bool(forKey: "readerTextNormalization"),
            textAlignment: PublicationTextAlignment(rawValue: defaults.string(forKey: "readerTextAlignment") ?? "publisher") ?? .publisher,
            columnCount: PublicationColumnCount(rawValue: defaults.string(forKey: "readerColumnCount") ?? "automatic") ?? .automatic,
            verticalWritingEnabled: defaults.bool(forKey: "verticalWriting")
        )
        startingLineHeight = lineHeight
        startingPublisherStyles = publisherStyles
    }
    var hasImages: Bool { content.contains(where: \.isImage) }
    var verticalImages: Bool { ["webtoon", "verticalPaged", "continuous"].contains(imageMode) }
    var previewImageSettings: ImageReaderSettings {
        var options = ReaderAdditionalPreferences()
        options.imageMode = imageMode
        options.background = "system"
        let layout: ImageReaderLayout = switch imageMode {
        case "webtoon": .webtoon
        case "continuous": .vertical
        case "verticalPaged": .verticalPaged
        default: .paged
        }
        return ImageReaderSettings(options: options,
            direction: imageMode == "rtl" ? .rightToLeft : .leftToRight,
            layout: layout, spread: .single)
    }
    func previewPreferences(darkAppearance: Bool) -> TextReaderPreferences {
        TextReaderPreferences(
            readingMode: epubScroll ? .scroll : .paged,
            theme: (PublicationTheme(rawValue: theme) ?? .system).resolved(forDarkAppearance: darkAppearance),
            font: fontFamily.map { .named($0) } ?? (PublicationFontPreset(rawValue: fontPreset) ?? .publisher).selection,
            fontScale: fontScale, fontWeight: originalText.fontWeight, lineHeight: lineHeight,
            paragraphSpacing: originalText.paragraphSpacing, paragraphIndent: originalText.paragraphIndent,
            horizontalMargin: margins, verticalMargin: margins,
            wordSpacing: originalText.wordSpacing, letterSpacing: originalText.letterSpacing,
            usesPublisherStyles: publisherStyles,
            hyphenationEnabled: originalText.hyphenationEnabled,
            textNormalizationEnabled: originalText.textNormalizationEnabled,
            textAlignment: originalText.textAlignment, columnCount: originalText.columnCount,
            verticalWritingEnabled: originalText.verticalWritingEnabled && !epubScroll
        )
    }
}

@MainActor
@Observable
final class ReaderSetupCoordinator {
    static let draftKey = "readerSetupDraft.v1"
    static let completedKey = "readerSetupCompleted.v1"
    private static var standardInstance: ReaderSetupCoordinator?
    let defaults: UserDefaults
    private(set) var isActive = false
    var owner: UUID?
    var draft: ReaderSetupDraft { didSet { saveDraft() } }

    static func shared(defaults: UserDefaults, existingInstallation: Bool, bypass: Bool) -> ReaderSetupCoordinator {
        if defaults === UserDefaults.standard, let standardInstance { return standardInstance }
        let instance = ReaderSetupCoordinator(defaults: defaults, existingInstallation: existingInstallation, bypass: bypass)
        if defaults === UserDefaults.standard { standardInstance = instance }
        return instance
    }

    init(defaults: UserDefaults, existingInstallation: Bool, bypass: Bool = false) {
        self.defaults = defaults
        draft = ReaderSetupDraft(defaults: defaults)
        if bypass { return }
        if let data = defaults.data(forKey: Self.draftKey),
           let restored = try? JSONDecoder().decode(ReaderSetupDraft.self, from: data) {
            draft = restored
            isActive = true
            // Legacy fine-grained steps now share one live preview per reader.
            if draft.step.isEPUB { draft.content.insert(.epub) }
            if draft.step.isImageSetup, !draft.hasImages { draft.content.insert(.comics) }
            draft.step = draft.step.canonical
            draft.isTryingSample = nil
            draft.flowVersion = 3
        } else if !defaults.bool(forKey: Self.completedKey) {
            if existingInstallation {
                defaults.set(true, forKey: Self.completedKey)
            } else {
                isActive = true
                saveDraft()
            }
        }
    }

    func claim(_ scene: UUID) { if isActive && owner == nil { owner = scene } }
    func release(_ scene: UUID) { if owner == scene { owner = nil } }
    func reopen(owner: UUID? = nil) {
        guard !isActive else { return }
        draft = ReaderSetupDraft(defaults: defaults)
        // Existing habits are the starting point when setup is reopened.
        switch draft.imageMode {
        case "webtoon", "continuous": draft.content.insert(.webtoons)
        case "rtl": draft.content.insert(.manga)
        case "ltr", "verticalPaged": draft.content.insert(.comics)
        default: break
        }
        draft.content.insert(.epub)
        draft.imageModeWasChosen = true
        draft.step = .content
        self.owner = owner
        isActive = true
        saveDraft()
    }

    func importAccepted(_ urls: [URL]) {
        guard isActive, [.welcome, .content].contains(draft.step) else { return }
        for url in urls {
            switch url.pathExtension.lowercased() {
            case "epub": draft.content.insert(.epub)
            case "pdf": draft.content.insert(.pdf)
            case "cbz", "zip": draft.content.insert(.comics)
            default: break
            }
        }
    }

    var isReopened: Bool { defaults.bool(forKey: Self.completedKey) }
    var showsImageDetails: Bool { draft.step.isImageSetup || draft.imageModeWasChosen }

    func chooseImageAxis(vertical: Bool) {
        if draft.verticalImages != vertical {
            draft.imageMode = vertical ? "webtoon" : (draft.content.contains(.manga) ? "rtl" : "ltr")
        }
        draft.imageModeWasChosen = true
        draft.changedKeys.insert("imageMode")
    }

    /// The visible route is also the source of truth for navigation and progress.
    var route: [ReaderSetupStep] {
        var steps: [ReaderSetupStep] = isReopened ? [.content] : [.welcome, .content]
        if draft.hasImages { steps.append(.imageAxis) }
        if draft.content.contains(.epub) { steps.append(.epubMode) }
        if !isReopened { steps.append(.imports) }
        return steps
    }
    var stepIndex: Int { route.firstIndex(of: draft.step.canonical) ?? 0 }
    var canGoBack: Bool { stepIndex > 0 }
    var isLastStep: Bool { stepIndex == route.count - 1 }

    func chooseImageMode(_ mode: String) {
        draft.imageMode = mode
        draft.imageModeWasChosen = true
        draft.changedKeys.insert("imageMode")
    }

    // Returns true when the caller should finish and commit the draft.
    func advance() -> Bool {
        if draft.step == .content, draft.hasImages, !draft.imageModeWasChosen || draft.imageMode == "auto" {
            draft.imageMode = draft.content.contains(.manga) ? "rtl" :
                (draft.content.contains(.webtoons) && !draft.content.contains(.comics) ? "webtoon" : "ltr")
        }
        if draft.step.isImageSetup {
            draft.imageModeWasChosen = true
            draft.changedKeys.insert("imageMode")
        }
        guard !isLastStep else { return true }
        draft.step = route[stepIndex + 1]
        return false
    }

    func back() {
        guard canGoBack else { return }
        draft.step = route[stepIndex - 1]
    }

    func selectPage(at index: Int) {
        guard isActive, route.indices.contains(index) else { return }
        while stepIndex < index {
            if advance() { break }
        }
        while stepIndex > index { back() }
    }

    func finish(useDefaults: Bool = false) {
        if !useDefaults {
            if draft.step.isImageSetup { draft.changedKeys.insert("imageMode") }
            let keys = draft.changedKeys
            if draft.hasImages, keys.contains("imageMode") {
                var options = ReaderAdditionalPreferences.read(from: defaults)
                options.imageMode = draft.imageMode
                options.tapPreset = "automatic"
                options.invertTapZones = false
                defaults.set(options.encoded, forKey: ReaderAdditionalPreferences.storageKey)
                defaults.set("", forKey: "imageReaderTapLeadingAction")
                defaults.set("", forKey: "imageReaderTapTrailingAction")
            }
            if draft.content.contains(.epub) {
                let values: [String: Any] = [
                    "epubScroll": draft.epubScroll, "readerFontScale": draft.fontScale,
                    "readerFontPreset": draft.fontPreset, "readerLineHeight": draft.lineHeight,
                    "publisherStyles": draft.publisherStyles, "readerPageMargins": draft.margins,
                    "publicationTheme": draft.theme
                ]
                for (key, value) in values where keys.contains(key) { defaults.set(value, forKey: key) }
                if keys.contains("epubScroll"), draft.epubScroll { defaults.set(false, forKey: "verticalWriting") }
                if keys.contains("readerFontPreset") {
                    var options = ReaderAdditionalPreferences.read(from: defaults)
                    options.fontFamily = nil
                    defaults.set(options.encoded, forKey: ReaderAdditionalPreferences.storageKey)
                }
            }
        }
        defaults.set(true, forKey: Self.completedKey)
        defaults.removeObject(forKey: Self.draftKey)
        isActive = false
        owner = nil
    }

    private func saveDraft() {
        guard isActive, let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: Self.draftKey)
    }
}

struct PublicationImportProgress: Equatable {
    var total = 0
    var processed = 0
    var imported = 0
    var duplicates = 0
    var failures: [String] = []
    var isRunning: Bool { processed < total }
    var message: String {
        if isRunning { return "Importing books: \(processed) of \(total)" }
        return "\(imported) imported · \(duplicates) duplicates skipped" +
            (failures.isEmpty ? "" : " · \(failures.count) couldn’t be imported")
    }
}
