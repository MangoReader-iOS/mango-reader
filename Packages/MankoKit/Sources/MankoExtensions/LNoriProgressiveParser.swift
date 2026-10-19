import Foundation
import MankoDomain

/// Tokenizes bytes before decoding, so split UTF-8 characters and quoted tag
/// delimiters survive arbitrary URLSession delivery boundaries. Source markup
/// is never sent directly to WebKit.
public actor LNoriProgressiveParser {
    public enum Failure: Error, Sendable, Equatable { case identity, malformed, tooLarge }
    private let workID: String
    private let volumeID: String
    private var buffer = Data()
    private var received = 0
    private var validated = false
    private var ended = false
    private var documentClosed = false
    private var sectionSeen = false
    private var proseSeen = false
    private var suppressed: String?
    private var unitRoot: String?
    private var unitDepth = 0
    private var unit = ""
    private var index = 0
    private var outputBytes = 0
    private var articleDepth = 1
    private static let roots: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "table", "ol", "ul", "blockquote"]
    private static let unsafe: Set<String> = ["script", "style", "iframe", "object", "embed", "svg", "math", "template", "picture"]

    public init(workID: String, volumeID: String) { self.workID = workID; self.volumeID = volumeID }

    public func append(_ bytes: Data) throws -> [ProgressivePublicationBlock] {
        try Task.checkCancellation()
        received += bytes.count
        guard received <= 16 * 1_024 * 1_024 else { throw Failure.tooLarge }
        buffer.append(bytes)
        if ended { validateDocumentTail(); return [] }
        if !validated {
            let prefix = String(decoding: buffer, as: UTF8.self)
            guard let match = Self.first(#"<article\b[^>]*class\s*=\s*["'][^"']*\bcontent-body\b[^"']*["'][^>]*>"#, prefix),
                  let range = Range(match.range, in: prefix) else {
                guard buffer.count <= 1_024 * 1_024 else { throw Failure.malformed }
                return []
            }
            let head = String(prefix[..<range.lowerBound])
            let scripts = try NSRegularExpression(pattern: #"<script\b[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>([\s\S]*?)</script\s*>"#, options: .caseInsensitive)
            let work = workID.split(separator: "/", maxSplits: 1).map(String.init)
            guard work.count == 2 else { throw Failure.identity }
            let matches = scripts.matches(in: head, range: NSRange(head.startIndex..., in: head))
            let identity = matches.compactMap { match -> [String: Any]? in
                guard let r = Range(match.range(at: 1), in: head), let data = String(head[r]).data(using: .utf8) else { return nil }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }.first { $0["additionalProperty"] is [[String: Any]] }
            guard let identity, let properties = identity["additionalProperty"] as? [[String: Any]] else { throw Failure.identity }
            func property(_ key: String) -> String? {
                properties.first { $0["name"] as? String == key }?["value"].map { String(describing: $0) }
            }
            guard identity["id"].map({ String(describing: $0) }) == volumeID.split(separator: "/").first.map(String.init),
                  property("series_id") == work[0], property("series_slug") == work[1] else { throw Failure.identity }
            let consumed = prefix[..<range.upperBound].utf8.count
            discard(consumed)
            validated = true
        }
        var blocks: [ProgressivePublicationBlock] = []
        while !buffer.isEmpty, !ended {
            try Task.checkCancellation()
            if let suppressed {
                let closing = Data("</\(suppressed)".utf8)
                if let range = Self.caseInsensitiveRange(closing, in: buffer) {
                    discard(range.lowerBound)
                    guard let end = Self.tagEnd(buffer) else { break }
                    discard(end + 1)
                    self.suppressed = nil
                } else {
                    // Retain only enough bytes to recognize a split closing tag.
                    if buffer.count > closing.count { discard(buffer.count - closing.count) }
                    break
                }
                continue
            }
            if buffer.first != 60 {
                guard let end = buffer.firstIndex(of: 60) else { break }
                let data = buffer.prefix(end)
                guard let text = String(data: data, encoding: .utf8) else { throw Failure.malformed }
                discard(end)
                if unitRoot != nil { unit += text }
                else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let block = try emit("<p>\(text)</p>") { blocks.append(block) }
                }
                continue
            }
            if buffer.starts(with: Data("<!--".utf8)) {
                guard let range = buffer.range(of: Data("-->".utf8)) else { break }
                discard(range.upperBound); continue
            }
            guard let end = Self.tagEnd(buffer), let tag = String(data: buffer.prefix(end + 1), encoding: .utf8) else { break }
            discard(end + 1)
            guard let match = Self.first(#"^<\s*(/?)\s*([a-zA-Z][a-zA-Z0-9:-]*)\b"#, tag),
                  let nr = Range(match.range(at: 2), in: tag), let cr = Range(match.range(at: 1), in: tag) else { continue }
            let name = tag[nr].lowercased(), closing = !tag[cr].isEmpty
            if Self.unsafe.contains(name) {
                if !closing && !tag.hasSuffix("/>") && name != "embed" { suppressed = name }
                continue
            }
            if name == "article" {
                articleDepth += closing ? -1 : 1
                if articleDepth == 0 {
                    guard unitRoot == nil, sectionSeen else { throw Failure.malformed }
                    ended = true; validateDocumentTail(); break
                }
            }
            if name == "section", !closing { sectionSeen = true }
            let canonical = closing ? "</\(name)>" : (["br", "hr", "img", "source", "input", "wbr"].contains(name) ? "<\(name) />" : "<\(name)>")
            if let root = unitRoot {
                unit += canonical
                if name == root { unitDepth += closing ? -1 : 1 }
                if unitDepth == 0 {
                    if let block = try emit(unit) { blocks.append(block) }; unit = ""; unitRoot = nil
                }
            } else if !closing, Self.roots.contains(name) {
                unitRoot = name; unitDepth = 1; unit = canonical
            }
        }
        return blocks
    }

    public func finish() throws {
        try Task.checkCancellation()
        guard validated, ended, documentClosed, proseSeen, index > 0, unitRoot == nil else { throw Failure.malformed }
    }

    private func validateDocumentTail() {
        if Self.caseInsensitiveRange(Data("</html>".utf8), in: buffer) != nil { documentClosed = true }
        if buffer.count > 16 { buffer = Data(buffer.suffix(16)) }
    }

    private func discard(_ count: Int) { buffer = Data(buffer.dropFirst(count)) }

    private func emit(_ html: String) throws -> ProgressivePublicationBlock? {
        let sanitized = try MankoExtensionEPUBBuilder.sanitize(html, title: "")
        guard let match = Self.first(#"<body>([\s\S]*)</body>"#, sanitized), let range = Range(match.range(at: 1), in: sanitized) else { throw Failure.malformed }
        let safe = String(sanitized[range])
        outputBytes += safe.utf8.count
        guard outputBytes <= 2 * 1_024 * 1_024 else { throw Failure.tooLarge }
        let collector = TextCollector()
        let parser = XMLParser(data: Data(sanitized.utf8)); parser.delegate = collector
        guard parser.parse() else { throw Failure.malformed }
        let text = collector.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let heading = Self.first(#"^<h[1-6]>"#, safe) == nil ? nil : text
        if heading == nil { proseSeen = true }
        defer { index += 1 }
        return ProgressivePublicationBlock(index: index, html: safe, text: text, heading: heading)
    }
    private static func first(_ pattern: String, _ text: String) -> NSTextCheckingResult? {
        (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive))?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private static func tagEnd(_ data: Data) -> Int? {
        var quote: UInt8?
        for (index, byte) in data.enumerated() {
            if let active = quote { if byte == active { quote = nil } }
            else if byte == 34 || byte == 39 { quote = byte }
            else if byte == 62 { return index }
        }
        return nil
    }
    private static func caseInsensitiveRange(_ needle: Data, in data: Data) -> Range<Int>? {
        let folded = Data(data.map { (65...90).contains($0) ? $0 + 32 : $0 })
        return folded.range(of: needle)
    }
    private final class TextCollector: NSObject, XMLParserDelegate {
        var text = "", inBody = false
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) { if elementName == "body" { inBody = true }; if inBody, !["span", "em", "strong", "b", "i", "a", "u", "s", "small", "sup", "sub"].contains(elementName) { text += " " } }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if inBody { text += string } }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { if elementName == "body" { inBody = false }; if inBody, !["span", "em", "strong", "b", "i", "a", "u", "s", "small", "sup", "sub"].contains(elementName) { text += " " } }
    }
}
