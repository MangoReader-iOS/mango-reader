import Foundation

public struct ContinueReadingItem: Identifiable, Hashable, Sendable {
    public var id: InstallmentID { installment.id }
    public var work: Work
    public var installment: Installment
    public var isUpNext: Bool

    public init(work: Work, installment: Installment, isUpNext: Bool) {
        self.work = work
        self.installment = installment
        self.isUpNext = isUpNext
    }
}

public enum ContinueReadingPolicy {
    private struct Resolution {
        var item: ContinueReadingItem
        var historyDate: Date
    }

    public static func item(
        sessions: [ReadingSession],
        worksByID: [WorkID: Work],
        installmentsByWorkID: [WorkID: [Installment]],
        progressesByWorkID: [WorkID: [ReadingProgress]]
    ) -> ContinueReadingItem? {
        worksByID.values.compactMap { work in
            resolution(
                work: work,
                sessions: sessions.filter { $0.workID == work.id },
                installments: installmentsByWorkID[work.id, default: []],
                progresses: progressesByWorkID[work.id, default: []],
                fallsBackToOldest: false
            )
        }
        .max(by: precedesByHistoryDate)?
        .item
    }

    public static func item(
        work: Work,
        sessions: [ReadingSession],
        installments: [Installment],
        progresses: [ReadingProgress],
        fallsBackToOldest: Bool
    ) -> ContinueReadingItem? {
        resolution(
            work: work,
            sessions: sessions,
            installments: installments,
            progresses: progresses,
            fallsBackToOldest: fallsBackToOldest
        )?.item
    }

    private static func resolution(
        work: Work,
        sessions: [ReadingSession],
        installments: [Installment],
        progresses: [ReadingProgress],
        fallsBackToOldest: Bool
    ) -> Resolution? {
        let oldestFirst = ReaderChapterPolicy.ordered(installments)
        guard !oldestFirst.isEmpty else { return nil }
        let hasStoredHistory = sessions.contains { $0.workID == work.id }
            || progresses.contains { $0.workID == work.id }

        let validInstallmentIDs = Set(oldestFirst.map(\.id))
        let progressByInstallmentID = progresses.reduce(
            into: [InstallmentID: ReadingProgress]()
        ) { result, progress in
            guard progress.workID == work.id,
                  validInstallmentIDs.contains(progress.installmentID)
            else { return }
            if let existing = result[progress.installmentID],
               !precedesByModifiedDate(existing, progress) {
                return
            }
            result[progress.installmentID] = progress
        }

        let latestSession = sessions
            .filter {
                $0.workID == work.id && validInstallmentIDs.contains($0.installmentID)
            }
            .max(by: precedesBySessionDate)
        if let latestSession,
           let anchor = oldestFirst.first(where: { $0.id == latestSession.installmentID }) {
            let isComplete = max(
                latestSession.endProgression,
                progressByInstallmentID[anchor.id]?.highestProgression ?? 0
            ) >= 1
            return Resolution(
                item: resolvedItem(
                    work: work,
                    anchor: anchor,
                    isComplete: isComplete,
                    oldestFirst: oldestFirst,
                    progressByInstallmentID: progressByInstallmentID
                ),
                historyDate: latestSession.endedAt ?? latestSession.startedAt
            )
        }

        let positions = Dictionary(uniqueKeysWithValues: oldestFirst.enumerated().map { ($0.element.id, $0.offset) })
        if let latestProgress = progressByInstallmentID.values.max(by: { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
            return (positions[lhs.installmentID] ?? -1) < (positions[rhs.installmentID] ?? -1)
        }),
           let anchor = oldestFirst.first(where: { $0.id == latestProgress.installmentID }) {
            return Resolution(
                item: resolvedItem(
                    work: work,
                    anchor: anchor,
                    isComplete: latestProgress.highestProgression >= 1,
                    oldestFirst: oldestFirst,
                    progressByInstallmentID: progressByInstallmentID
                ),
                historyDate: latestProgress.modifiedAt
            )
        }

        guard fallsBackToOldest || hasStoredHistory,
              let oldest = oldestFirst.first
        else { return nil }
        return Resolution(
            item: ContinueReadingItem(
                work: work,
                installment: oldest,
                isUpNext: false
            ),
            historyDate: .distantPast
        )
    }

    private static func resolvedItem(
        work: Work,
        anchor: Installment,
        isComplete: Bool,
        oldestFirst: [Installment],
        progressByInstallmentID: [InstallmentID: ReadingProgress]
    ) -> ContinueReadingItem {
        guard isComplete,
              let currentIndex = oldestFirst.firstIndex(where: { $0.id == anchor.id }),
              let nextUnread = oldestFirst.dropFirst(currentIndex + 1).first(where: {
                  (progressByInstallmentID[$0.id]?.highestProgression ?? 0) < 1
              })
        else {
            return ContinueReadingItem(
                work: work,
                installment: anchor,
                isUpNext: false
            )
        }
        return ContinueReadingItem(
            work: work,
            installment: nextUnread,
            isUpNext: true
        )
    }

    private static func precedesByHistoryDate(_ lhs: Resolution, _ rhs: Resolution) -> Bool {
        if lhs.historyDate != rhs.historyDate { return lhs.historyDate < rhs.historyDate }
        return lhs.item.id.rawValue.uuidString < rhs.item.id.rawValue.uuidString
    }

    private static func precedesBySessionDate(
        _ lhs: ReadingSession,
        _ rhs: ReadingSession
    ) -> Bool {
        let lhsDate = lhs.endedAt ?? lhs.startedAt
        let rhsDate = rhs.endedAt ?? rhs.startedAt
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func precedesByModifiedDate(
        _ lhs: ReadingProgress,
        _ rhs: ReadingProgress
    ) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

}
