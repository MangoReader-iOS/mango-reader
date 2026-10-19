import Foundation

/// Calendar components, not an instant. Partial service dates remain partial.
public struct TrackerDate: Codable, Hashable, Sendable {
    public var year: Int?
    public var month: Int?
    public var day: Int?

    public init(year: Int? = nil, month: Int? = nil, day: Int? = nil) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let components = gregorian.dateComponents([.year, .month, .day], from: date)
        self.init(year: components.year, month: components.month, day: components.day)
    }

    public var completeDate: Date? {
        guard let year, let month, let day else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        guard let date = calendar.date(from: components) else { return nil }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year, resolved.month == month, resolved.day == day else { return nil }
        return date
    }

    public var isValid: Bool {
        guard year != nil || month != nil || day != nil else { return false }
        if let year, !(1 ... 9999).contains(year) { return false }
        if let month, !(1 ... 12).contains(month) { return false }
        if let day, !(1 ... 31).contains(day) { return false }
        return year == nil || month == nil || day == nil || completeDate != nil
    }

    public static func areOrdered(start: Self?, finish: Self?) -> Bool {
        guard let start = start?.completeDate, let finish = finish?.completeDate else { return true }
        return start <= finish
    }
}

public struct TrackerCapabilities: Codable, Hashable, Sendable {
    public var supportsDateUpdates: Bool
    public init(supportsDateUpdates: Bool = false) { self.supportsDateUpdates = supportsDateUpdates }
}

/// Missing keys leave a service date untouched; explicit null clears it.
public struct TrackerDateUpdates: Codable, Hashable, Sendable {
    public var startDate: TrackerDate?
    public var finishDate: TrackerDate?
    public var fields: Set<TrackerSyncField>

    public init(startDate: TrackerDate?, finishDate: TrackerDate?, fields: Set<TrackerSyncField> = [.startDate, .finishDate]) {
        self.startDate = startDate
        self.finishDate = finishDate
        self.fields = fields.intersection([.startDate, .finishDate])
    }

    private enum CodingKeys: String, CodingKey { case startDate, finishDate }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startDate = try container.decodeIfPresent(TrackerDate.self, forKey: .startDate)
        finishDate = try container.decodeIfPresent(TrackerDate.self, forKey: .finishDate)
        fields = []
        if container.contains(.startDate) { fields.insert(.startDate) }
        if container.contains(.finishDate) { fields.insert(.finishDate) }
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if fields.contains(.startDate) { try container.encode(startDate, forKey: .startDate) }
        if fields.contains(.finishDate) { try container.encode(finishDate, forKey: .finishDate) }
    }
}

public struct TrackerSyncSnapshot: Codable, Hashable, Sendable {
    public var chapter: Double?
    public var volume: Double?
    public var status: TrackerReadingStatus?
    /// Tracker wire scores remain `Double` so an unrepresentable remote score
    /// can be surfaced as a conflict instead of rounded.
    public var score: Double?
    public var startDate: TrackerDate?
    public var finishDate: TrackerDate?

    public init(
        chapter: Double? = nil,
        volume: Double? = nil,
        status: TrackerReadingStatus? = nil,
        score: Double? = nil,
        startDate: TrackerDate? = nil,
        finishDate: TrackerDate? = nil
    ) {
        self.chapter = chapter
        self.volume = volume
        self.status = status
        self.score = score
        self.startDate = startDate
        self.finishDate = finishDate
    }

    public init(_ progress: TrackerProgress) {
        self.init(
            chapter: progress.chapter,
            volume: progress.volume,
            status: progress.status,
            score: progress.score,
            startDate: progress.dateUpdates?.fields.contains(.startDate) == true ? progress.dateUpdates?.startDate : progress.startDate,
            finishDate: progress.dateUpdates?.fields.contains(.finishDate) == true ? progress.dateUpdates?.finishDate : progress.finishDate
        )
    }

    public mutating func copy(_ field: TrackerSyncField, from snapshot: Self) {
        switch field {
        case .rating: score = snapshot.score
        case .chapter: chapter = snapshot.chapter
        case .volume: volume = snapshot.volume
        case .status: status = snapshot.status
        case .startDate: startDate = snapshot.startDate
        case .finishDate: finishDate = snapshot.finishDate
        }
    }
}

