import Foundation

public enum CloudFilePolicy: String, Codable, CaseIterable, Sendable {
    case inheritGlobal
    case localOnly
    case syncOriginal
}

public struct LibraryEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var workID: WorkID
    public var addedAt: Date
    public var lastOpenedAt: Date?
    public var isPinned: Bool
    public var isHidden: Bool
    public var unreadCount: Int
    public var downloadedCount: Int
    public var cloudFilePolicy: CloudFilePolicy

    public init(
        id: UUID = UUID(),
        workID: WorkID,
        addedAt: Date = .now,
        lastOpenedAt: Date? = nil,
        isPinned: Bool = false,
        isHidden: Bool = false,
        unreadCount: Int = 0,
        downloadedCount: Int = 0,
        cloudFilePolicy: CloudFilePolicy = .inheritGlobal
    ) {
        self.id = id
        self.workID = workID
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.isPinned = isPinned
        self.isHidden = isHidden
        self.unreadCount = unreadCount
        self.downloadedCount = downloadedCount
        self.cloudFilePolicy = cloudFilePolicy
    }
}

public struct Category: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var sortIndex: Int
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), name: String, sortIndex: Int = 0, createdAt: Date = .now, modifiedAt: Date = .now) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

public enum LibrarySort: String, Codable, CaseIterable, Sendable {
    case title
    case recentlyAdded
    case recentlyRead
    case unread
    case lastUpdated
}

public struct SavedFilter: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var query: String
    public var kinds: Set<ContentKind>
    public var categoryIDs: Set<UUID>
    public var sort: LibrarySort
    public var isSmart: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        query: String = "",
        kinds: Set<ContentKind> = [],
        categoryIDs: Set<UUID> = [],
        sort: LibrarySort = .title,
        isSmart: Bool = false
    ) {
        self.id = id
        self.name = name
        self.query = query
        self.kinds = kinds
        self.categoryIDs = categoryIDs
        self.sort = sort
        self.isSmart = isSmart
    }
}

public struct ReadingSession: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var workID: WorkID
    public var installmentID: InstallmentID
    public var startedAt: Date
    public var endedAt: Date?
    public var secondsRead: TimeInterval
    public var startProgression: Double
    public var endProgression: Double
    /// Image/PDF pages or stable EPUB positions known by the reader for this session.
    public var readingUnitCount: Int?

    public init(
        id: UUID = UUID(),
        workID: WorkID,
        installmentID: InstallmentID,
        startedAt: Date = .now,
        endedAt: Date? = nil,
        secondsRead: TimeInterval = 0,
        startProgression: Double = 0,
        endProgression: Double = 0,
        readingUnitCount: Int? = nil
    ) {
        self.id = id
        self.workID = workID
        self.installmentID = installmentID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.secondsRead = secondsRead
        self.startProgression = startProgression
        self.endProgression = endProgression
        self.readingUnitCount = readingUnitCount.flatMap { $0 > 0 ? $0 : nil }
    }
}

