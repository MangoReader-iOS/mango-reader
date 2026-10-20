import Foundation

public enum LibraryAutomationTrigger: String, Codable, CaseIterable, Sendable {
    case launch
    case foreground
    case manual
    case backgroundProcessing
    case readingCompleted
}

public struct LibraryAutomationRunReport: Codable, Equatable, Sendable {
    public var trigger: LibraryAutomationTrigger
    public var startedAt: Date
    public var finishedAt: Date
    public var checkedWorkCount: Int
    public var updatedWorkCount: Int
    public var queuedDownloadCount: Int
    public var deletedDownloadCount: Int
    public var failureCount: Int

    public init(
        trigger: LibraryAutomationTrigger,
        startedAt: Date,
        finishedAt: Date,
        checkedWorkCount: Int = 0,
        updatedWorkCount: Int = 0,
        queuedDownloadCount: Int = 0,
        deletedDownloadCount: Int = 0,
        failureCount: Int = 0
    ) {
        self.trigger = trigger
        self.startedAt = startedAt
        self.finishedAt = max(startedAt, finishedAt)
        self.checkedWorkCount = max(0, checkedWorkCount)
        self.updatedWorkCount = max(0, updatedWorkCount)
        self.queuedDownloadCount = max(0, queuedDownloadCount)
        self.deletedDownloadCount = max(0, deletedDownloadCount)
        self.failureCount = max(0, failureCount)
    }
}

public struct LibraryAutomationBackgroundRequest: Equatable, Sendable {
    public var earliestBeginDate: Date
    public var requiresNetworkConnectivity: Bool
    public var requiresExternalPower: Bool

    public init(
        earliestBeginDate: Date,
        requiresNetworkConnectivity: Bool,
        requiresExternalPower: Bool
    ) {
        self.earliestBeginDate = earliestBeginDate
        self.requiresNetworkConnectivity = requiresNetworkConnectivity
        self.requiresExternalPower = requiresExternalPower
    }
}

public enum LibraryAutomationBackgroundScheduleAction: Equatable, Sendable {
    case cancel
    case submit(LibraryAutomationBackgroundRequest)
}

public enum LibraryAutomationPolicy {
    public static let defaultUpdateInterval: TimeInterval = 6 * 60 * 60

    public static func updateCheckIsDue(
        rules: LibraryAutomationRules,
        lastCheck: Date?,
        now: Date = .now,
        minimumInterval: TimeInterval = defaultUpdateInterval
    ) -> Bool {
        guard rules.checksForUpdates else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= max(0, minimumInterval)
    }

    public static func nextUpdateCheckDate(
        rules: LibraryAutomationRules,
        lastCheck: Date?,
        now: Date = .now,
        minimumInterval: TimeInterval = defaultUpdateInterval
    ) -> Date? {
        guard rules.checksForUpdates else { return nil }
        guard let lastCheck else { return now }
        return max(now, lastCheck.addingTimeInterval(max(0, minimumInterval)))
    }

    public static func backgroundScheduleAction(
        rules: LibraryAutomationRules,
        now: Date = .now,
        minimumInterval: TimeInterval = defaultUpdateInterval
    ) -> LibraryAutomationBackgroundScheduleAction {
        guard rules.checksForUpdates || rules.deletesCompletedDownloads else {
            return .cancel
        }
        return .submit(LibraryAutomationBackgroundRequest(
            earliestBeginDate: now.addingTimeInterval(max(0, minimumInterval)),
            requiresNetworkConnectivity: rules.checksForUpdates,
            requiresExternalPower: false
        ))
    }

    public static func downloadIsEligibleForDeletion(
        rules: LibraryAutomationRules,
        state: DownloadState,
        completedAt: Date,
        highestProgression: Double?,
        now: Date = .now
    ) -> Bool {
        guard rules.deletesCompletedDownloads, state == .completed else { return false }
        guard let highestProgression, highestProgression >= 1 else { return false }
        guard completedAt <= now else { return false }
        // Rules normally clamp this value at initialization, but the fields
        // remain mutable and older persisted data may contain invalid values.
        let retentionDays = min(max(rules.deleteDelayDays, 0), 365)
        let retention = TimeInterval(retentionDays) * 24 * 60 * 60
        return now.timeIntervalSince(completedAt) >= retention
    }
}
