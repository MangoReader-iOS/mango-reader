import Foundation

/// The deliberately small, non-sensitive preference surface shared through
/// Mango Reader's private CloudKit zone.
///
/// Account details, source configuration, incognito state, downloads,
/// queues, and file-transfer opt-ins do not belong in
/// this value. Strings are normalized against compiled-in allowlists so a
/// malformed or newer payload cannot inject arbitrary UserDefaults values.
public struct SyncedAppSettings: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let singletonID = "preferences"

    public var version: Int
    public var library: SyncedLibraryPreferences
    public var appearance: SyncedAppearancePreferences
    public var reader: SyncedReaderPreferences
    public var modifiedAt: Date
    public var deviceID: String

    public init(
        version: Int = Self.currentVersion,
        library: SyncedLibraryPreferences = SyncedLibraryPreferences(),
        appearance: SyncedAppearancePreferences = SyncedAppearancePreferences(),
        reader: SyncedReaderPreferences = SyncedReaderPreferences(),
        modifiedAt: Date = .now,
        deviceID: String
    ) {
        self.version = version
        self.library = library
        self.appearance = appearance
        self.reader = reader
        self.modifiedAt = Self.boundedDate(modifiedAt)
        self.deviceID = Self.boundedDeviceID(deviceID)
    }

    /// Metadata does not participate in preference equality. This is used by
    /// the app to suppress the UserDefaults notification emitted while applying
    /// a remote record instead of writing the same value back to CloudKit.
    public func hasSamePreferences(as other: Self) -> Bool {
        library == other.library
            && appearance == other.appearance
            && reader == other.reader
    }

    public func replacingMetadata(modifiedAt: Date, deviceID: String) -> Self {
        Self(
            version: Self.currentVersion,
            library: library,
            appearance: appearance,
            reader: reader,
            modifiedAt: modifiedAt,
            deviceID: deviceID
        )
    }

    /// Latest-modified wins; a stable device identifier breaks equal-date ties.
    public func merging(_ other: Self) -> Self {
        if modifiedAt == other.modifiedAt {
            return deviceID >= other.deviceID ? self : other
        }
        return modifiedAt > other.modifiedAt ? self : other
    }

    public var isValidForCloudSync: Bool {
        isValidForCloudSync(referenceDate: .now)
    }

    public func isValidForCloudSync(referenceDate: Date) -> Bool {
        let trimmedDeviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return version == Self.currentVersion
            && !trimmedDeviceID.isEmpty
            && trimmedDeviceID == deviceID
            && deviceID.utf8.count <= 128
            && modifiedAt.timeIntervalSince1970.isFinite
            && modifiedAt >= Self.minimumDate
            && modifiedAt <= Self.maximumDate
            && modifiedAt <= referenceDate.addingTimeInterval(86_400)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case library
        case appearance
        case reader
        case modifiedAt
        case deviceID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        library = try container.decode(SyncedLibraryPreferences.self, forKey: .library)
        appearance = try container.decode(SyncedAppearancePreferences.self, forKey: .appearance)
        reader = try container.decode(SyncedReaderPreferences.self, forKey: .reader)
        // Preference fields are sanitized above. Conflict metadata remains raw
        // so validation at the database/CloudKit boundary can reject missing,
        // oversized, non-finite, or implausibly future values rather than
        // silently turning them into an LWW winner.
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        deviceID = try container.decode(String.self, forKey: .deviceID)
    }

    private static let minimumDate = Date(timeIntervalSince1970: 0)
    private static let maximumDate = Date(timeIntervalSince1970: 4_102_444_800)

    private static func boundedDate(_ value: Date) -> Date {
        let timestamp = value.timeIntervalSince1970
        guard timestamp.isFinite else { return minimumDate }
        return min(maximumDate, max(minimumDate, value))
    }

    private static func boundedDeviceID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown-device" }
        var result = ""
        result.reserveCapacity(min(128, trimmed.count))
        for character in trimmed {
            let candidate = result + String(character)
            guard candidate.utf8.count <= 128 else { break }
            result = candidate
        }
        return result.isEmpty ? "unknown-device" : result
    }
}

