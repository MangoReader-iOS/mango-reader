import MankoDomain
import MankoReaders
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Reusable settings sections backed directly by AppStorage so changes made
/// from the reader sheet and Settings stay in sync and update the live Readium
/// navigator without an intermediate mutable model.
struct EPUBTypographySettingsSections: View {
    @ReaderPreferencesStorage private var options
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

    var body: some View {
        Section {
            Toggle("Vertical CJK writing", isOn: $verticalWriting)
                .onChange(of: verticalWriting) { _, enabled in
                    if enabled {
                        epubScroll = false
                    }
                }

            Toggle("Scroll instead of pages", isOn: $epubScroll)
                .disabled(verticalWriting)

            Picker("Paged columns", selection: $readerColumnCount) {
                Text("Automatic").tag(PublicationColumnCount.automatic)
                Text("One Column").tag(PublicationColumnCount.one)
                Text("Two Columns").tag(PublicationColumnCount.two)
            }
            .disabled(epubScroll)

            Picker("Theme", selection: $publicationTheme) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Paper").tag("sepia")
                Text("Black").tag("black")
            }
            .onAppear {
                publicationTheme = (PublicationTheme(rawValue: publicationTheme) ?? .system).rawValue
            }

            Toggle("Use publisher styles", isOn: $publisherStyles)
        } header: {
            Text("EPUB Layout")
        } footer: {
            if publisherStyles {
                Text("Turn off publisher styles to change paragraph formatting.")
            }
        }
        .appFullWidthListSeparator()

        Section {
            Picker("Font", selection: $readerFontPreset) {
                ForEach(PublicationFontPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }

            Picker("Installed font", selection: Binding(get: { options.fontFamily ?? "" }, set: { options.fontFamily = $0.isEmpty ? nil : $0 })) {
                Text("Use Font Preset").tag("")
                ForEach(UIFont.familyNames.sorted(), id: \.self) { Text($0).tag($0) }
            }

            TypographySliderRow(
                "Text size",
                value: $readerFontScale,
                range: 0.5 ... 3,
                step: 0.1,
                format: .percentage
            )

            TypographySliderRow(
                "Text weight",
                value: $readerFontWeight,
                range: 0.5 ... 2,
                step: 0.25,
                format: .percentage
            )

            Toggle("Improve text legibility", isOn: $readerTextNormalization)
        } header: {
            Text("Typeface")
        }
        .appFullWidthListSeparator()
        Section {
            Picker("Alignment", selection: $readerTextAlignment) {
                Text("Publisher Default").tag(PublicationTextAlignment.publisher)
                Text("Leading").tag(PublicationTextAlignment.leading)
                Text("Justified").tag(PublicationTextAlignment.justified)
            }
            .disabled(publisherStyles)

            Toggle("Hyphenation", isOn: $readerHyphenation)
                .disabled(publisherStyles)

            TypographySliderRow(
                "Line height",
                value: $readerLineHeight,
                range: 1 ... 2,
                step: 0.1,
                format: .multiplier
            )
            .disabled(publisherStyles)

            TypographySliderRow(
                "Paragraph spacing",
                value: $readerParagraphSpacing,
                range: 0 ... 2,
                step: 0.1,
                format: .em
            )
            .disabled(publisherStyles)

            TypographySliderRow(
                "Paragraph indent",
                value: $readerParagraphIndent,
                range: 0 ... 3,
                step: 0.2,
                format: .em
            )
            .disabled(publisherStyles)

            TypographySliderRow(
                "Page margins",
                value: $readerPageMargins,
                range: 0 ... 4,
                step: 0.25,
                format: .multiplier
            )

            TypographySliderRow(
                "Word spacing",
                value: $readerWordSpacing,
                range: 0 ... 1,
                step: 0.1,
                format: .percentage
            )
            .disabled(publisherStyles)

            TypographySliderRow(
                "Letter spacing",
                value: $readerLetterSpacing,
                range: 0 ... 1,
                step: 0.1,
                format: .percentage
            )
            .disabled(publisherStyles)
        } header: {
            Text("Paragraph Layout")
        }
        .appFullWidthListSeparator()
    }
}

@propertyWrapper
struct ReaderPreferencesStorage: DynamicProperty {
    @AppStorage(ReaderAdditionalPreferences.storageKey) private var data = Data()
    var wrappedValue: ReaderAdditionalPreferences {
        get { (try? JSONDecoder().decode(ReaderAdditionalPreferences.self, from: data)) ?? ReaderAdditionalPreferences.read(from: .standard) }
        nonmutating set { data = newValue.encoded }
    }
    var projectedValue: Binding<ReaderAdditionalPreferences> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}

