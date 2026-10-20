import Foundation
import MangoReaderDomain

public enum PublicationReadingMode: String, Codable, CaseIterable, Sendable {
    case paged
    case scroll
}

public enum PublicationTheme: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case sepia
    case black

    public init?(rawValue: String) {
        switch rawValue {
        case Self.system.rawValue: self = .system
        case Self.light.rawValue: self = .light
        case Self.sepia.rawValue: self = .sepia
        case Self.black.rawValue, "dark": self = .black
        default: return nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported publication theme: \(rawValue)"
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public func resolved(forDarkAppearance isDarkAppearance: Bool) -> Self {
        guard self == .system else { return self }
        return isDarkAppearance ? .black : .light
    }
}

public enum PublicationFontSelection: Codable, Hashable, Sendable {
    case publisher
    case system
    case named(String)
}

/// Vetted font choices exposed by Mango Reader's typography controls.
///
/// Readium embeds the three accessibility-oriented faces and resolves the
/// remaining named faces through the iOS font stack. Keeping the UI on this
/// compiled-in list avoids accepting arbitrary font declarations while the
/// lower-level `PublicationFontSelection.named` case remains available for
/// decoding older preferences.
public enum PublicationFontPreset: String, Codable, CaseIterable, Sendable, Identifiable {
    case publisher
    case systemSans
    case systemSerif
    case accessibleDfA
    case iaWriterDuospace
    case openDyslexic
    case iowanOldStyle
    case athelas
    case georgia
    case seravek

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .publisher: "Publisher"
        case .systemSans: "System Sans"
        case .systemSerif: "System Serif"
        case .accessibleDfA: "AccessibleDfA"
        case .iaWriterDuospace: "IA Writer Duospace"
        case .openDyslexic: "OpenDyslexic"
        case .iowanOldStyle: "Iowan Old Style"
        case .athelas: "Athelas"
        case .georgia: "Georgia"
        case .seravek: "Seravek"
        }
    }

    public var selection: PublicationFontSelection {
        switch self {
        case .publisher: .publisher
        case .systemSans: .system
        case .systemSerif: .named("serif")
        case .accessibleDfA: .named("AccessibleDfA")
        case .iaWriterDuospace: .named("IA Writer Duospace")
        case .openDyslexic: .named("OpenDyslexic")
        case .iowanOldStyle: .named("Iowan Old Style")
        case .athelas: .named("Athelas")
        case .georgia: .named("Georgia")
        case .seravek: .named("Seravek")
        }
    }
}

public enum PublicationTextAlignment: String, Codable, CaseIterable, Sendable {
    case publisher
    case leading
    case justified
}

public enum PublicationColumnCount: String, Codable, CaseIterable, Sendable {
    case automatic
    case one
    case two
}

public struct TextReaderPreferences: Codable, Hashable, Sendable {
    public let readingMode: PublicationReadingMode
    public let theme: PublicationTheme
    public let font: PublicationFontSelection
    public let fontScale: Double
    public let fontWeight: Double
    public let lineHeight: Double
    public let paragraphSpacing: Double
    public let paragraphIndent: Double
    public let horizontalMargin: Double
    public let verticalMargin: Double
    public let wordSpacing: Double
    public let letterSpacing: Double
    public let usesPublisherStyles: Bool
    public let hyphenationEnabled: Bool
    public let textNormalizationEnabled: Bool
    public let textAlignment: PublicationTextAlignment
    public let columnCount: PublicationColumnCount
    public let verticalWritingEnabled: Bool

