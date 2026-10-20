import CoreGraphics
import MangoReaderDomain
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared

extension TextReaderPreferences {
    var readiumPreferences: EPUBPreferences {
        EPUBPreferences(
            backgroundColor: readiumBackgroundColor,
            columnCount: readiumColumnCount,
            fontFamily: readiumFontFamily,
            fontSize: fontScale,
            fontWeight: fontWeight,
            hyphens: hyphenationEnabled,
            letterSpacing: letterSpacing,
            lineHeight: lineHeight,
            pageMargins: horizontalMargin,
            paragraphIndent: paragraphIndent,
            paragraphSpacing: paragraphSpacing,
            publisherStyles: usesPublisherStyles,
            scroll: readingMode == .scroll && !verticalWritingEnabled,
            textAlign: readiumTextAlignment,
            textColor: readiumTextColor,
            textNormalization: textNormalizationEnabled,
            theme: readiumTheme,
            verticalText: verticalWritingEnabled,
            wordSpacing: wordSpacing
        )
    }

    var readiumBackgroundColor: ReadiumNavigator.Color? { nil }

    var readiumTextColor: ReadiumNavigator.Color? { nil }

    var readiumColumnCount: ColumnCount {
        switch columnCount {
        case .automatic: .auto
        case .one: .one
        case .two: .two
        }
    }

    var readiumFontFamily: FontFamily? {
        switch font {
        case .publisher:
            nil
        case .system:
            .sansSerif
        case let .named(name):
            FontFamily(rawValue: name)
        }
    }

    var readiumTextAlignment: ReadiumNavigator.TextAlignment? {
        switch textAlignment {
        case .publisher:
            nil
        case .leading:
            .start
        case .justified:
            .justify
        }
    }

    var readiumTheme: Theme? {
        switch theme {
        case .system:
            nil
        case .light:
            .light
        case .sepia:
            .sepia
        case .black:
            .dark
        }
    }
}

extension PDFReaderPreferences {
    var readiumPreferences: PDFPreferences {
        PDFPreferences(
            fit: readiumFit,
            pageSpacing: displaysPageBreaks ? 12 : 0,
            readingProgression: readingDirection == .leftToRight ? .ltr : .rtl,
            scroll: scrollMode == .continuous,
            scrollAxis: scrollMode == .continuous ? .vertical : .horizontal,
            spread: pageLayout == .automatic ? .auto : (pageLayout == .single ? .never : .always),
            visibleScrollbar: scrollMode == .continuous
        )
    }

    var readiumFit: Fit {
        switch fitMode {
        case .automatic:
            .auto
        case .page:
            .page
        case .width:
            .width
        }
    }
}


extension PDFReaderPreferences {
    func presentation(in viewport: ReaderViewport, expandedReading: String, anchorPage: Int?) -> (frame: CGRect, preferences: PDFPreferences) {
        var resolved = readiumPreferences
        var frame = viewport.unobscuredBounds
        guard viewport.isExpanded else { return (frame, resolved) }
        if !viewport.supportsSpread {
            frame = viewport.readingRegion
            resolved.spread = .never
        } else if scrollMode == .paged {
            if pageLayout == .automatic {
                resolved.spread = .always
                if expandedReading == "right", let page = anchorPage {
                    let start = readingDirection == .leftToRight ? max(0, page - 1) : page
                    resolved.offsetFirstPage = start % 2 == 1 || (page == 0 && readingDirection == .leftToRight)
                }
            } else if pageLayout == .single, expandedReading == "right" {
                frame = viewport.readingRegion
            }
        }
        return (frame, resolved)
    }
}

extension TextReaderPreferences {
    func presentationFrame(in viewport: ReaderViewport, reflowable: Bool, publisherSinglePage: Bool,
                           expandedReading: String) -> CGRect {
        guard viewport.isExpanded else { return viewport.unobscuredBounds }
        if !viewport.supportsSpread { return viewport.readingRegion }
        if expandedReading == "right", (reflowable && columnCount != .two) || (!reflowable && publisherSinglePage) {
            return viewport.readingRegion
        }
        return viewport.unobscuredBounds
    }
}