public enum TrackerSyncField: String, Codable, CaseIterable, Hashable, Sendable {
    case rating
    case chapter
    case volume
    case status
    case startDate
    case finishDate
}

public enum TrackerSyncValue: Codable, Hashable, Sendable {
    case number(Double)
    case status(TrackerReadingStatus)
    case date(TrackerDate)
    case none
}

public struct TrackerFieldConflict: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var field: TrackerSyncField
    public var mankoValue: TrackerSyncValue
    public var trackerValue: TrackerSyncValue
    public var detectedAt: Date

    public init(
        id: UUID = UUID(),
        field: TrackerSyncField,
        mankoValue: TrackerSyncValue,
        trackerValue: TrackerSyncValue,
        detectedAt: Date = .now
    ) {
        self.id = id
        self.field = field
        self.mankoValue = mankoValue
        self.trackerValue = trackerValue
        self.detectedAt = detectedAt
    }
}

public struct TrackerLink: Codable, Hashable, Sendable, Identifiable {
    public var workID: WorkID
    public var trackerID: TrackerID
    public var remoteWorkID: String
    public var remoteTitle: String
    public var lastSynced: TrackerSyncSnapshot
    public var lastPulledAt: Date?
    public var conflicts: [TrackerFieldConflict]
    public var lastRemote: TrackerProgress?
    public var supportsDateUpdates: Bool?
    public var generation: UUID?

    public var id: String { "\(workID.rawValue.uuidString):\(trackerID.rawValue)" }
    public var isStale: Bool {
        guard let lastPulledAt else { return true }
        return Date.now.timeIntervalSince(lastPulledAt) >= 15 * 60
    }

    public init(
        workID: WorkID,
        trackerID: TrackerID,
        remoteWorkID: String,
        remoteTitle: String,
        lastSynced: TrackerSyncSnapshot = .init(),
        lastPulledAt: Date? = nil,
        conflicts: [TrackerFieldConflict] = [],
        lastRemote: TrackerProgress? = nil,
        supportsDateUpdates: Bool? = nil,
        generation: UUID? = UUID()
    ) {
        self.workID = workID
        self.trackerID = trackerID
        self.remoteWorkID = remoteWorkID
        self.remoteTitle = remoteTitle
        self.lastSynced = lastSynced
        self.lastPulledAt = lastPulledAt
        self.conflicts = conflicts
        self.lastRemote = lastRemote
        self.supportsDateUpdates = supportsDateUpdates
        self.generation = generation
    }
}

public enum TrackerLinkSyncState: String, Codable, Hashable, Sendable {
    case notLinked
    case synced
    case progressAvailable
    case pending
    case conflict
    case error
}

public struct TrackerMergeResult: Hashable, Sendable {
    public var merged: TrackerSyncSnapshot
    public var fieldsToPush: Set<TrackerSyncField>
    public var fieldsPulled: Set<TrackerSyncField>
    public var conflicts: [TrackerFieldConflict]

    public init(
        merged: TrackerSyncSnapshot,
        fieldsToPush: Set<TrackerSyncField>,
        fieldsPulled: Set<TrackerSyncField>,
        conflicts: [TrackerFieldConflict]
    ) {
        self.merged = merged
        self.fieldsToPush = fieldsToPush
        self.fieldsPulled = fieldsPulled
        self.conflicts = conflicts
    }

    /// Pending writes and unresolved conflicts have not been acknowledged remotely.
    public func mergeBaseline(previous: TrackerSyncSnapshot) -> TrackerSyncSnapshot {
        var baseline = merged
        for field in fieldsToPush.union(conflicts.map(\.field)) {
            baseline.copy(field, from: previous)
        }
        return baseline
    }
}

