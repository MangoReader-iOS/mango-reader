import Foundation

/// Learned provider values, never a substitute for provider validation.
public struct SourceSuggestionIndex: Codable, Sendable {
    public static let capacity = 5_000
    public static let lifetime: TimeInterval = 30 * 24 * 60 * 60

    private struct Entry: Codable, Sendable {
        var suggestion: SourceSearchSuggestion
        var seenAt: Date
        var usedAt: Date?
        var uses = 0
        var titleKey: String
        var valueKey: String
        var titleWords: [String]
        var valueWords: [String]
    }
    private var entries: [String: Entry] = [:]
    public init() {}
    public var count: Int { entries.count }

    public mutating func merge(_ saved: Self, at now: Date = .now) {
        for entry in saved.entries.values where now.timeIntervalSince(recency(entry)) < Self.lifetime {
            guard Self.isValid(entry.suggestion), entries[entry.suggestion.id] == nil else { continue }
            entries[entry.suggestion.id] = entry
        }
        learn([], at: now)
    }

    public mutating func learn(_ suggestions: [SourceSearchSuggestion], at now: Date = .now) {
        prune(at: now)
        for suggestion in suggestions where Self.isValid(suggestion) {
            let old = entries[suggestion.id]
            let title = SourceSearchMatching.normalized(suggestion.title)
            let value = SourceSearchMatching.normalized(suggestion.value)
            entries[suggestion.id] = Entry(suggestion: suggestion, seenAt: now,
                usedAt: old?.usedAt, uses: old?.uses ?? 0,
                titleKey: title, valueKey: value,
                titleWords: title.split(separator: " ").map(String.init),
                valueWords: value.split(separator: " ").map(String.init))
        }
        if entries.count > Self.capacity {
            let retained = entries.sorted { recency($0.value) > recency($1.value) }.prefix(Self.capacity)
            entries = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
        }
    }

    public mutating func selected(_ suggestion: SourceSearchSuggestion, at now: Date = .now) {
        learn([suggestion], at: now)
        guard var entry = entries[suggestion.id] else { return }
        entry.uses = min(entry.uses + 1, 1_000_000)
        entry.usedAt = now
        entries[suggestion.id] = entry
    }

    public mutating func prune(at now: Date = .now) {
        entries = entries.filter { now.timeIntervalSince(recency($0.value)) < Self.lifetime }
    }

    public func suggestions(query: String, fieldID: String? = nil, limit: Int = 30,
                            at now: Date = .now) -> [SourceSearchSuggestion] {
        let query = SourceSearchMatching.normalized(query)
        let matcher = SourceSearchMatching.PreparedQuery(query)
        return entries.values.compactMap { entry -> (Entry, Int)? in
            guard (fieldID == nil || fieldID == entry.suggestion.fieldID),
                  now.timeIntervalSince(recency(entry)) < Self.lifetime,
                  !query.isEmpty || entry.usedAt != nil else { return nil }
            let titleScore = matcher.score(candidate: entry.titleKey, words: entry.titleWords) ?? Int.max
            let score = entry.titleKey == entry.valueKey ? titleScore : min(titleScore,
                matcher.score(candidate: entry.valueKey, words: entry.valueWords) ?? Int.max)
            return score == Int.max ? nil : (entry, score)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.0.uses != $1.0.uses { return $0.0.uses > $1.0.uses }
            if $0.0.usedAt != $1.0.usedAt { return ($0.0.usedAt ?? .distantPast) > ($1.0.usedAt ?? .distantPast) }
            return $0.0.suggestion.title.localizedStandardCompare($1.0.suggestion.title) == .orderedAscending
        }.prefix(max(0, min(limit, 30))).map { $0.0.suggestion }
    }

    private func recency(_ entry: Entry) -> Date { max(entry.seenAt, entry.usedAt ?? .distantPast) }
    private static func isValid(_ suggestion: SourceSearchSuggestion) -> Bool {
        !suggestion.fieldID.isEmpty && suggestion.fieldID.count <= 64
            && !suggestion.value.isEmpty && suggestion.value.count <= 256
            && !suggestion.title.isEmpty && suggestion.title.count <= 256
            && (suggestion.subtitle?.count ?? 0) <= 256
    }
}
