import Foundation

/// Disposable metadata for translating the former single-resource novel layout.
/// It travels inside the EPUB, so downloads and restored cache entries have the
/// same location mapping as the publication that produced them.
public struct GeneratedPublicationSections: Codable, Hashable, Sendable {
    public static let resourcePath = "OEBPS/manko-sections.json"
    public static let layoutVersion = 2

    public struct Section: Codable, Hashable, Sendable {
        public var href: String
        public var title: String
        public var text: String
        public init(href: String, title: String, text: String) {
            self.href = href; self.title = title; self.text = text
        }
    }

    public var version: Int
    public var sections: [Section]
    public init(sections: [Section]) {
        version = Self.layoutVersion
        self.sections = sections
    }

    /// Exact quoted text wins over approximate progression. Legacy highlights
    /// may only move when their selected passage is actually present.
    public func remap(_ data: Data, selectedText: String? = nil, requiresTextMatch: Bool = false) throws -> Data {
        guard version == Self.layoutVersion, !sections.isEmpty,
              var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let href = json["href"] as? String else { throw MappingError.unresolved }
        let locations = json["locations"] as? [String: Any] ?? [:]
        let progression = (locations["totalProgression"] as? Double) ?? (locations["progression"] as? Double)
        let text = json["text"] as? [String: Any] ?? [:]
        let quote = (selectedText ?? (text["highlight"] as? String)).map(Self.normalizedText)
        let before = Self.normalizedText(text["before"] as? String ?? "")
        let after = Self.normalizedText(text["after"] as? String ?? "")
        if let section = sections.first(where: { $0.href == href || $0.href == href.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }) {
            if requiresTextMatch {
                guard let quote, !quote.isEmpty, section.text.contains(quote) else { throw MappingError.unresolved }
            }
            return data
        }
        guard ["content.xhtml", "lnori.xhtml"].contains(URL(string: href)?.lastPathComponent ?? "") else { throw MappingError.unresolved }
        let lengths = sections.map { $0.text.utf16.count }
        let total = lengths.reduce(0, +)
        let combinedText = sections.map(\.text).joined(separator: " ") as NSString
        let expected = max(0, min(1, progression ?? 0)) * Double(total)
        var matches: [(index: Int, offset: Int, distance: Double)] = []
        var start = 0
        if let quote, !quote.isEmpty {
            for (index, section) in sections.enumerated() {
                let ns = section.text as NSString
                var range = NSRange(location: 0, length: ns.length)
                while range.length > 0 {
                    let found = ns.range(of: quote, options: [], range: range)
                    guard found.location != NSNotFound else { break }
                    // Context can cross the new section boundary even though
                    // the selected passage itself stays in one resource.
                    let preceding = combinedText.substring(to: start + index + found.location).trimmingCharacters(in: .whitespacesAndNewlines)
                    let following = combinedText.substring(from: start + index + NSMaxRange(found)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let contextMatches = (before.isEmpty || preceding.hasSuffix(before)) && (after.isEmpty || following.hasPrefix(after))
                    if contextMatches {
                        matches.append((index, found.location, abs(Double(start + found.location) - expected)))
                    }
                    let next = NSMaxRange(found)
                    range = NSRange(location: next, length: ns.length - next)
                }
                start += lengths[index]
            }
        }
        let index: Int
        let offset: Int
        if let match = matches.min(by: { $0.distance < $1.distance }) {
            index = match.index; offset = match.offset
        } else {
            guard !requiresTextMatch, let progression, progression.isFinite, total > 0 else { throw MappingError.unresolved }
            start = 0
            var target = sections.count - 1
            for i in sections.indices {
                if expected < Double(start + lengths[i]) { target = i; break }
                start += lengths[i]
            }
            index = target
            offset = max(0, min(lengths[index], Int(expected) - lengths.prefix(index).reduce(0, +)))
            // Failed text selectors must not redirect the progression fallback.
            json.removeValue(forKey: "text")
        }
        json["href"] = sections[index].href
        if let selectedText {
            var resolvedText = text
            resolvedText["highlight"] = Self.normalizedText(selectedText)
            json["text"] = resolvedText
        }
        json["locations"] = [
            "progression": Double(offset) / Double(max(1, lengths[index])),
            "totalProgression": total > 0 ? Double(lengths.prefix(index).reduce(0, +) + offset) / Double(total) : 0,
        ]
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    private static func normalizedText(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public enum MappingError: Error, LocalizedError {
        case unresolved
        public var errorDescription: String? {
            "This saved position could not be restored in the updated volume. Your saved position has been kept."
        }
    }
}
