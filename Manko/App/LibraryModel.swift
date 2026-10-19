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
final class LibraryModel {
    @ObservationIgnored var cloudSyncEngine: CloudSyncEngine?
    @ObservationIgnored var customCoverStore: CustomCoverStore?
    @ObservationIgnored var database: MankoDatabase?
    let defaults: UserDefaults
    let deviceID: String
    @ObservationIgnored var localPublicationCoverService: LocalPublicationCoverService?
    let feedback: AppFeedback
    let settingsSyncModel: SettingsSyncModel
    let sourcesModel: SourcesModel

    init(
        database: MankoDatabase?,
        defaults: UserDefaults,
        deviceID: String,
        feedback: AppFeedback,
        settingsSyncModel: SettingsSyncModel,
        sourcesModel: SourcesModel
    ) {
        self.database = database
        self.defaults = defaults
        self.deviceID = deviceID
        self.feedback = feedback
        self.settingsSyncModel = settingsSyncModel
        self.sourcesModel = sourcesModel
    }

    var library: [Work] = [] {
        didSet {
            // Build the searchable text when saved content changes, never while typing.
            librarySearchText = Dictionary(uniqueKeysWithValues: library.map { work in
                (work.id, ([work.title] + work.alternativeTitles + work.authors + work.tags)
                    .joined(separator: " ").mankoSearchNormalized)
            })
        }
    }

    @ObservationIgnored private var librarySearchText: [WorkID: String] = [:]
    @ObservationIgnored private var deferredReadingLibrary = false
    @ObservationIgnored private var deferredReadingHistory = false
    @ObservationIgnored private var deferredReadingStats = false
    @ObservationIgnored private var readingRefreshTask: Task<Void, Never>?
    @ObservationIgnored private(set) var readingRefreshRevision: UInt = 0

    func flushDeferredReadingRefreshes() async {
        if let readingRefreshTask { await readingRefreshTask.value }
        let library = deferredReadingLibrary, history = deferredReadingHistory, stats = deferredReadingStats
        guard library || history || stats else { return }
        deferredReadingLibrary = false; deferredReadingHistory = false; deferredReadingStats = false
        readingRefreshRevision &+= 1
        let task = Task {
            defer { readingRefreshTask = nil }
            await ReadingRefreshPolicy.$current.withValue(.immediate) {
                if library { await refreshLibrary(showsLoadingIndicator: false) }
                if history { await refreshHistory() }
                if stats, readingStats != nil { _ = await loadReadingStats() }
            }
        }
        readingRefreshTask = task
        await task.value
    }

