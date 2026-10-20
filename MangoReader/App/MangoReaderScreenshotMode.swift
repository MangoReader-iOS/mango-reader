#if DEBUG
import Foundation
import MangoReaderData
import MangoReaderDomain
import MangoReaderExtensions
import MangoReaderReaders
import MangoReaderSync
#if targetEnvironment(macCatalyst)
import UIKit
#endif

/// Marketing fixtures use their own database, files and preferences. No normal
/// service bootstrap, accounts, source refresh or cloud machinery is started.
@MainActor
enum MangoReaderScreenshotMode {
    static var scene: String? { ProcessInfo.processInfo.environment["MANGOREADER_SCREENSHOT_SCENE"] }
    static var isEnabled: Bool { scene != nil }
    static let date = Date(timeIntervalSince1970: 1_791_014_400) // 3 October 2026, 08:00 UTC
    static let suite = "com.k800k.manko.marketing-screenshots"

    struct Book: Codable, Sendable {
        let title, author, cover: String
        let file, chapterHref: String?
        let kind: ContentKind
        let summary: String
        let tags: [String]
        let inLibrary: Bool
    }

    struct LocalDocumentsResolver: ImportedOriginalCloudDocumentsResolving {
        nonisolated func documentsDirectory() async -> URL? { nil }
    }

