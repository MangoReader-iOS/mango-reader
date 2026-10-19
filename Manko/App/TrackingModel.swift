import Foundation
import ImageIO
import MankoData
import MankoDomain
import MankoExtensions
import MankoReaders
import MankoSources
import MankoSync
import Observation
import OSLog
import SwiftUI
import WebKit

@MainActor
@Observable
final class TrackingModel {
    @ObservationIgnored var database: MankoDatabase?
    @ObservationIgnored var extensionRuntimeRegistry: ExtensionRuntimeRegistry?
    @ObservationIgnored var trackerQueue: TrackerUpdateQueue?
    let feedback: AppFeedback
    let settingsSyncModel: SettingsSyncModel
    let sourcesModel: SourcesModel

    init(
        database: MankoDatabase?,
        feedback: AppFeedback,
        settingsSyncModel: SettingsSyncModel,
        sourcesModel: SourcesModel
    ) {
        self.database = database
        self.feedback = feedback
        self.settingsSyncModel = settingsSyncModel
        self.sourcesModel = sourcesModel
    }

    var trackerPendingCount = 0

    var trackerPendingUpdates: [QueuedTrackerUpdate] = []

    var isDeliveringTrackerUpdates = false

    var trackerLinksByWork: [WorkID: [TrackerLink]] = [:]

    var trackerSyncErrors: [WorkID: String] = [:]
    var progressRevision = 0
    @ObservationIgnored private var activeLinks: Set<String> = []
    @ObservationIgnored private var invalidatingTrackers: Set<TrackerID> = []
    @ObservationIgnored private var operationWaiters: [TrackerID: [CheckedContinuation<Void, Never>]] = [:]

    func beginLinkOperation(trackerID: TrackerID, remoteWorkID: String) -> Bool {
        guard !invalidatingTrackers.contains(trackerID) else { return false }
        return activeLinks.insert(trackerID.rawValue + "\u{1F}" + remoteWorkID).inserted
    }

    func finishLinkOperation(trackerID: TrackerID, remoteWorkID: String) {
        activeLinks.remove(trackerID.rawValue + "\u{1F}" + remoteWorkID)
        if !activeLinks.contains(where: { $0.hasPrefix(trackerID.rawValue + "\u{1F}") }) {
            for waiter in operationWaiters.removeValue(forKey: trackerID) ?? [] { waiter.resume() }
        }
    }

    func beginAccountChange(trackerID: TrackerID) async throws {
        guard invalidatingTrackers.insert(trackerID).inserted else {
            throw SourceError.transport("An account change is already in progress.")
        }
        if activeLinks.contains(where: { $0.hasPrefix(trackerID.rawValue + "\u{1F}") }) {
            await withCheckedContinuation { operationWaiters[trackerID, default: []].append($0) }
        }
        do {
            try await trackerQueue?.discardUpdates(for: [trackerID])
            if let database {
                for var link in try await database.trackerLinks(trackerID: trackerID) {
                    link.generation = nil; link.lastPulledAt = nil; link.lastRemote = nil
                    link.lastSynced = .init(); link.conflicts = []
                    try await database.save(trackerLink: link)
                    trackerLinksByWork[link.workID] = try await database.trackerLinks(for: link.workID)
                }
            }
            await refreshTrackerQueueStatus()
        } catch {
            finishAccountChange(trackerID: trackerID)
            throw error
        }
    }

    func finishAccountChange(trackerID: TrackerID) {
        invalidatingTrackers.remove(trackerID)
    }

    @ObservationIgnored var repositoryTrackerDeliveryOperationForTesting: (@Sendable () async throws -> Void)?

    func enqueueTrackerUpdate(_ progress: TrackerProgress, link authorizedLink: TrackerLink? = nil) async {
        guard !sourcesModel.isPrivate, !settingsSyncModel.incognitoMode, let trackerQueue else { return }
        do {
            guard let database,
                  let link = try await database.trackerLinks(trackerID: progress.trackerID)
                    .first(where: { $0.remoteWorkID == progress.remoteWorkID && (authorizedLink == nil || $0.workID == authorizedLink?.workID) }),
                  let generation = link.generation,
                  authorizedLink == nil || authorizedLink?.generation == generation,
                  !invalidatingTrackers.contains(progress.trackerID) else { return }
            try await trackerQueue.enqueue(progress, expectedBaseline: link.lastSynced, linkGeneration: generation)
            trackerPendingUpdates = await trackerQueue.pending()
            trackerPendingCount = trackerPendingUpdates.count
        } catch {
            sourcesModel.show(error, title: "Couldn’t queue tracker update")
        }
    }