public struct SyncedLibraryPreferences: Codable, Hashable, Sendable {
    public var layout: String
    public var sort: LibrarySort

    public init(layout: String = "grid", sort: LibrarySort = .recentlyAdded) {
        self.layout = Self.allowedLayouts.contains(layout) ? layout : "grid"
        self.sort = sort
    }

    private enum CodingKeys: String, CodingKey {
        case layout
        case sort
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawSort = try container.decode(String.self, forKey: .sort)
        self.init(
            layout: try container.decode(String.self, forKey: .layout),
            sort: LibrarySort(rawValue: rawSort) ?? .recentlyAdded
        )
    }

    private static let allowedLayouts: Set<String> = ["grid", "list"]
}

public struct SyncedAppearancePreferences: Codable, Hashable, Sendable {
    public var mode: String

    public init(mode: String = "system") {
        self.mode = Self.allowedModes.contains(mode) ? mode : "system"
    }

    private enum CodingKeys: String, CodingKey {
        case mode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(mode: try container.decode(String.self, forKey: .mode))
    }

    private static let allowedModes: Set<String> = ["system", "light", "dark"]
}

public struct SyncedReaderPreferences: Codable, Hashable, Sendable {
    public var additional: ReaderAdditionalPreferences
    public var direction: String
    public var epubScroll: Bool
    public var publisherStyles: Bool
    public var verticalWriting: Bool
    public var publicationTheme: String
    public var fontPreset: String
    public var fontScale: Double
    public var fontWeight: Double
    public var lineHeight: Double
    public var paragraphSpacing: Double
    public var paragraphIndent: Double
    public var pageMargins: Double
    public var wordSpacing: Double
    public var letterSpacing: Double
    public var hyphenation: Bool
    public var textNormalization: Bool
    public var textAlignment: String
    public var columnCount: String
    public var pdfDoublePage: Bool
    public var pdfContinuous: Bool
    public var reduceTransitions: Bool
    public var imagePageSpread: String
    public var imageWidePageBehavior: String
    public var imageCropMargins: Bool
    public var imageLiveText: Bool
    public var imageTransition: String
    public var imageTapLeadingAction: String
    public var imageTapCenterAction: String
    public var imageTapTrailingAction: String