    public init(
        readingMode: PublicationReadingMode = .scroll,
        theme: PublicationTheme = .system,
        font: PublicationFontSelection = .publisher,
        fontScale: Double = 1,
        fontWeight: Double = 1,
        lineHeight: Double = 1.4,
        paragraphSpacing: Double = 0.5,
        paragraphIndent: Double = 0,
        horizontalMargin: Double = 1,
        verticalMargin: Double = 1,
        wordSpacing: Double = 0,
        letterSpacing: Double = 0,
        usesPublisherStyles: Bool = true,
        hyphenationEnabled: Bool = true,
        textNormalizationEnabled: Bool = false,
        textAlignment: PublicationTextAlignment = .publisher,
        columnCount: PublicationColumnCount = .automatic,
        verticalWritingEnabled: Bool = false
    ) {
        self.readingMode = readingMode
        self.theme = theme
        self.font = font
        self.fontScale = Self.clamped(fontScale, to: 0.5 ... 3, fallback: 1)
        self.fontWeight = Self.clamped(fontWeight, to: 0 ... 2.5, fallback: 1)
        self.lineHeight = Self.clamped(lineHeight, to: 1 ... 2, fallback: 1.4)
        self.paragraphSpacing = Self.clamped(paragraphSpacing, to: 0 ... 2, fallback: 0.5)
        self.paragraphIndent = Self.clamped(paragraphIndent, to: 0 ... 3, fallback: 0)
        self.horizontalMargin = Self.clamped(horizontalMargin, to: 0 ... 4, fallback: 1)
        self.verticalMargin = Self.clamped(verticalMargin, to: 0 ... 4, fallback: 1)
        self.wordSpacing = Self.clamped(wordSpacing, to: 0 ... 1, fallback: 0)
        self.letterSpacing = Self.clamped(letterSpacing, to: 0 ... 1, fallback: 0)
        self.usesPublisherStyles = usesPublisherStyles
        self.hyphenationEnabled = hyphenationEnabled
        self.textNormalizationEnabled = textNormalizationEnabled
        self.textAlignment = textAlignment
        self.columnCount = columnCount
        self.verticalWritingEnabled = verticalWritingEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case readingMode
        case theme
        case font
        case fontScale
        case fontWeight
        case lineHeight
        case paragraphSpacing
        case paragraphIndent
        case horizontalMargin
        case verticalMargin
        case wordSpacing
        case letterSpacing
        case usesPublisherStyles
        case hyphenationEnabled
        case textNormalizationEnabled
        case textAlignment
        case columnCount
        case verticalWritingEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            readingMode: try container.decode(PublicationReadingMode.self, forKey: .readingMode),
            theme: try container.decode(PublicationTheme.self, forKey: .theme),
            font: try container.decode(PublicationFontSelection.self, forKey: .font),
            fontScale: try container.decode(Double.self, forKey: .fontScale),
            fontWeight: try container.decode(Double.self, forKey: .fontWeight),
            lineHeight: try container.decode(Double.self, forKey: .lineHeight),
            paragraphSpacing: try container.decode(Double.self, forKey: .paragraphSpacing),
            paragraphIndent: try container.decode(Double.self, forKey: .paragraphIndent),
            horizontalMargin: try container.decode(Double.self, forKey: .horizontalMargin),
            verticalMargin: try container.decode(Double.self, forKey: .verticalMargin),
            wordSpacing: try container.decode(Double.self, forKey: .wordSpacing),
            letterSpacing: try container.decode(Double.self, forKey: .letterSpacing),
            usesPublisherStyles: try container.decode(Bool.self, forKey: .usesPublisherStyles),
            hyphenationEnabled: try container.decode(Bool.self, forKey: .hyphenationEnabled),
            textNormalizationEnabled: try container.decode(Bool.self, forKey: .textNormalizationEnabled),
            textAlignment: try container.decode(PublicationTextAlignment.self, forKey: .textAlignment),
            columnCount: try container.decode(PublicationColumnCount.self, forKey: .columnCount),
            verticalWritingEnabled: try container.decode(Bool.self, forKey: .verticalWritingEnabled)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(readingMode, forKey: .readingMode)
        try container.encode(theme, forKey: .theme)
        try container.encode(font, forKey: .font)
        try container.encode(fontScale, forKey: .fontScale)
        try container.encode(fontWeight, forKey: .fontWeight)
        try container.encode(lineHeight, forKey: .lineHeight)
        try container.encode(paragraphSpacing, forKey: .paragraphSpacing)
        try container.encode(paragraphIndent, forKey: .paragraphIndent)
        try container.encode(horizontalMargin, forKey: .horizontalMargin)
        try container.encode(verticalMargin, forKey: .verticalMargin)
        try container.encode(wordSpacing, forKey: .wordSpacing)
        try container.encode(letterSpacing, forKey: .letterSpacing)
        try container.encode(usesPublisherStyles, forKey: .usesPublisherStyles)
        try container.encode(hyphenationEnabled, forKey: .hyphenationEnabled)
        try container.encode(textNormalizationEnabled, forKey: .textNormalizationEnabled)
        try container.encode(textAlignment, forKey: .textAlignment)
        try container.encode(columnCount, forKey: .columnCount)
        try container.encode(verticalWritingEnabled, forKey: .verticalWritingEnabled)
    }

