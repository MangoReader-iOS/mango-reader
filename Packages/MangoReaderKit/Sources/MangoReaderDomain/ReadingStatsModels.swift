import Foundation

public struct TenPointRating: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: Int

    public init?(rawValue: Int) {
        guard (1 ... 10).contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(Int.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A rating must be an integer between 1 and 10."
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum TrackerReadingStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case planning
    case reading
    case completed
    case paused
    case dropped
    case rereading
}

public struct UserTitleState: Codable, Hashable, Sendable, Identifiable {
    public var workID: WorkID
    public var rating: TenPointRating?
    public var status: TrackerReadingStatus?
    public var startDate: TrackerDate?
    public var finishDate: TrackerDate?
    public var modifiedAt: Date
    public var deviceID: String

    public var id: WorkID { workID }
    public var isEmpty: Bool { rating == nil && status == nil && startDate == nil && finishDate == nil }

    public init(
        workID: WorkID,
        rating: TenPointRating? = nil,
        status: TrackerReadingStatus? = nil,
        startDate: TrackerDate? = nil,
        finishDate: TrackerDate? = nil,
        modifiedAt: Date = .now,
        deviceID: String
    ) {
        self.workID = workID
        self.rating = rating
        self.status = status
        self.startDate = startDate
        self.finishDate = finishDate
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
    }

    private enum CodingKeys: String, CodingKey { case workID, rating, status, startDate, finishDate, modifiedAt, deviceID }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workID, forKey: .workID)
        try container.encodeIfPresent(rating, forKey: .rating)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encode(startDate, forKey: .startDate)
        try container.encode(finishDate, forKey: .finishDate)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(deviceID, forKey: .deviceID)
    }
}

public enum ReadingStatsRange: Hashable, Sendable {
    case thisMonth
    case thisYear
    case allTime
    case custom(DateInterval)

    public func interval(now: Date = .now, calendar: Calendar = .current) -> DateInterval? {
        switch self {
        case .thisMonth:
            calendar.dateInterval(of: .month, for: now)
        case .thisYear:
            calendar.dateInterval(of: .year, for: now)
        case .allTime:
            nil
        case let .custom(interval):
            interval
        }
    }
}

public struct ReadingStatsSession: Hashable, Sendable, Identifiable {
    public var session: ReadingSession
    public var work: Work
    public var installment: Installment

    public var id: UUID { session.id }

    public init(session: ReadingSession, work: Work, installment: Installment) {
        precondition(session.workID == work.id)
        precondition(session.installmentID == installment.id)
        self.session = session
        self.work = work
        self.installment = installment
    }
}

public enum ReadingStatsBucketGranularity: String, Codable, Hashable, Sendable {
    case day
    case month
    case year
}

public struct ReadingStatsBucket: Hashable, Sendable, Identifiable {
    public var start: Date
    public var secondsRead: TimeInterval

    public var id: Date { start }

    public init(start: Date, secondsRead: TimeInterval) {
        self.start = start
        self.secondsRead = secondsRead
    }
}

public struct ReadingActivityDay: Hashable, Sendable, Identifiable {
    public var date: Date
    public var secondsRead: TimeInterval

    public var id: Date { date }

    public init(date: Date, secondsRead: TimeInterval) {
        self.date = date
        self.secondsRead = secondsRead
    }
}

public struct ReadingTitleStats: Hashable, Sendable, Identifiable {
    public var work: Work
    public var secondsRead: TimeInterval
    public var estimatedPagesRead: Double
    public var eligiblePaceSeconds: TimeInterval
    public var latestSession: ReadingSession
    public var latestInstallment: Installment
    public var titleState: UserTitleState?

    public var id: WorkID { work.id }
    public var pagesPerHour: Double? {
        guard eligiblePaceSeconds >= 300, estimatedPagesRead >= 5 else { return nil }
        return estimatedPagesRead / (eligiblePaceSeconds / 3_600)
    }