    public init(
        additional: ReaderAdditionalPreferences = ReaderAdditionalPreferences(),
        direction: String = "vertical",
        epubScroll: Bool = true,
        publisherStyles: Bool = true,
        verticalWriting: Bool = false,
        publicationTheme: String = "system",
        fontPreset: String = "publisher",
        fontScale: Double = 1,
        fontWeight: Double = 1,
        lineHeight: Double = 1.4,
        paragraphSpacing: Double = 0.5,
        paragraphIndent: Double = 0,
        pageMargins: Double = 1,
        wordSpacing: Double = 0,
        letterSpacing: Double = 0,
        hyphenation: Bool = true,
        textNormalization: Bool = false,
        textAlignment: String = "publisher",
        columnCount: String = "automatic",
        pdfDoublePage: Bool = false,
        pdfContinuous: Bool = true,
        reduceTransitions: Bool = false,
        imagePageSpread: String = "single",
        imageWidePageBehavior: String = "fit",
        imageCropMargins: Bool = false,
        imageLiveText: Bool = false,
        imageTransition: String = "slide",
        imageTapLeadingAction: String = "",
        imageTapCenterAction: String = "",
        imageTapTrailingAction: String = ""
    ) {
        self.additional = additional
        if self.additional.pdfPageLayout == nil {
            self.additional.pdfPageLayout = pdfDoublePage ? "double" : "single"
        }
        self.direction = Self.value(direction, allowed: Self.directions, fallback: "vertical")
        self.publisherStyles = publisherStyles
        self.verticalWriting = verticalWriting
        self.epubScroll = verticalWriting ? false : epubScroll
        self.publicationTheme = Self.value(
            publicationTheme == "dark" ? "black" : publicationTheme,
            allowed: Self.publicationThemes,
            fallback: "system"
        )
        self.fontPreset = Self.value(fontPreset, allowed: Self.fontPresets, fallback: "publisher")
        self.fontScale = Self.clamped(fontScale, to: 0.5 ... 3, fallback: 1)
        self.fontWeight = Self.clamped(fontWeight, to: 0.5 ... 2, fallback: 1)
        self.lineHeight = Self.clamped(lineHeight, to: 1 ... 2, fallback: 1.4)
        self.paragraphSpacing = Self.clamped(paragraphSpacing, to: 0 ... 2, fallback: 0.5)
        self.paragraphIndent = Self.clamped(paragraphIndent, to: 0 ... 3, fallback: 0)
        self.pageMargins = Self.clamped(pageMargins, to: 0 ... 4, fallback: 1)
        self.wordSpacing = Self.clamped(wordSpacing, to: 0 ... 1, fallback: 0)
        self.letterSpacing = Self.clamped(letterSpacing, to: 0 ... 1, fallback: 0)
        self.hyphenation = hyphenation
        self.textNormalization = textNormalization
        self.textAlignment = Self.value(
            textAlignment,
            allowed: Self.textAlignments,
            fallback: "publisher"
        )
        self.columnCount = Self.value(
            columnCount,
            allowed: Self.columnCounts,
            fallback: "automatic"
        )
        self.pdfDoublePage = pdfDoublePage
        self.pdfContinuous = pdfContinuous
        self.reduceTransitions = reduceTransitions
        self.imagePageSpread = Self.value(
            imagePageSpread,
            allowed: Self.imagePageSpreads,
            fallback: "single"
        )
        self.imageWidePageBehavior = Self.value(
            imageWidePageBehavior,
            allowed: Self.imageWidePageBehaviors,
            fallback: "fit"
        )
        self.imageCropMargins = imageCropMargins
        self.imageLiveText = imageLiveText
        self.imageTransition = Self.value(
            imageTransition,
            allowed: Self.imageTransitions,
            fallback: "slide"
        )
        self.imageTapLeadingAction = Self.tapAction(imageTapLeadingAction)
        self.imageTapCenterAction = Self.tapAction(imageTapCenterAction)
        self.imageTapTrailingAction = Self.tapAction(imageTapTrailingAction)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case additional
        case direction
        case epubScroll
        case publisherStyles
        case verticalWriting
        case publicationTheme
        case fontPreset
        case fontScale
        case fontWeight
        case lineHeight
        case paragraphSpacing
        case paragraphIndent
        case pageMargins
        case wordSpacing
        case letterSpacing
        case hyphenation
        case textNormalization
        case textAlignment
        case columnCount
        case pdfDoublePage
        case pdfContinuous
        case reduceTransitions
        case imagePageSpread
        case imageWidePageBehavior
        case imageCropMargins
        case imageLiveText
        case imageTransition
        case imageTapLeadingAction
        case imageTapCenterAction
        case imageTapTrailingAction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            additional: try container.decodeIfPresent(ReaderAdditionalPreferences.self, forKey: .additional) ?? Self.legacyAdditional(container),
            direction: try container.decode(String.self, forKey: .direction),
            epubScroll: try container.decode(Bool.self, forKey: .epubScroll),
            publisherStyles: try container.decode(Bool.self, forKey: .publisherStyles),
            verticalWriting: try container.decode(Bool.self, forKey: .verticalWriting),
            publicationTheme: try container.decode(String.self, forKey: .publicationTheme),
            fontPreset: try container.decode(String.self, forKey: .fontPreset),
            fontScale: try container.decode(Double.self, forKey: .fontScale),
            fontWeight: try container.decode(Double.self, forKey: .fontWeight),
            lineHeight: try container.decode(Double.self, forKey: .lineHeight),
            paragraphSpacing: try container.decode(Double.self, forKey: .paragraphSpacing),
            paragraphIndent: try container.decode(Double.self, forKey: .paragraphIndent),
            pageMargins: try container.decode(Double.self, forKey: .pageMargins),
            wordSpacing: try container.decode(Double.self, forKey: .wordSpacing),
            letterSpacing: try container.decode(Double.self, forKey: .letterSpacing),
            hyphenation: try container.decode(Bool.self, forKey: .hyphenation),
            textNormalization: try container.decode(Bool.self, forKey: .textNormalization),
            textAlignment: try container.decode(String.self, forKey: .textAlignment),
            columnCount: try container.decode(String.self, forKey: .columnCount),
            pdfDoublePage: try container.decode(Bool.self, forKey: .pdfDoublePage),
            pdfContinuous: try container.decode(Bool.self, forKey: .pdfContinuous),
            reduceTransitions: try container.decode(Bool.self, forKey: .reduceTransitions),
            imagePageSpread: try container.decode(String.self, forKey: .imagePageSpread),
            imageWidePageBehavior: try container.decode(String.self, forKey: .imageWidePageBehavior),
            imageCropMargins: try container.decode(Bool.self, forKey: .imageCropMargins),
            imageLiveText: try container.decode(Bool.self, forKey: .imageLiveText),
            imageTransition: try container.decode(String.self, forKey: .imageTransition),
            imageTapLeadingAction: try container.decode(String.self, forKey: .imageTapLeadingAction),
            imageTapCenterAction: try container.decode(String.self, forKey: .imageTapCenterAction),
            imageTapTrailingAction: try container.decode(String.self, forKey: .imageTapTrailingAction)
        )
    }

    private static func legacyAdditional(_ c: KeyedDecodingContainer<CodingKeys>) throws -> ReaderAdditionalPreferences {
        var value = ReaderAdditionalPreferences()
        let direction = try c.decode(String.self, forKey: .direction)
        value.imageMode = direction == "vertical" ? "continuous" : direction
        value.pageLayout = try c.decode(String.self, forKey: .imagePageSpread)
        if try !c.decode(String.self, forKey: .imageTapLeadingAction).isEmpty
            || !c.decode(String.self, forKey: .imageTapTrailingAction).isEmpty { value.tapPreset = "custom" }
        return value
    }

    private static let directions: Set<String> = ["rtl", "ltr", "vertical", "webtoon"]
    private static let publicationThemes: Set<String> = ["system", "light", "sepia", "black"]
    private static let fontPresets: Set<String> = [
        "publisher",
        "systemSans",
        "systemSerif",
        "accessibleDfA",
        "iaWriterDuospace",
        "openDyslexic",
        "iowanOldStyle",
        "athelas",
        "georgia",
        "seravek",
    ]
    private static let textAlignments: Set<String> = ["publisher", "leading", "justified"]
    private static let columnCounts: Set<String> = ["automatic", "one", "two"]
    private static let imagePageSpreads: Set<String> = ["single", "double"]
    private static let imageWidePageBehaviors: Set<String> = ["fit", "split"]
    private static let imageTransitions: Set<String> = ["none", "slide", "fade", "pageCurl"]
    private static let tapActions: Set<String> = [
        "",
        "none",
        "previousPage",
        "nextPage",
        "scrollBackward",
        "scrollForward",
        "toggleControls",
    ]

    private static func value(_ value: String, allowed: Set<String>, fallback: String) -> String {
        allowed.contains(value) ? value : fallback
    }

    private static func tapAction(_ value: String) -> String {
        self.value(value, allowed: tapActions, fallback: "")
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