    private static func clamped(
        _ value: Double,
        to range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

public enum PDFPageLayout: String, Codable, CaseIterable, Sendable {
    case automatic
    case single
    case double
}

public enum PDFScrollMode: String, Codable, CaseIterable, Sendable {
    case paged
    case continuous
}

public enum PDFFitMode: String, Codable, CaseIterable, Sendable {
    case automatic
    case page
    case width
}

public struct PDFReaderPreferences: Codable, Hashable, Sendable {
    public let pageLayout: PDFPageLayout
    public let scrollMode: PDFScrollMode
    public let fitMode: PDFFitMode
    public let readingDirection: ImageReadingDirection
    public let displaysPageBreaks: Bool

    public init(
        pageLayout: PDFPageLayout = .single,
        scrollMode: PDFScrollMode = .continuous,
        fitMode: PDFFitMode = .width,
        readingDirection: ImageReadingDirection = .leftToRight,
        displaysPageBreaks: Bool = true
    ) {
        self.pageLayout = pageLayout
        self.scrollMode = scrollMode
        self.fitMode = fitMode
        self.readingDirection = readingDirection
        self.displaysPageBreaks = displaysPageBreaks
    }
}

public struct PublicationSearchPreferences: Codable, Hashable, Sendable {
    public let isCaseSensitive: Bool
    public let isDiacriticSensitive: Bool
    public let matchesWholeWords: Bool
    public let maximumResults: Int

    public init(
        isCaseSensitive: Bool = false,
        isDiacriticSensitive: Bool = false,
        matchesWholeWords: Bool = false,
        maximumResults: Int = 250
    ) {
        self.isCaseSensitive = isCaseSensitive
        self.isDiacriticSensitive = isDiacriticSensitive
        self.matchesWholeWords = matchesWholeWords
        self.maximumResults = min(2_000, max(1, maximumResults))
    }
}

public struct ReaderAnnotationPreferences: Codable, Hashable, Sendable {
    public let defaultHighlightColor: ReaderHighlightColor
    public let displaysHighlights: Bool
    public let includesSelectedTextInNotes: Bool

    public init(
        defaultHighlightColor: ReaderHighlightColor = .yellow,
        displaysHighlights: Bool = true,
        includesSelectedTextInNotes: Bool = true
    ) {
        self.defaultHighlightColor = defaultHighlightColor
        self.displaysHighlights = displaysHighlights
        self.includesSelectedTextInNotes = includesSelectedTextInNotes
    }
}

public struct PublicationTTSPreferences: Codable, Hashable, Sendable {
    public let languageCode: String?
    public let voiceIdentifier: String?
    public let rate: Double
    public let pitch: Double
    public let volume: Double

    public init(
        languageCode: String? = nil,
        voiceIdentifier: String? = nil,
        rate: Double = 0.5,
        pitch: Double = 1,
        volume: Double = 1
    ) {
        self.languageCode = languageCode
        self.voiceIdentifier = voiceIdentifier
        self.rate = min(1, max(0, rate))
        self.pitch = min(2, max(0.5, pitch))
        self.volume = min(1, max(0, volume))
    }
}