    func filteredLibrary(matching query: String) -> [Work] {
        let tokens = query.mankoSearchNormalized.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return library }
        return library.filter { work in
            let text = librarySearchText[work.id, default: ""]
            return tokens.allSatisfy { text.contains($0) }
        }
    }

    var libraryEntries: [WorkID: LibraryEntry] = [:]

    var sessions: [ReadingSession] = []

    var historyWorks: [WorkID: Work] = [:]

    var historyInstallments: [InstallmentID: Installment] = [:]

    var continueReadingItem: ContinueReadingItem?

    var continueReadingItemsByWorkID: [WorkID: ContinueReadingItem] = [:]

    var categories: [MankoDomain.Category] = []

    var savedFilters: [SavedFilter] = []

    var activeSavedFilterID: UUID?

    var libraryCategoryScope: LibraryCategoryScope = .all

    var pinnedWorkIDs: Set<WorkID> = []

    var isLoading = false

    var isPerformingSelectionAction = false

    var pinOrderRevision = 0

    var isApplyingBulkSourceMigration = false

    var readingInsights: ReadingInsights?

    var readingStats: ReadingStatsSnapshot?

    var readingStatsRange: ReadingStatsRange = .thisYear

    var readingStatsError: String?

    @ObservationIgnored var readingStatsLoadGate = LatestOperationGate()

    @ObservationIgnored var readingStatsLoadHookForTesting: (@MainActor (ReadingStatsRange) async -> Void)?

    var userTitleStates: [WorkID: UserTitleState] = [:]

    var isLoadingInsights = false

    var isCheckingLibraryUpdates = false

    var libraryUpdatesLastCheckedAt: Date?

    @ObservationIgnored var libraryUpdatePlanLoaderForTesting: (@MainActor @Sendable (Work, [Installment]) async throws -> RemoteLibraryUpdatePlan)?

    @ObservationIgnored var localCoverAttemptedWorkIDs: Set<WorkID> = []

    func refreshLibrary(showsLoadingIndicator: Bool = true, animatesPinChange: Bool = false) async {
        if ReadingRefreshPolicy.current == .afterReaderCloses {
            deferredReadingLibrary = true
            return
        }
        let log = OSLog(subsystem: "com.k800k.manko", category: "ReaderPerformance")
        let signpost = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "Library Refresh", signpostID: signpost)
        defer { os_signpost(.end, log: log, name: "Library Refresh", signpostID: signpost) }
        guard let database else { return }
        if showsLoadingIndicator { isLoading = true }
        defer {
            if showsLoadingIndicator { isLoading = false }
        }
        do {
            async let loadedPinnedWorkIDs = database.pinnedWorkIDs()
            async let loadedEntries = database.libraryEntries()
            let loadedLibrary: [Work]
            if let activeSavedFilterID,
               let filter = savedFilters.first(where: { $0.id == activeSavedFilterID }) {
                loadedLibrary = try await database.library(matching: filter)
            } else {
                switch libraryCategoryScope {
                case .all:
                    loadedLibrary = try await database.library(sort: settingsSyncModel.librarySort)
                case let .category(categoryID):
                    loadedLibrary = try await database.library(matching: SavedFilter(
                        name: "",
                        categoryIDs: [categoryID],
                        sort: settingsSyncModel.librarySort
                    ))
                case .uncategorized:
                    loadedLibrary = try await database.uncategorizedLibrary(sort: settingsSyncModel.librarySort)
                }
            }
            let newPinnedWorkIDs = try await loadedPinnedWorkIDs
            let newEntries = try await loadedEntries
            library = loadedLibrary
            pinnedWorkIDs = newPinnedWorkIDs
            libraryEntries = newEntries
            if animatesPinChange { pinOrderRevision &+= 1 }
        } catch {
            sourcesModel.show(error, title: "Couldn’t load library")
        }
    }

    func showLibraryUpdateSummary(_ summary: LibraryUpdateBatchSummary) {
        if summary.failedTitleCount > 0 {
            let failed = "\(summary.failedTitleCount) title\(summary.failedTitleCount == 1 ? "" : "s") couldn’t be checked"
            if summary.updatedTitleCount > 0 {
                feedback.showStatus(
                    "\(summary.updatedTitleCount) title\(summary.updatedTitleCount == 1 ? "" : "s") updated · \(failed)",
                    systemImage: "exclamationmark.triangle.fill"
                )
            } else {
                feedback.showStatus(failed, systemImage: "exclamationmark.triangle.fill")
            }
        } else if summary.updatedTitleCount > 0 {
            feedback.showStatus(
                "Checked just now · \(summary.updatedTitleCount) title\(summary.updatedTitleCount == 1 ? "" : "s") updated"
            )
        } else {
            feedback.showStatus("Checked just now · Everything is up to date")
        }
    }

    var activeLibraryFilter: SavedFilter? {
        if let activeSavedFilterID,
           let saved = savedFilters.first(where: { $0.id == activeSavedFilterID }) {
            return saved
        }
        if let activeCategoryID = libraryCategoryScope.categoryID,
           let category = categories.first(where: { $0.id == activeCategoryID }) {
            return SavedFilter(
                name: category.name,
                categoryIDs: [category.id],
                sort: settingsSyncModel.librarySort
            )
        }
        return nil
    }

    func refreshHistory() async {
        if ReadingRefreshPolicy.current == .afterReaderCloses {
            deferredReadingHistory = true
            return
        }
        let log = OSLog(subsystem: "com.k800k.manko", category: "ReaderPerformance")
        let signpost = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "History Refresh", signpostID: signpost)
        defer { os_signpost(.end, log: log, name: "History Refresh", signpostID: signpost) }
        guard let database else { return }
        do {
            let loaded = try await database.sessions(limit: 500)
            let loadedProgresses = try await database.progresses()
            let continuationWorkIDs = Set(loaded.map(\.workID))
                .union(loadedProgresses.map(\.workID))
            async let loadedWorks = database.works(ids: continuationWorkIDs)
            async let loadedInstallments = database.installments(ids: Set(loaded.map(\.installmentID)))
            let works = try await Dictionary(uniqueKeysWithValues: loadedWorks.map { ($0.id, $0) })
            let installments = try await Dictionary(
                uniqueKeysWithValues: loadedInstallments.map { ($0.id, $0) }
            )
            sessions = loaded.filter { works[$0.workID] != nil }
            historyWorks = works
            historyInstallments = installments
            let continueReadingState = try await loadContinueReadingState(
                sessions: sessions,
                worksByID: works,
                progresses: loadedProgresses,
                database: database
            )
            continueReadingItem = continueReadingState.item
            continueReadingItemsByWorkID = continueReadingState.itemsByWorkID
        } catch {
            sourcesModel.show(error, title: "Couldn’t load history")
        }
    }

    func loadContinueReadingState(
        sessions: [ReadingSession],
        worksByID: [WorkID: Work],
        progresses: [ReadingProgress],
        database: MankoDatabase
    ) async throws -> (item: ContinueReadingItem?, itemsByWorkID: [WorkID: ContinueReadingItem]) {
        var installmentsByWorkID: [WorkID: [Installment]] = [:]
        let progressesByWorkID = Dictionary(grouping: progresses, by: \.workID)
        let continuationWorkIDs = Set(sessions.map(\.workID))
            .union(progresses.map(\.workID))
        for workID in continuationWorkIDs where worksByID[workID] != nil {
            installmentsByWorkID[workID] = try await database.installments(for: workID)
        }

        var itemsByWorkID: [WorkID: ContinueReadingItem] = [:]
        for workID in continuationWorkIDs {
            if let item = ContinueReadingPolicy.item(
                sessions: sessions.filter { $0.workID == workID },
                worksByID: worksByID,
                installmentsByWorkID: installmentsByWorkID,
                progressesByWorkID: progressesByWorkID
            ) {
                itemsByWorkID[workID] = item
            }
        }

        return (
            ContinueReadingPolicy.item(
                sessions: sessions,
                worksByID: worksByID,
                installmentsByWorkID: installmentsByWorkID,
                progressesByWorkID: progressesByWorkID
            ),
            itemsByWorkID
        )
    }

    func continueReadingItem(for work: Work) async -> ContinueReadingItem? {
        guard let database else { return nil }
        do {
            async let loadedSessions = database.sessions(for: work.id)
            async let loadedInstallments = database.installments(for: work.id)
            let loadedProgresses = try await database.progresses(for: work.id)
            return ContinueReadingPolicy.item(
                work: work,
                sessions: try await loadedSessions,
                installments: try await loadedInstallments,
                progresses: loadedProgresses,
                fallsBackToOldest: false
            )
        } catch {
            sourcesModel.show(error, title: "Couldn’t continue reading")
            return nil
        }
    }

    func continuationItem(
        work: Work,
        installments: [Installment],
        fallsBackToOldest: Bool
    ) async throws -> ContinueReadingItem? {
        guard let database else {
            return ContinueReadingPolicy.item(
                work: work,
                sessions: [],
                installments: installments,
                progresses: [],
                fallsBackToOldest: fallsBackToOldest
            )
        }
        async let loadedSessions = database.sessions(for: work.id)
        let loadedProgresses = try await database.progresses(for: work.id)
        return ContinueReadingPolicy.item(
            work: work,
            sessions: try await loadedSessions,
            installments: installments,
            progresses: loadedProgresses,
            fallsBackToOldest: fallsBackToOldest
        )
    }

    func refreshCategories() async {
        guard let database else { return }
        do {
            categories = try await database.categories()
            if let activeCategoryID = libraryCategoryScope.categoryID,
               !categories.contains(where: { $0.id == activeCategoryID }) {
                setLibraryCategoryScope(.all)
            }
        } catch {
            sourcesModel.show(error, title: "Couldn’t load categories")
        }
    }

    func refreshSavedFilters() async {
        guard let database else { return }
        do {
            savedFilters = try await database.savedFilters()
            if let activeSavedFilterID,
               !savedFilters.contains(where: { $0.id == activeSavedFilterID }) {
                self.activeSavedFilterID = nil
                defaults.removeObject(forKey: "activeSavedFilterID")
            }
        } catch {
            sourcesModel.show(error, title: "Couldn’t load saved filters")
        }
    }

    func clearLibraryFilter() {
        activeSavedFilterID = nil
        setLibraryCategoryScope(.all)
        defaults.removeObject(forKey: "activeSavedFilterID")
        Task { await refreshLibrary() }
    }

    func setLibraryCategoryScope(_ scope: LibraryCategoryScope) {
        libraryCategoryScope = scope
        defaults.removeObject(forKey: "activeLibraryCategoryID")
        if let storageValue = scope.storageValue {
            defaults.set(storageValue, forKey: "activeLibraryCategoryScope")
        } else {
            defaults.removeObject(forKey: "activeLibraryCategoryScope")
        }
    }

    func deleteSavedFilter(_ filter: SavedFilter) async {
        guard let database else { return }
        do {
            try await database.deleteSavedFilter(id: filter.id)
            if activeSavedFilterID == filter.id {
                activeSavedFilterID = nil
                defaults.removeObject(forKey: "activeSavedFilterID")
            }
            await refreshSavedFilters()
            await refreshLibrary()
        } catch {
            sourcesModel.show(error, title: "Couldn’t delete filter")
        }
    }

    func customCoverURL(for work: Work) -> URL? {
        guard
            let path = work.customCoverPath,
            let customCoverStore
        else { return nil }
        return try? customCoverStore.managedURL(for: path)
    }

    func shareCoverData(for work: Work) async -> Data? {
        do {
            let data: Data?
            if let customURL = customCoverURL(for: work) {
                data = try await Self.readShareCoverData(from: customURL)
            } else if sourcesModel.isExtensionBacked(work) {
                data = try await sourcesModel.extensionCoverImageData(for: work)
            } else if let coverURL = work.coverURL {
                data = try await Self.readShareCoverData(from: coverURL)
            } else {
                data = nil
            }
            guard let data,
                  data.count <= 20 * 1_024 * 1_024,
                  SourcesModel.isDecodableRepositoryIcon(data)
            else { return nil }
            return data
        } catch is CancellationError {
            return nil
        } catch {
            _ = sourcesModel.handleCloudflareHandoff(error)
            return nil
        }
    }

    @concurrent
    static func readShareCoverData(from url: URL) async throws -> Data {
        if url.isFileURL {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        if let response = response as? HTTPURLResponse,
           !(200 ... 299).contains(response.statusCode)
        {
            throw URLError(.badServerResponse)
        }
        return data
    }

    func refreshLibraryCounts(for workID: WorkID) async {
        guard let database else { return }
        do {
            if let entry = try await database.refreshLibraryCounts(for: workID) {
                libraryEntries[workID] = entry
            } else {
                libraryEntries[workID] = nil
            }
        } catch {
            // Count refreshes are derived metadata. The underlying progress,
            // installment, and file mutations remain authoritative.
        }
    }

    func loadReadingStats(range: ReadingStatsRange? = nil) async -> Bool {
        if ReadingRefreshPolicy.current == .afterReaderCloses {
            deferredReadingStats = true
            return false
        }
        guard database != nil else { return false }
        let requestedRange = range ?? readingStatsRange
        let generation = readingStatsLoadGate.begin()
        readingStatsRange = requestedRange
        readingStatsError = nil
        isLoadingInsights = true
        defer {
            if readingStatsLoadGate.accepts(generation) {
                isLoadingInsights = false
                if Task.isCancelled, let readingStats { readingStatsRange = readingStats.range }
            }
        }
        do {
            if let readingStatsLoadHookForTesting {
                await readingStatsLoadHookForTesting(requestedRange)
            }
            guard !Task.isCancelled, readingStatsLoadGate.accepts(generation) else { return false }
            let snapshot = try await readingStatsSnapshot(range: requestedRange)
            guard !Task.isCancelled, readingStatsLoadGate.accepts(generation) else { return false }
            readingStats = snapshot
            readingInsights = snapshot.insights
            let titleStates = Dictionary(uniqueKeysWithValues: snapshot.titles.compactMap { title in
                title.titleState.map { (title.id, $0) }
            })
            userTitleStates.merge(titleStates) { _, incoming in incoming }
            return true
        } catch {
            guard !Task.isCancelled, readingStatsLoadGate.accepts(generation) else { return false }
            readingStatsError = error.localizedDescription
            return false
        }
    }

    /// Loads a snapshot without changing Activity's selection or published state.
    func readingStatsSnapshot(range: ReadingStatsRange) async throws -> ReadingStatsSnapshot {
        guard let database else {
            throw NSError(domain: "MankoReadingStats", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Reading stats are still starting. Try again shortly.",
            ])
        }
        try Task.checkCancellation()
        var now = Date.now
        var calendar = Calendar.current
        #if DEBUG
        if MankoScreenshotMode.isEnabled {
            now = MankoScreenshotMode.date
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        }
        #endif
        let interval = range.interval(now: now, calendar: calendar)
        let loadedSessions: [ReadingSession]
        let streakSessions: [ReadingSession]
        if interval == nil {
            loadedSessions = try await database.sessions(in: nil)
            streakSessions = loadedSessions
        } else {
            async let selectedLoad = database.sessions(in: interval)
            async let streakLoad = database.sessions(in: nil)
            (loadedSessions, streakSessions) = try await (selectedLoad, streakLoad)
        }

        let workIDs = Set(loadedSessions.map(\.workID))
        let installmentIDs = Set(loadedSessions.map(\.installmentID))
        async let workLoad = database.works(ids: workIDs)
        async let installmentLoad = database.installments(ids: installmentIDs)
        async let progressLoad = database.progresses(installmentIDs: installmentIDs)
        let (loadedWorks, loadedInstallments, loadedProgresses) = try await (workLoad, installmentLoad, progressLoad)
        let locatorCounts = Dictionary(uniqueKeysWithValues: loadedProgresses.compactMap { progress -> (InstallmentID, Int)? in
            guard case let .image(_, total?, _) = progress.locator, total > 0 else { return nil }
            return (progress.installmentID, total)
        })
        let works = Dictionary(
            uniqueKeysWithValues: loadedWorks.map { ($0.id, $0) }
        )
        let installments = Dictionary(
            uniqueKeysWithValues: loadedInstallments.map { ($0.id, $0) }
        )
        let titleStates = try await database.titleStates(workIDs: workIDs)
        let titleStatesByWork = Dictionary(
            uniqueKeysWithValues: titleStates.map { ($0.workID, $0) }
        )
        let contexts = loadedSessions.compactMap { session -> ReadingStatsSession? in
            guard let work = works[session.workID],
                  let installment = installments[session.installmentID]
            else { return nil }
            return ReadingStatsSession(
                session: session,
                work: work,
                installment: installment
            )
        }
        try Task.checkCancellation()
        return ReadingStatsSnapshot(
            range: range,
            sessions: contexts,
            titleStates: titleStatesByWork,
            streakSessions: streakSessions,
            fallbackReadingUnitCounts: locatorCounts,
            now: now,
            calendar: calendar
        )
    }

    func titleState(for workID: WorkID, reload: Bool = false) async -> UserTitleState? {
        if !reload, let cached = userTitleStates[workID] { return cached }
        guard let database else { return nil }
        do {
            let state = try await database.titleState(for: workID)
            userTitleStates[workID] = state
            return state
        } catch {
            sourcesModel.show(error, title: "Couldn’t load your rating")
            return nil
        }
    }

    @discardableResult
    func deleteTitleState(for workID: WorkID) async -> Bool {
        guard !settingsSyncModel.incognitoMode else {
            feedback.alert = AppAlert(
                title: "Incognito mode is on",
                message: "Turn off incognito mode before clearing rating and reading status."
            )
            return false
        }
        guard let database else { return false }
        do {
            let tombstone = try await database.deleteTitleState(
                workID: workID,
                deviceID: deviceID
            )
            userTitleStates[workID] = nil
            await cloudSyncEngine?.queueDelete(
                recordName: CloudSyncRecordID.titleState(workID: workID)
            )
            await settingsSyncModel.queueCloudSave(CloudSyncRecordID.tombstone(tombstone.id))
            if readingStats != nil { _ = await loadReadingStats() }
            return true
        } catch {
            sourcesModel.show(error, title: "Couldn’t clear your rating")
            return false
        }
    }

    func categoryIDs(for workID: WorkID) async -> Set<UUID> {
        guard let database else { return [] }
        do {
            return try await database.categoryIDs(for: workID)
        } catch {
            sourcesModel.show(error, title: "Couldn’t load categories")
            return []
        }
    }

    func setCategories(_ categoryIDs: Set<UUID>, for workID: WorkID) async -> Bool {
        guard let database else { return false }
        do {
            try await database.setCategories(categoryIDs, for: workID)
            await settingsSyncModel.queueCloudSave(CloudSyncRecordID.work(workID))
            await refreshLibrary()
            return true
        } catch {
            sourcesModel.show(error, title: "Couldn’t update categories")
            return false
        }
    }

    func addCategories(_ categoryIDs: Set<UUID>, to workIDs: Set<WorkID>) async -> Bool {
        guard let database, !categoryIDs.isEmpty, !workIDs.isEmpty else { return false }
        do {
            try await database.addCategories(categoryIDs, to: workIDs)
            for workID in workIDs {
                await settingsSyncModel.queueCloudSave(CloudSyncRecordID.work(workID))
            }
            await refreshLibrary()
            return true
        } catch {
            sourcesModel.show(error, title: "Couldn’t update categories")
            return false
        }
    }

    func deleteCategory(_ category: MankoDomain.Category) async -> Bool {
        guard let database else { return false }
        do {
            let tombstone = try await database.deleteCategory(id: category.id, deviceID: deviceID)
            if libraryCategoryScope.categoryID == category.id {
                setLibraryCategoryScope(.all)
            }
            await cloudSyncEngine?.queueDelete(recordName: CloudSyncRecordID.category(category.id))
            await settingsSyncModel.queueCloudSave(CloudSyncRecordID.tombstone(tombstone.id))
            await refreshCategories()
            await refreshSavedFilters()
            await refreshLibrary()
            return true
        } catch {
            sourcesModel.show(error, title: "Couldn’t delete category")
            return false
        }
    }

    func workDetailSnapshot(for work: Work) async throws -> WorkDetailSnapshot {
        if let cached = try await cachedWorkDetailSnapshot(for: work) { return cached }
        return try await refreshWorkDetailSnapshot(for: work)
    }

    func cachedWorkDetailSnapshot(for work: Work) async throws -> WorkDetailSnapshot? {
        guard let database else { throw WorkDetailLoadError.storageUnavailable }
        async let storedWork = database.work(id: work.id)
        async let storedInstallments = database.installments(for: work.id)
        async let libraryEntry = database.libraryEntry(for: work.id)
        async let storedProgresses = database.progresses(for: work.id)
        let (stored, installments, entry, progresses) = try await (
            storedWork, storedInstallments, libraryEntry, storedProgresses
        )
        try Task.checkCancellation()
        let resolved = stored ?? work
        let persistentKey = sourcesModel.sourceCacheKey(work.sourceID, operation: "detail", query: work.remoteID ?? work.id.description)
        let persistent = sourcesModel.usesPersistentContentCache ? await sourcesModel.contentCache.entry(for: persistentKey) : nil
        let cached = sourcesModel.workDetailCache.cached(sourcesModel.detailCacheKey(for: resolved))
            ?? (try? persistent?.decode(RemoteLibrarySnapshot.self))
        // Keep provider facets separate from user-edited library metadata.
        if let cached { await sourcesModel.learnSourceFacets([cached.work], for: work.sourceID) }
        guard cached != nil || !installments.isEmpty || resolved.sourceID == .local || entry != nil else { return nil }
        let content = cached.map {
            Self.mergeDetailContent(
                storedWork: resolved, storedInstallments: installments,
                refreshedWork: $0.work, refreshedInstallments: $0.installments,
                modifiedAt: resolved.modifiedAt, preserveMetadata: stored != nil, retainRemoved: true
            )
        }
        return WorkDetailSnapshot(
            work: content?.0 ?? resolved,
            installments: content?.1 ?? installments,
            isInLibrary: entry != nil,
            progressByInstallmentID: Dictionary(uniqueKeysWithValues: progresses.map { ($0.installmentID, $0) })
        )
    }

    func refreshWorkDetailSnapshot(for work: Work, invalidateSourceCache: Bool = false,
                                  onMetadata: WorkDetailMetadataHandler? = nil) async throws -> WorkDetailSnapshot {
        #if DEBUG
        let timingStart = ContinuousClock.now
        let measuresTiming = ProcessInfo.processInfo.environment["MANKO_DETAIL_TIMING"] == "1"
        #endif
        guard sourcesModel.sources.contains(where: { $0.id == work.sourceID && $0.isEnabled }) else {
            if let cached = try await cachedWorkDetailSnapshot(for: work) { return cached }
            throw SourceError.notFound
        }
        let key = sourcesModel.detailCacheKey(for: work)
        let storedWork = try await database?.work(id: work.id)
        let persistentKey = sourcesModel.sourceCacheKey(work.sourceID, operation: "detail", query: work.remoteID ?? work.id.description)
        let hasStoredResponse = await sourcesModel.contentCache.entry(for: persistentKey) != nil
        let refreshMode: CloudflareRecoveryMode = sourcesModel.isPerformingQuietRefresh || (hasStoredResponse && !invalidateSourceCache) ? .background : .foreground
        _ = try await sourcesModel.workDetailCache.refresh(key, replacing: invalidateSourceCache, onMetadata: { [self] metadata in
            guard sourcesModel.detailCacheKey(for: work) == key else { return }
            let merged = Self.mergeDetailContent(
                storedWork: storedWork ?? work, storedInstallments: [], refreshedWork: metadata, refreshedInstallments: [],
                modifiedAt: (storedWork ?? work).modifiedAt, preserveMetadata: storedWork != nil, retainRemoved: true
            ).0
            onMetadata?(merged)
            #if DEBUG
            if measuresTiming {
                print("DetailTiming source=\(work.sourceID) cached=\(hasStoredResponse) stage=metadata elapsed=\(timingStart.duration(to: .now))")
            }
            #endif
        }) { [self] publish in
            try await sourcesModel.cachedSourceValue(sourceID: work.sourceID, key: persistentKey, force: invalidateSourceCache) { [self] in
                let (details, installments) = try await remoteDetailsAndInstallments(for: work, mode: refreshMode, onMetadata: publish)
                return RemoteLibrarySnapshot(work: details, installments: installments)
            }
        }
        try Task.checkCancellation()
        guard sourcesModel.detailCacheKey(for: work) == key,
              let snapshot = try await cachedWorkDetailSnapshot(for: work),
              snapshot.work.sourceID == work.sourceID
        else { throw CancellationError() }
        #if DEBUG
        if measuresTiming {
            print("DetailTiming source=\(work.sourceID) cached=\(hasStoredResponse) stage=complete elapsed=\(timingStart.duration(to: .now))")
        }
        #endif
        if !settingsSyncModel.incognitoMode, let database,
           let entry = try await database.libraryEntry(for: work.id) {
            // Upsert only: retain local files, progress, and installments removed by the source.
            try await database.save(work: snapshot.work, entry: entry, installments: snapshot.installments)
            await refreshLibraryCounts(for: work.id)
            await settingsSyncModel.queueCloudSave(CloudSyncRecordID.work(work.id))
        }
        return snapshot
    }

    func readingProgress(
        for workID: WorkID,
        installmentID: InstallmentID
    ) async -> ReadingProgress? {
        guard let database else { return nil }
        return try? await database.progress(
            workID: workID,
            installmentID: installmentID
        )
    }

    func readerMarks(for installmentID: InstallmentID) async -> ReaderMarksSnapshot {
        guard let database else { return .empty }
        do {
            return ReaderMarksSnapshot(
                bookmarks: try await database.bookmarks(for: installmentID),
                annotations: try await database.annotations(for: installmentID)
            )
        } catch {
            sourcesModel.show(error, title: "Couldn’t load bookmarks and notes")
            return .empty
        }
    }

    func beginReadingSession(
        id: UUID,
        work: Work,
        installment: Installment,
        startedAt: Date
    ) async {
        guard !settingsSyncModel.incognitoMode, let database else { return }
        let session = ReadingSession(
            id: id,
            workID: work.id,
            installmentID: installment.id,
            startedAt: startedAt
        )
        do {
            let entry = try await database.beginReadingSession(
                session,
                openedAt: startedAt
            )
            if let entry {
                libraryEntries[work.id] = entry
            }

            var cloudRecordIDs = [CloudSyncRecordID.session(session.id)]
            if entry != nil {
                cloudRecordIDs.append(CloudSyncRecordID.work(work.id))
            }
            await settingsSyncModel.queueCloudSaves(cloudRecordIDs)
            await refreshLibrary(showsLoadingIndicator: false)
            await refreshHistory()
            if readingStats != nil { _ = await loadReadingStats() }
        } catch {
            sourcesModel.show(error, title: "Couldn’t start reading session")
        }
    }

    func addBookmark(
        work: Work,
        installment: Installment,
        locator: ReadingLocator
    ) async -> Bookmark? {
        guard let database else { return nil }
        do {
            let bookmark = Bookmark(
                workID: work.id,
                installmentID: installment.id,
                locator: locator,
                title: installment.title
            )
            try await database.save(bookmark: bookmark)
            await settingsSyncModel.queueCloudSave(CloudSyncRecordID.bookmark(bookmark.id))
            feedback.showStatus("Bookmark added.", systemImage: "bookmark.fill")
            return bookmark
        } catch {
            sourcesModel.show(error, title: "Couldn’t add bookmark")
            return nil
        }
    }

    func addAnnotation(
        work: Work,
        installment: Installment,
        anchor: ReaderAnnotationAnchor,
        note: String,
        highlightColor: ReaderHighlightColor
    ) async -> Annotation? {
        guard let database else { return nil }
        do {
            let annotation = Annotation(
                workID: work.id,
                installmentID: installment.id,
                locator: anchor.locator,
                selectedText: anchor.selectedText,
                note: note,
                highlightColor: highlightColor
            )
            try await database.save(annotation: annotation)
            await settingsSyncModel.queueCloudSave(CloudSyncRecordID.annotation(annotation.id))
            return annotation
        } catch {
            sourcesModel.show(error, title: "Couldn’t add highlight or note")
            return nil
        }
    }

    func updateAnnotation(
        _ annotation: Annotation,
        note: String,
        highlightColor: ReaderHighlightColor
    ) async -> Annotation? {
        guard let database else { return nil }
        do {
            var updated = annotation
            updated.note = note
            updated.highlightColor = highlightColor
            updated.modifiedAt = .now
            try await database.save(annotation: updated)
            await settingsSyncModel.queueCloudSave(CloudSyncRecordID.annotation(updated.id))
            return updated
        } catch {
            sourcesModel.show(error, title: "Couldn’t update highlight or note")
            return nil
        }
    }

    func deleteBookmark(_ bookmark: Bookmark) async -> Bool {
        guard let database else { return false }
        do {
            let tombstone = try await database.deleteBookmark(id: bookmark.id, deviceID: deviceID)
            await cloudSyncEngine?.queueDelete(recordName: CloudSyncRecordID.bookmark(bookmark.id))
            await settingsSyncModel.queueCloudSave(CloudSyncRecordID.tombstone(tombstone.id))
            return true
        } catch {
            sourcesModel.show(error, title: "Couldn’t delete bookmark")
            return false
        }
    }

    func deleteAnnotation(_ annotation: Annotation) async -> Bool {
        guard let database else { return false }
        do {
            let tombstone = try await database.deleteAnnotation(id: annotation.id, deviceID: deviceID)
            await cloudSyncEngine?.queueDelete(recordName: CloudSyncRecordID.annotation(annotation.id))
            await settingsSyncModel.queueCloudSave(CloudSyncRecordID.tombstone(tombstone.id))
            return true
        } catch {
            sourcesModel.show(error, title: "Couldn’t delete highlight or note")
            return false
        }
    }

    func cacheReadingContentIfNeeded(
        work: Work,
        installments: [Installment]
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard !settingsSyncModel.incognitoMode, let database else { return true }
        do {
            guard try await database.libraryEntry(for: work.id) == nil else { return true }
            try await database.saveReadingContent(work: work, installments: installments)
            await settingsSyncModel.queueCloudSave(CloudSyncRecordID.readingContent(work.id))
            return true
        } catch is CancellationError {
            // SwiftUI cancels the source-detail task as navigation settles. That is
            // expected control flow, not a failure the reader needs to surface.
            return false
        } catch {
            guard !Task.isCancelled else { return false }
            sourcesModel.show(error, title: "Couldn’t prepare this title")
            return false
        }
    }

    func remoteImagePublication(
        for work: Work,
        installment: Installment
    ) async throws -> RemoteImagePublication {
        guard let descriptor = sourcesModel.sources.first(where: {
            $0.id == work.sourceID && $0.isEnabled
        }) else {
            throw SourceError.notFound
        }
        guard installment.workID == work.id else { throw SourceError.unsupportedResponse }
        let scope = sourcesModel.usesPersistentContentCache ? sourcesModel.contentCacheScope(work.sourceID) : nil
        let key = sourcesModel.sourceCacheKey(work.sourceID, operation: "manifest-v2", query: [work.id.description, installment.remoteID ?? installment.id.description])
        let pageLoader = recoveringImageLoader(work: work, installment: installment, descriptor: descriptor)
        if scope != nil, let cached = await sourcesModel.contentCache.entry(for: key),
           let manifest = try? cached.decode(CachedRemoteManifest.self), manifest.workID == work.id,
           manifest.installmentID == installment.id, !manifest.pages.isEmpty,
           manifest.pages.allSatisfy({ $0.sourceID == work.sourceID && $0.installmentID == installment.id }) {
            return RemoteImagePublication(sourcePages: manifest.pages, loader: pageLoader, cacheScope: scope)
        }
        return try await freshImagePublication(work: work, installment: installment, descriptor: descriptor, loader: pageLoader)
    }

    private func recoveringImageLoader(work: Work, installment: Installment, descriptor: SourceDescriptor) -> RecoveringRemoteImagePageLoader {
        var loader = RecoveringRemoteImagePageLoader { [weak self] page in
            guard let self else { throw CancellationError() }
            return try await self.loadReaderImage(page, work: work, installment: installment, descriptor: descriptor, priority: .visible, onPartial: { _ in })
        }
        loader.prioritizedLoad = { [weak self] page, priority in
            guard let self else { throw CancellationError() }
            return try await self.loadReaderImage(page, work: work, installment: installment, descriptor: descriptor, priority: priority, onPartial: { _ in })
        }
        loader.incrementalLoad = { [weak self] page, priority, partial in
            guard let self else { throw CancellationError() }
            return try await self.loadReaderImage(page, work: work, installment: installment, descriptor: descriptor, priority: priority, onPartial: partial)
        }
        loader.progressLoad = { [weak self] page, priority, partial, progress in
            guard let self else { throw CancellationError() }
            return try await self.loadReaderImage(page, work: work, installment: installment, descriptor: descriptor,
                priority: priority, onPartial: partial, onProgress: progress)
        }
        loader.updatePriority = { [weak self] page, priority in
            guard let self, let source = try? await self.sourcesModel.makeRemoteSource(for: descriptor) else { return }
            await source.setImagePagePriority(for: page, priority: priority)
        }
        return loader
    }

    private func loadReaderImage(_ page: RemoteImagePageDescriptor, work: Work, installment: Installment,
        descriptor: SourceDescriptor, priority: RemoteImageRequestPriority,
        onPartial: @escaping RemoteImagePageProgress,
        onProgress: RemoteImageDownloadProgressHandler? = nil) async throws -> RemoteImagePageContent {
        do {
            return try await sourcesModel.performSourceOperation(mode: priority == .visible ? .foreground : .background) { [self] in
                let source = try await sourcesModel.makeRemoteSource(for: descriptor)
                let content: RemoteImagePageContent
                if let onProgress {
                    content = try await source.streamImagePageContent(for: page, priority: priority, onPartial: onPartial, onProgress: onProgress)
                } else {
                    content = try await source.streamImagePageContent(for: page, priority: priority, onPartial: onPartial)
                }
                guard await ImagePageDecoder.isValidImageData(content.data) else { throw SourceError.unsupportedResponse }
                return content
            }
        } catch {
            try Task.checkCancellation()
            // An expired URL gets one manifest refresh, never an unbounded retry.
            guard !(error is CloudflareVerificationCancelledError), !(error is CloudflareVerificationRequiredError) else { throw error }
            try await sourcesModel.invalidateContentCache(for: descriptor)
            let fresh = try await freshImagePublication(work: work, installment: installment, descriptor: descriptor)
            guard let replacement = fresh.sourcePages.first(where: { $0.id == page.id && $0.index == page.index }),
                  replacement.resourceURL != page.resourceURL else { throw error }
            let source = try await sourcesModel.makeRemoteSource(for: descriptor)
            let content: RemoteImagePageContent
            if let onProgress {
                await onProgress(.init(receivedBytes: 0, expectedBytes: nil))
                content = try await source.streamImagePageContent(for: replacement, priority: priority, onPartial: onPartial, onProgress: onProgress)
            } else {
                content = try await source.streamImagePageContent(for: replacement, priority: priority, onPartial: onPartial)
            }
            guard await ImagePageDecoder.isValidImageData(content.data) else { throw SourceError.unsupportedResponse }
            return content
        }
    }

    private func freshImagePublication(work: Work, installment: Installment, descriptor: SourceDescriptor,
        loader: (any RemoteImagePageLoading)? = nil) async throws -> RemoteImagePublication {
        let scope = sourcesModel.usesPersistentContentCache ? sourcesModel.contentCacheScope(work.sourceID) : nil
        guard installment.workID == work.id else { throw SourceError.unsupportedResponse }
        let token = await sourcesModel.contentCache.writeToken()
        let source = try await sourcesModel.makeRemoteSource(for: descriptor)
        let publication = try await SourceCachePolicy.$scope.withValue(scope) {
            try await SourceCachePolicy.$isPrivate.withValue(scope == nil) {
                let prepared = try await prepareExtensionContent(source: source, work: work, installment: installment)
                guard prepared.work.id == work.id, prepared.selectedInstallment.workID == work.id else { throw SourceError.unsupportedResponse }
                return try await RemoteImageSequenceCatalog().publication(for: prepared.work,
                    installment: prepared.selectedInstallment, source: source, loader: loader, cacheScope: scope)
            }
        }
        if let scope, sourcesModel.usesPersistentContentCache, scope == sourcesModel.contentCacheScope(work.sourceID) {
            let key = sourcesModel.sourceCacheKey(work.sourceID, operation: "manifest-v2", query: [work.id.description, installment.remoteID ?? installment.id.description])
            let data = try JSONEncoder().encode(CachedRemoteManifest(workID: work.id, installmentID: installment.id, pages: publication.sourcePages))
            await sourcesModel.contentCache.store(data, for: key, token: token)
        }
        return publication
    }

    func prepareExtensionContent(
        source: any ContentSource,
        work: Work,
        installment: Installment
    ) async throws -> ExtensionContentRefresh {
        guard let extensionSource = source as? MankoExtensionSourceAdapter else {
            return ExtensionContentRefresh(
                work: work,
                installments: [installment],
                selectedInstallment: installment
            )
        }

        let context = try await extensionSource.rehydrate(work: work, installment: installment)
        var storedWork = work
        var storedInstallments = [installment]
        var libraryEntry: LibraryEntry?
        if let database {
            storedWork = try await database.work(id: work.id) ?? work
            let persistedInstallments = try await database.installments(for: work.id)
            if !persistedInstallments.isEmpty {
                storedInstallments = persistedInstallments
            }
            libraryEntry = try await database.libraryEntry(for: work.id)
        }

        var merged = try Self.mergeExtensionContent(
            storedWork: storedWork,
            storedInstallments: storedInstallments,
            refreshedWork: context.work,
            refreshedInstallments: context.installments,
            selectedRemoteID: context.selectedInstallment.remoteID,
            modifiedAt: storedWork.modifiedAt
        )

        let hasPersistedChanges = context.didRefresh
            && (
                merged.work != storedWork
                    || Set(merged.installments) != Set(storedInstallments)
            )
        if hasPersistedChanges, let database, let libraryEntry {
            merged.work.modifiedAt = .now
            try await database.save(
                work: merged.work,
                entry: libraryEntry,
                installments: merged.installments
            )
            await settingsSyncModel.queueCloudSave(CloudSyncRecordID.work(merged.work.id))
        }
        if sourcesModel.usesPersistentContentCache {
            let key = sourcesModel.sourceCacheKey(work.sourceID, operation: "detail", query: work.remoteID ?? work.id.description)
            await sourcesModel.contentCache.store(RemoteLibrarySnapshot(work: context.work, installments: context.installments), for: key)
        }
        return merged
    }

    nonisolated static func mergeExtensionContent(
        storedWork: Work,
        storedInstallments: [Installment],
        refreshedWork: Work,
        refreshedInstallments: [Installment],
        selectedRemoteID: String?,
        modifiedAt: Date
    ) throws -> ExtensionContentRefresh {
        let (mergedWork, mergedInstallments) = mergeDetailContent(
            storedWork: storedWork, storedInstallments: storedInstallments,
            refreshedWork: refreshedWork, refreshedInstallments: refreshedInstallments,
            modifiedAt: modifiedAt
        )
        guard let selectedRemoteID,
              let selected = mergedInstallments.first(where: { $0.remoteID == selectedRemoteID })
        else { throw SourceError.notFound }
        return ExtensionContentRefresh(
            work: mergedWork,
            installments: mergedInstallments,
            selectedInstallment: selected
        )
    }

    nonisolated static func mergeDetailContent(
        storedWork: Work,
        storedInstallments: [Installment],
        refreshedWork: Work,
        refreshedInstallments: [Installment],
        modifiedAt: Date,
        preserveMetadata: Bool = true,
        retainRemoved: Bool = false
    ) -> (Work, [Installment]) {
        var mergedWork = refreshedWork
        mergedWork.id = storedWork.id
        mergedWork.sourceID = storedWork.sourceID
        if preserveMetadata {
            mergedWork.authors = storedWork.authors
            mergedWork.tags = storedWork.tags
            mergedWork.kind = storedWork.kind
            mergedWork.status = storedWork.status
        }
        mergedWork.customCoverPath = storedWork.customCoverPath
        mergedWork.createdAt = storedWork.createdAt
        mergedWork.modifiedAt = modifiedAt

        var storedByRemoteID: [String: Installment] = [:]
        for stored in storedInstallments {
            if let remoteID = stored.remoteID {
                storedByRemoteID[remoteID] = stored
            }
        }
        var mergedInstallments = refreshedInstallments.map { refreshed in
            var merged = refreshed
            merged.workID = storedWork.id
            let stored = refreshed.remoteID.flatMap { storedByRemoteID[$0] }
                ?? storedInstallments.first(where: { $0.id == refreshed.id })
            if let stored {
                // Repaired extension identities must not be replaced by an old
                // detail snapshot. Native connectors retain their identifiers.
                let scoped = refreshed.remoteID.map { ExtensionChapterIdentity.id(sourceID: storedWork.sourceID, workID: storedWork.id, remoteID: $0) }
                merged.id = refreshed.id == scoped ? refreshed.id : stored.id
                merged.acquisitionURL = stored.acquisitionURL
                merged.pageCount = stored.pageCount
            }
            return merged
        }
        if retainRemoved {
            let refreshedIDs = Set(mergedInstallments.map(\.id))
            mergedInstallments.append(contentsOf: storedInstallments.filter { !refreshedIDs.contains($0.id) })
        }
        return (mergedWork, mergedInstallments)
    }

    func planSourceMigration(
        from existingWork: Work,
        to targetWork: Work
    ) async throws -> SourceMigrationPlan {
        guard existingWork.id != targetWork.id || existingWork.sourceID != targetWork.sourceID else {
            throw SourceMigrationApplicationError.sameSource
        }
        guard existingWork.sourceID != .local, targetWork.sourceID != .local else {
            throw SourceMigrationApplicationError.unsupportedLocalSource
        }
        guard sourcesModel.sources.contains(where: { $0.id == targetWork.sourceID && $0.isEnabled }) else {
            throw SourceMigrationApplicationError.sourceUnavailable
        }
        guard let database else {
            throw SourceMigrationApplicationError.libraryUnavailable
        }

        let existingInstallments = try await database.installments(for: existingWork.id)
        let descriptor = sourcesModel.sources.first(where: { $0.id == targetWork.sourceID })
        return try await sourcesModel.performSourceOperation { [weak self] in
            guard let self else { throw CancellationError() }
            let source = try await self.sourcesModel.makeRemoteSource(for: descriptor)
            return try await RemoteLibraryPlanner(source: source).planMigration(
                existingWork: existingWork,
                existingInstallments: existingInstallments,
                targetWork: targetWork
            )
        }
    }

    func planBulkSourceMigration(
        works: [Work],
        to descriptor: SourceDescriptor
    ) async throws -> BulkSourceMigrationPreview {
        guard !works.isEmpty else {
            throw BulkSourceMigrationPlanningError.emptySelection
        }
        guard works.count <= BulkSourceMigrationCommitLimits.maximumWorks else {
            throw BulkSourceMigrationPlanningError.tooManyTitles(
                maximum: BulkSourceMigrationCommitLimits.maximumWorks
            )
        }
        guard
            descriptor.kind != .local,
            let configuredSource = sourcesModel.sources.first(where: {
                $0.id == descriptor.id && $0.isEnabled && $0.kind != .local
            })
        else {
            throw SourceMigrationApplicationError.sourceUnavailable
        }
        guard let database else {
            throw SourceMigrationApplicationError.libraryUnavailable
        }

        var requests: [BulkSourceMigrationRequest] = []
        requests.reserveCapacity(works.count)
        for work in works {
            try Task.checkCancellation()
            let existingInstallments: [Installment] = if work.sourceID == .local
                || work.sourceID == configuredSource.id
            {
                []
            } else {
                try await database.installments(for: work.id)
            }
            requests.append(
                BulkSourceMigrationRequest(
                    existingWork: work,
                    existingInstallments: existingInstallments
                )
            )
        }
        let migrationRequests = requests

        return try await sourcesModel.performSourceOperation { [weak self] in
            guard let self else { throw CancellationError() }
            let source = try await self.sourcesModel.makeRemoteSource(for: configuredSource)
            return try await BulkSourceMigrationPlanner(source: source).plan(migrationRequests)
        }
    }

    func applySourceMigration(_ plan: SourceMigrationPlan, to existingWork: Work) async throws {
        guard plan.proposedWork.id == existingWork.id else {
            throw SourceMigrationApplicationError.inconsistentWork
        }
        guard plan.proposedWork.sourceID != existingWork.sourceID else {
            throw SourceMigrationApplicationError.sameSource
        }
        guard plan.ambiguousMatches.isEmpty else {
            throw SourceMigrationApplicationError.ambiguousMatches(plan.ambiguousMatches.count)
        }
        guard let database else {
            throw SourceMigrationApplicationError.notInLibrary
        }

        var committedWork = plan.proposedWork
        committedWork.modifiedAt = .now
        _ = try await database.applySourceMigrations([
            LibrarySourceMigrationCommit(
                expectedSourceID: existingWork.sourceID,
                expectedModifiedAt: existingWork.modifiedAt,
                proposedWork: committedWork,
                proposedInstallments: plan.proposedInstallments
            ),
        ])
        await refreshLibraryCounts(for: existingWork.id)
        await settingsSyncModel.queueCloudSave(CloudSyncRecordID.work(existingWork.id))
        await refreshLibrary()
    }

    func addToLibrary(
        _ work: Work,
        knownInstallments: [Installment]? = nil
    ) async -> Bool {
        guard let database else { return false }
        do {
            let details: Work
            let allInstallments: [Installment]
            if let knownInstallments {
                details = work
                allInstallments = knownInstallments
            } else {
                let cachedWork = try await database.work(id: work.id)
                let cachedInstallments = try await database.installments(for: work.id)
                let hasEnabledSource = sourcesModel.sources.contains {
                    $0.id == work.sourceID && $0.isEnabled
                }
                if let cachedWork, !cachedInstallments.isEmpty, !hasEnabledSource {
                    details = cachedWork
                    allInstallments = cachedInstallments
                } else {
                    (details, allInstallments) = try await remoteDetailsAndInstallments(for: work)
                }
            }
            try await database.promoteReadingContentToLibrary(
                work: details,
                entry: LibraryEntry(workID: details.id, unreadCount: allInstallments.count),
                installments: allInstallments
            )
            await refreshLibraryCounts(for: details.id)
            await settingsSyncModel.queueCloudSave(CloudSyncRecordID.work(details.id))
            await cloudSyncEngine?.queueDelete(
                recordName: CloudSyncRecordID.readingContent(details.id)
            )
            await refreshLibrary()
            return true
        } catch {
            sourcesModel.show(error, title: "Couldn’t add \(work.title)")
            return false
        }
    }

    func remoteDetailsAndInstallments(
        for work: Work,
        mode: CloudflareRecoveryMode = .foreground,
        onMetadata: WorkDetailMetadataHandler? = nil
    ) async throws -> (Work, [Installment]) {
        let descriptor = sourcesModel.sources.first(where: { $0.id == work.sourceID })
        return try await sourcesModel.performSourceOperation(mode: mode) { [weak self] in
            guard let self else { throw CancellationError() }
            let source = try await self.sourcesModel.makeRemoteSource(for: descriptor)
            let details = try await source.details(for: work.remoteID ?? work.id.description)
            try Task.checkCancellation()
            await onMetadata?(details)
            async let learnFacets: Void = self.sourcesModel.learnSourceFacets([details], for: work.sourceID)
            var pageNumber = 1
            var seenPages: Set<Int> = []
            var allInstallments: [Installment] = []
            while true {
                try Task.checkCancellation()
                guard seenPages.insert(pageNumber).inserted else { throw SourceError.unsupportedResponse }
                let page = try await source.installments(for: details, page: pageNumber)
                allInstallments.append(contentsOf: page.items)
                guard let nextPage = page.nextPage else { break }
                pageNumber = nextPage
            }
            await learnFacets
            return (details, allInstallments)
        }
    }

    func setPinned(_ isPinned: Bool, for workIDs: Set<WorkID>) async -> Bool {
        guard let database, !workIDs.isEmpty else { return false }
        do {
            try await database.setPinned(isPinned, for: workIDs)
            for workID in workIDs {
                await settingsSyncModel.queueCloudSave(CloudSyncRecordID.work(workID))
            }
            await refreshLibrary(showsLoadingIndicator: false, animatesPinChange: true)
            return true
        } catch {
            sourcesModel.show(error, title: isPinned ? "Couldn’t pin titles" : "Couldn’t unpin titles")
            return false
        }
    }

    func workByAddingGeneratedCover(
        to work: Work,
        fileURL: URL,
        format: PublicationFormat
    ) async -> (work: Work, managedPath: String?) {
        guard
            let localPublicationCoverService,
            let customCoverStore,
            let data = await localPublicationCoverService.coverData(at: fileURL, format: format)
        else {
            return (work, nil)
        }

        do {
            let path = try await customCoverStore.store(data, for: work.id)
            var coveredWork = work
            coveredWork.coverURL = try customCoverStore.managedURL(for: path)
            return (coveredWork, path)
        } catch {
            return (work, nil)
        }
    }

    static func progression(for locator: ReadingLocator) -> Double? {
        if let imageProgression = locator.progression {
            return imageProgression
        }
        guard case let .publication(readiumJSON) = locator else { return nil }
        guard let persisted = try? PersistedReadiumLocator(jsonData: readiumJSON) else { return nil }
        return persisted.totalProgression
    }
}

struct CachedRemoteManifest: Codable, Sendable {
    let workID: WorkID
    let installmentID: InstallmentID
    let pages: [RemoteImagePageDescriptor]
}
