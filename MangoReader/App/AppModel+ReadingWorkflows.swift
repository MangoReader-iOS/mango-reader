import Foundation
import ImageIO
import MangoReaderData
import MangoReaderDomain
import MangoReaderExtensions
import MangoReaderReaders
import MangoReaderSources
import MangoReaderSync
import Observation
import OSLog
import SwiftUI
import WebKit

/// Inherited by reading writes and their completion side effects, without
/// changing the immediate refresh behavior of Library and Settings actions.
nonisolated enum ReadingRefreshPolicy: Sendable {
    case immediate, afterReaderCloses
    @TaskLocal static var current: Self = .immediate
}

/// Lives with AppModel so a dismissed view cannot cancel accepted progress.
@MainActor
final class ReaderWriteQueue {
    private var tail: Task<Void, Never>?
    private var revision: UInt = 0
    private(set) var readers: Set<UUID> = []

    func begin(_ id: UUID) { readers.insert(id) }
    func end(_ id: UUID) { readers.remove(id) }

    func enqueue(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        let previous = tail
        revision &+= 1
        let token = revision
        tail = Task { [self] in
            await previous?.value
            await ReadingRefreshPolicy.$current.withValue(.afterReaderCloses) {
                await operation()
            }
            if token == revision { tail = nil }
        }
    }

    func drain() async {
        while let pending = tail { await pending.value }
    }
}

extension AppModel {
    func finishReaderActivity(_ id: UUID, workID: WorkID) {
        readerWrites.end(id)
        readerRefreshWorkIDs.insert(workID)
        Task { await refreshAfterReaderDismissal() }
    }

    func refreshAfterReaderDismissal() async {
        await readerWrites.drain()
        guard readerWrites.readers.isEmpty else { return }
        let workIDs = readerRefreshWorkIDs
        readerRefreshWorkIDs.removeAll()
        for id in workIDs { await refreshCachedWorkFromStorage(id) }
        await libraryModel.flushDeferredReadingRefreshes()
    }

    @concurrent
    nonisolated static func completedDuplicates(of chapter: Installment, in chapters: [Installment]) async -> [Installment] {
        chapters.filter { $0.id != chapter.id && ReaderChapterPolicy.areDuplicates($0, chapter) }
    }

    func prepareToContinue(
        work: Work,
        installments: [Installment]
    ) async -> PreparedReaderContent? {
        guard !Task.isCancelled else { return nil }
        do {
            let item = try await libraryModel.continuationItem(
                work: work,
                installments: installments,
                fallsBackToOldest: true
            )
            guard let item else { return nil }
            return await prepareToRead(
                work: item.work,
                installment: item.installment,
                installments: installments
            )
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled else { return nil }
            sourcesModel.show(error, title: "Couldn’t continue reading")
            return nil
        }
    }

    func prepareToResume(_ item: ContinueReadingItem) async -> PreparedReaderContent? {
        do {
            let snapshot = try await libraryModel.workDetailSnapshot(for: item.work)
            guard let resolvedItem = try await libraryModel.continuationItem(
                work: snapshot.work,
                installments: snapshot.installments,
                fallsBackToOldest: true
            ) else {
                feedback.alert = AppAlert(
                    title: "Installment unavailable",
                    message: "No readable installment could be found for this title."
                )
                return nil
            }
            return await prepareToRead(
                work: snapshot.work,
                installment: resolvedItem.installment,
                installments: snapshot.installments
            )
        } catch is CancellationError {
            return nil
        } catch {
            feedback.alert = AppAlert(
                title: "Couldn’t open publication",
                message: error.localizedDescription
            )
            return nil
        }
    }

    func prepareToResume(session: ReadingSession, work: Work) async -> PreparedReaderContent? {
        do {
            let snapshot = try await libraryModel.workDetailSnapshot(for: work)
            guard let installment = snapshot.installments.first(where: {
                $0.id == session.installmentID
            }) else {
                feedback.alert = AppAlert(
                    title: "Installment unavailable",
                    message: "This reading session refers to an installment that is no longer available from the title."
                )
                return nil
            }
            return await prepareToRead(
                work: snapshot.work,
                installment: installment,
                installments: snapshot.installments
            )
        } catch is CancellationError {
            return nil
        } catch {
            feedback.alert = AppAlert(
                title: "Couldn’t open publication",
                message: error.localizedDescription
            )
            return nil
        }
    }