    var enabledTrackerInstallations: [InstalledRepositorySource] {
        sourcesModel.installedRepositorySources.filter {
            $0.entryType == .mankoExtension
                && $0.kind == .tracker
                && $0.availability == .available
                && $0.isEnabled
                && $0.isRuntimeCompatible
        }
    }

    func trackerID(for installed: InstalledRepositorySource) -> TrackerID {
        TrackerID(rawValue: "repository.\(installed.repositoryID).\(installed.sourceID)")
    }

    func trackerLinks(for workID: WorkID, reload: Bool = false) async -> [TrackerLink] {
        if !reload, let cached = trackerLinksByWork[workID] { return cached }
        guard let database else { return [] }
        do {
            let links = try await database.trackerLinks(for: workID)
            trackerLinksByWork[workID] = links
            return links
        } catch {
            trackerSyncErrors[workID] = error.localizedDescription
            return []
        }
    }

    func trackerLinkState(for workID: WorkID) -> TrackerLinkSyncState {
        if trackerSyncErrors[workID] != nil { return .error }
        let links = trackerLinksByWork[workID] ?? []
        guard !links.isEmpty else { return .notLinked }
        if links.contains(where: { $0.conflicts.contains { $0.field == .chapter || $0.field == .volume } }) {
            return .progressAvailable
        }
        if links.contains(where: { !$0.conflicts.isEmpty }) { return .conflict }
        if trackerPendingUpdates.contains(where: { update in
            links.contains { $0.trackerID == update.progress.trackerID && $0.remoteWorkID == update.progress.remoteWorkID }
        }) { return .pending }
        return .synced
    }

    func trackerMatches(
        for work: Work,
        using installed: InstalledRepositorySource,
        query: String? = nil
    ) async throws -> [TrackerMatch] {
        guard !sourcesModel.isPrivate, !settingsSyncModel.incognitoMode else { return [] }
        let title = (query ?? work.title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return [] }
        guard let extensionRuntimeRegistry else {
            throw SourceError.transport("Tracker services are still starting.")
        }
        let provider = try await extensionRuntimeRegistry.tracker(for: installed)
        return try await Self.searchMatches(for: work, query: query) { title, kind in
            try await provider.search(title: title, kind: kind)
        }
    }