public enum TrackerThreeWayMerge {
    public static func merge(
        base: TrackerSyncSnapshot,
        local: TrackerSyncSnapshot,
        remote: TrackerSyncSnapshot,
        now: Date = .now,
        syncDates: Bool = false
    ) -> TrackerMergeResult {
        var merged = base
        var push: Set<TrackerSyncField> = []
        var pulled: Set<TrackerSyncField> = []
        var conflicts: [TrackerFieldConflict] = []

        resolve(
            field: .rating,
            base: value(base.score),
            local: value(local.score),
            remote: value(remote.score),
            assign: { merged.score = $0.number },
            push: &push,
            pulled: &pulled,
            conflicts: &conflicts,
            now: now
        )
        resolve(
            field: .chapter,
            base: value(base.chapter),
            local: value(local.chapter),
            remote: value(remote.chapter),
            assign: { merged.chapter = $0.number },
            push: &push,
            pulled: &pulled,
            conflicts: &conflicts,
            now: now
        )
        resolve(
            field: .volume,
            base: value(base.volume),
            local: value(local.volume),
            remote: value(remote.volume),
            assign: { merged.volume = $0.number },
            push: &push,
            pulled: &pulled,
            conflicts: &conflicts,
            now: now
        )
        resolve(
            field: .status,
            base: value(base.status),
            local: value(local.status),
            remote: value(remote.status),
            assign: { merged.status = $0.readingStatus },
            push: &push,
            pulled: &pulled,
            conflicts: &conflicts,
            now: now
        )
        if syncDates {
            resolve(field: .startDate, base: value(base.startDate), local: value(local.startDate), remote: value(remote.startDate),
                    assign: { merged.startDate = $0.readingDate }, push: &push, pulled: &pulled, conflicts: &conflicts, now: now)
            resolve(field: .finishDate, base: value(base.finishDate), local: value(local.finishDate), remote: value(remote.finishDate),
                    assign: { merged.finishDate = $0.readingDate }, push: &push, pulled: &pulled, conflicts: &conflicts, now: now)
        }
        return TrackerMergeResult(
            merged: merged,
            fieldsToPush: push,
            fieldsPulled: pulled,
            conflicts: conflicts
        )
    }

    private static func resolve(
        field: TrackerSyncField,
        base: TrackerSyncValue,
        local: TrackerSyncValue,
        remote: TrackerSyncValue,
        assign: (TrackerSyncValue) -> Void,
        push: inout Set<TrackerSyncField>,
        pulled: inout Set<TrackerSyncField>,
        conflicts: inout [TrackerFieldConflict],
        now: Date
    ) {
        if local == remote {
            assign(local)
        } else if local == base {
            assign(remote)
            pulled.insert(field)
        } else if remote == base {
            assign(local)
            push.insert(field)
        } else {
            assign(local)
            conflicts.append(TrackerFieldConflict(
                field: field,
                mankoValue: local,
                trackerValue: remote,
                detectedAt: now
            ))
        }
    }

    private static func value(_ number: Double?) -> TrackerSyncValue {
        number.map(TrackerSyncValue.number) ?? .none
    }

    private static func value(_ status: TrackerReadingStatus?) -> TrackerSyncValue {
        status.map(TrackerSyncValue.status) ?? .none
    }

    private static func value(_ date: TrackerDate?) -> TrackerSyncValue {
        date.map(TrackerSyncValue.date) ?? .none
    }
}

private extension TrackerSyncValue {
    var readingDate: TrackerDate? {
        guard case let .date(value) = self else { return nil }
        return value
    }
    var number: Double? {
        guard case let .number(value) = self else { return nil }
        return value
    }

    var readingStatus: TrackerReadingStatus? {
        guard case let .status(value) = self else { return nil }
        return value
    }
}


public extension TrackerSyncSnapshot {
    func value(for field: TrackerSyncField) -> TrackerSyncValue {
        switch field {
        case .chapter: chapter.map(TrackerSyncValue.number) ?? .none
        case .volume: volume.map(TrackerSyncValue.number) ?? .none
        case .rating: score.map(TrackerSyncValue.number) ?? .none
        case .status: status.map(TrackerSyncValue.status) ?? .none
        case .startDate: startDate.map(TrackerSyncValue.date) ?? .none
        case .finishDate: finishDate.map(TrackerSyncValue.date) ?? .none
        }
    }
}