    func recordReadingProgress(
        work: Work,
        installment: Installment,
        locator: ReadingLocator,
        modifiedAt: Date = .now
    ) async {
        guard !Task.isCancelled, !settingsSyncModel.incognitoMode, let database else { return }
        do {
            let previous = try await database.progress(
                workID: work.id,
                installmentID: installment.id
            )
            let previousHighestProgression = previous?.highestProgression ?? 0
            let progression = LibraryModel.progression(for: locator)
                ?? previous?.currentProgression
                ?? 0
            var isFirstActivity = false
            if progression > 0, previousHighestProgression == 0 {
                isFirstActivity = !(try await database.progresses(for: work.id)).contains { $0.highestProgression > 0 }
            }
            let progress = ReadingProgress(
                id: previous?.id ?? UUID(),
                workID: work.id,
                installmentID: installment.id,
                locator: locator,
                currentProgression: progression,
                highestProgression: max(
                    progression,
                    previousHighestProgression
                ),
                modifiedAt: modifiedAt,
                deviceID: deviceID
            )
            let didFinishInstallment = previousHighestProgression < 1
                && progress.highestProgression >= 1
            let trackingBefore = didFinishInstallment ? (try? await trackingModel.localTrackerSnapshot(for: work.id)) : nil
            try await database.save(progress: progress)
            if isFirstActivity { await fillTrackingStartDate(for: work.id, now: modifiedAt) }
            if didFinishInstallment {
                await libraryModel.refreshLibraryCounts(for: work.id)
                await libraryModel.refreshLibrary()
            }
            await settingsSyncModel.queueCloudSaves([CloudSyncRecordID.progress(workID: work.id), CloudSyncRecordID.chapterProgress(installment.id)])
            if didFinishInstallment {
                await advanceStatusAfterFirstCompletion(workID: work.id)
                if let trackingBefore { await trackingModel.enqueueCompletedInstallment(installment, since: trackingBefore) }
            }
            if didFinishInstallment, settingsSyncModel.automationRules.deletesCompletedDownloads {
                await performReadingCompletedLibraryMaintenance()
            }
        } catch is CancellationError {
            // A newer reader position cancels the previous debounced save.
            return
        } catch {
            Logger(subsystem: "com.k800k.manko", category: "ReadingProgress").error(
                "Could not save reading progress: \(String(describing: error), privacy: .private)"
            )
            sourcesModel.show(error, title: "Couldn’t save reading progress")
        }
    }

    func markRead(
        work: Work,
        installment: Installment,
        announces: Bool = true,
        runsAutomation: Bool = true,
        locator: ReadingLocator? = nil,
        modifiedAt: Date = .now
    ) async -> Bool {
        guard !settingsSyncModel.incognitoMode else {
            if announces {
                feedback.alert = AppAlert(
                    title: "Incognito mode is on",
                    message: "Turn off incognito mode before changing reading progress."
                )
            }
            return false
        }
        guard let database else { return false }

        do {
            let existing = try await database.progress(
                workID: work.id,
                installmentID: installment.id
            )
            let didFinishInstallment = (existing?.highestProgression ?? 0) < 1
            let trackingBefore = didFinishInstallment ? (try? await trackingModel.localTrackerSnapshot(for: work.id)) : nil
            try await database.save(
                progress: ReadingProgress(
                    id: existing?.id ?? UUID(),
                    workID: work.id,
                    installmentID: installment.id,
                    locator: locator ?? existing?.locator ?? .image(page: 1, total: 1, offset: 0),
                    currentProgression: 1,
                    highestProgression: 1,
                    modifiedAt: modifiedAt,
                    deviceID: deviceID
                )
            )
            await libraryModel.refreshLibraryCounts(for: work.id)
            if announces {
                await libraryModel.refreshLibrary()
            }
            await settingsSyncModel.queueCloudSaves([CloudSyncRecordID.progress(workID: work.id), CloudSyncRecordID.chapterProgress(installment.id)])
            if didFinishInstallment {
                await advanceStatusAfterFirstCompletion(workID: work.id)
                if let trackingBefore { await trackingModel.enqueueCompletedInstallment(installment, since: trackingBefore) }
            }
            if didFinishInstallment,
               runsAutomation,
               settingsSyncModel.automationRules.deletesCompletedDownloads {
                await performReadingCompletedLibraryMaintenance()
            }
            if didFinishInstallment, announces {
                await libraryModel.refreshHistory()
            }
            if announces {
                feedback.showStatus("Marked \(installment.title) as read.", systemImage: "checkmark.circle.fill")
            }
            return true
        } catch {
            sourcesModel.show(error, title: "Couldn’t mark \(installment.title) as read")
            return false
        }
    }