    static func searchMatches(
        for work: Work,
        query: String? = nil,
        search: (String, ContentKind) async throws -> [TrackerMatch]
    ) async throws -> [TrackerMatch] {
        let title = (query ?? work.title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return [] }
        let matches = try await search(title, work.kind)
        let candidates = Set((query == nil ? [work.title] + work.alternativeTitles : [title]).map(Self.normalizedTrackerTitle))
        return matches.sorted { lhs, rhs in
            let lhsExact = candidates.contains(Self.normalizedTrackerTitle(lhs.title))
            let rhsExact = candidates.contains(Self.normalizedTrackerTitle(rhs.title))
            if lhsExact != rhsExact { return lhsExact }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    func removeTrackerLink(workID: WorkID, trackerID: TrackerID) async {
        guard let database else { return }
        do {
            let remoteWorkID = try await database.trackerLinks(for: workID)
                .first(where: { $0.trackerID == trackerID })?.remoteWorkID
            guard let remoteWorkID,
                  beginLinkOperation(trackerID: trackerID, remoteWorkID: remoteWorkID) else {
                throw SourceError.transport("Tracking is busy. Try unlinking again after sync finishes.")
            }
            defer { finishLinkOperation(trackerID: trackerID, remoteWorkID: remoteWorkID) }
            try await database.deleteTrackerLink(workID: workID, trackerID: trackerID)
            do {
                try await trackerQueue?.discardUpdate(
                    for: trackerID,
                    remoteWorkID: remoteWorkID
                )
            }
            trackerLinksByWork[workID]?.removeAll { $0.trackerID == trackerID }
            trackerPendingCount = await trackerQueue?.pending().count ?? 0
        } catch {
            sourcesModel.show(error, title: "Couldn’t remove tracker link")
        }
    }

    func enqueueCompletedInstallment(_ installment: Installment, since baseline: TrackerSyncSnapshot) async {
        guard var snapshot = try? await localTrackerSnapshot(for: installment.workID) else { return }
        var fields: Set<TrackerSyncField> = []
        // Authorize only the milestone completed by this action. Rereading below
        // an imported milestone must not relay that import to another tracker.
        if let chapter = installment.number, chapter.isFinite, chapter >= 0, chapter.rounded(.down) == chapter,
           let completed = snapshot.chapter, completed >= chapter, chapter > (baseline.chapter ?? 0) {
            snapshot.chapter = chapter
            fields.insert(.chapter)
        }
        if let volume = installment.volume, volume.isFinite, volume >= 0, volume.rounded(.down) == volume,
           let completed = snapshot.volume, completed >= volume, volume > (baseline.volume ?? 0) {
            snapshot.volume = volume
            fields.insert(.volume)
        }
        await enqueueTrackerSnapshot(for: installment.workID, changedFields: fields, snapshot: snapshot)
    }

    func enqueueTrackerSnapshot(for workID: WorkID,
                                changedFields: Set<TrackerSyncField> = [.chapter, .volume],
                                snapshot approvedSnapshot: TrackerSyncSnapshot? = nil) async {
        guard !sourcesModel.isPrivate, !settingsSyncModel.incognitoMode else { return }
        let links = await trackerLinks(for: workID, reload: true)
        guard !links.isEmpty else { return }
        let snapshot: TrackerSyncSnapshot
        if let approvedSnapshot { snapshot = approvedSnapshot }
        else {
            guard let local = try? await localTrackerSnapshot(for: workID) else { return }
            snapshot = local
        }
        for link in links {
            let blocked = Set(link.conflicts.map(\.field))
            do {
                try await trackerQueue?.excludeFields(blocked, trackerID: link.trackerID, remoteWorkID: link.remoteWorkID)
            } catch {
                sourcesModel.show(error, title: "Couldn’t preserve tracker conflicts")
                continue
            }
            var fields = changedFields.subtracting(blocked)
            if snapshot.chapter == nil { fields.remove(.chapter) }
            if snapshot.volume == nil { fields.remove(.volume) }
            if link.supportsDateUpdates != true { fields.subtract([.startDate, .finishDate]) }
            // Local rereading and unread actions never queue backward tracker updates.
            if let value = snapshot.chapter, value <= (link.lastRemote?.chapter ?? 0) { fields.remove(.chapter) }
            if let value = snapshot.volume, value <= (link.lastRemote?.volume ?? 0) { fields.remove(.volume) }
            guard !fields.isEmpty else { continue }
            let dates = fields.intersection([.startDate, .finishDate])
            await enqueueTrackerUpdate(TrackerProgress(
                trackerID: link.trackerID, remoteWorkID: link.remoteWorkID,
                chapter: snapshot.chapter, volume: snapshot.volume, status: snapshot.status, score: snapshot.score,
                dateUpdates: dates.isEmpty ? nil : .init(startDate: snapshot.startDate, finishDate: snapshot.finishDate, fields: dates),
                fieldsToUpdate: fields), link: link)
        }
        if ReadingRefreshPolicy.current == .afterReaderCloses {
            Task(priority: .utility) { await deliverRepositoryTrackerQueue() }
        } else {
            await deliverRepositoryTrackerQueue()
        }
    }

    func localTrackerSnapshot(for workID: WorkID) async throws -> TrackerSyncSnapshot {
        guard let database else { return .init() }
        async let stateLoad = database.titleState(for: workID)
        async let installmentLoad = database.installments(for: workID)
        async let progressLoad = database.progresses(for: workID)
        let (state, installments, progresses) = try await (stateLoad, installmentLoad, progressLoad)
        return await Self.makeLocalTrackerSnapshot(state: state, installments: installments, progresses: progresses)
    }

    @concurrent
    nonisolated private static func makeLocalTrackerSnapshot(
        state: UserTitleState?, installments: [Installment], progresses: [ReadingProgress]
    ) async -> TrackerSyncSnapshot {
        let completeIDs = Set(progresses.filter { $0.highestProgression >= 1 }.map(\.installmentID))
        let chapter = TrackerChapterMapping.completedChapter(in: installments, progresses: progresses)
        let volumes = Dictionary(grouping: installments.filter {
            $0.volume.map { $0.isFinite && $0 >= 0 && $0.rounded(.down) == $0 } == true
        }, by: { $0.volume! })
        let completeVolumes = volumes.filter { _, group in
            let numberedGroups = Dictionary(grouping: group, by: \.number)
            return numberedGroups.values.allSatisfy { alternatives in
                alternatives.contains { completeIDs.contains($0.id) }
            }
        }.keys.max()
        return TrackerSyncSnapshot(
            chapter: chapter,
            volume: volumes.isEmpty || TrackerChapterMapping.issue(in: installments) != nil ? nil : completeVolumes ?? 0,
            status: state?.status,
            score: state?.rating.map { Double($0.rawValue) },
            startDate: state?.startDate,
            finishDate: state?.finishDate
        )
    }

    func addRepresentabilityConflictIfNeeded(
        remote: TrackerSyncSnapshot,
        local: TrackerSyncSnapshot,
        result: inout TrackerMergeResult
    ) {
        guard let score = remote.score,
              score.rounded() != score || !(1 ... 10).contains(score)
        else { return }
        result.fieldsPulled.remove(.rating)
        result.fieldsToPush.remove(.rating)
        result.conflicts.removeAll { $0.field == .rating }
        result.conflicts.append(TrackerFieldConflict(
            field: .rating,
            mankoValue: local.score.map(TrackerSyncValue.number) ?? .none,
            trackerValue: .number(score)
        ))
    }

    func addDateConflictsIfNeeded(remote: TrackerSyncSnapshot, local: TrackerSyncSnapshot, result: inout TrackerMergeResult) {
        guard result.merged.startDate?.isValid == false || result.merged.finishDate?.isValid == false
            || !TrackerDate.areOrdered(start: result.merged.startDate, finish: result.merged.finishDate) else { return }
        for field: TrackerSyncField in [.startDate, .finishDate] where result.fieldsPulled.contains(field) {
            let localDate = field == .startDate ? local.startDate : local.finishDate
            let remoteDate = field == .startDate ? remote.startDate : remote.finishDate
            result.fieldsPulled.remove(field)
            result.conflicts.append(.init(field: field, mankoValue: localDate.map(TrackerSyncValue.date) ?? .none,
                                          trackerValue: remoteDate.map(TrackerSyncValue.date) ?? .none))
        }
        result.merged.startDate = local.startDate
        result.merged.finishDate = local.finishDate
    }

    static func normalizedTrackerTitle(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    func refreshTrackerQueueStatus() async {
        trackerPendingUpdates = await trackerQueue?.pending() ?? []
        trackerPendingCount = trackerPendingUpdates.count
    }

    func retryTrackerDelivery() async {
        guard !isDeliveringTrackerUpdates else { return }
        guard !sourcesModel.isPrivate, !settingsSyncModel.incognitoMode else {
            feedback.showStatus("Turn off Incognito Reading to deliver tracker updates.", systemImage: "eye.slash")
            return
        }
        await refreshTrackerQueueStatus()
        guard trackerPendingUpdates.contains(where: { $0.deliveryState == .ready && $0.nextAttemptAt <= .now }) else {
            feedback.showStatus("No updates are ready to send. Check sign-in requirements or retry times below.", systemImage: "info.circle")
            return
        }
        await deliverRepositoryTrackerQueue()
        feedback.showStatus(
            trackerPendingCount == 0 ? "Tracker updates delivered." : "\(trackerPendingCount) update\(trackerPendingCount == 1 ? " remains" : "s remain") queued. Check delivery details.",
            systemImage: trackerPendingCount == 0 ? "checkmark.circle" : "info.circle"
        )
    }

    func deliverRepositoryTrackerQueue(
        mode: CloudflareRecoveryMode = .foreground
    ) async {
        guard !sourcesModel.isPrivate, !settingsSyncModel.incognitoMode, !isDeliveringTrackerUpdates else { return }
        isDeliveringTrackerUpdates = true
        defer { isDeliveringTrackerUpdates = false }
        let deliveryOperationForTesting = repositoryTrackerDeliveryOperationForTesting
        do {
            try await sourcesModel.performSourceOperation(mode: mode) { [weak self] in
                guard let self else { throw CancellationError() }
                if let deliveryOperationForTesting {
                    try await deliveryOperationForTesting()
                    return
                }
                try await self.flushRepositoryTrackerQueue()
            }
        } catch is CancellationError {
            return
        } catch is CloudflareVerificationRequiredError {
            // `performSourceOperation` already persisted the exact context. The
            // challenged queue item remains ready and consumes no retry budget.
        } catch {
            switch mode {
            case .foreground:
                sourcesModel.show(error, title: "Couldn’t deliver tracker updates")
            case .background:
                settingsSyncModel.automationLastError = error.localizedDescription
            }
        }
        await refreshTrackerQueueStatus()
    }

    func flushRepositoryTrackerQueue() async throws {
        guard !sourcesModel.isPrivate, let trackerQueue, let extensionRuntimeRegistry else { return }
        var providers: [TrackerID: any TrackerProvider] = [:]
        for installed in sourcesModel.installedRepositorySources where
            installed.entryType == .mankoExtension
                && installed.kind == .tracker
                && installed.availability == .available
                && installed.isEnabled
                && installed.isRuntimeCompatible
        {
            do {
                let provider = try await extensionRuntimeRegistry.tracker(for: installed)
                let providerID = TrackerID(rawValue: "repository.\(installed.repositoryID).\(installed.sourceID)")
                providers[providerID] = provider
            } catch let runtimeError as MankoExtensionRuntimeError {
                if case .cloudflareHandoff = runtimeError {
                    throw runtimeError
                }
                // Preserve the previous best-effort provider discovery for all
                // non-challenge runtime failures.
            } catch {
                // Preserve the previous best-effort provider discovery.
            }
        }
        try await trackerQueue.flushReportingCloudflareChallenges(using: providers) { [weak self] item, provider in
            guard let self else { throw CancellationError() }
            return try await self.deliverTrackerItem(item, provider: provider)
        }
    }

    func deliverTrackerItem(_ item: QueuedTrackerUpdate, provider: any TrackerProvider) async throws -> Set<TrackerSyncField> {
        guard !settingsSyncModel.incognitoMode, !sourcesModel.isPrivate, let database,
              let generation = item.linkGeneration,
              var link = try await database.trackerLinks(trackerID: item.progress.trackerID)
                .first(where: { $0.remoteWorkID == item.progress.remoteWorkID && $0.generation == generation }) else {
            return item.progress.updateFields
        }
        guard beginLinkOperation(trackerID: link.trackerID, remoteWorkID: link.remoteWorkID) else {
            throw CancellationError()
        }
        defer { finishLinkOperation(trackerID: link.trackerID, remoteWorkID: link.remoteWorkID) }
        let fetched = try await provider.progress(remoteWorkID: link.remoteWorkID)
        let remote = fetched.map(TrackerSyncSnapshot.init) ?? .init()
        var decision = TrackerDeliveryDecision.reconcile(update: item.progress, baseline: item.expectedBaseline, remote: remote)
        if fetched == nil, item.expectedBaseline != .init() {
            decision.fieldsToSend = []; decision.acknowledged = []; decision.conflicts = item.progress.updateFields
        }
        guard !settingsSyncModel.incognitoMode, !sourcesModel.isPrivate,
              await trackerQueue?.isCurrent(item) == true,
              try await database.trackerLinks(for: link.workID).contains(where: {
                  $0.trackerID == link.trackerID && $0.generation == generation
              }) else { throw CancellationError() }
        if !decision.fieldsToSend.isEmpty {
            try await provider.update(item.progress.updatingOnly(decision.fieldsToSend))
        }
        var acknowledged = remote
        for field in decision.fieldsToSend { acknowledged.copy(field, from: TrackerSyncSnapshot(item.progress)) }
        for field in decision.fieldsToSend.union(decision.acknowledged) {
            link.lastSynced.copy(field, from: acknowledged)
        }
        link.lastRemote = TrackerProgress(trackerID: link.trackerID, remoteWorkID: link.remoteWorkID,
            chapter: acknowledged.chapter, volume: acknowledged.volume, status: acknowledged.status, score: acknowledged.score,
            startDate: acknowledged.startDate, finishDate: acknowledged.finishDate,
            totalChapters: fetched?.totalChapters, totalVolumes: fetched?.totalVolumes)
        link.lastPulledAt = .now
        for field in decision.conflicts {
            link.conflicts.removeAll { $0.field == field }
            link.conflicts.append(.init(field: field,
                mankoValue: TrackerSyncSnapshot(item.progress).value(for: field), trackerValue: remote.value(for: field)))
        }
        let local = try await localTrackerSnapshot(for: link.workID)
        for field: TrackerSyncField in [.chapter, .volume] {
            if case let .number(value) = remote.value(for: field),
               case let .number(localValue) = local.value(for: field), value > localValue,
               !link.conflicts.contains(where: { $0.field == field }) {
                link.conflicts.append(.init(field: field, mankoValue: .number(localValue), trackerValue: .number(value)))
            }
        }
        try await database.save(trackerLink: link)
        try await trackerQueue?.acknowledgeDelivery(of: item, fields: decision.fieldsToSend, snapshot: acknowledged)
        trackerLinksByWork[link.workID] = try await database.trackerLinks(for: link.workID)
        return decision.conflicts
    }
}