    static func defaults(suiteName: String = suite, scene: String? = scene) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("marketing-device", forKey: "deviceID")
        defaults.set(ProcessInfo.processInfo.environment["MANGOREADER_FIXTURE_APPEARANCE"] ?? "light", forKey: "preferredAppearance")
        defaults.set("title", forKey: "librarySort")
        defaults.set("grid", forKey: "libraryLayout")
        defaults.set(scene == "dark" ? "black" : scene == "paper" ? "sepia" : "light", forKey: "publicationTheme")
        defaults.set(false, forKey: "publisherStyles")
        defaults.set(false, forKey: "epubScroll")
        defaults.set("iowanOldStyle", forKey: "readerFontPreset")
        defaults.set(1.1, forKey: "readerFontScale")
        defaults.set(1.5, forKey: "readerLineHeight")
        defaults.set(ReaderAdditionalPreferences().encoded, forKey: ReaderAdditionalPreferences.storageKey)
        return defaults
    }

    static func paths(root: URL) -> StoragePaths {
        StoragePaths(applicationSupportDirectory: root.appendingPathComponent("Storage"),
                     cachesDirectory: root.appendingPathComponent("Caches"))
    }

    static var inputDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarketingScreenshots")
    }

    #if targetEnvironment(macCatalyst)
    static func prepareWindowForCapture() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            // Catalyst's default 77% UIKit-to-Mac scale gives a native
            // 1280 × 800 point window (2560 × 1600 Retina pixels).
            let size = CGSize(width: 1662, height: 1039)
            scene.sizeRestrictions?.minimumSize = size
            scene.sizeRestrictions?.maximumSize = size
        }
    }

    /// A native folder picker grants access without weakening the Mac sandbox.
    static func stageInputs(from folder: URL) throws {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let books = try JSONDecoder().decode([Book].self, from: Data(contentsOf: folder.appendingPathComponent("books.json")))
        let names = Set(["books.json"] + books.flatMap { [$0.cover] + ($0.file.map { [$0] } ?? []) })
        try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        for name in names {
            guard name == URL(fileURLWithPath: name).lastPathComponent else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            try Data(contentsOf: folder.appendingPathComponent(name)).write(to: inputDirectory.appendingPathComponent(name), options: .atomic)
        }
    }
    #endif

    static func bootstrap(model: AppModel, inputs: URL = inputDirectory, root suppliedRoot: URL? = nil) async throws {
        let root = suppliedRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MangoReaderMarketingScreenshots")
        let paths = paths(root: root)
        try paths.prepare()
        let database = try MangoReaderDatabase(databaseURL: paths.databaseURL)
        let importer = LocalPublicationImporter(storagePaths: paths)
        let books = try JSONDecoder().decode([Book].self, from: Data(contentsOf: inputs.appendingPathComponent("books.json")))
        try await seed(books: books, inputs: inputs, paths: paths, database: database, importer: importer)
        model.storagePaths = paths
        model.database = database
        model.importer = importer
        model.importedOriginalCloudOrchestrator = ImportedOriginalCloudOrchestrator(
            database: database,
            transfer: ImportedOriginalCloudTransferService(libraryFilesDirectory: paths.libraryFilesDirectory, cloudDocumentsDirectory: nil),
            documentsResolver: LocalDocumentsResolver(), libraryFilesDirectory: paths.libraryFilesDirectory,
            deviceID: model.deviceID
        )
        model.localPublicationCoverService = LocalPublicationCoverService()
        model.libraryModel.database = database
        model.libraryModel.localPublicationCoverService = model.localPublicationCoverService
        model.searchModel.database = database
        model.trackingModel.database = database
        model.settingsSyncModel.database = database
        model.transfersModel.storagePaths = paths
        if let fixture = ProcessInfo.processInfo.environment["MANGOREADER_BACKUP_FIXTURE"] {
            let backup = try BackupService(database: database, storagePaths: paths)
            let repositories = try SourceRepositoryStore(directory: root.appendingPathComponent("BackupRepositories"))
            model.backupService = backup
            model.transfersModel.backupService = backup
            model.transfersModel.repositoryStore = repositories
            model.sourcesModel.repositoryStore = repositories
            if fixture == "import" {
                let file = paths.backupStagingDirectory.appendingPathComponent("Verification.mankobackup")
                try await backup.export(to: file,
                    settingsData: model.transfersModel.encodedBackupSetup(selection: .exportDefault), selection: .exportDefault)
                model.transfersModel.stagedRestore = try await backup.stageRestore(from: file)
            } else {
                model.transfersModel.isSelectingBackupContents = true
                if fixture == "error" {
                    model.transfersModel.backupExporterForTesting = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
                }
            }
        }
        model.libraryModel.readingStatsRange = .allTime
        await model.libraryModel.refreshCategories()
        await model.libraryModel.refreshLibrary()
        if let fixture = ProcessInfo.processInfo.environment["MANGOREADER_TRACKING_FIXTURE"],
           let work = model.libraryModel.library.first {
            try await seedTracking(fixture: fixture, work: work, model: model, database: database)
        }
        await model.libraryModel.refreshLibrary()
        await model.libraryModel.refreshHistory()
        _ = await model.libraryModel.loadReadingStats()
        try Data("ready".utf8).write(to: inputs.appendingPathComponent("ready.txt"), options: .atomic)
    }

    /// Local visual verification shares the marketing database's isolation.
    static func seedTracking(fixture: String, work: Work, model: AppModel, database: MangoReaderDatabase) async throws {
        guard fixture != "empty" else { return }
        var work = work
        if fixture == "chapters" {
            // Disposable catalogue with an acknowledged visit and two later arrivals.
            try await database.remove(workIDs: [work.id], deviceID: "marketing-device")
            work.kind = .manga
            let chapters = (48...52).enumerated().map { index, number in
                Installment(id: InstallmentID(rawValue: identifier(20, index)), workID: work.id,
                    title: "Chapter \(number)", volume: 5, number: Double(number),
                    publishedAt: index == 1 ? nil : Date.now.addingTimeInterval(Double(index - 4) * 86400),
                    format: .cbz, pageCount: 24)
            }
            try await database.save(work: work, entry: LibraryEntry(workID: work.id, unreadCount: 4), installments: chapters)
            try await database.save(progress: ReadingProgress(workID: work.id, installmentID: chapters[0].id,
                locator: .image(page: 23, total: 24, offset: 0), currentProgression: 1, highestProgression: 1, deviceID: "marketing-device"))
            try await database.save(progress: ReadingProgress(workID: work.id, installmentID: chapters[1].id,
                locator: .image(page: 8, total: 24, offset: 0), currentProgression: 0.33, highestProgression: 0.33, deviceID: "marketing-device"))
            try await database.acknowledgeChapters(workID: work.id, sourceID: work.sourceID, ids: Set(chapters.prefix(3).map(\.id)))
        }
        let state = UserTitleState(workID: work.id, rating: .init(rawValue: 8), status: .reading,
            startDate: .init(year: 2026, month: 9, day: 15), deviceID: model.deviceID)
        _ = try await database.save(titleState: state)
        model.libraryModel.userTitleStates[work.id] = state
        for (index, name) in ["AniList", "MyAnimeList"].enumerated() {
            let installed = InstalledRepositorySource(repositoryID: "tracking-preview", sourceID: name,
                descriptor: SourceDescriptor(id: SourceID(rawValue: "tracking-preview.\(name)"), name: name,
                    kind: .mangoReaderExtension, isEnabled: true),
                entryType: .mangoReaderExtension, kind: .tracker, version: "2.1.0",
                scriptSHA256: nil, capabilities: [.authentication, .progress], allowedHTTPSHosts: [])
            model.sourcesModel.installedRepositorySources.append(installed)
            let remote = TrackerProgress(trackerID: model.trackingModel.trackerID(for: installed),
                remoteWorkID: "preview", chapter: fixture == "chapters" ? 51 : 19, volume: fixture == "chapters" ? 5 : 2, status: .reading, score: 8,
                startDate: .init(year: 2026, month: 9, day: index == 0 ? 15 : nil),
                totalChapters: 127, totalVolumes: 13)
            let conflicts: [TrackerFieldConflict] = fixture == "chapters"
                ? [.init(field: .chapter, mangoReaderValue: .number(48), trackerValue: .number(51))]
                : fixture == "error" && index == 0
                ? [.init(field: .startDate, mangoReaderValue: .date(state.startDate!), trackerValue: .date(.init(year: 2026, month: 9, day: 12)))] : []
            try await database.save(trackerLink: TrackerLink(workID: work.id, trackerID: remote.trackerID,
                remoteWorkID: "preview", remoteTitle: work.title, lastSynced: .init(remote),
                lastPulledAt: .now, conflicts: conflicts, lastRemote: remote, supportsDateUpdates: index == 0))
        }
        if fixture == "error" { model.trackingModel.trackerSyncErrors[work.id] = "Couldn’t connect to AniList. Try syncing again." }
    }

    static func seed(books: [Book], inputs: URL, paths: StoragePaths, database: MangoReaderDatabase,
                     importer: LocalPublicationImporter) async throws {
        let categories = ["Classics", "Adventure", "Mystery"].enumerated().map { index, name in
            MangoReaderDomain.Category(id: identifier(3, index), name: name, sortIndex: index, createdAt: date, modifiedAt: date)
        }
        try await database.save(categories: categories)
        // Reseed only the supplied screenshot database, including obsolete visible
        // fixtures and metadata-only entries that previously had installments.
        let visibleIDs = Set(try await database.library(sort: .title).map(\.id))
        let fixtureIDs = Set(books.indices.map { WorkID(rawValue: identifier(1, $0)) })
        try await database.remove(workIDs: visibleIDs.union(fixtureIDs), deviceID: "marketing-device")
        _ = try await database.deleteReadingSessions()
        for (index, book) in books.enumerated() {
            let coverURL = paths.cachesDirectory.appendingPathComponent(book.cover)
            try Data(contentsOf: inputs.appendingPathComponent(book.cover)).write(to: coverURL, options: .atomic)
            let work = Work(id: WorkID(rawValue: identifier(1, index)), sourceID: .local,
                            title: book.title, authors: [book.author], summary: book.summary,
                            tags: book.tags, kind: book.kind, coverURL: coverURL,
                            createdAt: date, modifiedAt: date)
            var installments: [Installment] = []
            if let file = book.file {
                let imported = try await importer.importPublication(from: inputs.appendingPathComponent(file))
                installments = [Installment(id: InstallmentID(rawValue: identifier(2, index)), workID: work.id,
                    title: "Complete edition", format: imported.format,
                    acquisitionURL: paths.libraryFilesDirectory.appendingPathComponent(imported.relativePath))]
            }
            if book.inLibrary {
                try await database.save(work: work, entry: LibraryEntry(workID: work.id, addedAt: date,
                    lastOpenedAt: book.file == nil ? nil : date,
                    unreadCount: installments.count, downloadedCount: installments.count,
                    cloudFilePolicy: .localOnly), installments: installments)
                let membership: Set<UUID> = book.kind == .manga ? [categories[1].id] : [categories[0].id]
                try await database.setCategories(membership, for: work.id)
            } else {
                // Historical publications stay available to Activity without adding grid rows.
                try await database.saveReadingContent(work: work, installments: installments)
            }
            guard let installment = installments.first, let chapterHref = book.chapterHref else { continue }
            let locator = try JSONSerialization.data(withJSONObject: ["href": chapterHref,
                "type": "application/xhtml+xml", "locations": ["progression": 0.0]])
            let progression = [0.12, 0.20, 0.28, 0.44, 0.64, 0.18][index]
            try await database.save(progress: ReadingProgress(id: identifier(4, index), workID: work.id,
                installmentID: installment.id, locator: .publication(readiumJSON: locator),
                currentProgression: progression, highestProgression: progression,
                modifiedAt: date.addingTimeInterval(Double(-index * 3600)), deviceID: "marketing-device"))
            for day in 0..<24 {
                let start = date.addingTimeInterval(Double(-(day * 6 + index) * 86400 - 3600))
                let minutes = Double(12 + (day * 7 + index * 3) % 25)
                try await database.save(session: ReadingSession(id: identifier(5 + index, day), workID: work.id,
                    installmentID: installment.id, startedAt: start, endedAt: start.addingTimeInterval(minutes * 60),
                    secondsRead: minutes * 60, startProgression: progression * Double(23 - day) / 24,
                    endProgression: progression * Double(24 - day) / 24, readingUnitCount: 360))
            }
        }
    }

    static func identifier(_ group: Int, _ index: Int) -> UUID {
        UUID(uuidString: String(format: "AA%06d-0000-0000-0000-%012d", group, index + 1))!
    }

    static func presentReaderIfNeeded(model: AppModel, coordinator: ReaderPresentationCoordinator) async {
        guard scene.map({ ["reader", "paper", "dark", "settings"].contains($0) }) == true, let database = model.database,
              let work = model.libraryModel.library.first(where: { $0.id.rawValue == identifier(1, 0) }) else { return }
        do {
            guard let installment = try await database.installments(for: work.id).first else { return }
            coordinator.open(ReaderOpenRequest(work: work, target: .installment(installment, chapters: nil)))
        } catch { report(error: error) }
    }

    static func report(error: Error) {
        try? Data(error.localizedDescription.utf8).write(to: inputDirectory.appendingPathComponent("error.txt"), options: .atomic)
    }
}

