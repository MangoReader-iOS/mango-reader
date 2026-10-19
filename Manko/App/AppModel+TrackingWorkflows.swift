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

extension AppModel {
    func prepareTitleTracking(work: Work, installments: [Installment]) async -> Bool {
        await libraryModel.cacheReadingContentIfNeeded(work: work, installments: installments)
    }

    func confirmTrackerLink(work: Work, installments: [Installment],
                            installed: InstalledRepositorySource, match: TrackerMatch) async -> Bool {
        guard !sourcesModel.isPrivate, !settingsSyncModel.incognitoMode,
              await prepareTitleTracking(work: work, installments: installments),
              let database, let extensionRuntimeRegistry else { return false }
        let trackerID = trackingModel.trackerID(for: installed)
        let previous = try? await database.trackerLinks(for: work.id).first(where: { $0.trackerID == trackerID })
        if let previous, previous.remoteWorkID != match.id {
            guard trackingModel.beginLinkOperation(trackerID: trackerID, remoteWorkID: previous.remoteWorkID) else { return false }
        }
        defer {
            if let previous, previous.remoteWorkID != match.id {
                trackingModel.finishLinkOperation(trackerID: trackerID, remoteWorkID: previous.remoteWorkID)
            }
        }
        guard trackingModel.beginLinkOperation(trackerID: trackerID, remoteWorkID: match.id) else { return false }
        defer { trackingModel.finishLinkOperation(trackerID: trackerID, remoteWorkID: match.id) }
        do {
            let provider = try await extensionRuntimeRegistry.tracker(for: installed)
            let capabilities = try await provider.trackingCapabilities()
            let local = try await trackingModel.localTrackerSnapshot(for: work.id)
            let fetched = try await provider.progress(remoteWorkID: match.id)
            try Task.checkCancellation()
            guard sourcesModel.isCurrentInstallation(installed), !sourcesModel.isPrivate, !settingsSyncModel.incognitoMode else { return false }
            let existing = try await database.trackerLinks(for: work.id).first(where: { $0.trackerID == trackerID })
            guard existing?.generation == previous?.generation, existing?.remoteWorkID == previous?.remoteWorkID else { throw TrackerImportError.changed }
            let remote = fetched.map(TrackerSyncSnapshot.init) ?? .init()
            let fields = Set(TrackerSyncField.allCases).subtracting(capabilities.supportsDateUpdates ? [] : [.startDate, .finishDate])
            let conflicts = fields.filter { local.needsReview($0, comparedWith: remote) }.map {
                TrackerFieldConflict(field: $0, mankoValue: local.value(for: $0), trackerValue: remote.value(for: $0))
            }
            // Matching authorizes the link, never a replacement of either side's data.
            let link = TrackerLink(workID: work.id, trackerID: trackerID, remoteWorkID: match.id,
                remoteTitle: match.title, lastSynced: remote, lastPulledAt: .now,
                conflicts: conflicts, lastRemote: fetched, supportsDateUpdates: capabilities.supportsDateUpdates)
            try await trackingModel.trackerQueue?.discardUpdate(for: trackerID, remoteWorkID: match.id)
            if let previous, previous.remoteWorkID != match.id {
                try await trackingModel.trackerQueue?.discardUpdate(for: trackerID, remoteWorkID: previous.remoteWorkID)
            }
            try await database.save(trackerLink: link)
            trackingModel.trackerLinksByWork[work.id] = try await database.trackerLinks(for: work.id)
            trackingModel.trackerSyncErrors[work.id] = TrackerChapterMapping.issue(in: installments)
            return true
        } catch {
            trackingModel.trackerSyncErrors[work.id] = error.localizedDescription
            sourcesModel.show(error, title: "Couldn’t link tracker title")
            return false
        }
    }