    public init(
        work: Work,
        secondsRead: TimeInterval,
        estimatedPagesRead: Double,
        eligiblePaceSeconds: TimeInterval,
        latestSession: ReadingSession,
        latestInstallment: Installment,
        titleState: UserTitleState?
    ) {
        self.work = work
        self.secondsRead = secondsRead
        self.estimatedPagesRead = estimatedPagesRead
        self.eligiblePaceSeconds = eligiblePaceSeconds
        self.latestSession = latestSession
        self.latestInstallment = latestInstallment
        self.titleState = titleState
    }
}

public struct ReadingKindStats: Hashable, Sendable, Identifiable {
    public var kind: ContentKind
    public var secondsRead: TimeInterval

    public var id: ContentKind { kind }

    public init(kind: ContentKind, secondsRead: TimeInterval) {
        self.kind = kind
        self.secondsRead = secondsRead
    }
}

public struct ReadingRatingStats: Hashable, Sendable, Identifiable {
    public var rating: TenPointRating
    public var count: Int

    public var id: TenPointRating { rating }

    public init(rating: TenPointRating, count: Int) {
        self.rating = rating
        self.count = count
    }
}

public struct ReadingStatsSnapshot: Equatable, Sendable {
    private static let maximumActivityWeekCount = 52

    public var range: ReadingStatsRange
    public var interval: DateInterval?
    public var insights: ReadingInsights
    public var currentStreakDays: Int
    public var estimatedPagesRead: Double
    public var eligiblePaceSeconds: TimeInterval
    public var bucketGranularity: ReadingStatsBucketGranularity
    public var buckets: [ReadingStatsBucket]
    public var activityInterval: DateInterval?
    public var activityDays: [ReadingActivityDay]
    public var isActivityIntervalCapped: Bool
    public var titles: [ReadingTitleStats]
    public var kinds: [ReadingKindStats]
    public var ratings: [ReadingRatingStats]
    public var averageRating: Double?

    public var pagesPerHour: Double? {
        guard eligiblePaceSeconds >= 300, estimatedPagesRead >= 5 else { return nil }
        return estimatedPagesRead / (eligiblePaceSeconds / 3_600)
    }