/// Video walkthroughs keep real content providers but never load regular user
/// storage, source credentials, tracker accounts, or an iCloud document resolver.
@MainActor
enum MangoReaderDemoMode {
    private static var preparationTask: Task<Void, Error>?
    static var isEnabled: Bool {
        isEnabled(environment: ProcessInfo.processInfo.environment, inputDirectory: inputs)
    }

    /// Recording installations remain isolated when launched from the Home Screen.
    /// An explicit environment value still takes precedence for development/tests.
    static func isEnabled(environment: [String: String], inputDirectory: URL) -> Bool {
        if let value = environment["MANGOREADER_DEMO_VIDEO"] { return value == "1" }
        return FileManager.default.fileExists(atPath: inputDirectory.appendingPathComponent(".recording-demo-enabled").path)
    }
    static let suite = "com.k800k.manko.demo-video"
    static var inputs: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MangoReaderDemoInputs")
    }

    static func iconContent(entry: SourceRepositoryEntry) throws -> RepositoryIconContent {
        // Only the catalog's package-local icon paths may access staged inputs.
        let components = entry.icon.split(separator: "/")
        guard components.count == 2, components[0] == "icons",
              !components[1].contains(".."), !components[1].contains(":") else { throw SourceError.invalidURL }
        let url = inputs.appendingPathComponent(entry.icon)
        let types = ["svg": "image/svg+xml", "png": "image/png", "webp": "image/webp", "ico": "image/x-icon", "jpg": "image/jpeg"]
        guard let mediaType = types[url.pathExtension.lowercased()] else { throw SourceError.unsupportedResponse }
        return RepositoryIconContent(data: try Data(contentsOf: url), mediaType: mediaType)
    }

    static func defaults(suiteName: String = suite, reset: Bool = ProcessInfo.processInfo.environment["MANGOREADER_DEMO_RESET"] == "1") -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        if reset { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(ProcessInfo.processInfo.environment["MANGOREADER_FIXTURE_APPEARANCE"] ?? "light", forKey: "preferredAppearance")
        defaults.set(false, forKey: "syncImportedFiles")
        defaults.set(false, forKey: "syncPreferences")
        return defaults
    }

    static func prepare(services: AppServiceBundle, defaults: UserDefaults, inputDirectory: URL = inputs) async throws {
        if let preparationTask { return try await preparationTask.value }
        let task = Task { try await prepareInputs(services: services, defaults: defaults, inputs: inputDirectory) }
        preparationTask = task
        do { try await task.value }
        catch { preparationTask = nil; throw error }
    }

    private static func prepareInputs(services: AppServiceBundle, defaults: UserDefaults, inputs: URL) async throws {
        let manifestURL = inputs.appendingPathComponent("versioning.json")
        var manifest = try JSONDecoder().decode(SourceRepositoryManifestV2.self, from: Data(contentsOf: manifestURL))
        manifest.repository.id = "demo-video"
        let root = URL(string: "https://k800k.github.io/extensions/dist/v1/stable/")!
        let checkedAt = (try? manifestURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let record = RepositoryRecord(manifest: manifest, repositoryURL: root, manifestURL: root.appendingPathComponent("versioning.json"), checkedAt: checkedAt)
        let packages = try ExtensionPackageStore(rootDirectory: services.storagePaths.sourceExtensionsDirectory)
        var installed: [InstalledRepositorySource] = []
        for entry in manifest.sources {
            guard let payload = entry.mangoReaderExtension else { continue }
            let module = try Data(contentsOf: inputs.appendingPathComponent(payload.artifactURL))
            let active = try? await packages.activeScriptURL(repositoryID: record.id, sourceID: entry.id)
            if active.flatMap({ try? Data(contentsOf: $0) }) != module {
                let staged = try await packages.stage(script: module, repositoryID: record.id,
                    sourceID: entry.id, version: entry.version, expectedSHA256: payload.sha256, expectedSize: payload.size)
                let receipt = try await packages.activate(staged)
                try await packages.commit(receipt)
            }
            let enabled = entry.kind == .content
            installed.append(InstalledRepositorySource(repositoryID: record.id, sourceID: entry.id,
                descriptor: SourceDescriptor(id: SourceID(rawValue: "repository.demo-video.\(entry.id)"),
                    name: entry.name, kind: .mangoReaderExtension, languageCodes: entry.languages,
                    capabilities: Set(entry.capabilities.compactMap(\.sourceCapability)), isEnabled: enabled),
                entryType: .mangoReaderExtension, kind: entry.kind ?? .content, availability: .available,
                version: entry.version, apiVersion: payload.apiVersion, scriptSHA256: payload.sha256,
                capabilities: entry.capabilities, allowedHTTPSHosts: payload.allowedHTTPSHosts,
                authenticationModes: payload.authenticationModes, permissions: entry.permissions,
                isEnabled: enabled, connectorKind: payload.connectorKind))
        }
        try await services.repositoryStore.upsert(record)
        for source in installed { try await services.repositoryStore.install(source) }
        if !defaults.bool(forKey: "demoHistorySeeded"), FileManager.default.fileExists(atPath: inputs.appendingPathComponent("books.json").path) {
            let books = try JSONDecoder().decode([MangoReaderScreenshotMode.Book].self, from: Data(contentsOf: inputs.appendingPathComponent("books.json")))
            try await MangoReaderScreenshotMode.seed(books: books, inputs: inputs, paths: services.storagePaths,
                database: services.database, importer: services.importer)
            defaults.set(true, forKey: "demoHistorySeeded")
        }
    }
}
#endif