    func syncTrackerLinks(work: Work, installments: [Installment], force: Bool = false) async {
        guard !sourcesModel.isPrivate, !settingsSyncModel.incognitoMode, let database, let extensionRuntimeRegistry else { return }
        let links = await trackingModel.trackerLinks(for: work.id, reload: true)
        for var link in links where force || link.isStale {
            guard let installed = trackingModel.enabledTrackerInstallations.first(where: {
                trackingModel.trackerID(for: $0) == link.trackerID
            }), trackingModel.beginLinkOperation(trackerID: link.trackerID, remoteWorkID: link.remoteWorkID) else { continue }
            defer { trackingModel.finishLinkOperation(trackerID: link.trackerID, remoteWorkID: link.remoteWorkID) }
            do {
                let provider = try await extensionRuntimeRegistry.tracker(for: installed)
                let capabilities = try await provider.trackingCapabilities()
                let fetched = try await provider.progress(remoteWorkID: link.remoteWorkID)
                try Task.checkCancellation()
                guard !sourcesModel.isPrivate, !settingsSyncModel.incognitoMode, sourcesModel.isCurrentInstallation(installed),
                      try await database.trackerLinks(for: work.id).contains(where: {
                          $0.trackerID == link.trackerID && $0.remoteWorkID == link.remoteWorkID && $0.generation == link.generation
                      }) else { return }
                let remote = fetched.map(TrackerSyncSnapshot.init) ?? .init()
                let local = try await trackingModel.localTrackerSnapshot(for: work.id)
                let needsInitialReview = link.generation == nil
                var merge = TrackerThreeWayMerge.merge(base: link.lastSynced, local: local, remote: remote,
                    syncDates: capabilities.supportsDateUpdates)
                trackingModel.addRepresentabilityConflictIfNeeded(remote: remote, local: local, result: &merge)
                trackingModel.addDateConflictsIfNeeded(remote: remote, local: local, result: &merge)
                if needsInitialReview {
                    merge.fieldsPulled = []
                    merge.conflicts = TrackerSyncField.allCases.filter {
                        (capabilities.supportsDateUpdates || ($0 != .startDate && $0 != .finishDate))
                            && local.needsReview($0, comparedWith: remote)
                    }.map { .init(field: $0, mankoValue: local.value(for: $0), trackerValue: remote.value(for: $0)) }
                    link.generation = UUID()
                    link.lastSynced = remote
                }
                for field: TrackerSyncField in [.chapter, .volume] {
                    let wouldPull = merge.fieldsPulled.remove(field) != nil
                    // Preserve an explicit review decision until it is resolved. Never apply progress on opening a title.
                    if local.needsReview(field, comparedWith: remote),
                       (merge.conflicts.contains { $0.field == field } || link.conflicts.contains { $0.field == field }
                        || wouldPull
                        || (remote.value(for: field).numberForProgress ?? 0) > (local.value(for: field).numberForProgress ?? 0)) {
                        merge.conflicts.removeAll { $0.field == field }
                        merge.conflicts.append(.init(field: field, mankoValue: local.value(for: field), trackerValue: remote.value(for: field)))
                    }
                }
                // Unresolved metadata conflicts cannot be implicitly cleared by another refresh.
                for conflict in link.conflicts where conflict.field != .chapter && conflict.field != .volume {
                    if local.value(for: conflict.field) != remote.value(for: conflict.field) {
                        merge.fieldsPulled.remove(conflict.field)
                        merge.conflicts.removeAll { $0.field == conflict.field }
                        merge.conflicts.append(.init(field: conflict.field,
                            mankoValue: local.value(for: conflict.field), trackerValue: remote.value(for: conflict.field)))
                    }
                }
                try await trackingModel.trackerQueue?.excludeFields(Set(merge.conflicts.map(\.field)),
                    trackerID: link.trackerID, remoteWorkID: link.remoteWorkID)
                try await applyRemoteTrackerSnapshot(remote, pulledFields: merge.fieldsPulled,
                    workID: work.id, installments: installments, expectedLocal: local)
                let conflicts = Set(merge.conflicts.map(\.field))
                for field in merge.fieldsPulled.union(TrackerSyncField.allCases.filter {
                    local.value(for: $0) == remote.value(for: $0)
                }).subtracting(conflicts) {
                    link.lastSynced.copy(field, from: remote)
                }
                // Only the originating user action queues a push. A fetch cannot invent edit intent.
                link.lastPulledAt = .now; link.lastRemote = fetched
                link.conflicts = merge.conflicts; link.supportsDateUpdates = capabilities.supportsDateUpdates
                try await database.save(trackerLink: link)
                trackingModel.trackerSyncErrors[work.id] = TrackerChapterMapping.issue(in: installments)
            } catch is CancellationError { return }
            catch { trackingModel.trackerSyncErrors[work.id] = error.localizedDescription }
        }
        trackingModel.trackerLinksByWork[work.id] = (try? await database.trackerLinks(for: work.id)) ?? []
        await trackingModel.deliverRepositoryTrackerQueue()
    }

