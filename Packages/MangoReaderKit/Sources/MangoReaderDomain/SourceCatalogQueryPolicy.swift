import Foundation

public struct SourceCatalogQueryContext: Equatable {
    public var fragment: String
    public var value: String
    public var field: SourceSearchField?
    public var isExcluding: Bool
    public var remainingQuery: String = ""

    public init(fragment: String, value: String, field: SourceSearchField?, isExcluding: Bool, remainingQuery: String = "") {
        self.fragment = fragment
        self.value = value
        self.field = field
        self.isExcluding = isExcluding
        self.remainingQuery = remainingQuery
    }
}

public enum SourceCatalogQueryParser {
    public static func context(
        in query: String,
        fields: [SourceSearchField]
    ) -> SourceCatalogQueryContext {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var starts: [String.Index] = []
        var inQuotes = false, escaped = false, atStart = true
        for index in trimmed.indices {
            let character = trimmed[index]
            if atStart, !character.isWhitespace { starts.append(index); atStart = false }
            if character == "\\", !escaped { escaped = true; continue }
            if character == "\"", !escaped { inQuotes.toggle() }
            if character.isWhitespace, !inQuotes { atStart = true }
            escaped = false
        }
        var start = trimmed.startIndex
        var field: SourceSearchField?
        for candidate in starts.reversed() {
            let suffix = String(trimmed[candidate...])
            let body = suffix.hasPrefix("-") ? String(suffix.dropFirst()) : suffix
            if let match = fields.first(where: { body.lowercased().hasPrefix($0.queryPrefix.lowercased()) }) {
                start = candidate; field = match; break
            }
        }
        if field == nil, let last = starts.last(where: { trimmed[$0] == "\"" }) { start = last }
        var end = trimmed.endIndex
        if let openingQuote = trimmed[start...].firstIndex(of: "\"") {
            var isEscaped = false
            for index in trimmed[trimmed.index(after: openingQuote)...].indices {
                let character = trimmed[index]
                if character == "\"", !isEscaped {
                    end = trimmed.index(after: index)
                    break
                }
                if character == "\\", !isEscaped { isEscaped = true } else { isEscaped = false }
            }
        }
        let fragment = String(trimmed[start..<end])
        let isExcluding = fragment.hasPrefix("-")
        let body = isExcluding ? String(fragment.dropFirst()) : fragment
        let rawValue = field.map { String(body.dropFirst($0.queryPrefix.count)) } ?? body
        return SourceCatalogQueryContext(
            fragment: fragment,
            value: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
            field: field,
            isExcluding: isExcluding,
            remainingQuery: [String(trimmed[..<start]), String(trimmed[end...])]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: " ")
        )
    }

}

public enum SourceCatalogSuggestionPolicy {
    public static func mergedSuggestions(
        context: SourceCatalogQueryContext,
        configuration: SourceSearchConfiguration?,
        remote: [SourceSearchSuggestion],
        local: [SourceSearchSuggestion] = []
    ) -> [SourceSearchSuggestion] {
        guard let configuration else { return [] }
        let fields = context.field.map { [$0] } ?? configuration.fields
        var suggestions = fields.flatMap { field in
            field.options.map { option in
                SourceSearchSuggestion(fieldID: field.id, value: option.id, title: option.title, subtitle: option.subtitle)
            }
        }
        suggestions.append(contentsOf: local + remote)
        let preference = Dictionary(local.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: min)
        let knownFields = Dictionary(uniqueKeysWithValues: configuration.fields.map { ($0.id, $0) })
        var seen: Set<String> = []
        return suggestions.compactMap { suggestion -> (SourceSearchSuggestion, Int)? in
            guard let field = knownFields[suggestion.fieldID],
                  context.field?.id == nil || context.field?.id == field.id,
                  field.resolvedInputKind != .choice || field.options.contains(where: { $0.id == suggestion.value }),
                  !context.isExcluding || field.supportsExclusion,
                  seen.insert(suggestion.id).inserted else { return nil }
            let score = [
                SourceSearchMatching.score(query: context.value, candidate: suggestion.title),
                SourceSearchMatching.score(query: context.value, candidate: suggestion.value)
            ].compactMap { $0 }.min()
            return score.map { (suggestion, $0) }
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            let lhs = preference[$0.0.id] ?? Int.max, rhs = preference[$1.0.id] ?? Int.max
            if lhs != rhs { return lhs < rhs }
            return $0.0.title.localizedStandardCompare($1.0.title) == .orderedAscending
        }
        .prefix(30).map { $0.0 }
    }

    public static func completionTitle(
        for suggestion: SourceSearchSuggestion,
        configuration: SourceSearchConfiguration?,
        excluding: Bool
    ) -> String {
        let prefix = configuration?.fields
            .first(where: { $0.id == suggestion.fieldID })?
            .queryPrefix ?? "\(suggestion.fieldID):"
        return "\(excluding ? "-" : "")\(prefix)\(suggestion.title)"
    }

    public static func selecting(
        _ suggestion: SourceSearchSuggestion,
        configuration: SourceSearchConfiguration?,
        excluding: Bool,
        current: [SourceSearchSelection]
    ) -> [SourceSearchSelection] {
        guard let field = configuration?.fields.first(where: { $0.id == suggestion.fieldID }) else {
            return current
        }
        let selection = SourceSearchSelection(
            fieldID: field.id,
            value: suggestion.value,
            title: suggestion.title,
            polarity: excluding && field.supportsExclusion ? .exclude : .include
        )
        return current.filter {
            $0.fieldID.caseInsensitiveCompare(selection.fieldID) != .orderedSame
                || (field.maximumSelections != 1 && $0.value.caseInsensitiveCompare(selection.value) != .orderedSame)
        } + [selection]
    }
}
