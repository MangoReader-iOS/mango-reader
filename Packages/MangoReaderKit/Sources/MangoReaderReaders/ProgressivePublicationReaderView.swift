import AVFoundation
import Foundation
import MangoReaderDomain
import OSLog
import ReadiumNavigator
import SwiftUI
import UIKit
@preconcurrency import WebKit

@MainActor protocol ProgressiveReaderBackend: AnyObject {
    func navigate(locator: ReadingLocator)
    func navigate(blockID: String)
    func navigate(position: Int)
    func move(forward: Bool)
    func annotationAnchor(fallback: ReadingLocator?) -> ReaderAnnotationAnchor?
    func setAnnotations(_ annotations: [Annotation])
    func search(_ query: String, preferences: PublicationSearchPreferences) -> [PublicationSearchResult]
    func toggleSpeech()
    func advanceSpeech(forward: Bool)
    func stopSpeech()
}

/// LNORI's progressive document is appended in place. Readium remains the
/// renderer for complete EPUB/PDF files and explicit offline acquisitions.
public struct ProgressivePublicationReaderView: UIViewRepresentable {
    /// Prepares an empty, local document only. No source request or reading data
    /// is loaded before the user opens a volume.
    public static func prepareRenderer() { ProgressiveWebViewPreparation.shared.prepare() }
    public let session: ProgressivePublicationSession
    public var initialLocator: ReadingLocator?
    public var startAtEnd: Bool
    public var textPreferences: TextReaderPreferences
    public var controller: ReadiumReaderController
    @Binding public var controlsVisible: Bool
    public var onPhaseChange: (ReadiumReaderPhase) -> Void
    public var onLocatorChange: (ReadingLocator) -> Void
    public init(session: ProgressivePublicationSession, initialLocator: ReadingLocator?, startAtEnd: Bool = false, textPreferences: TextReaderPreferences,
        controller: ReadiumReaderController, controlsVisible: Binding<Bool>, onPhaseChange: @escaping (ReadiumReaderPhase) -> Void,
        onLocatorChange: @escaping (ReadingLocator) -> Void) {
        self.session = session; self.initialLocator = initialLocator; self.startAtEnd = startAtEnd; self.textPreferences = textPreferences
        self.controller = controller; _controlsVisible = controlsVisible
        self.onPhaseChange = onPhaseChange; self.onLocatorChange = onLocatorChange
    }
    public func makeCoordinator() -> Coordinator { Coordinator(self) }
    public func makeUIView(context: Context) -> WKWebView {
        let (web, prepared) = ProgressiveWebViewPreparation.shared.take()
        web.configuration.userContentController.add(context.coordinator, name: "reader")
        web.isOpaque = false; web.backgroundColor = .systemBackground
        web.navigationDelegate = context.coordinator
        web.scrollView.delegate = context.coordinator
        web.accessibilityIdentifier = "lnori-progressive-reader"
        context.coordinator.web = web
        context.coordinator.auditMarker("lnori-reader-shell", value: ProcessInfo.processInfo.systemUptime)
        context.coordinator.auditMarker("lnori-boundary-wait", value: 0)
        controller.attachProgressive(context.coordinator)
        context.coordinator.ready = prepared
        context.coordinator.parent.onPhaseChange(.loading)
        session.start()
        return web
    }
    public func updateUIView(_ web: WKWebView, context: Context) {
        _ = session.revision
        context.coordinator.parent = self
        context.coordinator.refresh()
    }
    public static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.ready = false
        coordinator.parent.session.cancel()
        coordinator.parent.controller.detachProgressive(coordinator)
        web.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
        web.stopLoading(); web.navigationDelegate = nil; web.scrollView.delegate = nil
        ProgressiveWebViewPreparation.shared.prepare()
    }

    @MainActor public final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, UIScrollViewDelegate, ProgressiveReaderBackend, AVSpeechSynthesizerDelegate {
        var parent: ProgressivePublicationReaderView
        weak var web: WKWebView?
        var ready = false, rendering = false, restored = false
        var restoringDOM = false
        var renderedStart = 0, renderedCount = 0, current = 0
        var fraction = 0.0
        var pendingLocator: ReadingLocator?
        var waitingForEnd = false
        var restorationFailure: String?
        var appliedPreferences: TextReaderPreferences?
        var appliedDark: Bool?
        var marks: [Annotation] = []
        let speech = AVSpeechSynthesizer()
        var spokenIndex = 0
        var boundaryGate = ReaderChapterGestureGate<ObjectIdentifier>()
        var firstPaintReported = false
        var boundaryLabel: String?
        var boundaryWaitStarted: TimeInterval?
        var boundaryWait = 0.0
        init(_ parent: ProgressivePublicationReaderView) {
            self.parent = parent; pendingLocator = parent.initialLocator; waitingForEnd = parent.startAtEnd
            super.init(); speech.delegate = self
        }
        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; refresh() }
        public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard ready, let value = message.body as? [String: Any], let event = value["event"] as? String else { return }
            switch event {
            case "position":
                guard !restoringDOM, restored else { return }
                let waiting = value["waiting"] as? Bool == true && !parent.session.complete
                if waiting, boundaryWaitStarted == nil { boundaryWaitStarted = ProcessInfo.processInfo.systemUptime }
                if !waiting, let started = boundaryWaitStarted {
                    boundaryWait += ProcessInfo.processInfo.systemUptime - started; boundaryWaitStarted = nil
                    auditMarker("lnori-boundary-wait", value: boundaryWait)
                }
                current = max(0, value["index"] as? Int ?? current)
                fraction = min(1, max(0, value["fraction"] as? Double ?? 0))
                if restored, let locator = location(index: current, fraction: fraction) {
                    parent.controller.updateProgressive(blocks: parent.session.blocks, complete: parent.session.complete,
                        current: parent.session.position(index: current, fraction: fraction), count: parent.session.positionCount, locator: locator, restored: true)
                    parent.onLocatorChange(locator)
                }
                refresh()
            case "restored":
                restoringDOM = false; restored = true
                current = value["index"] as? Int ?? current
                fraction = value["fraction"] as? Double ?? fraction
                if let locator = location(index: current, fraction: fraction) {
                    parent.controller.updateProgressive(blocks: parent.session.blocks, complete: parent.session.complete,
                        current: parent.session.position(index: current, fraction: fraction), count: parent.session.positionCount, locator: locator, restored: true)
                }
                refresh()
            case "restoreError":
                restoringDOM = false
                pendingLocator = location(index: current, fraction: fraction)
                restorationFailure = "Your saved position could not be displayed. It has been kept."
                parent.onPhaseChange(.failed(restorationFailure!)); updateBoundary()
            case "selection":
                selectedText = (value["text"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(20_000)) }
                selectedIndex = value["index"] as? Int
                selectedFraction = value["fraction"] as? Double ?? 0
                if selectedText == nil { highlightedCount = -1; setAnnotations(marks) }
            case "begin":
                if let locator = location(index: 0) { navigate(locator: locator) }
            case "retry":
                parent.session.retry()
                if renderedCount == 0 { parent.onPhaseChange(.loading) }
                refresh()
            case "boundary":
                let forward = value["forward"] as? Bool ?? true
                if (!forward && renderedStart == 0) || (forward && parent.session.complete && renderedCount == parent.session.blocks.count) {
                    attemptBoundary(forward)
                }
            case "paint":
                guard restored else { return }
                parent.onPhaseChange(.ready)
                if !firstPaintReported {
                    firstPaintReported = true
                    let uptime = ProcessInfo.processInfo.systemUptime
                    Logger(subsystem: "com.k800k.manko", category: "ReaderOpening").debug("LNORI first readable paint at \(uptime, privacy: .public)")
                    auditMarker("lnori-first-text-ready", value: uptime)
#if DEBUG
                    if ProcessInfo.processInfo.environment["MANGOREADER_PERFORMANCE_RUN"] != nil {
                        NotificationCenter.default.post(name: Notification.Name("MangoReaderPerformance"), object: nil, userInfo: ["textPaint": true])
                    }
#endif
                }
                refresh()
            case "tap":
                guard value["selected"] as? Bool != true else { return }
                let region = TapZoneRegion.region(normalizedX: value["x"] as? Double ?? 0.5, normalizedY: value["y"] as? Double ?? 0.5)
                switch parent.controller.tapZones.action(for: region) {
                case .nextPage, .scrollForward: move(forward: true)
                case .previousPage, .scrollBackward: move(forward: false)
                case .toggleControls: parent.controlsVisible.toggle()
                case .none: break
                }
            default: break
            }
        }
        func auditMarker(_ identifier: String, value: Double) {
#if DEBUG
            guard ProcessInfo.processInfo.environment["MANGOREADER_SOURCE_AUDIT"] == "1", let web else { return }
            if let marker = web.subviews.first(where: { $0.accessibilityIdentifier == identifier }) {
                marker.accessibilityValue = String(value); return
            }
            let marker = UILabel(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            marker.text = " "; marker.textColor = .clear; marker.isAccessibilityElement = true
            marker.accessibilityIdentifier = identifier; marker.accessibilityLabel = identifier
            marker.accessibilityValue = String(value); web.addSubview(marker)
#endif
        }
        func attemptBoundary(_ forward: Bool) {
            boundaryGate.beginInteraction(chapterID: ObjectIdentifier(self))
            switch boundaryGate.attempt(forward ? .next : .previous, chapterID: ObjectIdentifier(self)) {
            case .stop: parent.controller.onBoundaryHint?(forward)
            case .continueChapter: parent.controller.onBoundary?(forward)
            case .ignored: break
            }
            boundaryGate.endInteraction()
        }
        public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            let minimum = -scrollView.adjustedContentInset.top
            let maximum = max(minimum, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
            if scrollView.contentOffset.y < minimum - 24, renderedStart == 0 { attemptBoundary(false) }
            else if scrollView.contentOffset.y > maximum + 24, parent.session.complete, renderedCount == parent.session.blocks.count { attemptBoundary(true) }
        }

        func refresh() {
            if let first = parent.session.firstTextUptime { auditMarker("lnori-first-block-ready", value: first) }
            guard ready, !rendering, let web else { return }
            let blocks = parent.session.blocks
            if let completion = parent.session.completedUptime { auditMarker("lnori-background-complete", value: completion) }
            if appliedPreferences != parent.textPreferences || appliedDark != (web.traitCollection.userInterfaceStyle == .dark) {
                appliedPreferences = parent.textPreferences
                appliedDark = web.traitCollection.userInterfaceStyle == .dark
                applyPreferences()
            }
            // A resource position is approximately 1 KiB of text in Readium.
            // Grow the DOM only to the visible position plus six such positions.
            if pendingLocator != nil, !restored, resolve(pendingLocator) == nil {
                parent.controller.updateProgressive(blocks: blocks, complete: parent.session.complete,
                    current: 0, count: parent.session.positionCount, locator: nil, restored: false)
                restoreIfPossible(); updateBoundary(); return
            }
            if renderedCount == 0, let pendingLocator, let target = resolve(pendingLocator) {
                current = target.index; fraction = target.fraction; renderedStart = target.index; renderedCount = target.index
            }
            var start = renderedStart
            if let pendingLocator, let target = resolve(pendingLocator) { start = min(start, target.index) }
            if firstPaintReported, current <= start + 2 {
                var behind = 0
                while start > 0, behind < 6 * 1_024 { start -= 1; behind += blocks[start].text.utf16.count }
            }
            if waitingForEnd, parent.session.complete, let last = blocks.last {
                pendingLocator = location(index: last.index, fraction: 1); waitingForEnd = false
            }
            var end = min(blocks.count, max(renderedCount, current + 1))
            var ahead = blocks[min(current, end)..<end].reduce(0) { $0 + $1.text.utf16.count }
            if blocks.indices.contains(current), current < end { ahead -= Int(Double(blocks[current].text.utf16.count) * fraction) }
            let budget = firstPaintReported ? 6 * 1_024 : 1_024
            while end < blocks.count, ahead < budget { ahead += blocks[end].text.utf16.count; end += 1 }
            if let pendingLocator, let target = resolve(pendingLocator), target.index >= end { end = min(blocks.count, target.index + 2) }
            if end > renderedCount || start < renderedStart {
                rendering = true
                let incoming = (Array(blocks[start..<renderedStart]) + Array(blocks[renderedCount..<end])).map { ["id": $0.id, "index": String($0.index), "html": $0.html] }
                let payload = Self.json(incoming)
                web.evaluateJavaScript("appendBlocks(\(payload));") { [weak self] _, error in
                    guard let self else { return }
                    rendering = false
                    if let error { parent.onPhaseChange(.failed(error.localizedDescription)); return }
                    renderedStart = start; renderedCount = end
                    restoreIfPossible()
                    updateBoundary()
                    setAnnotations(marks)
                    refresh()
                }
            } else {
                restoreIfPossible(); updateBoundary()
            }
            parent.controller.updateProgressive(blocks: blocks, complete: parent.session.complete,
                current: parent.session.position(index: current, fraction: fraction), count: parent.session.positionCount, locator: restored ? location(index: current, fraction: fraction) : nil, restored: restored)
        }
        func restoreIfPossible() {
            guard parent.session.blocks.contains(where: { $0.heading == nil && !$0.text.isEmpty }), let web, restorationFailure == nil, !waitingForEnd, !restoringDOM, !restored || pendingLocator != nil else { return }
            if let target = resolve(pendingLocator), target.index >= renderedStart, target.index < renderedCount {
                current = target.index; fraction = target.fraction
                pendingLocator = nil; restoringDOM = true
                web.evaluateJavaScript("restore(\(target.index),\(target.fraction));")
            } else if pendingLocator == nil, renderedCount > renderedStart {
                restoringDOM = true; web.evaluateJavaScript("restore(0,0);")
            } else if parent.session.complete && !parent.session.legacyLoading {
                let message = "Your saved position could not be restored. It has been kept."
                restorationFailure = message
                parent.onPhaseChange(.failed(message))
                web.evaluateJavaScript("showRecovery(\(Self.json(message)), 'Read from beginning', 'begin');")
                return
            }
            if restored {
                parent.controller.updateProgressive(blocks: parent.session.blocks, complete: parent.session.complete,
                    current: parent.session.position(index: current, fraction: fraction), count: parent.session.positionCount, locator: location(index: current, fraction: fraction), restored: true)
            }
        }
        func updateBoundary() {
            guard let web else { return }
            if let restorationFailure, !restored {
                web.evaluateJavaScript("showRecovery(\(Self.json(restorationFailure)), 'Read from beginning', 'begin');")
                return
            }
            let label: String
            if let failure = parent.session.failure { label = failure + " Retry to load more." }
            else if !restored && (pendingLocator != nil || waitingForEnd) { label = "Loading your saved position…" }
            else if parent.session.complete && renderedCount == parent.session.blocks.count { label = "End of volume" }
            else { label = "Loading more…" }
            guard boundaryLabel != label else { return }
            boundaryLabel = label
            web.evaluateJavaScript("setBoundary(\(Self.json(label)),\(parent.session.failure != nil));")
            if !restored && !restoringDOM && (pendingLocator != nil || waitingForEnd), parent.session.failure == nil {
                web.evaluateJavaScript("showRecovery(\(Self.json(label)), null, null);")
            }
            if parent.session.failure != nil && !restored {
                parent.onPhaseChange(.failed(label))
                web.evaluateJavaScript("showRecovery(\(Self.json(label)), 'Retry', 'retry');")
            }
        }
        func location(index: Int, fraction: Double = 0) -> ReadingLocator? {
            guard parent.session.blocks.indices.contains(index) else { return nil }
            var locations: [String: Any] = ["fragments": ["block-\(index)"], "progression": fraction, "position": parent.session.position(index: index, fraction: fraction) + 1]
            if parent.session.complete {
                locations["totalProgression"] = (Double(parent.session.textOffsets[index]) + fraction * Double(parent.session.blocks[index].text.utf16.count)) / Double(max(1, parent.session.textLength))
            }
            let text = parent.session.blocks[index].text as NSString
            func boundary(_ candidate: Int) -> Int {
                var value = min(text.length, max(0, candidate))
                if value < text.length, value > 0, (0xDC00...0xDFFF).contains(Int(text.character(at: value))) { value -= 1 }
                return value
            }
            let offset = boundary(Int(Double(text.length) * min(1, max(0, fraction))))
            let end = boundary(offset + 80), before = boundary(offset - 60), after = boundary(end + 60)
            let object: [String: Any] = ["href": "lnori.xhtml", "type": "application/xhtml+xml", "locations": locations,
                "text": ["highlight": text.substring(with: NSRange(location: offset, length: end - offset)),
                         "before": text.substring(with: NSRange(location: before, length: offset - before)),
                         "after": text.substring(with: NSRange(location: end, length: after - end))]]
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return .publication(readiumJSON: data)
        }
        func resolve(_ locator: ReadingLocator?) -> (index: Int, fraction: Double)? {
            guard let locator else { return (0, 0) }
            guard case let .publication(data) = locator, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let locations = value["locations"] as? [String: Any] ?? [:]
            if value["href"] as? String == "lnori.xhtml",
               let id = (locations["fragments"] as? [String])?.first, let index = Int(id.replacingOccurrences(of: "block-", with: "")),
               parent.session.blocks.indices.contains(index) {
                return (index, locations["progression"] as? Double ?? 0)
            }
            let text = value["text"] as? [String: String] ?? [:]
            let quote = (text["highlight"] ?? text["after"] ?? text["before"] ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if !quote.isEmpty, let target = locateText(quote) { return target }
            // A legacy locator without a text selector is mapped through the
            // immutable old section map, never the currently downloaded length.
            var legacyValue = value
            if let map = parent.session.legacySections, URL(string: value["href"] as? String ?? "")?.lastPathComponent == "content.xhtml",
               let mapped = try? map.remap(data), let migrated = try? JSONSerialization.jsonObject(with: mapped) as? [String: Any] { legacyValue = migrated }
            if let map = parent.session.legacySections,
               let href = legacyValue["href"] as? String, let section = map.sections.first(where: { $0.href == href || URL(string: $0.href)?.lastPathComponent == URL(string: href)?.lastPathComponent }), !section.text.isEmpty {
                let progression = (legacyValue["locations"] as? [String: Any])?["progression"] as? Double ?? 0
                if let target = locateText(String(section.text.prefix(160)), offsetWithinMatch: Int(Double(section.text.utf16.count) * progression)) { return target }
                guard parent.session.complete else { return nil }
                let offset = min(section.text.count - 1, max(0, Int(Double(section.text.count) * progression)))
                let start = section.text.index(section.text.startIndex, offsetBy: offset)
                let target = String(section.text[start...].prefix(80))
                if let target = locateText(target, requiresUniqueMatch: true) { return target }
            }
            return nil
        }
        func locateText(_ text: String, offsetWithinMatch: Int = 0, requiresUniqueMatch: Bool = false) -> (index: Int, fraction: Double)? {
            let combined = parent.session.blocks.map(\.text).joined(separator: " ") as NSString
            let found = combined.range(of: text)
            guard found.location != NSNotFound else { return nil }
            if requiresUniqueMatch, NSMaxRange(found) < combined.length,
               combined.range(of: text, range: NSRange(location: NSMaxRange(found), length: combined.length - NSMaxRange(found))).location != NSNotFound { return nil }
            let location = found.location + offsetWithinMatch
            var start = 0
            for block in parent.session.blocks {
                let length = block.text.utf16.count
                if location < start + length { return (block.index, Double(location - start) / Double(max(1, length))) }
                start += length + 1
            }
            return nil
        }
        func navigate(locator: ReadingLocator) { restorationFailure = nil; pendingLocator = locator; restored = false; refresh() }
        func navigate(blockID: String) {
            if let block = parent.session.blocks.first(where: { $0.id == blockID }), let locator = location(index: block.index) { navigate(locator: locator) }
        }
        func navigate(position: Int) {
            let offset = max(0, position) * 1_024
            guard let index = parent.session.textOffsets.lastIndex(where: { $0 <= offset }),
                  let locator = location(index: index, fraction: Double(offset - parent.session.textOffsets[index]) / Double(max(1, parent.session.blocks[index].text.utf16.count))) else { return }
            navigate(locator: locator)
        }
        func move(forward: Bool) {
            guard let web else { return }
            parent.controller.onUserNavigation?()
            web.evaluateJavaScript("move(\(forward ? 1 : -1));")
        }
        func annotationAnchor(fallback: ReadingLocator?) -> ReaderAnnotationAnchor? {
            // The latest visible anchor remains available while a native text
            // selection is copied through the message handler below.
            guard let locator = location(index: selectedText == nil ? current : (selectedIndex ?? current), fraction: selectedText == nil ? fraction : selectedFraction) ?? fallback else { return nil }
            return ReaderAnnotationAnchor(locator: locator, selectedText: selectedText, kind: selectedText == nil ? .currentPosition : .textSelection)
        }
        var selectedText: String?
        var selectedIndex: Int?
        var selectedFraction = 0.0
        var highlightedMarks: [Annotation] = []
        var highlightedCount = -1
        func setAnnotations(_ annotations: [Annotation]) {
            marks = annotations
            guard ready, selectedText == nil, annotations != highlightedMarks || renderedCount != highlightedCount else { return }
            highlightedMarks = annotations; highlightedCount = renderedCount
            let highlights = annotations.compactMap { annotation -> [String: String]? in
                guard let text = annotation.selectedText, !text.isEmpty else { return nil }
                guard let target = resolve(annotation.locator) else { return nil }
                return ["text": text, "color": annotation.highlightColor.rawValue, "id": "block-\(target.index)"]
            }
            web?.evaluateJavaScript("highlight(\(Self.json(highlights)));")
        }
        func search(_ query: String, preferences: PublicationSearchPreferences) -> [PublicationSearchResult] {
            guard parent.session.complete, !query.isEmpty else { return [] }
            var options: String.CompareOptions = preferences.isCaseSensitive ? [] : .caseInsensitive
            if !preferences.isDiacriticSensitive { options.insert(.diacriticInsensitive) }
            var results: [PublicationSearchResult] = []
            for block in parent.session.blocks {
                var start = block.text.startIndex
                while start < block.text.endIndex,
                      let range = block.text.range(of: query, options: options, range: start..<block.text.endIndex) {
                    guard range.lowerBound < range.upperBound else { break }
                    start = range.upperBound
                    func word(_ character: Character) -> Bool { character.isLetter || character.isNumber || character == "_" }
                    if preferences.matchesWholeWords,
                       (range.lowerBound != block.text.startIndex && word(block.text[block.text.index(before: range.lowerBound)]))
                        || (range.upperBound != block.text.endIndex && word(block.text[range.upperBound])) { continue }
                    let offset = block.text[..<range.lowerBound].utf16.count
                    guard let locator = location(index: block.index, fraction: Double(offset) / Double(max(1, block.text.utf16.count))),
                          let persisted = try? PersistedReadiumLocator(readingLocator: locator) else { continue }
                    results.append(PublicationSearchResult(id: "\(block.id)-\(offset)", locator: persisted, title: block.heading,
                        before: String(block.text[..<range.lowerBound].suffix(80)), match: String(block.text[range]),
                        after: String(block.text[range.upperBound...].prefix(80)), totalProgression: persisted.totalProgression))
                    if results.count == preferences.maximumResults { return results }
                }
            }
            return results
        }
        func toggleSpeech() {
            if speech.isPaused { speech.continueSpeaking(); parent.controller.updateProgressiveSpeech(.speaking, excerpt: nil) }
            else if speech.isSpeaking { speech.pauseSpeaking(at: .word); parent.controller.updateProgressiveSpeech(.paused, excerpt: nil) }
            else { spokenIndex = current; speakNext() }
        }
        func advanceSpeech(forward: Bool) {
            speech.stopSpeaking(at: .immediate)
            spokenIndex = max(0, spokenIndex + (forward ? 1 : -1)); speakNext()
        }
        func stopSpeech() { speech.stopSpeaking(at: .immediate); parent.controller.updateProgressiveSpeech(.idle, excerpt: nil) }
        func speakNext() {
            guard parent.session.blocks.indices.contains(spokenIndex) else { stopSpeech(); return }
            let text = parent.session.blocks[spokenIndex].text
            let utterance = AVSpeechUtterance(string: text)
            speech.speak(utterance); parent.controller.updateProgressiveSpeech(.speaking, excerpt: String(text.prefix(160)))
        }
        public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { Task { @MainActor [weak self] in self?.spokenIndex += 1; self?.speakNext() } }
        func applyPreferences() {
            guard let web else { return }
            let p = parent.textPreferences
            let dark = web.traitCollection.userInterfaceStyle == .dark
            let theme = p.theme.resolved(forDarkAppearance: dark)
            let background = theme == .black ? "#101010" : theme == .sepia ? "#f5ecd8" : "#ffffff"
            let foreground = theme == .black ? "#eeeeee" : "#202020"
            let font: String
            switch p.font { case .publisher: font = "serif"; case .system: font = "-apple-system"; case let .named(name): font = name }
            let alignment = p.textAlignment == .justified ? "justify" : "start"
            let style = bundledFontCSS(font) + "body{background:\(background);color:\(foreground);font-family:'\(font.replacingOccurrences(of: "'", with: ""))';font-size:\(16*p.fontScale)px;font-weight:\(400*p.fontWeight);line-height:\(p.lineHeight);padding:\(16*p.verticalMargin)px \(20*p.horizontalMargin)px;word-spacing:\(p.wordSpacing)em;letter-spacing:\(p.letterSpacing)em;writing-mode:\(p.verticalWritingEnabled ? "vertical-rl" : "horizontal-tb");text-align:\(alignment);hyphens:\(p.hyphenationEnabled ? "auto" : "none");}p{margin-block:\(p.paragraphSpacing)em;text-indent:\(p.paragraphIndent)em;}"
            let mode = p.readingMode == .paged || p.verticalWritingEnabled ? "paged" : "scroll"
            let columns = p.columnCount == .two ? 2 : p.columnCount == .one ? 1 : (web.bounds.width >= 700 ? 2 : 1)
            let layout = p.verticalWritingEnabled ? "#text{height:calc(100vh - \(32*p.verticalMargin)px);width:max-content;}#boundary{position:absolute;left:0;top:100%;}" : p.readingMode == .paged ? "#text{height:calc(100vh - \(32*p.verticalMargin)px);column-width:calc((100vw - \(40*p.horizontalMargin)px - \(columns == 2 ? 40 : 0)px)/\(columns));column-gap:40px;column-fill:auto;}#boundary{position:absolute;top:0;left:100%;}" : "#text{height:auto;columns:auto;max-width:80ch;margin-inline:auto;}"
            web.evaluateJavaScript("setMode(\(Self.json(mode)),\(p.verticalWritingEnabled));applyStyle(\(Self.json(style + layout)));")
            web.backgroundColor = theme == .black ? UIColor(white: 0.063, alpha: 1) : theme == .sepia ? UIColor(red: 0.96, green: 0.925, blue: 0.847, alpha: 1) : .white
        }
        static var fontCSS: [String: String] = [:]
        func bundledFontCSS(_ name: String) -> String {
            if let cached = Self.fontCSS[name] { return cached }
            let resource: String
            switch name {
            case "OpenDyslexic": resource = "Assets/Static/fonts/OpenDyslexic-Regular.otf"
            case "AccessibleDfA": resource = "Assets/Static/readium-css/fonts/AccessibleDfA.otf"
            case "IA Writer Duospace": resource = "Assets/Static/readium-css/fonts/iAWriterDuospace-Regular.ttf"
            default: return ""
            }
            let containers = [Bundle.main, Bundle(for: EPUBNavigatorViewController.self)]
            guard let url = containers.compactMap({ $0.url(forResource: "Readium_ReadiumNavigator", withExtension: "bundle") }).first,
                  let data = try? Data(contentsOf: url.appendingPathComponent(resource)) else { return "" }
            let css = "@font-face{font-family:'\(name)';src:url(data:font/otf;base64,\(data.base64EncodedString()));}"
            Self.fontCSS[name] = css; return css
        }
        static func json(_ value: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), let string = String(data: data, encoding: .utf8) else { return "null" }
            return string
        }
    }
    fileprivate static let document = #"""
    <!doctype html><html lang="en"><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=5"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; font-src data:; img-src 'none'; connect-src 'none'; form-action 'none'; base-uri 'none'"><style id="preferences"></style><style>body{margin:0;padding:16px 20px;overflow-wrap:break-word}#text{visibility:hidden}#boundary{padding:24px 0 70px;font:14px -apple-system;color:#777}button{font:inherit}pre{white-space:pre-wrap}table{max-width:100%;border-collapse:collapse}h1,h2,h3{line-height:1.2}mark{background:#ffe580}</style></head><body><main id="text"></main><div id="boundary" role="status">Loading…</div><script>
    const text=document.getElementById('text'), boundary=document.getElementById('boundary');
    const post=v=>{if(v.event==='position')window.lastPosition=v;window.webkit.messageHandlers.reader.postMessage(v)};
    window.addEventListener('error',e=>{window.readerError=e.message});
    function boundaryPlacement(){if(paged&&!vertical){boundary.style.left=(text.scrollWidth+parseFloat(getComputedStyle(document.body).paddingLeft))+'px';boundary.style.width='calc(100vw - 40px)'}}
    function appendBlocks(blocks){let caret=anchor(),before=caret?measure(caret):null;for(const block of blocks){if(document.getElementById(block.id))continue;const node=document.createElement('div');node.id=block.id;node.dataset.index=block.index;node.innerHTML=block.html;const next=Array.from(text.children).find(n=>Number(n.dataset.index)>Number(block.index));text.insertBefore(node,next||null)}boundaryPlacement();if(caret&&before){let after=measure(caret);window.scrollBy(paged?after.left-before.left:0,paged?0:after.top-before.top)}requestAnimationFrame(position)}
    function showText(){text.style.display='block';text.style.visibility='visible';boundary.style.cssText='';boundaryPlacement();requestAnimationFrame(()=>requestAnimationFrame(()=>{position();post({event:'paint'})}))}
    function showRecovery(label,title,event){text.style.display='none';boundary.style.cssText='position:fixed;inset:24px 20px auto;';boundary.replaceChildren(document.createTextNode(label+' '));if(title){let button=document.createElement('button');button.textContent=title;button.onclick=()=>post({event});boundary.appendChild(button)}}
    function setBoundary(label,retry){boundary.replaceChildren(document.createTextNode(label));if(retry){let button=document.createElement('button');button.textContent='Retry';button.onclick=()=>post({event:'retry'});boundary.appendChild(button)}}
    let paged=false,vertical=false;
    function setMode(mode,isVertical){paged=mode==='paged';vertical=isVertical}
    function anchor(){let style=getComputedStyle(document.body),x=vertical?window.innerWidth-parseFloat(style.paddingRight)-1:parseFloat(style.paddingLeft)+1,y=parseFloat(style.paddingTop)+1;let caret=document.caretRangeFromPoint(x,y),node=caret?.startContainer.parentElement?.closest('[data-index]');if(node){let rect=node.getBoundingClientRect();if(rect.bottom>y&&rect.top<=y&&rect.right>x&&rect.left<=x)return caret}node=Array.from(text.children).find(n=>{let r=n.getBoundingClientRect();return r.bottom>y&&(!paged||r.right>x&&r.left<window.innerWidth)});if(!node)return null;let walker=document.createTreeWalker(node,NodeFilter.SHOW_TEXT);while(walker.nextNode()){let t=walker.currentNode,r=document.createRange();r.selectNodeContents(t);let rect=r.getBoundingClientRect();if(rect.bottom<=y||paged&&rect.right<=x)continue;let low=0,high=t.length;while(low<high){let mid=Math.floor((low+high)/2);r.setStart(t,mid);r.setEnd(t,Math.min(mid+1,t.length));rect=r.getBoundingClientRect();if(vertical?rect.left>x:rect.bottom<=y)low=mid+1;else high=mid}r.setStart(t,Math.min(low,t.length));r.collapse(true);return r}let r=document.createRange();r.selectNodeContents(node);r.collapse(true);return r}
    // A saved caret can point at a collapsed space at a line break. Include the
    // nearest painted character when checking visibility, without changing the
    // persisted text offset or treating a zero-width space as a restore failure.
    function paintedRange(node,offset){let r=document.createRange();r.setStart(node,offset);r.setEnd(node,Math.min(offset+1,node.length));let rect=r.getBoundingClientRect();while(rect.width===0&&r.endOffset<node.length){r.setEnd(node,r.endOffset+1);rect=r.getBoundingClientRect()}while(rect.width===0&&r.startOffset>0){r.setStart(node,r.startOffset-1);rect=r.getBoundingClientRect()}return r}
    function go(index,fraction){let node=document.getElementById('block-'+index);if(!node)return;let remaining=Math.floor(node.textContent.length*fraction),walker=document.createTreeWalker(node,NodeFilter.SHOW_TEXT);while(walker.nextNode()){let textNode=walker.currentNode;if(remaining<=textNode.length){let offset=Math.min(remaining,Math.max(0,textNode.length-1)),r=paintedRange(textNode,offset),rect=r.getBoundingClientRect();if(paged)window.scrollBy(rect.left-parseFloat(getComputedStyle(document.body).paddingLeft),0);else window.scrollBy(0,rect.top-parseFloat(getComputedStyle(document.body).paddingTop));return r}remaining-=textNode.length}node.scrollIntoView()}
    // DOM appends and annotation updates can invalidate a saved Range or move its
    // rectangle while WebKit commits a scroll. Resolve the requested text again
    // on each layout frame. Require two frames without corrective scrolling so
    // WebKit can commit a preceding prepend before publishing the restored position.
    // A newer navigation cancels the older check.
    let restoration=0;
    function restore(index,fraction){const generation=++restoration;text.style.display='block';text.style.visibility='hidden';boundary.style.cssText='';boundaryPlacement();let frames=0,stable=0;function check(){if(generation!==restoration)return;const x=window.scrollX,y=window.scrollY;let range=go(index,fraction),rect=range?.getBoundingClientRect();const visible=rect&&rect.width>0&&rect.height>0&&rect.bottom>0&&rect.top<window.innerHeight&&rect.right>0&&rect.left<window.innerWidth;stable=visible&&Math.abs(window.scrollX-x)<1&&Math.abs(window.scrollY-y)<1?stable+1:0;if(stable>=2){post({event:'restored',index,fraction});showText()}else if(++frames<120)requestAnimationFrame(check);else post({event:'restoreError'})}requestAnimationFrame(check)}
    function move(direction){const pos=paged?(vertical?-window.scrollX:window.scrollX):window.scrollY, size=paged?window.innerWidth:window.innerHeight,total=paged?document.documentElement.scrollWidth:document.documentElement.scrollHeight;if(direction>0&&pos+size>=total-2||direction<0&&pos<=0)post({event:'boundary',forward:direction>0});else window.scrollBy({left:paged?direction*size*(vertical?-1:1):0,top:paged?0:direction*size*.85,behavior:'smooth'})}
    function position(){let caret=anchor(), node=caret?.startContainer.parentElement?.closest('[data-index]');if(node){let range=document.createRange();range.selectNodeContents(node);try{range.setEnd(caret.startContainer,caret.startOffset)}catch(e){}post({event:'position',index:Number(node.dataset.index),fraction:range.toString().length/Math.max(1,node.textContent.length),waiting:boundary.getBoundingClientRect().top<window.innerHeight});return}let nodes=Array.from(text.children);node=nodes.find(n=>n.getBoundingClientRect().bottom>0)||nodes.at(-1);if(node)post({event:'position',index:Number(node.dataset.index),fraction:0,waiting:boundary.getBoundingClientRect().top<window.innerHeight})}
    let queued=false;window.addEventListener('scroll',()=>{if(!queued){queued=true;requestAnimationFrame(()=>{queued=false;position()})}},{passive:true});
    window.addEventListener('resize',position);
    document.addEventListener('click',e=>{if(e.target.closest('button'))return;post({event:'tap',x:e.clientX/window.innerWidth,y:e.clientY/window.innerHeight,selected:!!window.getSelection().toString()})});
    document.addEventListener('selectionchange',()=>{let selection=window.getSelection(),range=selection.rangeCount?selection.getRangeAt(0):null,node=range?.startContainer.parentElement?.closest('[data-index]'),prefix=document.createRange();let fraction=0;if(node){prefix.selectNodeContents(node);prefix.setEnd(range.startContainer,range.startOffset);fraction=prefix.toString().length/Math.max(1,node.textContent.length)}post({event:'selection',text:selection.toString(),index:node?Number(node.dataset.index):null,fraction})});
    function measure(r){let copy=r.cloneRange();if(copy.startContainer.nodeType===Node.TEXT_NODE){let node=copy.startContainer,offset=Math.min(copy.startOffset,Math.max(0,node.length-1));copy.setStart(node,offset);copy.setEnd(node,Math.min(offset+1,node.length))}return copy.getBoundingClientRect()}
    function applyStyle(css){let r=anchor(),before=r?measure(r):null;document.getElementById('preferences').textContent=css;boundaryPlacement();if(r&&before){let after=measure(r);window.scrollBy(paged?after.left-before.left:0,paged?0:after.top-before.top)}position()}
    function highlight(marks){
      if(window.getSelection().toString())return;
      for(const mark of text.querySelectorAll('mark'))mark.replaceWith(...mark.childNodes);
      for(const value of marks){
        const root=document.getElementById(value.id);if(!root||!value.text)continue;
        let walker=document.createTreeWalker(text,NodeFilter.SHOW_TEXT),started=false,letters='',points=[];
        while(walker.nextNode()){
          const node=walker.currentNode;if(root.contains(node))started=true;if(!started)continue;
          for(let offset=0;offset<node.length;offset++){if(/\s/.test(node.textContent[offset]))continue;letters+=node.textContent[offset];points.push([node,offset])}
        }
        const needle=value.text.replace(/\s/g,''),index=letters.indexOf(needle);if(index<0||!needle)continue;
        let segments=new Map();
        for(const [node,offset] of points.slice(index,index+needle.length)){if(!segments.has(node))segments.set(node,[offset,offset+1]);else segments.get(node)[1]=offset+1}
        for(const [node,[start,end]] of Array.from(segments).reverse()){
          let range=document.createRange();range.setStart(node,start);range.setEnd(node,end);let mark=document.createElement('mark');
          mark.style.background=({yellow:'#ffe580',green:'#bce5ad',blue:'#b8dafa',pink:'#f5b8d8',purple:'#d8c3f2',orange:'#facd96'})[value.color]||'#ffe580';range.surroundContents(mark);
        }
      }
    }
    </script></body></html>
    """#
}

@MainActor private final class ProgressiveWebViewPreparation: NSObject, WKNavigationDelegate {
    static let shared = ProgressiveWebViewPreparation()
    private var web: WKWebView?
    private var ready = false
    func prepare() {
        guard web == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let candidate = WKWebView(frame: .zero, configuration: configuration)
        web = candidate; ready = false
        candidate.navigationDelegate = self
        candidate.loadHTMLString(ProgressivePublicationReaderView.document, baseURL: nil)
    }
    func take() -> (WKWebView, Bool) {
        prepare()
        let candidate = web!, wasReady = ready
        web = nil; ready = false
        return (candidate, wasReady)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if web === webView { ready = true }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if web === webView { web = nil; ready = false }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if web === webView { web = nil; ready = false }
    }
}