    func resolveTrackerConflict(work: Work, installments: [Installment], link: TrackerLink,
                                conflict: TrackerFieldConflict, useTrackerValue: Bool) async -> Bool {
        guard !sourcesModel.isPrivate, !settingsSyncModel.incognitoMode, let database,
              trackingModel.beginLinkOperation(trackerID: link.trackerID, remoteWorkID: link.remoteWorkID) else { return false }
        defer { trackingModel.finishLinkOperation(trackerID: link.trackerID, remoteWorkID: link.remoteWorkID) }
        do {
            guard var current = try await database.trackerLinks(for: work.id).first(where: { $0.trackerID == link.trackerID }),
                  current.generation == link.generation, current.conflicts.contains(conflict) else { throw TrackerImportError.changed }
            if useTrackerValue, conflict.field == .chapter || conflict.field == .volume {
                // Progress uses the preview/apply path; it can never reset trailing chapters.
                return false
            }
            let reviewedLocal = try await trackingModel.localTrackerSnapshot(for: work.id)
            guard reviewedLocal.value(for: conflict.field) == conflict.mankoValue else { throw TrackerImportError.changed }
            var remoteChoice = current.lastRemote.map(TrackerSyncSnapshot.init) ?? .init()
            if useTrackerValue {
                guard let registry = extensionRuntimeRegistry,
                      let installed = trackingModel.enabledTrackerInstallations.first(where: { trackingModel.trackerID(for: $0) == link.trackerID }) else { throw TrackerImportError.changed }
                let provider = try await registry.tracker(for: installed)
                let fetched = try await provider.progress(remoteWorkID: current.remoteWorkID)
                remoteChoice = fetched.map(TrackerSyncSnapshot.init) ?? .init()
                guard remoteChoice.value(for: conflict.field) == conflict.trackerValue,
                      !sourcesModel.isPrivate, !settingsSyncModel.incognitoMode,
                      sourcesModel.isCurrentInstallation(installed) else { throw TrackerImportError.changed }
            }
            remoteChoice.assign(conflict.field, value: conflict.trackerValue)
            if useTrackerValue {
                try await applyRemoteTrackerSnapshot(remoteChoice, pulledFields: [conflict.field],
                    workID: work.id, installments: installments, expectedLocal: reviewedLocal)
            }
            current.conflicts.removeAll { $0.id == conflict.id }
            current.lastSynced.copy(conflict.field, from: remoteChoice)
            try await database.save(trackerLink: current)
            trackingModel.trackerLinksByWork[work.id] = try await database.trackerLinks(for: work.id)
            if !useTrackerValue {
                let local = try await trackingModel.localTrackerSnapshot(for: work.id)
                let dates: Set<TrackerSyncField> = [.startDate, .finishDate]
                await trackingModel.enqueueTrackerUpdate(.init(trackerID: current.trackerID, remoteWorkID: current.remoteWorkID,
                    chapter: local.chapter, volume: local.volume, status: local.status, score: local.score,
                    dateUpdates: dates.contains(conflict.field) && current.supportsDateUpdates == true
                        ? .init(startDate: local.startDate, finishDate: local.finishDate, fields: [conflict.field]) : nil,
                    fieldsToUpdate: [conflict.field]), link: current)
            }
            return true
        } catch {
            trackingModel.trackerSyncErrors[work.id] = error.localizedDescription
            sourcesModel.show(error, title: "Couldn’t resolve tracker conflict")
            return false
        }
    }

