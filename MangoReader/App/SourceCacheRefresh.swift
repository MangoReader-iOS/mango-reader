import Foundation
import MangoReaderDomain
import MangoReaderSources
import Network
import UIKit
#if !targetEnvironment(macCatalyst)
import BackgroundTasks
#endif

struct SourceCacheVisit: Codable {
    var sourceID: SourceID
    var work: Work?
    var visitedAt: Date
    var checkedAt: Date?
    var id: String { work?.id.description ?? sourceID.rawValue }
}

extension SourcesModel {
    private var cacheVisitsKey: String { ContentCache.key(["recent-source-visits-v1"]) }
    func loadCacheVisits() async {
        guard usesPersistentContentCache, let entry = await contentCache.entry(for: cacheVisitsKey),
              let visits = try? entry.decode([SourceCacheVisit].self) else { return }
        cacheVisits = visits
    }
    func recordCacheVisit(sourceID: SourceID, work: Work? = nil) {
        guard usesPersistentContentCache, sourceID != .local, !isPerformingQuietRefresh else { return }
        var visits = recentCacheVisits()
        let id = work?.id.description ?? sourceID.rawValue
        visits.removeAll { $0.id == id }
        visits.append(.init(sourceID: sourceID, work: work, visitedAt: .now, checkedAt: .now))
        saveCacheVisits(visits)
    }
    func recentCacheVisits(now: Date = .now) -> [SourceCacheVisit] {
        guard usesPersistentContentCache else { return [] }
        let recent = cacheVisits.filter { now.timeIntervalSince($0.visitedAt) < 7 * 86_400 }.sorted { $0.visitedAt > $1.visitedAt }
        return Array(recent.filter { $0.work == nil }.prefix(3)) + Array(recent.filter { $0.work != nil }.prefix(10))
    }
    func saveCacheVisits(_ visits: [SourceCacheVisit]) {
        cacheVisits = Array(visits.sorted { $0.visitedAt > $1.visitedAt }.prefix(20))
        let snapshot = cacheVisits, key = cacheVisitsKey, cache = contentCache
        let generation = cacheVisitGeneration
        Task { [weak self] in
            let token = await cache.writeToken()
            guard let self, generation == cacheVisitGeneration, usesPersistentContentCache,
                  let data = try? JSONEncoder().encode(snapshot) else { return }
            await cache.store(data, for: key, token: token)
        }
    }

    func refreshRecentCache(library: LibraryModel, inBackground: Bool) async {
        guard usesPersistentContentCache, !isPerformingQuietRefresh else { return }
        isPerformingQuietRefresh = true
        defer { isPerformingQuietRefresh = false }
        for visit in recentCacheVisits() {
            guard !Task.isCancelled, usesPersistentContentCache, SourceCacheRefresh.shared.canRefresh else { return }
            guard visit.checkedAt.map({ Date.now.timeIntervalSince($0) >= 6 * 3_600 }) ?? true,
                  let source = sources.first(where: { $0.id == visit.sourceID && $0.isEnabled }) else { continue }
            // WebKit source runtimes require an active scene. Native sources
            // can refresh during the system's bounded background opportunity.
            if inBackground, source.kind == .mangoReaderExtension { continue }
            do {
                if let work = visit.work {
                    _ = try await library.refreshWorkDetailSnapshot(for: work, invalidateSourceCache: true)
                } else {
                    let sections = try await sourceDiscoverSections(for: source, force: true)
                    if sections.isEmpty { _ = try await browse(source, force: true) }
                    else {
                        for section in sections {
                            guard !Task.isCancelled, SourceCacheRefresh.shared.canRefresh else { return }
                            _ = try await discover(source, sectionID: section.id, force: true)
                        }
                    }
                }
            } catch { /* Cached content stays available; opened screens own Retry. */ }
            var visits = recentCacheVisits()
            if let index = visits.firstIndex(where: { $0.id == visit.id }) { visits[index].checkedAt = .now }
            saveCacheVisits(visits)
        }
    }
}

@MainActor
final class SourceCacheRefresh {
    static let shared = SourceCacheRefresh()
    static let taskIdentifier = "com.k800k.manko.source-cache-refresh"
    private let monitor = NWPathMonitor()
    private var networkAllowsRefresh = false
    private var hasNetworkPath = false
    private var idleTask: Task<Void, Never>?
    private var powerStateTask: Task<Void, Never>?
    private weak var model: AppModel?
    private var activeScenes: Set<ObjectIdentifier> = []
    var readers: Set<UUID> = []
    var canRefresh: Bool {
        networkAllowsRefresh && readers.isEmpty && !ProcessInfo.processInfo.isLowPowerModeEnabled
            && !UserDefaults.standard.bool(forKey: "incognitoMode")
    }
    private init() {
        guard !MangoReaderTestEnvironment.isUnitTesting else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let allowed = path.status == .satisfied && !path.isConstrained && !path.isExpensive
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            Task { @MainActor in
                self?.networkAllowsRefresh = allowed; self?.hasNetworkPath = true
                if !allowed { self?.model?.importedFilePrefetchTask?.cancel() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "manko.cache.network", qos: .utility))
        powerStateTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .NSProcessInfoPowerStateDidChange) {
                if ProcessInfo.processInfo.isLowPowerModeEnabled { self?.model?.importedFilePrefetchTask?.cancel() }
            }
        }
    }
    func update(model: AppModel, active: Bool) {
        guard !MangoReaderTestEnvironment.isUnitTesting else { return }
        let id = ObjectIdentifier(model)
        if active { activeScenes.insert(id); self.model = model }
        else {
            activeScenes.remove(id)
            model.importedFilePrefetchTask?.cancel()
        }
        idleTask?.cancel(); idleTask = nil
        scheduleBackground()
        guard !activeScenes.isEmpty else { return }
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self else { return }
                if canRefresh, let model = self.model, model.isReadyForInteraction {
                    model.scheduleImportedFileReconciliation()
                    await model.prefetchRecentImportedBooks()
                    await model.sourcesModel.refreshRecentCache(library: model.libraryModel, inBackground: false)
                }
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
    }
    func scheduleBackground() {
        guard !MangoReaderTestEnvironment.isUnitTesting else { return }
        #if !targetEnvironment(macCatalyst)
        guard !UserDefaults.standard.bool(forKey: "incognitoMode") else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier); return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = .now.addingTimeInterval(6 * 3_600)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }
    func register() {
        #if !targetEnvironment(macCatalyst)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { task in
            let relay = BackgroundTaskCancellationRelay()
            task.expirationHandler = { Task { await relay.expire() } }
            let work = Task { @MainActor in
                let coordinator = SourceCacheRefresh.shared
                defer { coordinator.scheduleBackground(); task.setTaskCompleted(success: !Task.isCancelled) }
                for _ in 0..<10 where !coordinator.hasNetworkPath && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard coordinator.canRefresh else { return }
                let model = coordinator.model ?? AppModel(isLibraryAutomationProcess: true)
                await model.bootstrap()
                guard !Task.isCancelled else { return }
                await model.prefetchRecentImportedBooks()
                await model.sourcesModel.refreshRecentCache(library: model.libraryModel, inBackground: true)
            }
            Task { await relay.install(work) }
        }
        #endif
    }
}