public enum TrackerChapterMapping {
    public static func issue(in chapters: [Installment]) -> String? {
        guard !chapters.isEmpty, chapters.contains(where: { $0.number != nil }) else {
            return "Chapter numbers are unavailable. Progress cannot be matched safely."
        }
        if chapters.contains(where: { $0.number == nil }) {
            return "Some chapter numbers are unavailable. Progress cannot be matched safely."
        }
        if chapters.contains(where: { $0.volume.map { !$0.isFinite || $0 < 0 } == true }) {
            return "Some volume numbers are invalid. Progress cannot be matched safely."
        }
        if chapters.contains(where: { $0.number.map { !$0.isFinite || $0 < 0 } == true }) {
            return "Some chapter numbers are invalid. Progress cannot be matched safely."
        }
        let groups = Dictionary(grouping: chapters.filter { $0.number != nil }, by: { $0.number! })
        if groups.values.contains(where: { Set($0.map(\.volume)).count > 1 }) {
            return "Chapter numbers repeat across volumes. Progress needs a verified numbering match."
        }
        return nil
    }

    public static func completedChapter(in chapters: [Installment], progresses: [ReadingProgress]) -> Double? {
        guard issue(in: chapters) == nil else { return nil }
        let completed = Set(progresses.filter { $0.highestProgression >= 1 }.map(\.installmentID))
        // Integer trackers cannot represent a fractional milestone without guessing.
        return chapters.filter { completed.contains($0.id) }.compactMap(\.number)
            .filter { $0.rounded(.down) == $0 }.max() ?? 0
    }

    public static func importChapters(boundary: Double, chapters: [Installment]) -> [Installment]? {
        guard boundary.isFinite, boundary >= 0, issue(in: chapters) == nil else { return nil }
        return ReaderChapterPolicy.ordered(chapters.filter { $0.number.map { $0 <= boundary } == true })
    }
}

/// Keeps a reviewed import bound to the exact catalogue, progress, link, and remote value.
public struct TrackerImportPreview: Sendable, Equatable {
    public var link: TrackerLink
    public var remote: TrackerSyncSnapshot
    public var chapters: [Installment]
    public var progresses: [ReadingProgress]
    public var sessions: [ReadingSession]
    public var affectedIDs: Set<InstallmentID>
    public var continuation: Installment?

    public init(link: TrackerLink, remote: TrackerSyncSnapshot, chapters: [Installment],
                progresses: [ReadingProgress], affectedIDs: Set<InstallmentID>, continuation: Installment?, sessions: [ReadingSession] = []) {
        self.link = link; self.remote = remote; self.chapters = chapters
        self.progresses = progresses; self.sessions = sessions; self.affectedIDs = affectedIDs; self.continuation = continuation
    }
}

public struct TrackerDeliveryDecision: Sendable {
    public var fieldsToSend: Set<TrackerSyncField> = []
    public var acknowledged: Set<TrackerSyncField> = []
    public var conflicts: Set<TrackerSyncField> = []

    public static func reconcile(update: TrackerProgress, baseline: TrackerSyncSnapshot?,
                                 remote: TrackerSyncSnapshot) -> Self {
        var result = Self()
        let proposed = TrackerSyncSnapshot(update)
        guard let baseline else { result.conflicts = update.updateFields; return result }
        for field in update.updateFields {
            let value = proposed.value(for: field)
            let current = remote.value(for: field)
            if value == current { result.acknowledged.insert(field); continue }
            if field == .chapter || field == .volume {
                guard case let .number(number) = value, number.isFinite, number >= 0,
                      number.rounded(.down) == number else {
                    result.conflicts.insert(field); continue
                }
                let remoteNumber: Double
                switch current {
                case .none: remoteNumber = 0
                case let .number(value) where value.isFinite && value >= 0: remoteNumber = value
                default: result.conflicts.insert(field); continue
                }
                // A newer remote milestone is preserved, never replaced by a queued lower value.
                if number <= remoteNumber { result.acknowledged.insert(field) }
                else if current == baseline.value(for: field) { result.fieldsToSend.insert(field) }
                else { result.conflicts.insert(field) }
            } else if current == baseline.value(for: field) {
                result.fieldsToSend.insert(field)
            } else {
                result.conflicts.insert(field)
            }
        }
        return result
    }
}

public extension TrackerProgress {
    func updatingOnly(_ fields: Set<TrackerSyncField>) -> Self {
        var value = self
        value.fieldsToUpdate = fields
        if var dates = value.dateUpdates {
            dates.fields.formIntersection(fields)
            value.dateUpdates = dates.fields.isEmpty ? nil : dates
        }
        return value
    }
}