    func prepareTrackerImport(work: Work, link: TrackerLink) async throws -> TrackerImportPreview {
        guard !sourcesModel.isPrivate, !settingsSyncModel.incognitoMode, let database, let extensionRuntimeRegistry,
              let installed = trackingModel.enabledTrackerInstallations.first(where: { trackingModel.trackerID(for: $0) == link.trackerID }),
              trackingModel.beginLinkOperation(trackerID: link.trackerID, remoteWorkID: link.remoteWorkID) else {
            throw SourceError.transport("Tracking is busy or unavailable. Try again.")
        }
        defer { trackingModel.finishLinkOperation(trackerID: link.trackerID, remoteWorkID: link.remoteWorkID) }
        let provider = try await extensionRuntimeRegistry.tracker(for: installed)
        guard let fetched = try await provider.progress(remoteWorkID: link.remoteWorkID) else { throw TrackerImportError.changed }
        guard var current = try await database.trackerLinks(for: work.id).first(where: { $0.trackerID == link.trackerID }),
              current.generation == link.generation, !sourcesModel.isPrivate,
              !settingsSyncModel.incognitoMode, sourcesModel.isCurrentInstallation(installed) else { throw TrackerImportError.changed }
        current.generation = current.generation ?? UUID()
        current.lastRemote = fetched; current.lastPulledAt = .now
        try await database.save(trackerLink: current)
        trackingModel.trackerLinksByWork[work.id] = try await database.trackerLinks(for: work.id)
        guard let persisted = trackingModel.trackerLinksByWork[work.id]?.first(where: { $0.trackerID == link.trackerID }) else { throw TrackerImportError.changed }
        return try await trackerImportPreview(work: work, link: persisted)
    }

    /// Shared by the live review and isolated screenshot fixtures.
    func trackerImportPreview(work: Work, link: TrackerLink) async throws -> TrackerImportPreview {
        guard let database, let fetched = link.lastRemote else { throw TrackerImportError.changed }
        let chapters = try await database.installments(for: work.id)
        let progresses = try await database.progresses(for: work.id)
        let remote = TrackerSyncSnapshot(fetched)
        let mapped: [Installment]
        if let boundary = remote.chapter {
            guard let result = TrackerChapterMapping.importChapters(boundary: boundary, chapters: chapters) else {
                throw SourceError.transport(TrackerChapterMapping.issue(in: chapters) ?? "Tracker progress cannot be matched safely.")
            }
            mapped = result
        } else if let volume = remote.volume, volume.isFinite, volume >= 0,
                  TrackerChapterMapping.issue(in: chapters) == nil,
                  chapters.allSatisfy({ $0.volume.map { $0.isFinite && $0 >= 0 } == true }) {
            mapped = ReaderChapterPolicy.ordered(chapters.filter { $0.volume! <= volume })
        } else { throw SourceError.transport("Tracker progress cannot be matched safely.") }
        let complete = Set(progresses.filter { $0.highestProgression >= 1 }.map(\.installmentID))
        let affected = Set(mapped.map(\.id)).subtracting(complete)
        var projected = progresses
        let projectedDate = Date.now
        for chapter in chapters where affected.contains(chapter.id) {
            if let index = projected.firstIndex(where: { $0.installmentID == chapter.id }) {
                projected[index].highestProgression = 1; projected[index].modifiedAt = projectedDate
            } else {
                projected.append(.init(workID: work.id, installmentID: chapter.id,
                    locator: .image(page: 0, total: chapter.pageCount, offset: 0),
                    currentProgression: 0, highestProgression: 1, modifiedAt: projectedDate, deviceID: deviceID))
            }
        }
        let sessions = try await database.sessions(for: work.id)
        let next = ContinueReadingPolicy.item(work: work, sessions: sessions, installments: chapters,
            progresses: projected, fallsBackToOldest: true)?.installment
        return .init(link: link, remote: remote, chapters: chapters, progresses: progresses,
                     affectedIDs: affected, continuation: next, sessions: sessions)
    }