    public init(
        range: ReadingStatsRange,
        sessions: [ReadingStatsSession],
        titleStates: [WorkID: UserTitleState] = [:],
        streakSessions: [ReadingSession]? = nil,
        fallbackReadingUnitCounts: [InstallmentID: Int] = [:],
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        self.range = range
        let selectedInterval = range.interval(now: now, calendar: calendar)
        interval = selectedInterval
        let selected = sessions.filter { context in
            guard let interval = selectedInterval else { return true }
            return context.session.startedAt >= interval.start
                && context.session.startedAt < interval.end
        }
        let selectedSessions = selected.map(\.session)
        insights = ReadingInsights(sessions: selectedSessions, now: now, calendar: calendar)
        currentStreakDays = ReadingInsights(
            sessions: streakSessions ?? selectedSessions,
            now: now,
            calendar: calendar
        ).currentStreakDays

        let effectiveInterval = selectedInterval ?? Self.allTimeInterval(for: selectedSessions, now: now)
        bucketGranularity = Self.granularity(for: effectiveInterval)
        buckets = Self.makeBuckets(
            sessions: selectedSessions,
            granularity: bucketGranularity,
            calendar: calendar
        )
        let activity = Self.makeActivityDays(
            sessions: selectedSessions,
            selectedInterval: selectedInterval,
            now: now,
            calendar: calendar
        )
        activityInterval = activity.interval
        activityDays = activity.days
        isActivityIntervalCapped = activity.isCapped

        var pagesByWork: [WorkID: Double] = [:]
        var paceSecondsByWork: [WorkID: TimeInterval] = [:]
        var furthestProgressByInstallment: [InstallmentID: Double] = [:]
        var capturedCounts: [InstallmentID: Int] = [:]
        for session in (streakSessions ?? sessions.map(\.session)).sorted(by: { $0.startedAt < $1.startedAt }) {
            if let count = session.readingUnitCount, count > 0 {
                capturedCounts[session.installmentID] = count
            }
        }
        for context in selected.sorted(by: { $0.session.startedAt < $1.session.startedAt }) {
            let counts = [context.session.readingUnitCount, capturedCounts[context.installment.id],
                          context.installment.pageCount, fallbackReadingUnitCounts[context.installment.id]]
            guard let pageCount = counts.compactMap({ $0 }).first(where: { $0 > 0 }) else { continue }
            let startProgression = min(max(context.session.startProgression, 0), 1)
            let endProgression = min(max(context.session.endProgression, 0), 1)
            let positiveDelta = endProgression - startProgression
            guard positiveDelta > 0 else { continue }

            let installmentID = context.installment.id
            let previousFurthest = furthestProgressByInstallment[installmentID] ?? startProgression
            let newDelta = max(0, endProgression - max(startProgression, previousFurthest))
            furthestProgressByInstallment[installmentID] = max(previousFurthest, endProgression)
            guard newDelta > 0, context.session.secondsRead > 0 else { continue }

            let pages = Double(pageCount) * newDelta
            pagesByWork[context.work.id, default: 0] += pages
            // When a session overlaps previously read pages, count only the proportional
            // duration attached to new progress so rereads cannot distort reading speed.
            paceSecondsByWork[context.work.id, default: 0] +=
                context.session.secondsRead * (newDelta / positiveDelta)
        }
        estimatedPagesRead = pagesByWork.values.reduce(0, +)
        eligiblePaceSeconds = paceSecondsByWork.values.reduce(0, +)

        let groupedByWork = Dictionary(grouping: selected, by: { $0.work.id })
        titles = groupedByWork.values.compactMap { contexts in
            guard let latest = contexts.max(by: {
                ($0.session.endedAt ?? $0.session.startedAt)
                    < ($1.session.endedAt ?? $1.session.startedAt)
            }) else { return nil }
            return ReadingTitleStats(
                work: latest.work,
                secondsRead: contexts.reduce(0) { $0 + max(0, $1.session.secondsRead) },
                estimatedPagesRead: pagesByWork[latest.work.id, default: 0],
                eligiblePaceSeconds: paceSecondsByWork[latest.work.id, default: 0],
                latestSession: latest.session,
                latestInstallment: latest.installment,
                titleState: titleStates[latest.work.id]
            )
        }
        .sorted {
            if $0.secondsRead == $1.secondsRead {
                return $0.work.title.localizedCaseInsensitiveCompare($1.work.title) == .orderedAscending
            }
            return $0.secondsRead > $1.secondsRead
        }

        let kindTotals = Dictionary(grouping: selected, by: { $0.work.kind })
            .mapValues { contexts in
                contexts.reduce(0) { $0 + max(0, $1.session.secondsRead) }
            }
        kinds = kindTotals.map { ReadingKindStats(kind: $0.key, secondsRead: $0.value) }
            .sorted { $0.secondsRead > $1.secondsRead }

        let selectedWorkIDs = Set(groupedByWork.keys)
        let selectedRatings = titleStates.values.compactMap { state -> TenPointRating? in
            selectedWorkIDs.contains(state.workID) ? state.rating : nil
        }
        ratings = Dictionary(grouping: selectedRatings, by: { $0 })
            .map { ReadingRatingStats(rating: $0.key, count: $0.value.count) }
            .sorted { $0.rating < $1.rating }
        averageRating = selectedRatings.isEmpty
            ? nil
            : selectedRatings.reduce(0) { $0 + Double($1.rawValue) } / Double(selectedRatings.count)
    }

    private static func allTimeInterval(
        for sessions: [ReadingSession],
        now: Date
    ) -> DateInterval {
        let start = sessions.map(\.startedAt).min() ?? now
        let end = max(now, sessions.compactMap(\.endedAt).max() ?? now)
        return DateInterval(start: start, end: max(end, start.addingTimeInterval(1)))
    }