struct ReaderSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let work: Work
    let format: PublicationFormat
    let epubLayout: EPUBPublicationLayout?

    var body: some View {
        NavigationStack {
            Form {
                ReaderCommonSettingsSections()
                switch format {
                case .cbz, .remoteImageSequence:
                    ImageReaderSettingsSections(work: work)
                case .epub:
                    if epubLayout == .fixed {
                        Section { Text("This publication uses fixed pages. Its text size and layout are set by the publisher.") }
                    } else {
                        EPUBTypographySettingsSections()
                    }
                case .pdf:
                    PDFReaderSettingsSections()
                }
            }
            .navigationTitle("Reader Settings")
            .navigationBarTitleDisplayMode(.inline)
            .appNativeNavigationChrome()
            .toolbar { ToolbarItem(placement: .confirmationAction) { FixedNavigationChrome { Button("Done") { dismiss() } } } }
        }
        .presentationDetents([.large])
    }
}

struct ReaderCommonSettingsSections: View {
    @ReaderPreferencesStorage private var options
    @State private var supportsHinge = false
    @AppStorage("reduceReaderTransitions") private var reduceTransitions = false
    @AppStorage("imageReaderTapLeadingAction") private var leftAction = ""
    @AppStorage("imageReaderTapTrailingAction") private var rightAction = ""

    var body: some View {
        Section("Controls") {
            Picker("Expanded reading", selection: $options.expandedReading) {
                Text("Keep content on right").tag("right")
                Text("Use full width").tag("fullWidth")
            }
            Picker("Tap zones", selection: $options.tapPreset) {
                Text("Automatic").tag("automatic")
                Text("Left / Right").tag("left-right")
                Text("L-shaped").tag("l-shaped")
                Text("Kindle").tag("kindle")
                Text("Edge").tag("edge")
                Text("Disabled").tag("disabled")
                Text("Custom").tag("custom")
            }
            if options.tapPreset == "custom" {
                sidePicker("Left side", selection: $leftAction)
                sidePicker("Right side", selection: $rightAction)
            }
            Toggle("Invert tap zones", isOn: $options.invertTapZones)
            Toggle("Hide controls on swipe", isOn: $options.hideBarsOnSwipe)
            Toggle("Reduce page transitions", isOn: $reduceTransitions)
            if UIDevice.current.userInterfaceIdiom == .phone {
                Picker("Orientation", selection: $options.orientation) {
                    Text("Follow Device").tag("device")
                    Text("Portrait").tag("portrait")
                    Text("Landscape").tag("landscape")
                }
            }
        }
        .appFullWidthListSeparator()
        .observeBookCoverHinge { supportsHinge = $0 != nil }
        if supportsHinge {
            FoldedBookCoverSettingsSection()
        }
    }
    private func sidePicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("Default").tag("")
            Text("Previous Page").tag("previousPage")
            Text("Next Page").tag("nextPage")
            Text("Show or Hide Controls").tag("toggleControls")
            Text("No Action").tag("none")
        }
    }
}

struct ImageReaderSettingsSections: View {
    var work: Work? = nil
    @ReaderPreferencesStorage private var options
    @AppStorage("imageReaderWidePageBehavior") private var widePages: WidePageBehavior = .fit
    @AppStorage("imageReaderCropMargins") private var crop = false
    @AppStorage("imageReaderLiveText") private var liveText = false
    @AppStorage("imageReaderTransition") private var transition = "slide"