    func applyTrackerImport(work: Work, preview: TrackerImportPreview) async -> Bool {
        guard work.id == preview.link.workID, !sourcesModel.isPrivate, !settingsSyncModel.incognitoMode, let database, let extensionRuntimeRegistry,
              let installed = trackingModel.enabledTrackerInstallations.first(where: { trackingModel.trackerID(for: $0) == preview.link.trackerID }),
              trackingModel.beginLinkOperation(trackerID: preview.link.trackerID, remoteWorkID: preview.link.remoteWorkID) else { return false }
        defer { trackingModel.finishLinkOperation(trackerID: preview.link.trackerID, remoteWorkID: preview.link.remoteWorkID) }
        do {
            let provider = try await extensionRuntimeRegistry.tracker(for: installed)
            guard let fetched = try await provider.progress(remoteWorkID: preview.link.remoteWorkID),
                  TrackerSyncSnapshot(fetched) == preview.remote,
                  !sourcesModel.isPrivate, !settingsSyncModel.incognitoMode, sourcesModel.isCurrentInstallation(installed) else { throw TrackerImportError.changed }
            let ids = try await database.applyTrackerImport(preview, deviceID: deviceID)
            trackingModel.progressRevision &+= 1
            do {
                try await trackingModel.trackerQueue?.excludeFields([.chapter, .volume],
                    trackerID: preview.link.trackerID, remoteWorkID: preview.link.remoteWorkID)
            } catch {
                sourcesModel.show(error, title: "Progress saved; couldn’t clear the pending tracker update")
            }
            await settingsSyncModel.queueCloudSaves(ids.map(CloudSyncRecordID.chapterProgress) + [CloudSyncRecordID.progress(workID: work.id)])
            trackingModel.trackerLinksByWork[work.id] = try await database.trackerLinks(for: work.id)
            await libraryModel.refreshLibraryCounts(for: work.id)
            await libraryModel.refreshLibrary(showsLoadingIndicator: false)
            trackingModel.trackerSyncErrors[work.id] = nil
            return true
        } catch {
            trackingModel.trackerSyncErrors[work.id] = error.localizedDescription
            sourcesModel.show(error, title: "Couldn’t apply tracker progress")
            return false
        }
    }

    func applyRemoteTrackerSnapshot(
        _ remote: TrackerSyncSnapshot,
        pulledFields: Set<TrackerSyncField>,
        workID: WorkID,
        installments: [Installment],
        expectedLocal: TrackerSyncSnapshot? = nil
    ) async throws {
        guard let database else { return }
        let metadataFields = pulledFields.subtracting([.chapter, .volume])
        if !metadataFields.isEmpty {
            let expected: TrackerSyncSnapshot
            if let expectedLocal { expected = expectedLocal }
            else { expected = try await trackingModel.localTrackerSnapshot(for: workID) }
            let result = try await database.applyTrackerMetadata(remote, fields: metadataFields,
                expected: expected, workID: workID, deviceID: deviceID)
            libraryModel.userTitleStates[workID] = result.state
            if let id = result.tombstoneID { await settingsSyncModel.queueCloudSave(CloudSyncRecordID.tombstone(id)) }
            if let id = result.supersededTombstoneID { await cloudSyncEngine?.queueDelete(recordName: CloudSyncRecordID.tombstone(id)) }
            await settingsSyncModel.queueCloudSave(CloudSyncRecordID.titleState(workID: workID))
        }

        if pulledFields.contains(.chapter), let chapter = remote.chapter {
            try await applyForwardChapterCount(chapter, workID: workID, installments: installments, updatesTrackingStatus: false)
        } else if pulledFields.contains(.volume), let volume = remote.volume {
            let target = volume.rounded(.down)
            let volumeInstallments = installments.filter { ($0.volume ?? .infinity) <= target }
            try await markInstallmentsComplete(volumeInstallments, workID: workID, updatesTrackingStatus: false)
        }
    }

}

private extension TrackerSyncValue {
    var numberForProgress: Double? {
        guard case let .number(number) = self else { return nil }
        return number
    }
}

private extension TrackerSyncSnapshot {
    func needsReview(_ field: TrackerSyncField, comparedWith remote: Self) -> Bool {
        if field == .chapter || field == .volume {
            // A title absent from a list and an untouched local milestone both mean zero.
            if (value(for: field).numberForProgress ?? 0) == 0,
               (remote.value(for: field).numberForProgress ?? 0) == 0 { return false }
        }
        return value(for: field) != remote.value(for: field)
    }

    mutating func assign(_ field: TrackerSyncField, value: TrackerSyncValue) {
        switch (field, value) {
        case let (.chapter, .number(v)): chapter = v
        case let (.volume, .number(v)): volume = v
        case let (.rating, .number(v)): score = v
        case let (.status, .status(v)): status = v
        case let (.startDate, .date(v)): startDate = v
        case let (.finishDate, .date(v)): finishDate = v
        case (.rating, .none): score = nil
        case (.status, .none): status = nil
        case (.startDate, .none): startDate = nil
        case (.finishDate, .none): finishDate = nil
        default: break
        }
    }
}
