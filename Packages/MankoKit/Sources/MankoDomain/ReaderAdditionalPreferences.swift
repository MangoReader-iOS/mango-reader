import Foundation

/// Shared additions to the original reader preferences. Older sync records and
/// backups omit this object and are migrated without changing their behavior.
public struct ReaderAdditionalPreferences: Codable, Hashable, Sendable {
    public static let storageKey = "readerAdditionalPreferences"
    public var imageMode: String = "auto"
    public var tapPreset: String = "automatic"
    public var invertTapZones: Bool = false
    public var disableDoubleTap: Bool = false
    public var disableQuickActions: Bool = false
    public var hideBarsOnSwipe: Bool = false
    public var background: String = "black"
    public var orientation: String = "device"
    public var pageLayout: String = "automatic"
    public var expandedReading: String = "right"
    /// Nil means an older settings record; resolve its legacy PDF toggle before use.
    public var pdfPageLayout: String? = nil
    public var pageOffset: Bool = false
    public var reverseSplitOrder: Bool = false
    public var downsampleImages: Bool = false
    public var preloadCount: Int = 2
    public var infiniteScroll: Bool = true
    public var autoScroll: Bool = false
    public var autoScrollSpeed: Double = 5
    public var autoScrollPosition: String = "right"
    public var pillarbox: Bool = false
    public var pillarboxAmount: Double = 15
    public var pillarboxOrientation: String = "both"
    public var skipDuplicateChapters: Bool = true
    public var markDuplicateChapters: Bool = true
    public var pdfDirection: String = "ltr"
    public var pdfFit: String = "width"
    public var pdfPageBreaks: Bool = true
    public var fontFamily: String? = nil
    public var workOverrides: [String: ReaderWorkPreferences] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case imageMode
        case tapPreset
        case invertTapZones
        case disableDoubleTap
        case disableQuickActions
        case hideBarsOnSwipe
        case background
        case orientation
        case pageLayout
        case expandedReading, pdfPageLayout
        case pageOffset
        case reverseSplitOrder
        case downsampleImages
        case preloadCount
        case infiniteScroll
        case autoScroll
        case autoScrollSpeed
        case autoScrollPosition
        case pillarbox
        case pillarboxAmount
        case pillarboxOrientation
        case skipDuplicateChapters
        case markDuplicateChapters
        case pdfDirection
        case pdfFit
        case pdfPageBreaks
        case fontFamily
        case workOverrides
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imageMode = try c.decodeIfPresent(String.self, forKey: .imageMode) ?? "auto"
        tapPreset = try c.decodeIfPresent(String.self, forKey: .tapPreset) ?? "automatic"
        invertTapZones = try c.decodeIfPresent(Bool.self, forKey: .invertTapZones) ?? false
        disableDoubleTap = try c.decodeIfPresent(Bool.self, forKey: .disableDoubleTap) ?? false
        disableQuickActions = try c.decodeIfPresent(Bool.self, forKey: .disableQuickActions) ?? false
        hideBarsOnSwipe = try c.decodeIfPresent(Bool.self, forKey: .hideBarsOnSwipe) ?? false
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? "black"
        orientation = try c.decodeIfPresent(String.self, forKey: .orientation) ?? "device"
        pageLayout = try c.decodeIfPresent(String.self, forKey: .pageLayout) ?? "automatic"
        expandedReading = try c.decodeIfPresent(String.self, forKey: .expandedReading) == "fullWidth" ? "fullWidth" : "right"
        pdfPageLayout = try c.decodeIfPresent(String.self, forKey: .pdfPageLayout)
        if let value = pdfPageLayout, !["automatic", "single", "double"].contains(value) { pdfPageLayout = nil }
        pageOffset = try c.decodeIfPresent(Bool.self, forKey: .pageOffset) ?? false
        reverseSplitOrder = try c.decodeIfPresent(Bool.self, forKey: .reverseSplitOrder) ?? false
        downsampleImages = try c.decodeIfPresent(Bool.self, forKey: .downsampleImages) ?? false
        preloadCount = try c.decodeIfPresent(Int.self, forKey: .preloadCount) ?? 2
        infiniteScroll = try c.decodeIfPresent(Bool.self, forKey: .infiniteScroll) ?? true
        autoScroll = try c.decodeIfPresent(Bool.self, forKey: .autoScroll) ?? false
        autoScrollSpeed = try c.decodeIfPresent(Double.self, forKey: .autoScrollSpeed) ?? 5
        autoScrollPosition = try c.decodeIfPresent(String.self, forKey: .autoScrollPosition) ?? "right"
        pillarbox = try c.decodeIfPresent(Bool.self, forKey: .pillarbox) ?? false
        pillarboxAmount = try c.decodeIfPresent(Double.self, forKey: .pillarboxAmount) ?? 15
        pillarboxOrientation = try c.decodeIfPresent(String.self, forKey: .pillarboxOrientation) ?? "both"
        skipDuplicateChapters = try c.decodeIfPresent(Bool.self, forKey: .skipDuplicateChapters) ?? true
        markDuplicateChapters = try c.decodeIfPresent(Bool.self, forKey: .markDuplicateChapters) ?? true
        pdfDirection = try c.decodeIfPresent(String.self, forKey: .pdfDirection) ?? "ltr"
        pdfFit = try c.decodeIfPresent(String.self, forKey: .pdfFit) ?? "width"
        pdfPageBreaks = try c.decodeIfPresent(Bool.self, forKey: .pdfPageBreaks) ?? true
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily)
        workOverrides = try c.decodeIfPresent([String: ReaderWorkPreferences].self, forKey: .workOverrides) ?? [:]
        preloadCount = min(10, max(1, preloadCount))
        autoScrollSpeed = autoScrollSpeed.isFinite ? min(10, max(1, autoScrollSpeed)) : 5
        pillarboxAmount = pillarboxAmount.isFinite ? min(95, max(5, pillarboxAmount)) : 15
    }

    public static func read(from defaults: UserDefaults) -> Self {
        if let data = defaults.data(forKey: storageKey),
           var value = try? JSONDecoder().decode(Self.self, from: data) {
            if value.pdfPageLayout == nil { value.pdfPageLayout = legacyPDFLayout(from: defaults) }
            return value
        }
        var value = Self()
        value.pdfPageLayout = legacyPDFLayout(from: defaults)
        if let legacy = defaults.string(forKey: "readerDirection") {
            value.imageMode = legacy == "vertical" ? "continuous" : legacy
        }
        if let legacy = defaults.string(forKey: "imageReaderPageSpread") {
            value.pageLayout = legacy
        }
        // Old installations exposed custom side actions instead of presets.
        if defaults.string(forKey: "imageReaderTapLeadingAction")?.isEmpty == false
            || defaults.string(forKey: "imageReaderTapTrailingAction")?.isEmpty == false {
            value.tapPreset = "custom"
        }
        return value
    }

    private static func legacyPDFLayout(from defaults: UserDefaults) -> String {
        defaults.object(forKey: "pdfDoublePage") == nil ? "automatic" : (defaults.bool(forKey: "pdfDoublePage") ? "double" : "single")
    }

    public var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public func readingMode(for work: Work) -> String {
        let override = workOverrides[work.id.description]?.readingMode
        let selected = override == nil || override == "default" ? imageMode : override!
        return selected == "auto" ? (work.readingMode ?? "rtl") : selected
    }
}

public struct ReaderWorkPreferences: Codable, Hashable, Sendable {
    public var readingMode: String?
    public var pageOffset: Bool?
    public init(readingMode: String? = nil, pageOffset: Bool? = nil) {
        self.readingMode = readingMode
        self.pageOffset = pageOffset
    }
}