    func markUnread(work: Work, installment: Installment) async -> Bool {
        await resetReadingProgress(work: work, installments: [installment], announces: true)
    }

    func resetReadingProgress(work: Work, installments: [Installment], announces: Bool) async -> Bool {
        guard !Task.isCancelled, !settingsSyncModel.incognitoMode, let database else { return false }
        do {
            let resetIDs = try await database.resetProgress(workID: work.id, installments: installments, deviceID: deviceID)
            await settingsSyncModel.queueCloudSaves(resetIDs.map(CloudSyncRecordID.chapterProgress) + [CloudSyncRecordID.progress(workID: work.id)])
            await libraryModel.refreshLibraryCounts(for: work.id)
            if announces {
                await libraryModel.refreshLibrary(showsLoadingIndicator: false)
                await libraryModel.refreshHistory()
                feedback.showStatus("Marked as unread.", systemImage: "circle")
            }
            return true
        } catch {
            sourcesModel.show(error, title: "Couldn’t mark as unread")
            return false
        }
    }

    func finishReadingSession(
        id: UUID,
        work: Work,
        installment: Installment,
        startedAt: Date,
        startProgression: Double,
        locator: ReadingLocator?,
        secondsRead: TimeInterval? = nil,
        readingUnitCount: Int? = nil,
        progressModifiedAt: Date? = nil,
        savesPosition: Bool = true
    ) async {
        guard !settingsSyncModel.incognitoMode, let database else { return }
        let endedAt = Date.now
        let endProgression = locator.flatMap(LibraryModel.progression(for:)) ?? startProgression
        do {
            if let locator, savesPosition {
                await recordReadingProgress(work: work, installment: installment, locator: locator,
                    modifiedAt: progressModifiedAt ?? .now)
            }
            let session = ReadingSession(
                id: id,
                workID: work.id,
                installmentID: installment.id,
                startedAt: startedAt,
                endedAt: endedAt,
                secondsRead: max(0, secondsRead ?? endedAt.timeIntervalSince(startedAt)),
                startProgression: startProgression,
                endProgression: endProgression,
                readingUnitCount: readingUnitCount ?? {
                    guard case let .image(_, total, _) = locator else { return nil }
                    return total
                }()
            )
            try await database.save(session: session)
            await settingsSyncModel.queueCloudSave(CloudSyncRecordID.session(session.id))
            await libraryModel.refreshLibrary(showsLoadingIndicator: false)
            await libraryModel.refreshHistory()
            if libraryModel.readingStats != nil { _ = await libraryModel.loadReadingStats() }
        } catch {
            sourcesModel.show(error, title: "Couldn’t save reading session")
        }
    }

