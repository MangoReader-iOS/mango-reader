import Foundation

public enum ReaderChapterPolicy {
    public static func ordered(_ chapters: [Installment]) -> [Installment] {
        chapters.sorted(by: precedes)
    }

    /// A total order: missing metadata never changes which comparison is used.
    public static func precedes(_ lhs: Installment, _ rhs: Installment) -> Bool {
        for (a, b) in [(lhs.volume, rhs.volume), (lhs.number, rhs.number)] {
            let a = a.flatMap { $0.isFinite ? $0 : nil }
            let b = b.flatMap { $0.isFinite ? $0 : nil }
            if let a, let b, a != b { return a < b }
            if (a != nil) != (b != nil) { return a != nil }
        }
        let a = lhs.publishedAt.flatMap { $0.timeIntervalSince1970.isFinite ? $0 : nil }
        let b = rhs.publishedAt.flatMap { $0.timeIntervalSince1970.isFinite ? $0 : nil }
        if let a, let b, a != b { return a < b }
        if (a != nil) != (b != nil) { return a != nil }
        let comparison = lhs.title.localizedStandardCompare(rhs.title)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id.description < rhs.id.description
    }

    public static func areDuplicates(_ lhs: Installment, _ rhs: Installment) -> Bool {
        guard lhs.workID == rhs.workID, let number = lhs.number, let other = rhs.number else { return false }
        return number == other && lhs.volume == rhs.volume && lhs.languageCode == rhs.languageCode
    }

    public static func adjacent(to current: Installment, in chapters: [Installment], forward: Bool, skipDuplicates: Bool) -> Installment? {
        let ordered = ordered(chapters)
        guard let start = ordered.firstIndex(where: { $0.id == current.id }) else { return nil }
        let candidates = forward ? Array(ordered.dropFirst(start + 1)) : Array(ordered.prefix(start).reversed())
        guard let first = candidates.first(where: { !skipDuplicates || !areDuplicates($0, current) }) else { return nil }
        guard skipDuplicates, let scanlators = current.scanlators, !scanlators.isEmpty else { return first }
        let group = candidates.prefix { $0.id == first.id || areDuplicates($0, current) || areDuplicates($0, first) }
        return group.first { areDuplicates($0, first) && !Set($0.scanlators ?? []).isDisjoint(with: scanlators) } ?? first
    }
}