    private var mode: Binding<String> {
        guard let work else { return $options.imageMode }
        return Binding(get: { options.workOverrides[work.id.description]?.readingMode ?? "default" }, set: { value in
            var override = options.workOverrides[work.id.description] ?? ReaderWorkPreferences()
            override.readingMode = value == "default" ? nil : value
            options.workOverrides[work.id.description] = override
        })
    }
    private var offset: Binding<Bool> {
        guard let work else { return $options.pageOffset }
        return Binding(get: { options.workOverrides[work.id.description]?.pageOffset ?? options.pageOffset }, set: { value in
            var override = options.workOverrides[work.id.description] ?? ReaderWorkPreferences()
            override.pageOffset = value
            options.workOverrides[work.id.description] = override
        })
    }
    var body: some View {
        Section("Image Reading") {
            Picker(work == nil ? "Default reading mode" : "Reading mode for this title", selection: mode) {
                if work != nil { Text("Use Default").tag("default") }
                Text("Automatic").tag("auto")
                Text("Right to Left").tag("rtl")
                Text("Left to Right").tag("ltr")
                Text("Vertical Pages").tag("verticalPaged")
                Text("Webtoon").tag("webtoon")
                Text("Continuous with Gaps").tag("continuous")
            }
            Toggle("Skip duplicate chapters", isOn: $options.skipDuplicateChapters)
            Toggle("Mark duplicate chapters read", isOn: $options.markDuplicateChapters)
            Toggle("Downsample images", isOn: $options.downsampleImages)
            Toggle("Crop page margins", isOn: $crop)
            Toggle("Live Text selection", isOn: $liveText).disabled(!ImageLiveTextSupport.isAvailable)
            Toggle("Disable double-tap zoom", isOn: $options.disableDoubleTap)
            Toggle("Disable page quick actions", isOn: $options.disableQuickActions)
            Picker("Background", selection: $options.background) {
                Text("System").tag("system"); Text("Automatic").tag("auto")
                Text("Black").tag("black"); Text("White").tag("white")
            }
            Picker("Page transition", selection: $transition) {
                Text("None").tag("none"); Text("Slide").tag("slide"); Text("Fade").tag("fade")
            }
        }
        .appFullWidthListSeparator()
        Section("Paged Reading") {
            Picker("Page layout", selection: $options.pageLayout) {
                Text("Automatic").tag("automatic"); Text("Single Page").tag("single"); Text("Two-Page Spread").tag("double")
            }
            Toggle("Offset page pairs", isOn: offset)
            if let work, options.workOverrides[work.id.description]?.pageOffset != nil {
                Button("Use Default Page Offset") {
                    options.workOverrides[work.id.description]?.pageOffset = nil
                }
            }
            Picker("Wide pages", selection: $widePages) {
                Text("Fit on Screen").tag(WidePageBehavior.fit)
                Text("Split into Two Pages").tag(WidePageBehavior.split)
            }
            if widePages == .split { Toggle("Reverse split order", isOn: $options.reverseSplitOrder) }
            Stepper("Pages to preload: \(options.preloadCount)", value: $options.preloadCount, in: 1...10)
        }
        .appFullWidthListSeparator()
        Section("Continuous Reading") {
            Toggle("Continue across chapters", isOn: $options.infiniteScroll)
            Toggle("Auto-scroll control", isOn: $options.autoScroll)
            if options.autoScroll {
                Stepper("Auto-scroll speed: \(Int(options.autoScrollSpeed))", value: $options.autoScrollSpeed, in: 1...10)
                Picker("Auto-scroll control position", selection: $options.autoScrollPosition) {
                    Text("Left").tag("left"); Text("Center").tag("center"); Text("Right").tag("right")
                }
            }
            Toggle("Limit page width", isOn: $options.pillarbox)
            if options.pillarbox {
                Stepper("Side margins: \(Int(options.pillarboxAmount))%", value: $options.pillarboxAmount, in: 5...95, step: 5)
                Picker("Apply margins in", selection: $options.pillarboxOrientation) {
                    Text("Both Orientations").tag("both"); Text("Portrait").tag("portrait"); Text("Landscape").tag("landscape")
                }
            }
        }
        .appFullWidthListSeparator()
    }
}

struct PDFReaderSettingsSections: View {
    @ReaderPreferencesStorage private var options
    @AppStorage("pdfDoublePage") private var doublePage = false
    @AppStorage("pdfContinuous") private var continuous = true
    var body: some View {
        Section("PDF") {
            Picker("Page layout", selection: Binding(
                get: { options.pdfPageLayout ?? (doublePage ? "double" : "single") },
                set: { options.pdfPageLayout = $0; doublePage = $0 == "double" }
            )) {
                Text("Automatic").tag("automatic")
                Text("Single Page").tag("single")
                Text("Two-Page Spread").tag("double")
            }
            Toggle("Continuous scrolling", isOn: $continuous)
            Picker("Direction", selection: $options.pdfDirection) {
                Text("Left to Right").tag("ltr"); Text("Right to Left").tag("rtl")
            }
            Picker("Page fit", selection: $options.pdfFit) {
                Text("Automatic").tag("automatic"); Text("Fit Page").tag("page"); Text("Fit Width").tag("width")
            }
            Toggle("Show page breaks", isOn: $options.pdfPageBreaks)
        }
        .appFullWidthListSeparator()
    }
}

private enum TypographyValueFormat {
    case percentage
    case multiplier
    case em

    func string(from value: Double) -> String {
        switch self {
        case .percentage:
            value.formatted(.percent.precision(.fractionLength(0)))
        case .multiplier:
            value.formatted(.number.precision(.fractionLength(1))) + "×"
        case .em:
            value.formatted(.number.precision(.fractionLength(1))) + " em"
        }
    }
}

private struct TypographySliderRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: TypographyValueFormat

    init(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: TypographyValueFormat
    ) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                Text(format.string(from: value))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                slider
            }
        } else {
            LabeledContent(title) {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(format.string(from: value))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    slider
                        .frame(maxWidth: 220)
                }
            }
        }
    }

    private var slider: some View {
        Slider(value: $value, in: range, step: step)
            .accessibilityLabel(title)
            .accessibilityValue(format.string(from: value))
    }
}