    func prepareReader(_ request: ReaderOpenRequest) async throws -> PreparedReaderContent {
        try Task.checkCancellation()
        #if DEBUG
        if AppFixtures.isVerifyingReaderOpening, request.work.id == AppFixtures.openingVerificationWork.id {
            return try await AppFixtures.prepareOpeningVerification()
        }
        #endif
        let work = request.work
        switch request.target {
        case let .installment(installment, chapters):
            return try await prepareToReadOrThrow(work: work, installment: installment, installments: chapters, announcesFailure: false)
        case let .continuation(chapters):
            let snapshot: WorkDetailSnapshot
            if let chapters { snapshot = WorkDetailSnapshot(work: work, installments: chapters) }
            else { snapshot = try await libraryModel.workDetailSnapshot(for: work) }
            guard let item = try await libraryModel.continuationItem(work: snapshot.work, installments: snapshot.installments, fallsBackToOldest: true) else {
                throw ReaderPreparationFailure.unavailable("No readable volume could be found for this title.")
            }
            return try await prepareToReadOrThrow(work: item.work, installment: item.installment, installments: snapshot.installments, announcesFailure: false)
        case let .history(session):
            let snapshot = try await libraryModel.workDetailSnapshot(for: work)
            guard let installment = snapshot.installments.first(where: { $0.id == session.installmentID }) else {
                throw ReaderPreparationFailure.unavailable("This reading session’s volume is no longer available.")
            }
            return try await prepareToReadOrThrow(work: snapshot.work, installment: installment, installments: snapshot.installments, announcesFailure: false)
        }
    }

    func importedBookRecovery(for request: ReaderOpenRequest) async -> ImportedBookRecovery? {
        guard request.work.sourceID == .local,
              let snapshot = try? await libraryModel.workDetailSnapshot(for: request.work) else { return nil }
        let installment: Installment?
        switch request.target {
        case let .installment(value, _): installment = value
        case let .history(session):
            installment = snapshot.installments.first { $0.id == session.installmentID }
        case .continuation:
            installment = try? await libraryModel.continuationItem(
                work: snapshot.work, installments: snapshot.installments, fallsBackToOldest: true
            )?.installment
        }
        guard !Task.isCancelled, let installment,
              let state = importedFileAvailability[installment.id], state != .ready else { return nil }
        return ImportedBookRecovery(work: snapshot.work, installment: installment)
    }

    /// Compatibility entry point for downloads, chapter switching and recovery.
    func prepareToRead(
        work: Work, installment: Installment, installments: [Installment]? = nil, announcesFailure: Bool = true
    ) async -> PreparedReaderContent? {
        do {
            return try await prepareToReadOrThrow(work: work, installment: installment, installments: installments, announcesFailure: announcesFailure)
        } catch is CancellationError { return nil }
        catch {
            if announcesFailure, !Task.isCancelled, feedback.alert == nil {
                sourcesModel.show(error, title: "Couldn’t prepare this chapter")
            }
            return nil
        }
    }