    private static func granularity(for interval: DateInterval) -> ReadingStatsBucketGranularity {
        let days = interval.duration / 86_400
        if days <= 90 { return .day }
        if days <= 730 { return .month }
        return .year
    }

    private static func makeBuckets(
        sessions: [ReadingSession],
        granularity: ReadingStatsBucketGranularity,
        calendar: Calendar
    ) -> [ReadingStatsBucket] {
        let grouped = Dictionary(grouping: sessions.filter { $0.secondsRead > 0 }) { session in
            switch granularity {
            case .day:
                calendar.startOfDay(for: session.startedAt)
            case .month:
                calendar.dateInterval(of: .month, for: session.startedAt)?.start
                    ?? calendar.startOfDay(for: session.startedAt)
            case .year:
                calendar.dateInterval(of: .year, for: session.startedAt)?.start
                    ?? calendar.startOfDay(for: session.startedAt)
            }
        }
        return grouped.map { start, sessions in
            ReadingStatsBucket(
                start: start,
                secondsRead: sessions.reduce(0) { $0 + $1.secondsRead }
            )
        }
        .sorted { $0.start < $1.start }
    }

    private static func makeActivityDays(
        sessions: [ReadingSession],
        selectedInterval: DateInterval?,
        now: Date,
        calendar: Calendar
    ) -> (interval: DateInterval?, days: [ReadingActivityDay], isCapped: Bool) {
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else {
            return (nil, [], false)
        }

        let candidateStart: Date
        if let selectedInterval {
            candidateStart = calendar.startOfDay(for: selectedInterval.start)
        } else if let earliestSession = sessions.map(\.startedAt).min() {
            candidateStart = calendar.startOfDay(for: earliestSession)
        } else {
            return (nil, [], false)
        }

        let requestedEnd = selectedInterval.map {
            normalizedExclusiveDayEnd($0.end, calendar: calendar)
        } ?? tomorrow
        let candidateEnd = min(requestedEnd, tomorrow)
        guard candidateStart < candidateEnd,
              let lastIncludedDay = calendar.date(byAdding: .day, value: -1, to: candidateEnd),
              let finalWeekStart = mondayStartOfWeek(containing: lastIncludedDay, calendar: calendar),
              let cappedStart = calendar.date(
                  byAdding: .weekOfYear,
                  value: -(maximumActivityWeekCount - 1),
                  to: finalWeekStart
              )
        else {
            return (nil, [], false)
        }

        let start = max(candidateStart, cappedStart)
        let isCapped = start > candidateStart
        let totals = Dictionary(grouping: sessions.filter {
            $0.secondsRead > 0 && $0.startedAt >= start && $0.startedAt < candidateEnd
        }) { session in
            calendar.startOfDay(for: session.startedAt)
        }
        .mapValues { sessions in
            sessions.reduce(0) { $0 + max(0, $1.secondsRead) }
        }

        var days: [ReadingActivityDay] = []
        var cursor = start
        while cursor < candidateEnd {
            days.append(ReadingActivityDay(
                date: cursor,
                secondsRead: totals[cursor, default: 0]
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor),
                  next > cursor
            else { break }
            cursor = next
        }

        return (
            DateInterval(start: start, end: candidateEnd),
            days,
            isCapped
        )
    }

    private static func normalizedExclusiveDayEnd(
        _ end: Date,
        calendar: Calendar
    ) -> Date {
        let startOfEndDay = calendar.startOfDay(for: end)
        guard end > startOfEndDay else { return end }
        return calendar.date(byAdding: .day, value: 1, to: startOfEndDay) ?? end
    }

    private static func mondayStartOfWeek(
        containing date: Date,
        calendar: Calendar
    ) -> Date? {
        let start = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: start)
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: start)
    }
}