public struct Bookmark: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var workID: WorkID
    public var installmentID: InstallmentID
    public var locator: ReadingLocator
    public var title: String
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), workID: WorkID, installmentID: InstallmentID, locator: ReadingLocator, title: String, createdAt: Date = .now, modifiedAt: Date = .now) {
        self.id = id
        self.workID = workID
        self.installmentID = installmentID
        self.locator = locator
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

public enum ReaderHighlightColor: String, Codable, CaseIterable, Hashable, Sendable {
    case yellow
    case green
    case orange
    case pink
}

public struct Annotation: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var workID: WorkID
    public var installmentID: InstallmentID
    public var locator: ReadingLocator
    public var selectedText: String?
    public var note: String
    public var highlightColor: ReaderHighlightColor
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), workID: WorkID, installmentID: InstallmentID, locator: ReadingLocator, selectedText: String? = nil, note: String = "", highlightColor: ReaderHighlightColor = .yellow, createdAt: Date = .now, modifiedAt: Date = .now) {
        self.id = id
        self.workID = workID
        self.installmentID = installmentID
        self.locator = locator
        self.selectedText = selectedText
        self.note = note
        self.highlightColor = highlightColor
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

public enum DownloadState: String, Codable, CaseIterable, Sendable {
    case queued
    case downloading
    case paused
    case completed
    case failed
    case cancelled
}

public struct DownloadJob: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var workID: WorkID
    public var installmentID: InstallmentID
    public var state: DownloadState
    public var priority: Int
    public var completedBytes: Int64
    public var totalBytes: Int64?
    public var localRelativePath: String?
    public var lastError: String?
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), workID: WorkID, installmentID: InstallmentID, state: DownloadState = .queued, priority: Int = 0, completedBytes: Int64 = 0, totalBytes: Int64? = nil, localRelativePath: String? = nil, lastError: String? = nil, createdAt: Date = .now, modifiedAt: Date = .now) {
        self.id = id
        self.workID = workID
        self.installmentID = installmentID
        self.state = state
        self.priority = priority
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.localRelativePath = localRelativePath
        self.lastError = lastError
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

public struct Tombstone: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var entityType: String
    public var entityID: String
    public var deletedAt: Date
    public var deviceID: String

    public init(id: UUID = UUID(), entityType: String, entityID: String, deletedAt: Date = .now, deviceID: String) {
        self.id = id
        self.entityType = entityType
        self.entityID = entityID
        self.deletedAt = deletedAt
        self.deviceID = deviceID
    }
}

/// User-authored automation preferences. The app evaluates these rules during
/// foreground maintenance and from its registered background-processing task.
public struct LibraryAutomationRules: Codable, Equatable, Sendable {
    public var checksForUpdates: Bool
    public var downloadsNewInstallments: Bool
    public var deletesCompletedDownloads: Bool
    public var deleteDelayDays: Int

    public init(
        checksForUpdates: Bool = false,
        downloadsNewInstallments: Bool = false,
        deletesCompletedDownloads: Bool = false,
        deleteDelayDays: Int = 7
    ) {
        self.checksForUpdates = checksForUpdates
        self.downloadsNewInstallments = downloadsNewInstallments
        self.deletesCompletedDownloads = deletesCompletedDownloads
        self.deleteDelayDays = min(max(deleteDelayDays, 0), 365)
    }

    public static let disabled = LibraryAutomationRules()
}

/// A deterministic aggregate of locally recorded reading sessions. Incognito
/// sessions never enter this calculation because they are never persisted.
public struct ReadingInsights: Equatable, Sendable {
    public var totalSeconds: TimeInterval
    public var sessionCount: Int
    public var distinctWorkCount: Int
    public var daysRead: Int
    public var currentStreakDays: Int
    public var longestSessionSeconds: TimeInterval
    public var secondsByWork: [WorkID: TimeInterval]

    public var averageSessionSeconds: TimeInterval {
        sessionCount == 0 ? 0 : totalSeconds / Double(sessionCount)
    }

    public init(
        sessions: [ReadingSession],
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        let completedSessions = sessions.filter { $0.secondsRead > 0 }
        sessionCount = completedSessions.count
        totalSeconds = completedSessions.reduce(0) { $0 + $1.secondsRead }
        longestSessionSeconds = completedSessions.map(\.secondsRead).max() ?? 0
        secondsByWork = Dictionary(grouping: completedSessions, by: \.workID)
            .mapValues { sessions in sessions.reduce(0) { $0 + $1.secondsRead } }
        distinctWorkCount = secondsByWork.count

        let readingDays = Set(completedSessions.map { calendar.startOfDay(for: $0.startedAt) })
        daysRead = readingDays.count

        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        var cursor = readingDays.contains(today) ? today : yesterday
        var streak = 0
        while readingDays.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        currentStreakDays = streak
    }
}