    func prepareToReadOrThrow(
        work: Work,
        installment: Installment,
        installments knownInstallments: [Installment]? = nil,
        announcesFailure: Bool = true
    ) async throws -> PreparedReaderContent {
        try Task.checkCancellation()
        #if DEBUG
        if let fixture = try AppFixtures.readerChapterFixture(work: work, installment: installment) { return fixture }
        #endif
        var cachedInstallments = knownInstallments ?? [installment]
        if !cachedInstallments.contains(where: { $0.id == installment.id }) {
            cachedInstallments.append(installment)
        }
        guard await libraryModel.cacheReadingContentIfNeeded(
            work: work,
            installments: cachedInstallments
        ) else { throw ReaderPreparationFailure.unavailable("Reading information could not be saved. Try again.") }
        try Task.checkCancellation()

        if work.sourceID == .local {
            guard let readable = await prepareImportedBook(
                work: work, installment: installment, announcesFailure: announcesFailure
            ) else {
                try Task.checkCancellation()
                throw ReaderPreparationFailure.unavailable(importedFileAvailability[installment.id]?.title ?? "This book is not available on this device.")
            }
            return PreparedReaderContent(chapters: cachedInstallments,
                chaptersAreComplete: knownInstallments != nil, work: work, installment: readable)
        }

        if let snapshot = transfersModel.downloadSnapshot(for: installment.id), snapshot.state == .completed,
           let downloadCoordinator,
           let localURL = await downloadCoordinator.localFileURL(for: snapshot.id),
           FileManager.default.fileExists(atPath: localURL.path) {
            try Task.checkCancellation()
            var localInstallment = installment
            localInstallment.acquisitionURL = localURL
            if localInstallment.format == .remoteImageSequence {
                // Configured image-sequence acquisitions are accepted
                // only after archive validation, so the local artifact is CBZ.
                localInstallment.format = .cbz
            }
            return PreparedReaderContent(chapters: cachedInstallments, chaptersAreComplete: work.sourceID == .local && knownInstallments != nil, work: work, installment: localInstallment)
        }

        if installment.format == .epub,
           sourcesModel.installedRepositorySources.contains(where: { $0.descriptor.id == work.sourceID && $0.sourceID == "LNori" && $0.isEnabled && $0.version.compare("0.1.1", options: .numeric) != .orderedAscending }),
           let descriptor = sourcesModel.sources.first(where: { $0.id == work.sourceID && $0.isEnabled }) {
            let publication = sourcesModel.progressivePublication(work: work, installment: installment, descriptor: descriptor)
            return PreparedReaderContent(chapters: cachedInstallments, chaptersAreComplete: knownInstallments != nil,
                progressivePublication: publication, work: work, installment: installment)
        }

        var legacyNovelContent: MangoReaderPublicationContent?
        var rebuildGeneratedNovel = false
        if let localURL = installment.acquisitionURL, localURL.isFileURL,
           FileManager.default.fileExists(atPath: localURL.path) {
            let generatedSource = sourcesModel.installedRepositorySources.first { $0.descriptor.id == work.sourceID }
            let isGeneratedPublication = generatedSource != nil && localURL.pathComponents.contains("MankoExtensionPublications")
            let isGeneratedLNori = isGeneratedPublication && generatedSource?.sourceID == "LNori"
            if isGeneratedLNori, sourcesModel.usesPersistentContentCache {
                do {
                    legacyNovelContent = try await MangoReaderExtensionEPUBBuilder.legacyContent(at: localURL,
                        workID: work.remoteID ?? work.id.description, volumeID: installment.remoteID ?? installment.id.description)
                } catch { rebuildGeneratedNovel = true }
                try Task.checkCancellation()
            }
            // Private reading does not adopt a persistent generated cache file.
            if legacyNovelContent == nil, !rebuildGeneratedNovel, !isGeneratedPublication || sourcesModel.usesPersistentContentCache {
                var localInstallment = installment
                if localInstallment.format == .remoteImageSequence { localInstallment.format = .cbz }
                return PreparedReaderContent(chapters: cachedInstallments, chaptersAreComplete: work.sourceID == .local && knownInstallments != nil, work: work, installment: localInstallment)
            }
        }

        if installment.format == .remoteImageSequence,
           let descriptor = sourcesModel.sources.first(where: {
               $0.id == work.sourceID
                   && $0.isEnabled
           })
        {
            do {
                if sourcesModel.usesPersistentContentCache {
                    let manifestKey = sourcesModel.sourceCacheKey(work.sourceID, operation: "manifest-v2", query: [work.id.description, installment.remoteID ?? installment.id.description])
                    if installment.workID == work.id,
                       let entry = await sourcesModel.contentCache.entry(for: manifestKey),
                       let manifest = try? entry.decode(CachedRemoteManifest.self),
                       manifest.workID == work.id, manifest.installmentID == installment.id,
                       !manifest.pages.isEmpty, manifest.pages.allSatisfy({ $0.sourceID == work.sourceID && $0.installmentID == installment.id }) {
                        let publication = try await libraryModel.remoteImagePublication(for: work, installment: installment)
                        let detailKey = sourcesModel.sourceCacheKey(work.sourceID, operation: "detail", query: work.remoteID ?? work.id.description)
                        let detail = await sourcesModel.contentCache.entry(for: detailKey)
                        let snapshot = try? detail?.decode(RemoteLibrarySnapshot.self)
                        return PreparedReaderContent(chapters: snapshot?.installments ?? cachedInstallments,
                            chaptersAreComplete: snapshot != nil, remotePublication: publication,
                            work: snapshot?.work ?? work, installment: installment)
                    }
                }
                let prepared: ExtensionContentRefresh? = try await sourcesModel.performSourceOperation { [weak self] in
                    guard let self else { throw CancellationError() }
                    let source = try await self.sourcesModel.makeRemoteSource(for: descriptor)
                    let capabilities = await source.descriptor.capabilities
                    guard capabilities.contains(.imageSequence) else { return nil }
                    return try await self.libraryModel.prepareExtensionContent(
                        source: source,
                        work: work,
                        installment: installment
                    )
                }
                try Task.checkCancellation()
                if let prepared {
                    guard await libraryModel.cacheReadingContentIfNeeded(
                        work: prepared.work,
                        installments: prepared.installments
                    ) else { throw ReaderPreparationFailure.unavailable("Reading information could not be saved. Try again.") }
                    try Task.checkCancellation()
                    return PreparedReaderContent(
                        chapters: prepared.installments,
                        chaptersAreComplete: descriptor.kind == .mangoReaderExtension,
                        work: prepared.work,
                        installment: prepared.selectedInstallment
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                if descriptor.kind == .mangoReaderExtension {
                    throw error
                }
                // Compiled sources retain their existing offline-acquisition fallback.
            }
        }

        if installment.format == .epub,
           let descriptor = sourcesModel.sources.first(where: {
               $0.id == work.sourceID && $0.kind == .mangoReaderExtension && $0.isEnabled
           }) {
            let publicationScope = sourcesModel.contentCacheScope(work.sourceID)
            let content = try await sourcesModel.cachedPublicationContent(work: work, installment: installment, descriptor: descriptor, legacyContent: legacyNovelContent)
            try Task.checkCancellation()
            let installed = sourcesModel.installedRepositorySources.first { $0.descriptor.id == work.sourceID }
            let isPrivate = !sourcesModel.usesPersistentContentCache
            var builder = MangoReaderExtensionEPUBBuilder()
            if self.isPrivate, let storagePaths {
                builder.destinationDirectory = storagePaths.cachesDirectory.appending(path: "Publications/\(UUID().uuidString)", directoryHint: .isDirectory)
            } else if isPrivate {
                builder.destinationDirectory = builder.destinationDirectory.appending(path: "Private/\(UUID().uuidString)", directoryHint: .isDirectory)
            }
            var delivered = false
            defer {
                if isPrivate, !delivered { try? FileManager.default.removeItem(at: builder.destinationDirectory) }
            }
            let log = OSLog(subsystem: "com.k800k.manko", category: "ReaderOpening")
            let id = OSSignpostID(log: log)
            os_signpost(.begin, log: log, name: "PublicationConversion", signpostID: id)
            let localURL: URL
            do {
                localURL = try await builder.build(content: content, title: installment.title,
                    sourceNamespace: installed?.id ?? work.sourceID.rawValue,
                    sectioned: installed?.sourceID == "LNori")
            } catch {
                os_signpost(.end, log: log, name: "PublicationConversion", signpostID: id)
                throw error
            }
            os_signpost(.end, log: log, name: "PublicationConversion", signpostID: id)
            try Task.checkCancellation()
            guard isPrivate == !sourcesModel.usesPersistentContentCache,
                  publicationScope == sourcesModel.contentCacheScope(work.sourceID) else { throw CancellationError() }
            var readable = installment
            readable.acquisitionURL = localURL
            delivered = true
            return PreparedReaderContent(chapters: cachedInstallments, work: work, installment: readable,
                temporaryPublicationURL: isPrivate ? localURL : nil)
        }

        try Task.checkCancellation()
        if work.sourceID != .local,
           installment.acquisitionURL == nil,
           !sourcesModel.sources.contains(where: { $0.id == work.sourceID && $0.isEnabled })
        {
            if announcesFailure { feedback.alert = AppAlert(
                title: "Source unavailable",
                message: "This title is in your synced History, but its source isn’t installed or enabled on this device. Add or enable the source to read it here."
            ) }
            throw ReaderPreparationFailure.unavailable("This title’s source isn’t installed or enabled. Add or enable the source to read it here.")
        }

        if announcesFailure { await enqueueDownload(work: work, installment: installment) }
        throw ReaderPreparationFailure.unavailable("Download this publication before reading it.")
    }
}
