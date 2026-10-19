#if DEBUG
import CryptoKit
import Foundation
import ImageIO
import MankoData
import MankoDomain
@_spi(Testing) import MankoExtensions
@_spi(Testing) import MankoReaders
@_spi(Testing) import MankoSources
import MankoSync
import Observation
import OSLog
import SwiftUI
import Synchronization
import UIKit
import WebKit

@MainActor
enum AppFixtures {
    static var didResetPersistentStateForUITesting = false

    static func resetPersistentStateForUITesting(defaults: UserDefaults) {
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bundleIdentifier)
        }
        guard let paths = try? StoragePaths.applicationSupport() else { return }
        try? FileManager.default.removeItem(at: paths.applicationSupportDirectory)
        try? FileManager.default.removeItem(at: paths.cachesDirectory)
    }

    static var shouldSeedLibraryForUITesting: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--manko-ui-test-reset")
            && arguments.contains("--manko-ui-test-seed-library")
    }

    static var shouldSeedMetadataTagSearchForUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--manko-ui-test-seed-metadata-tags")
    }

    static var shouldUseSourceLayoutForUITesting: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--manko-ui-test-reset")
            && arguments.contains("--manko-ui-test-source-layout")
    }

    static func sourceLayoutPageForUITesting(page: Int, query: String) async throws -> SourcePage<Work> {
        try await Task.sleep(for: .milliseconds(600))
        if query.lowercased() == "empty" { return SourcePage(items: []) }
        if query.lowercased() == "error" { throw URLError(.notConnectedToInternet) }
        let first = (page - 1) * 24 + 1
        let works = (first..<(first + 24)).map { index in
            Work(
                id: WorkID(rawValue: UUID(uuidString: String(format: "A2000000-0000-0000-0000-%012d", index))!),
                sourceID: metadataTagSearchSourceForUITesting.id,
                remoteID: "layout-\(index)",
                title: "Layout Result \(index)",
                authors: ["Fixture Author"],
                kind: .manga
            )
        }
        return SourcePage(items: works, nextPage: page == 1 ? 2 : nil)
    }

    static var shouldSeedLibraryLayoutForUITesting: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--manko-ui-test-reset")
            && arguments.contains("--manko-ui-test-seed-library-layout")
    }

    static var shouldUseShortLibrarySummaryForUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains(
            "--manko-ui-test-short-library-summary"
        )
    }

    static var shouldSeedTrackerExtensionForUITesting: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--manko-ui-test-reset")
            && arguments.contains("--manko-ui-test-seed-tracker")
    }

    static var shouldSeedBrowseSourcesForUITesting: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--manko-ui-test-reset")
            && arguments.contains("--manko-ui-test-seed-browse-sources")
    }

    static var shouldSeedSearchAndHistoryForUITesting: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--manko-ui-test-reset")
            && arguments.contains("--manko-ui-test-seed-search-history")
    }

    static var shouldSeedSearchCloudflareSummaryForUITesting: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--manko-ui-test-reset")
            && arguments.contains("--manko-ui-test-search-cloudflare-summary")
    }

    static var shouldSeedReadingContentForUITesting: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--manko-ui-test-reset")
            && arguments.contains("--manko-ui-test-seed-reading-content")
    }

    static let searchSourceForUITesting = SourceDescriptor(
        id: "ui-test-search-source",
        name: "Fixture Server",
        kind: .opds,
        capabilities: [.browse, .search, .filters]
    )

    static let metadataTagSearchSourceForUITesting = SourceDescriptor(
        id: "ui-test-metadata-tag-source",
        name: ProcessInfo.processInfo.arguments.contains("--manko-ui-test-long-source-name")
            ? "Fixture Catalogue with a Very Long Source Name for Layout Verification"
            : "Fixture Tag Source",
        kind: .mankoExtension,
        baseURL: URL(string: "https://fixture.example"),
        capabilities: [.browse, .search, .filters]
    )

    static let metadataTagSearchConfigurationForUITesting = SourceSearchConfiguration(
        id: "ui-test-tag-search",
        title: "Fixture Tag Search",
        fields: [
            SourceSearchField(
                id: "tag",
                title: "Tag",
                queryPrefix: "tag:",
                placeholder: "Filter by tag",
                supportsExclusion: true
            ),
            SourceSearchField(
                id: "author",
                title: "Author",
                queryPrefix: "author:",
                placeholder: "Filter by author",
                supportsExclusion: true
            ),
            SourceSearchField(
                id: "genre",
                title: "Genre",
                queryPrefix: "genre:",
                placeholder: "Filter by genre",
                supportsExclusion: true
            ),
            SourceSearchField(
                id: "theme",
                title: "Theme",
                queryPrefix: "theme:",
                placeholder: "Filter by theme",
                supportsExclusion: true
            ),
        ],
        sortOptions: ProcessInfo.processInfo.arguments.contains("--manko-ui-test-source-sort-options")
            ? [.init(id: "popular", title: "Popular"), .init(id: "updated", title: "Recently Updated")]
            : [],
        defaultSortID: ProcessInfo.processInfo.arguments.contains("--manko-ui-test-source-sort-options")
            ? "popular" : nil
    )

    static let metadataTagSuggestionsForUITesting = [
        SourceSearchSuggestion(fieldID: "tag", value: "glasses"),
        SourceSearchSuggestion(
            fieldID: "tag",
            value: "big breasts",
            subtitle: "231086 galleries"
        ),
    ]

    static let metadataTagSearchResultsForUITesting: [Work] = [
        Work(
            id: WorkID(rawValue: UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!),
            sourceID: metadataTagSearchSourceForUITesting.id,
            remoteID: "fixture-1",
            title: "Placeholder Title 1",
            authors: ["Reading Club"],
            latestChapterTitle: "Chapter 18 — The Hidden Stacks",
            tags: ["Mystery"],
            searchFacets: [
                WorkSearchFacet(fieldID: "author", value: "reading-club", title: "Reading Club", presentation: .creator),
                WorkSearchFacet(fieldID: "genre", value: "mystery", title: "Mystery", presentation: .tag),
            ],
            languageCode: "en-GB",
            kind: .manga
        ),
        Work(
            id: WorkID(rawValue: UUID(uuidString: "A1000000-0000-0000-0000-000000000002")!),
            sourceID: metadataTagSearchSourceForUITesting.id,
            remoteID: "fixture-2",
            title: "プレースホルダー 2",
            authors: ["Fixture Author"],
            latestChapterTitle: "第12話",
            languageCode: "ja",
            kind: .manga
        ),
        Work(
            id: WorkID(rawValue: UUID(uuidString: "A1000000-0000-0000-0000-000000000003")!),
            sourceID: metadataTagSearchSourceForUITesting.id,
            remoteID: "fixture-3",
            title: "Placeholder Title 3",
            authors: ["Manko Fixtures"],
            latestChapterTitle: "Chapter 7",
            languageCode: "en-US",
            kind: .comic
        ),
        Work(
            id: WorkID(rawValue: UUID(uuidString: "A1000000-0000-0000-0000-000000000004")!),
            sourceID: metadataTagSearchSourceForUITesting.id,
            remoteID: "fixture-4",
            title: "占位标题 4",
            authors: ["Sample Studio"],
            latestChapterTitle: "第九章",
            languageCode: "zh-Hans-CN",
            kind: .manga
        ),
        Work(
            id: WorkID(rawValue: UUID(uuidString: "A1000000-0000-0000-0000-000000000005")!),
            sourceID: metadataTagSearchSourceForUITesting.id,
            remoteID: "fixture-5",
            title: "Titre de remplacement 5",
            authors: ["Atelier Exemple"],
            latestChapterTitle: "Chapitre 5",
            languageCode: "fr",
            kind: .book
        ),
        Work(
            id: WorkID(rawValue: UUID(uuidString: "A1000000-0000-0000-0000-000000000006")!),
            sourceID: metadataTagSearchSourceForUITesting.id,
            remoteID: "fixture-6",
            title: "Placeholder Title 6",
            authors: ["Fixture Collective"],
            latestChapterTitle: "Signal 3",
            languageCode: "tlh",
            kind: .lightNovel
        ),
    ]

    static let searchCloudflareSourcesForUITesting = [
        SourceDescriptor(
            id: "ui-test-cloudflare-first",
            name: "First Protected Source",
            kind: .opds,
            baseURL: URL(string: "https://first-protected.example"),
            capabilities: [.search]
        ),
        SourceDescriptor(
            id: "ui-test-cloudflare-second",
            name: "Second Protected Source",
            kind: .opds,
            baseURL: URL(string: "https://second-protected.example"),
            capabilities: [.search]
        ),
    ]

    static let browseSourcesForUITesting = [
        SourceDescriptor(
            id: "ui-test-browse-server",
            name: "Fixture Komga",
            kind: .komga,
            baseURL: URL(string: "https://komga.example"),
            capabilities: [.browse, .search]
        ),
        SourceDescriptor(
            id: "ui-test-browse-extension",
            name: "Fixture Extension",
            kind: .mankoExtension,
            capabilities: [.browse, .search]
        ),
    ]

    static func seedLibraryForUITesting(in database: MankoDatabase) async throws {
        let workID = WorkID(
            rawValue: UUID(uuidString: "B14E768E-C547-4F85-83E2-D8B47217AB20")!
        )
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let summary: String
        if shouldUseShortLibrarySummaryForUITesting {
            summary = "A concise summary that fits without an expansion control."
        } else {
            summary = [
                "A deterministic long summary used to verify the About section on the Library detail screen.",
                "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
                "Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.",
                "The complete fixture deliberately spans well beyond three lines so the expansion control is always exercised.",
            ].joined(separator: " ")
        }
        let work = Work(
            id: workID,
            sourceID: shouldSeedMetadataTagSearchForUITesting
                ? metadataTagSearchSourceForUITesting.id
                : .local,
            title: "UI Test Library Title",
            authors: ["manko"],
            summary: summary,
            tags: ["Mystery", "Adventure"],
            searchFacets: shouldSeedMetadataTagSearchForUITesting ? [
                WorkSearchFacet(
                    fieldID: "author",
                    value: "manko",
                    title: "manko",
                    presentation: .creator
                ),
                WorkSearchFacet(
                    fieldID: "artist",
                    value: "reading-club-archivist",
                    title: "Placeholder Author",
                    presentation: .creator
                ),
                WorkSearchFacet(
                    fieldID: "group",
                    value: "city-archive-collective",
                    title: "Placeholder Artist",
                    presentation: .creator
                ),
                WorkSearchFacet(
                    fieldID: "genre",
                    value: "mystery",
                    title: "Mystery",
                    groupTitle: "Genres",
                    presentation: .tag
                ),
                WorkSearchFacet(
                    fieldID: "genre",
                    value: "adventure",
                    title: "Adventure",
                    groupTitle: "Genres",
                    presentation: .tag
                ),
                WorkSearchFacet(
                    fieldID: "theme",
                    value: "found-family",
                    title: "Found Family",
                    groupTitle: "Themes",
                    presentation: .tag
                ),
            ] : [],
            kind: .book,
            status: .ongoing,
            shareURL: shouldSeedMetadataTagSearchForUITesting
                ? URL(string: "https://fixture.example/titles/library") : nil,
            createdAt: timestamp,
            modifiedAt: timestamp
        )
        let entry = LibraryEntry(
            id: UUID(uuidString: "824E82C6-2936-407D-A1A4-C1AA5DB621B8")!,
            workID: workID,
            addedAt: timestamp
        )
        try await database.save(work: work, entry: entry)
        try await database.save(installments: [
            Installment(
                id: InstallmentID(
                    rawValue: UUID(uuidString: "8A62AD08-05FE-4EF6-94E7-41E599F6B3A7")!
                ),
                workID: workID,
                remoteID: "ui-test-chapter-1",
                title: "Chapter 1",
                number: 1,
                publishedAt: timestamp,
                format: .epub,
                acquisitionURL: URL(fileURLWithPath: "/ui-test/chapter-1.epub")
            ),
            Installment(
                id: InstallmentID(
                    rawValue: UUID(uuidString: "584B0514-946B-4A17-A2EA-6D17A12D2EE5")!
                ),
                workID: workID,
                remoteID: "ui-test-chapter-2",
                title: "Chapter 2",
                number: 2,
                publishedAt: timestamp.addingTimeInterval(86_400),
                format: .epub,
                acquisitionURL: URL(fileURLWithPath: "/ui-test/chapter-2.epub")
            ),
            Installment(
                id: InstallmentID(
                    rawValue: UUID(uuidString: "02E0D0C4-DBA5-4D6B-924E-779655F40341")!
                ),
                workID: workID,
                remoteID: "ui-test-chapter-3",
                title: "Chapter 3",
                number: 3,
                publishedAt: timestamp.addingTimeInterval(172_800),
                format: .epub,
                acquisitionURL: URL(fileURLWithPath: "/ui-test/chapter-3.epub")
            ),
        ])
    }

    static func seedReadingContentForUITesting(
        in database: MankoDatabase
    ) async throws {
        let workID = WorkID(
            rawValue: UUID(uuidString: "D0000000-0000-0000-0000-000000000001")!
        )
        let installmentID = InstallmentID(
            rawValue: UUID(uuidString: "D0000000-0000-0000-0000-000000000002")!
        )
        // Keep this prior-read fixture safely before the launch date so opening a
        // new title can deterministically replace it in recent-reading surfaces.
        let timestamp = Date(timeIntervalSince1970: 1_600_000_000)
        let work = Work(
            id: workID,
            sourceID: "ui-test-history-source",
            remoteID: "ui-test-history-title",
            title: "UI Test History-Only Title With an Intentionally Long Navigation Name",
            authors: ["manko"],
            summary: "Reader metadata synchronized without creating Library membership.",
            kind: .book,
            createdAt: timestamp,
            modifiedAt: timestamp
        )
        let installment = Installment(
            id: installmentID,
            workID: workID,
            remoteID: "ui-test-history-volume",
            title: "History Volume",
            number: 1,
            publishedAt: timestamp,
            format: .epub,
            acquisitionURL: URL(fileURLWithPath: "/ui-test/history-volume.epub")
        )
        try await database.saveReadingContent(work: work, installments: [installment])
        try await database.save(progress: ReadingProgress(
            workID: workID,
            installmentID: installmentID,
            locator: .publication(readiumJSON: Data(#"{"href":"chapter.xhtml"}"#.utf8)),
            currentProgression: 0.1,
            highestProgression: 0.1,
            deviceID: "ui-test-device"
        ))
        try await database.save(session: ReadingSession(
            id: UUID(uuidString: "D0000000-0000-0000-0000-000000000003")!,
            workID: workID,
            installmentID: installmentID,
            startedAt: timestamp,
            endedAt: timestamp.addingTimeInterval(120),
            secondsRead: 120,
            endProgression: 0.1
        ))
    }

    static func seedLibraryLayoutForUITesting(in database: MankoDatabase) async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let fixtures: [(String, String, ContentKind, Int, Int)] = [
            ("C28C66E7-D9C2-4699-BB02-290CE5551451", "Short", .manga, 0, 0),
            ("BFD7BEA4-E6DF-4F41-A3BD-7A3E2696056F", "A Library Title That Uses Both Reserved Lines", .comic, 0, 0),
            ("78BA46F0-079F-46CE-8345-7E6A19DB95FC", "SupercalifragilisticexpialidociousWithoutBreaks", .lightNovel, 0, 0),
            ("1909CFB9-1CD3-44B3-82A6-597DA492FE4E", "Unread Chapters", .manga, 189, 0),
            ("712E146F-DB99-45D7-B10B-D44EFF91564D", "Downloaded for Offline Reading", .book, 0, 12),
            ("DBEB1B33-1E04-44A5-8E8C-26BB1A553407", "Unread and Downloaded", .comic, 7, 3),
            ("2D9BFA7C-C444-48D7-BB85-43809193A0A0", "真夜中の読書クラブ", .manga, 0, 0),
            ("3C10530B-4D80-4BE1-A479-47B1AA5CD7BE", "The Final Layout Fixture", .lightNovel, 0, 0),
        ]

        for (index, fixture) in fixtures.enumerated() {
            let workID = WorkID(rawValue: UUID(uuidString: fixture.0)!)
            let date = timestamp.addingTimeInterval(Double(index))
            let work = Work(
                id: workID,
                sourceID: .local,
                title: fixture.1,
                authors: ["manko"],
                summary: "Deterministic content used to verify the adaptive Library grid.",
                kind: fixture.2,
                status: .ongoing,
                createdAt: date,
                modifiedAt: date
            )
            let entry = LibraryEntry(
                workID: workID,
                addedAt: date,
                unreadCount: fixture.3,
                downloadedCount: fixture.4
            )
            try await database.save(work: work, entry: entry)
        }
    }

    static func seedSearchAndHistoryForUITesting(
        in database: MankoDatabase
    ) async throws {
        let timestamp = Date.now
        for index in 1 ... 8 {
            let identifier = UUID(uuidString: String(format: "A0000000-0000-0000-0000-%012d", index))!
            let work = Work(
                id: WorkID(rawValue: identifier),
                sourceID: .local,
                title: "Carousel Fixture \(index)",
                authors: ["Search Author \(index)"],
                kind: index.isMultiple(of: 2) ? .comic : .manga,
                createdAt: timestamp.addingTimeInterval(Double(index)),
                modifiedAt: timestamp.addingTimeInterval(Double(index))
            )
            try await database.save(work: work, entry: LibraryEntry(workID: work.id))
        }

        let weeklyWork = Work(
            id: WorkID(rawValue: UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!),
            sourceID: .local,
            title: "Weekly History Fixture",
            authors: ["History Author"],
            kind: .manga
        )
        let secondWork = Work(
            id: WorkID(rawValue: UUID(uuidString: "B0000000-0000-0000-0000-000000000002")!),
            sourceID: .local,
            title: "Second Weekly Fixture",
            authors: ["History Author"],
            kind: .book
        )
        let firstInstallment = Installment(
            id: InstallmentID(rawValue: UUID(uuidString: "C0000000-0000-0000-0000-000000000001")!),
            workID: weeklyWork.id,
            title: "Chapter One",
            number: 1,
            format: .cbz
        )
        let latestInstallment = Installment(
            id: InstallmentID(rawValue: UUID(uuidString: "C0000000-0000-0000-0000-000000000002")!),
            workID: weeklyWork.id,
            title: "Chapter Two",
            number: 2,
            format: .cbz
        )
        let secondWorkInstallment = Installment(
            id: InstallmentID(rawValue: UUID(uuidString: "C0000000-0000-0000-0000-000000000003")!),
            workID: secondWork.id,
            title: "Complete Edition",
            format: .epub
        )
        try await database.save(
            work: weeklyWork,
            entry: LibraryEntry(workID: weeklyWork.id),
            installments: [firstInstallment, latestInstallment]
        )
        try await database.save(
            work: secondWork,
            entry: LibraryEntry(workID: secondWork.id),
            installments: [secondWorkInstallment]
        )

        let calendar = Calendar.autoupdatingCurrent
        let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: timestamp)?.start
            ?? calendar.startOfDay(for: timestamp)
        let previousWeekDate = calendar.date(byAdding: .day, value: -1, to: currentWeekStart)
            ?? timestamp.addingTimeInterval(-8 * 24 * 60 * 60)
        let sessions = [
            ReadingSession(
                workID: weeklyWork.id,
                installmentID: firstInstallment.id,
                startedAt: timestamp.addingTimeInterval(-3 * 60 * 60),
                endedAt: timestamp.addingTimeInterval(-2 * 60 * 60),
                secondsRead: 600,
                endProgression: 0.25
            ),
            ReadingSession(
                workID: weeklyWork.id,
                installmentID: latestInstallment.id,
                startedAt: timestamp.addingTimeInterval(-90 * 60),
                endedAt: timestamp.addingTimeInterval(-60 * 60),
                secondsRead: 900,
                endProgression: 0.7
            ),
            ReadingSession(
                workID: secondWork.id,
                installmentID: secondWorkInstallment.id,
                startedAt: timestamp.addingTimeInterval(-45 * 60),
                endedAt: nil,
                secondsRead: 300,
                endProgression: 0.4
            ),
            ReadingSession(
                workID: weeklyWork.id,
                installmentID: firstInstallment.id,
                startedAt: previousWeekDate.addingTimeInterval(-30 * 60),
                endedAt: previousWeekDate,
                secondsRead: 1_200,
                endProgression: 0.9
            ),
        ]
        for session in sessions {
            try await database.save(session: session)
        }
    }

    static func seedTrackerExtensionForUITesting(
        in repositoryStore: SourceRepositoryStore
    ) async throws {
        let repositoryID = "ui-test-trackers"
        let sourceID = "ui-test-tracker"
        let publisher = RepositoryPublisher(name: "UI Test Publisher")
        let repositoryURL = URL(string: "https://tracker.example/repository/")!
        func makeEntry(
            id: String,
            name: String,
            description: String,
            language: String,
            moduleURL: String,
            maturityRating: RepositoryMaturityRating = .safe
        ) -> SourceRepositoryEntry {
            SourceRepositoryEntry(
                id: id,
                name: name,
                description: description,
                version: "2.4.0",
                icon: "icon.png",
                languages: [language],
                maturityRating: maturityRating,
                capabilities: [.trackerSearch, .progress, .trackerCollections, .authentication],
                developers: [publisher],
                rightsDeclaration: "UI testing fixture",
                rightsURL: "https://tracker.example/rights",
                reportURL: "https://tracker.example/report",
                entryType: .mankoExtension,
                kind: .tracker,
                availability: .available,
                permissions: ExtensionPermissionSet([
                    .network,
                    .state,
                    .secureState,
                    .rateLimiting,
                    .redactedLogging,
                    .authenticationHandoff,
                    .trackerUpdates,
                ]),
                mankoExtension: MankoExtensionPayload(
                    moduleURL: moduleURL,
                    sha256: String(repeating: "0", count: 64),
                    size: 1_024,
                    allowedHTTPSHosts: ["tracker.example"],
                    authenticationModes: [.oauth2PKCE]
                )
            )
        }

        let entry = makeEntry(
            id: sourceID,
            name: "UI Test Tracker",
            description: "A deterministic tracker extension used to verify the installed manager.",
            language: "en",
            moduleURL: "tracker.wasm"
        )
        let auxiliaryEntry = makeEntry(
            id: "ui-test-auxiliary-tracker",
            name: "UI Test Auxiliary Tracker",
            description: "A deterministic uninstalled tracker used to verify filtered catalog actions.",
            language: "en",
            moduleURL: "auxiliary-tracker.wasm",
            maturityRating: .mature
        )
        let japaneseEntry = makeEntry(
            id: "ui-test-japanese-tracker",
            name: "UI Test Japanese Tracker",
            description: "A second uninstalled tracker used to verify multi-selection catalog actions.",
            language: "ja",
            moduleURL: "japanese-tracker.wasm",
            maturityRating: .adult
        )
        let manifest = SourceRepositoryManifestV2(
            repository: SourceRepositoryIdentity(
                id: repositoryID,
                name: "UI Test Tracker Repository",
                description: "A deterministic repository used by tracker manager UI tests.",
                homepage: "https://tracker.example",
                privacyURL: "https://tracker.example/privacy",
                publisher: publisher
            ),
            sources: [entry, auxiliaryEntry, japaneseEntry]
        )
        let repository = RepositoryRecord(
            manifest: manifest,
            repositoryURL: repositoryURL,
            manifestURL: repositoryURL.appendingPathComponent("index.json"),
            isBlocked: false,
            knownSourceIDs: [sourceID, auxiliaryEntry.id, japaneseEntry.id],
            newSourceIDs: [auxiliaryEntry.id, japaneseEntry.id]
        )
        let installed = InstalledRepositorySource(
            repositoryID: repositoryID,
            sourceID: sourceID,
            descriptor: SourceDescriptor(
                id: SourceID(rawValue: "repository.\(repositoryID).\(sourceID)"),
                name: entry.name,
                kind: .mankoExtension,
                languageCodes: entry.languages,
                capabilities: [.search, .authentication, .progressSync],
                isEnabled: true
            ),
            entryType: .mankoExtension,
            kind: .tracker,
            availability: .available,
            version: "2.3.0",
            apiVersion: entry.mankoExtension?.apiVersion ?? MankoExtensionPayload.supportedAPIVersion,
            scriptSHA256: entry.mankoExtension?.sha256,
            capabilities: entry.capabilities,
            allowedHTTPSHosts: entry.mankoExtension?.allowedHTTPSHosts ?? [],
            authenticationModes: entry.mankoExtension?.authenticationModes ?? [],
            permissions: entry.permissions,
            isEnabled: true
        )
        try await repositoryStore.restoreReferences(
            repositories: [repository],
            installedSources: [installed]
        )
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--manko-ui-test-tracker-signed-in") {
            let namespace = ExtensionRuntimeNamespace.primary(repositoryID: repositoryID, sourceID: sourceID)
            let secureStore = ExtensionSecureStateStore()
            try await secureStore.setIndexed(try JSONEncoder().encode("ui-test-fixture-token"),
                namespace: namespace, key: "oauth_access_token")
        }
        #endif
    }

#if DEBUG
    static func seedWasmMigrationForVerification(in store: SourceRepositoryStore) async throws {
        let repositoryID = "wasm-verification"
        let baseURL = URL(string: "https://wasm-fixture.example/repository/")!
        let publisher = RepositoryPublisher(name: "Manko Extension Contributors")
        let entries = try ["AniList", "MyAnimeList", "HitomiLA", "NHentai"].map { id in
            let isTracker = id == "AniList" || id == "MyAnimeList"
            var entry = SourceRepositoryEntry(
                id: id, name: id, description: "", version: "2.0.0", icon: "icon.png",
                languages: ["en"], maturityRating: isTracker ? .safe : .adult,
                capabilities: isTracker ? [.trackerSearch, .progress, .trackerCollections, .authentication]
                    : [.browse, .search, .details, .installments, .imageSequence],
                developers: [publisher], rightsDeclaration: "Local verification fixture",
                rightsURL: "", reportURL: "", entryType: .mankoExtension,
                kind: isTracker ? .tracker : .content,
                mankoExtension: MankoExtensionPayload(
                    moduleURL: "sources/\(id)/2.0.0/main.wasm",
                    sha256: String(repeating: "0", count: 64), size: 1_024,
                    allowedHTTPSHosts: ["catalog.example", "images.example"]
                )
            )
            entry.permissions = .init(isTracker ? [.network, .authenticationHandoff, .trackerUpdates] : [.network])
            if isTracker {
                entry.mankoExtension?.authenticationModes = [.oauth2PKCE]
                entry.mankoExtension?.accountPolicy = try JSONDecoder().decode(ExtensionAccountPolicy.self, from: Data(#"{"authentication":{"mode":"oauth2PKCE","authorizationURL":"https://catalog.example/oauth/authorize","tokenURL":"https://catalog.example/oauth/token","callbackScheme":"manko"},"requests":[{"origin":"https://catalog.example","pathPrefix":"/v2/manga/","methods":["GET"],"operations":["progress","collections"]},{"origin":"https://catalog.example","pathPrefix":"/v2/manga/","methods":["PUT"],"operations":["update"]}]}"#.utf8))
            } else {
                entry.mankoExtension?.allowedHTTPSHosts.append("*.media.static-extension-verification.catalog.example")
            }
            return entry
        }
        let manifest = SourceRepositoryManifestV2(repository: SourceRepositoryIdentity(
            id: repositoryID, name: "Manko Extensions", description: "", homepage: "",
            privacyURL: "", publisher: publisher
        ), sources: entries)
        let installations = ["AniList", "NHentai", "MangaDex"].map { id in
            InstalledRepositorySource(
                repositoryID: repositoryID, sourceID: id,
                descriptor: SourceDescriptor(
                    id: SourceID(rawValue: "repository.\(repositoryID).\(id)"), name: id,
                    kind: .mankoExtension, capabilities: id == "AniList" ? [.search, .progressSync] : [.browse, .search]
                ), entryType: .mankoExtension, kind: id == "AniList" ? .tracker : .content,
                version: "1.0.0", apiVersion: "1.2", scriptSHA256: nil,
                capabilities: [], allowedHTTPSHosts: [], runtime: .javascript
            )
        }
        let record = RepositoryRecord(manifest: manifest, repositoryURL: baseURL,
            manifestURL: baseURL.appending(path: "versioning.json"))
        try await store.restoreReferences(repositories: [record], installedSources: installations)
    }
#endif

    static func seedBrowseRepositoryForUITesting(
        in repositoryStore: SourceRepositoryStore
    ) async throws {
        let repositoryID = "ui-test-content"
        let sourceID = "ui-test-content-extension"
        let publisher = RepositoryPublisher(name: "UI Test Publisher")
        let repositoryURL = URL(string: "https://content.example/repository/")!
        let entry = SourceRepositoryEntry(
            id: sourceID,
            name: "Fixture Extension",
            description: "A deterministic content extension for Add Source catalog tests.",
            version: "1.0.0",
            icon: "icon.png",
            languages: ["en"],
            maturityRating: .safe,
            capabilities: [.browse, .search, .details, .installments, .imageSequence],
            developers: [publisher],
            rightsDeclaration: "UI testing fixture",
            rightsURL: "https://content.example/rights",
            reportURL: "https://content.example/report",
            entryType: .mankoExtension,
            kind: .content,
            availability: .available,
            permissions: ExtensionPermissionSet([.network, .state, .rateLimiting, .redactedLogging]),
            mankoExtension: MankoExtensionPayload(
                moduleURL: "content.wasm",
                sha256: String(repeating: "0", count: 64),
                size: 1_024,
                allowedHTTPSHosts: ["content.example"]
            )
        )
        let manifest = SourceRepositoryManifestV2(
            repository: SourceRepositoryIdentity(
                id: repositoryID,
                name: "UI Test Content Repository",
                description: "A deterministic content repository for Add Source catalog tests.",
                homepage: "https://content.example",
                privacyURL: "https://content.example/privacy",
                publisher: publisher
            ),
            sources: [entry]
        )
        let repository = RepositoryRecord(
            manifest: manifest,
            repositoryURL: repositoryURL,
            manifestURL: repositoryURL.appendingPathComponent("index.json")
        )
        let installed = InstalledRepositorySource(
            repositoryID: repositoryID,
            sourceID: sourceID,
            descriptor: browseSourcesForUITesting[1],
            entryType: .mankoExtension,
            kind: .content,
            availability: .available,
            version: entry.version,
            apiVersion: entry.mankoExtension?.apiVersion ?? MankoExtensionPayload.supportedAPIVersion,
            scriptSHA256: entry.mankoExtension?.sha256,
            capabilities: entry.capabilities,
            allowedHTTPSHosts: entry.mankoExtension?.allowedHTTPSHosts ?? [],
            authenticationModes: entry.mankoExtension?.authenticationModes ?? [],
            permissions: entry.permissions,
            isEnabled: true
        )
        try await repositoryStore.restoreReferences(
            repositories: [repository],
            installedSources: [installed]
        )
    }
}

#if DEBUG
extension AppFixtures {
    static var readerFixtureShouldFail = ProcessInfo.processInfo.arguments.contains("--manko-reader-chapter-failure-verification")
    private static let readerFixtureWorks = [
        WorkID(rawValue: UUID(uuidString: "E8000000-0000-0000-0000-000000000001")!),
        WorkID(rawValue: UUID(uuidString: "E8000000-0000-0000-0000-000000000002")!)
    ]
    private static var readerFixtureDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "ReaderChapterFixtures")
    }
    private static func readerFixtureChapters(variant: Int) -> [Installment] {
        (1...3).map { number in
            Installment(id: InstallmentID(rawValue: UUID(uuidString: String(format: "E8000000-0000-0000-0000-%012d", (variant + 1) * 100 + number))!),
                workID: readerFixtureWorks[variant], title: "Chapter \(number)", number: Double(number),
                format: variant == 0 ? .remoteImageSequence : .cbz,
                acquisitionURL: variant == 0 ? nil : readerFixtureDirectory.appending(path: "chapter-\(number).cbz"), pageCount: 2)
        }
    }
    static func seedReaderChapterSamples(model: AppModel) async throws {
        guard let database = model.database else { return }
        for number in 1...3 {
            try await ReaderVerificationArchive.write(pages: (1...2).map { readerFixtureImage(chapter: number, page: $0) },
                to: readerFixtureDirectory.appending(path: "chapter-\(number).cbz"))
        }
        var preferences = ReaderAdditionalPreferences.read(from: .standard)
        for variant in 0...1 {
            let work = Work(id: readerFixtureWorks[variant], sourceID: .local,
                title: "Reader Chapters — \(variant == 0 ? "Streamed" : "CBZ")", readingMode: "webtoon",
                authors: ["Manko verification"], summary: "Three original chapters for verifying boundaries and continuous reading.", kind: .comic)
            try await database.save(work: work, entry: LibraryEntry(workID: work.id, unreadCount: 3), installments: readerFixtureChapters(variant: variant))
            preferences.workOverrides[work.id.description] = ReaderWorkPreferences(readingMode: "webtoon")
        }
        UserDefaults.standard.set(preferences.encoded, forKey: ReaderAdditionalPreferences.storageKey)
        await model.libraryModel.refreshLibrary(showsLoadingIndicator: false)
    }
    static func readerChapterFixture(work: Work, installment: Installment) throws -> PreparedReaderContent? {
        guard let variant = readerFixtureWorks.firstIndex(of: work.id) else { return nil }
        if readerFixtureShouldFail, installment.number == 2 { throw ReaderFixtureError.offline }
        let chapters = readerFixtureChapters(variant: variant)
        guard let chapter = chapters.first(where: { $0.id == installment.id }) else { return nil }
        var content = PreparedReaderContent(chapters: chapters, chaptersAreComplete: true, work: work, installment: chapter)
        if variant == 0 {
            let images = (1...2).map { readerFixtureImage(chapter: Int(chapter.number ?? 1), page: $0) }
            let pages = (0..<2).map { RemoteImagePageDescriptor(id: "\(chapter.id)/\($0)", sourceID: .local,
                installmentID: chapter.id, index: $0, resourceURL: URL(string: "https://reader-fixture.invalid/\(chapter.id)/\($0).png")!) }
            content.remotePublication = RemoteImagePublication(sourcePages: pages, loader: ReaderFixturePageLoader(images: images))
        }
        return content
    }
    fileprivate static func readerFixtureImage(chapter: Int, page: Int) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: format).pngData { context in
            UIColor(white: 0.96, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            let color: UIColor = [.systemBlue, .systemOrange, .systemTeal][chapter - 1]
            color.setFill(); context.fill(CGRect(x: 36, y: 40, width: 528, height: 12))
            let heading = "CHAPTER \(chapter)\nPAGE \(page) OF 2" as NSString
            heading.draw(in: CGRect(x: 40, y: 80, width: 520, height: 160), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 40), .foregroundColor: UIColor.black])
            for row in 0..<3 {
                color.withAlphaComponent(0.15).setFill(); context.fill(CGRect(x: 40, y: 280 + row * 130, width: 520, height: 100))
                color.setFill(); context.fill(CGRect(x: 65 + chapter * 65 + page * 20, y: 305 + row * 130, width: 50, height: 50))
            }
            ("Placeholder Image · 600 × 800" as NSString).draw(at: CGPoint(x: 40, y: 740), withAttributes: [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.darkGray])
        }
    }
}
private enum ReaderFixtureError: LocalizedError {
    case offline
    var errorDescription: String? { "Fixture chapter 2 is unavailable. Enable it in Reader Verification, then retry." }
}
private struct ReaderFixturePageLoader: RemoteImagePageLoading {
    let images: [Data]
    func imagePageContent(for page: RemoteImagePageDescriptor) async throws -> RemoteImagePageContent {
        RemoteImagePageContent(data: images[page.index], mediaType: "image/png")
    }
    nonisolated func streamImagePageContent(for page: RemoteImagePageDescriptor, priority: RemoteImageRequestPriority,
        onPartial: @escaping RemoteImagePageProgress,
        onProgress: @escaping RemoteImageDownloadProgressHandler) async throws -> RemoteImagePageContent {
        let data = images[page.index]
        if ProcessInfo.processInfo.arguments.contains("--manko-reader-page-progress-verification") {
            for step in 0..<4 {
                try Task.checkCancellation()
                await onProgress(.init(receivedBytes: Int64(data.count * step / 4), expectedBytes: Int64(data.count)))
                try await Task.sleep(for: .seconds(page.index == 0 ? 2 : 10))
            }
            await onProgress(.init(receivedBytes: Int64(data.count), expectedBytes: Int64(data.count)))
        }
        return .init(data: data, mediaType: "image/png")
    }
}

actor CacheVerificationSource: SourceDiscoverSectionProviding, SourceSearchConfigurationProviding {
    static let shared = CacheVerificationSource()
    nonisolated static let descriptor = SourceDescriptor(id: "cache-verification", name: "Cache Verification", kind: .opds,
        baseURL: URL(string: "https://cache-fixture.invalid"), capabilities: [.browse, .search, .imageSequence])
    nonisolated var descriptor: SourceDescriptor { Self.descriptor }
    private var version = 1
    private var fails = false
    private(set) var pageRequests: [URL] = []
    func setFailure(_ enabled: Bool) { fails = enabled }
    func advance() { version += 1 }
    private func response() async throws -> [Work] {
        try await Task.sleep(for: .seconds(2))
        if fails { throw URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "The sample source is offline. Previously loaded titles are still available."]) }
        return (1...3).map { number in
            Work(id: WorkID(rawValue: UUID(uuidString: String(format: "E9000000-0000-0000-0000-%012d", number))!),
                sourceID: Self.descriptor.id, remoteID: String(number), title: "Cached Sample \(number) · revision \(version)", kind: .comic)
        }
    }
    func discoverSections() -> [SourceDiscoverSection] { [.init(id: "latest", title: "Recently Updated", presentation: .latestGallery)] }
    func discover(sectionID: String, query: SourceQuery) async throws -> SourcePage<Work> { .init(items: try await response()) }
    func browse(_ query: SourceQuery) async throws -> SourcePage<Work> { .init(items: try await response()) }
    func search(_ query: SourceQuery) async throws -> SourcePage<Work> { .init(items: try await response()) }
    func details(for remoteID: String) async throws -> Work {
        guard let work = try await response().first(where: { $0.remoteID == remoteID }) else { throw SourceError.notFound }
        return work
    }
    func installments(for work: Work, page: Int) -> SourcePage<Installment> {
        let number = Int(work.remoteID ?? "1") ?? 1
        return .init(items: [Installment(id: InstallmentID(rawValue: UUID(uuidString: String(format: "E9100000-0000-0000-0000-%012d", number))!),
            workID: work.id, remoteID: "preview-\(number)", title: "Progressive image sample", number: 1,
            format: .remoteImageSequence, pageCount: 2)])
    }
    func imagePages(for installment: Installment, query: RemoteImagePageQuery) -> SourcePage<RemoteImagePageDescriptor> {
        .init(items: (0..<2).map { .init(id: "\(installment.id)/\($0)", sourceID: Self.descriptor.id,
            installmentID: installment.id, index: $0, resourceURL: URL(string: "https://cache-fixture.invalid/\(installment.id)/\($0).jpg?revision=\(version)")!) })
    }
    func imagePageContent(for page: RemoteImagePageDescriptor) async throws -> RemoteImagePageContent {
        try await fixtureImageContent(for: page, onPartial: { _ in })
    }
    nonisolated func streamImagePageContent(for page: RemoteImagePageDescriptor, priority: RemoteImageRequestPriority,
        onPartial: @escaping RemoteImagePageProgress) async throws -> RemoteImagePageContent {
        try await fixtureImageContent(for: page, onPartial: onPartial)
    }
    nonisolated func streamImagePageContent(for page: RemoteImagePageDescriptor, priority: RemoteImageRequestPriority,
        onPartial: @escaping RemoteImagePageProgress,
        onProgress: @escaping RemoteImageDownloadProgressHandler) async throws -> RemoteImagePageContent {
        try await fixtureImageContent(for: page, onPartial: onPartial, onProgress: onProgress)
    }
    private func fixtureImageContent(for page: RemoteImagePageDescriptor,
        onPartial: @escaping RemoteImagePageProgress,
        onProgress: @escaping RemoteImageDownloadProgressHandler = { _ in }) async throws -> RemoteImagePageContent {
        pageRequests.append(page.resourceURL)
        guard page.resourceURL.query == "revision=\(version)" else {
            return .init(data: Data("<html>This image link has expired.</html>".utf8), mediaType: "text/html")
        }
        if fails { throw URLError(.notConnectedToInternet) }
        let png = await AppFixtures.readerFixtureImage(chapter: 1, page: page.index + 1)
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw SourceError.unsupportedResponse }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw SourceError.unsupportedResponse }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true]] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw SourceError.unsupportedResponse }
        let bytes = data as Data
        await onProgress(.init(receivedBytes: 0, expectedBytes: Int64(bytes.count)))
        for step in 1...4 {
            try await Task.sleep(for: .seconds(1))
            let received = bytes.count * step / 5
            await onProgress(.init(receivedBytes: Int64(received), expectedBytes: Int64(bytes.count)))
            if step == 3 { await onPartial(.init(data: Data(bytes.prefix(received)), mediaType: "image/jpeg")) }
        }
        return .init(data: bytes, mediaType: "image/jpeg")
    }
    func acquisitionURL(for installment: Installment) throws -> URL { throw SourceError.unsupportedResponse }
    func searchConfiguration() -> SourceSearchConfiguration? { nil }
}

extension AppFixtures {
    static var cacheVerificationKeys: Set<String> = []
    static func expireCacheVerification(model: AppModel) async {
        for key in cacheVerificationKeys {
            if let cached = await ContentCache.shared.entry(for: key) {
                await ContentCache.shared.store(cached.data, for: key, date: .distantPast)
            }
        }
    }
}
#endif


#if DEBUG
extension AppFixtures {
    static var shouldSeedCloudBooks: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--manko-ui-test-reset") && arguments.contains("--manko-ui-test-seed-cloud-books")
    }
    static let cloudBookWorkID = WorkID(rawValue: UUID(uuidString: "F1000000-0000-0000-0000-000000000001")!)
    static var didDeliverCloudPosition = false

    static func seedCloudBooks(database: MankoDatabase, paths: StoragePaths) async throws -> ImportedOriginalCloudOrchestrator {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 420, height: 600))
        let bytes = renderer.pdfData { context in
            for page in 1 ... 4 {
                context.beginPage()
                ("Local Book Sync\n\nPage \(page) of 4\n\nA small original publication for verifying local copies and reading-position handoff." as NSString)
                    .draw(in: CGRect(x: 32, y: 60, width: 350, height: 450),
                          withAttributes: [.font: UIFont.systemFont(ofSize: 23)])
            }
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let documents = paths.cachesDirectory.appendingPathComponent("LocalBookCloudFixture/Documents", isDirectory: true)
        let originals = documents.appendingPathComponent("manko/ImportedOriginals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try bytes.write(to: originals.appendingPathComponent("\(digest).pdf"))
        let work = Work(id: cloudBookWorkID, sourceID: .local, title: "Local Book Sync", kind: .book)
        let chapter = Installment(id: InstallmentID(rawValue: UUID(uuidString: "F2000000-0000-0000-0000-000000000001")!),
            workID: work.id, title: "Complete book", format: .pdf)
        try await database.save(work: work, entry: LibraryEntry(workID: work.id, cloudFilePolicy: .syncOriginal), installments: [chapter])
        try await database.save(importedOriginalReference: ImportedOriginalReference(workID: work.id,
            installmentID: chapter.id, sourceID: .local, format: .pdf, sha256Hex: digest,
            byteCount: Int64(bytes.count), deviceID: "fixture-other-device"))
        try await database.save(progress: ReadingProgress(workID: work.id, installmentID: chapter.id,
            locator: .publication(readiumJSON: Data(#"{"href":"publication.pdf","type":"application/pdf","locations":{"position":3,"totalProgression":0.5}}"#.utf8)),
            currentProgression: 0.5, highestProgression: 0.5, modifiedAt: .now.addingTimeInterval(-8 * 86_400), deviceID: "fixture-other-device"))
        let transfer = CloudBookFixtureTransfer(base: ImportedOriginalCloudTransferService(
            libraryFilesDirectory: paths.libraryFilesDirectory, cloudDocumentsDirectory: documents))
        let orchestrator = ImportedOriginalCloudOrchestrator(database: database, transfer: transfer,
            documentsResolver: CloudBookFixtureDocuments(url: documents),
            libraryFilesDirectory: paths.libraryFilesDirectory, deviceID: "fixture-this-device")
        _ = await orchestrator.setCloudAccountAvailable(true, globalImportedFileSyncEnabled: true, reconcile: false)
        return orchestrator
    }

    static func deliverCloudPositionIfNeeded(model: AppModel, work: Work, installment: Installment) async {
        guard shouldSeedCloudBooks, work.id == cloudBookWorkID, !didDeliverCloudPosition else { return }
        didDeliverCloudPosition = true
        do {
            try await Task.sleep(for: .seconds(15))
            guard let database = model.database else { return }
            try await database.save(progress: ReadingProgress(workID: work.id, installmentID: installment.id,
                locator: .publication(readiumJSON: Data(#"{"href":"publication.pdf","type":"application/pdf","locations":{"position":1,"totalProgression":0}}"#.utf8)),
                currentProgression: 0, highestProgression: 0.5, deviceID: "fixture-other-device"))
            model.cloudReadingRevision &+= 1
        } catch {}
    }
}

private struct CloudBookFixtureDocuments: ImportedOriginalCloudDocumentsResolving {
    let url: URL
    func documentsDirectory() async -> URL? { url }
}

private actor CloudBookFixtureTransfer: ImportedOriginalCloudTransferring {
    let base: ImportedOriginalCloudTransferService
    private var attempts = 0
    init(base: ImportedOriginalCloudTransferService) { self.base = base }
    func updateCloudDocumentsDirectory(_ directory: URL?) async { await base.updateCloudDocumentsDirectory(directory) }
    func reconcileUpload(_ original: ManagedImportedOriginal, globalImportedFileSyncEnabled: Bool) async throws -> ImportedOriginalCloudReconciliation {
        try await base.reconcileUpload(original, globalImportedFileSyncEnabled: globalImportedFileSyncEnabled)
    }
    func reconcileDownload(_ descriptor: ImportedOriginalReference, titlePolicy: CloudFilePolicy,
                           globalImportedFileSyncEnabled: Bool) async throws -> ImportedOriginalCloudReconciliation {
        attempts += 1
        if attempts == 1 { throw ImportedOriginalCloudTransferError.cloudFileMissing }
        try await Task.sleep(for: .seconds(8))
        return try await base.reconcileDownload(descriptor, titlePolicy: titlePolicy,
            globalImportedFileSyncEnabled: globalImportedFileSyncEnabled)
    }
}
// Manual Computer Use fixture. It exercises the production reader shell and
// sectioned EPUB navigator without depending on a third-party site's availability.
@MainActor
extension AppFixtures {
    static var isVerifyingReaderOpening: Bool {
        ProcessInfo.processInfo.arguments.contains("--manko-reader-opening-verification")
    }
    static let openingVerificationWork = Work(sourceID: "reader-opening-verification", remoteID: "series",
        title: "LNori Reader Verification", kind: .lightNovel)
    static let openingVerificationVolume = Installment(workID: openingVerificationWork.id, remoteID: "volume",
        title: "Volume 1", format: .epub)
    static var openingVerificationAttempts = 0
    static var openingVerificationRequest: ReaderOpenRequest {
        .init(work: openingVerificationWork, target: .installment(openingVerificationVolume, chapters: [openingVerificationVolume]))
    }
    static func prepareOpeningVerification() async throws -> PreparedReaderContent {
        openingVerificationAttempts += 1
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--manko-reader-opening-loading"), openingVerificationAttempts == 1 {
            try await Task.sleep(for: .seconds(30))
        } else { try await Task.sleep(for: .milliseconds(400)) }
        if arguments.contains("--manko-reader-opening-failure"), openingVerificationAttempts == 1 {
            throw ReaderPreparationFailure.unavailable("The source is offline. Retry to load the cached verification volume.")
        }
        let paragraphs = (0..<300).map { index in
            "<p>Passage \(index + 1). " + String(repeating: "The reader opens first, then the volume appears. Each section is prepared for comfortable reading. ", count: 8) + "</p>"
        }.joined()
        let content = try JSONDecoder().decode(MankoPublicationContent.self, from: JSONEncoder().encode([
            "id": "volume", "workId": "series", "mimeType": "application/xhtml+xml",
            "text": "<h1>A Faster Opening</h1>" + paragraphs,
        ]))
        var builder = MankoExtensionEPUBBuilder()
        builder.destinationDirectory = builder.destinationDirectory.appending(path: "Private/\(UUID().uuidString)", directoryHint: .isDirectory)
        var delivered = false
        defer { if !delivered { try? FileManager.default.removeItem(at: builder.destinationDirectory) } }
        let url = try await builder.build(content: content, title: "Volume 1", sourceNamespace: "LNori", sectioned: true)
        try Task.checkCancellation()
        var volume = openingVerificationVolume
        volume.acquisitionURL = url
        delivered = true
        return PreparedReaderContent(chapters: [volume], chaptersAreComplete: true,
            work: openingVerificationWork, installment: volume, temporaryPublicationURL: url)
    }
}
#endif



#endif

#if DEBUG
/// Runs staged release WASM with deterministic HTTP responses and isolated app state.
/// Generated by extensions/scripts/audit-extensions.mjs; absent from release builds.
@MainActor
enum ExtensionAuditFixture {
    static let publicSourceIDs: Set<String> = ["HitomiLA", "NHentai", "LNori", "MangaFox", "MangaFire", "MangaBat", "OmegaScans"]
    static var isLive: Bool { ProcessInfo.processInfo.environment["MANKO_PUBLIC_SOURCE_AUDIT"] != nil }
    static var isEnabled: Bool { isLive || ProcessInfo.processInfo.environment["MANKO_EXTENSION_AUDIT"] != nil }
    static func validateSelection(fixtureID: String?, publicID: String?) throws -> String {
        guard (fixtureID == nil) != (publicID == nil) else { throw SourceError.unsupportedResponse }
        if let publicID {
            guard publicSourceIDs.contains(publicID) else { throw SourceError.unsupportedResponse }
            return publicID
        }
        return fixtureID!
    }
    static var sources: [SourceID: any ContentSource] = [:]
    static var sessions: [URLSession] = []
    static var resetIDs: Set<String> = []
    static func defaults() -> UserDefaults {
        let value = UserDefaults(suiteName: "com.k800k.manko.extension-audit")!
        value.set(ProcessInfo.processInfo.environment["MANKO_FIXTURE_APPEARANCE"] ?? "light", forKey: "preferredAppearance")
        return value
    }
    static func contentCache(root: URL) -> ContentCache {
        ContentCache(directory: root.appending(path: "ContentCache"))
    }
    static func bootstrap(model: AppModel) async throws {
        let environment = ProcessInfo.processInfo.environment
        let id = try validateSelection(fixtureID: environment["MANKO_EXTENSION_AUDIT"], publicID: environment["MANKO_PUBLIC_SOURCE_AUDIT"])
        SourcePerformanceAudit.shared.install()
        let inputs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "ExtensionAudit/\(id)")
        let root = inputs.appending(path: isLive ? "PublicState" : "State")
        if ProcessInfo.processInfo.environment["MANKO_EXTENSION_AUDIT_RESET"] == "1", resetIDs.insert(id).inserted, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        let paths = StoragePaths(applicationSupportDirectory: root.appending(path: "Storage"), cachesDirectory: root.appending(path: "Caches"))
        try paths.prepare()
        let database = try MankoDatabase(databaseURL: paths.databaseURL)
        model.storagePaths = paths; model.database = database
        model.importer = LocalPublicationImporter(storagePaths: paths)
        model.localPublicationCoverService = LocalPublicationCoverService()
        model.libraryModel.database = database
        model.libraryModel.localPublicationCoverService = model.localPublicationCoverService
        model.searchModel.database = database; model.trackingModel.database = database
        model.settingsSyncModel.database = database; model.transfersModel.storagePaths = paths
        model.sourcesModel.contentCache = contentCache(root: root)
        let fixture = try JSONDecoder().decode(ExtensionAuditPayload.self, from: Data(contentsOf: inputs.appending(path: "fixture.json")))
        guard fixture.schemaVersion == 1, fixture.manifest.id == id,
              !isLive || (fixture.connection == nil && fixture.manifest.kind == "content") else { throw SourceError.unsupportedResponse }
        let downloadCoordinator = DownloadCoordinator(configuration: .init(offlineDownloadsDirectory: paths.offlineDownloadsDirectory, isPrivate: true),
            stateStore: FileDownloadStateStore(directory: root.appending(path: "DownloadQueue"), isPrivate: true),
            transport: ExtensionAuditDownloadTransport(allowedURLs: Set(fixture.downloads ?? []), publication: inputs.appending(path: "publication.epub"), directory: root.appending(path: "Publications")))
        model.downloadCoordinator = downloadCoordinator
        model.sourcesModel.downloadCoordinator = downloadCoordinator
        model.transfersModel.downloadCoordinator = downloadCoordinator
        try await downloadCoordinator.restore()
        let events = await downloadCoordinator.progress()
        model.downloadObservationTask = Task { [weak model] in
            for await event in events { await model?.receiveDownload(event, from: downloadCoordinator) }
        }
        let metadata = fixture.manifest
        // A fresh run namespace isolates persistent media as well as metadata caches.
        let runScope = environment["MANKO_PERFORMANCE_RUN"].map { ".\($0)" } ?? ""
        let sourceID = SourceID(rawValue: "extension-audit.\(id)\(runScope)")
        let kind = metadata.connectorKind.flatMap(SourceKind.init(rawValue:)) ?? .mankoExtension
        let descriptor = SourceDescriptor(id: sourceID, name: metadata.name, kind: kind,
            baseURL: fixture.connection.flatMap { URL(string: $0.baseURL) }, languageCodes: fixture.connection == nil ? ["en"] : [],
            capabilities: Set(metadata.capabilities.compactMap(SourceCapability.init(rawValue:))))
        let permissions = ExtensionPermissionSet(Set(metadata.permissions.compactMap(ExtensionPermission.init(rawValue:))))
        var installed = InstalledRepositorySource(repositoryID: "extension-audit", sourceID: id, descriptor: descriptor,
            entryType: .mankoExtension, kind: metadata.kind == "tracker" ? .tracker : .content,
            version: metadata.version, apiVersion: metadata.apiVersion, scriptSHA256: nil,
            capabilities: Set(metadata.capabilities.compactMap(RepositoryCapability.init(rawValue:))), allowedHTTPSHosts: metadata.allowedHTTPSHosts, permissions: permissions)
        installed.accountPolicy = metadata.accountPolicy
        installed.connectorKind = metadata.connectorKind.flatMap(SourceKind.init(rawValue:))
        let module = try Data(contentsOf: inputs.appending(path: "main.wasm"))
        installed.scriptSHA256 = SHA256.hash(data: module).map { String(format: "%02x", $0) }.joined()
        let entry = SourceRepositoryEntry(id: id, name: metadata.name, description: "Offline audit fixture", version: metadata.version,
            icon: "", languages: ["en"], maturityRating: .safe, capabilities: installed.capabilities, developers: [],
            rightsDeclaration: "Original audit fixtures", rightsURL: "", reportURL: "", entryType: .mankoExtension,
            kind: installed.kind, permissions: permissions,
            mankoExtension: .init(moduleURL: "main.wasm", sha256: installed.scriptSHA256!, size: module.count,
                allowedHTTPSHosts: installed.allowedHTTPSHosts, authenticationModes: installed.authenticationModes,
                connectorKind: installed.connectorKind, accountPolicy: installed.accountPolicy))
        let record = RepositoryRecord(manifest: .init(repository: .init(id: "extension-audit", name: "Offline audit",
            description: "", homepage: "", privacyURL: "", publisher: .init(name: "Manko Fixtures")), sources: [entry]),
            repositoryURL: URL(string: "https://fixture.example/")!, manifestURL: URL(string: "https://fixture.example/versioning.json")!)
        installed.accessGrant = try ExtensionAccessGrant(entry: entry, record: record)
        let client: HTTPClient
        if isLive {
            // Production transport enforces egress and carries no shared credentials.
            client = HTTPClient()
            PublicationImageCache.fixtureClient = nil
        } else {
            let token = UUID().uuidString
            var artworkIDs: [String: Int] = [:]
            let artwork = fixture.exchanges.filter { $0.asset == "image" && fixture.preserveRecordedImages != true }.reduce(into: [String: Data]()) { result, exchange in
                guard result[exchange.url] == nil else { return }
                let canonical = exchange.url.replacingOccurrences(of: "/avifsmallbigtn/", with: "/avifbigtn/")
                let page = artworkIDs[canonical] ?? (artworkIDs.count + 1)
                artworkIDs[canonical] = page
                result[exchange.url] = image(label: metadata.name, page: page,
                    scale: exchange.url.contains("/avifsmallbigtn/") ? 0.2 : 1)
            }
            ExtensionAuditURLProtocol.payloads.withLock { $0[token] = .init(exchanges: fixture.exchanges, artwork: artwork, fault: ProcessInfo.processInfo.environment["MANKO_EXTENSION_AUDIT_FAULT"] ?? "") }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ExtensionAuditURLProtocol.self]
            configuration.httpAdditionalHeaders = ["X-Manko-Audit": token]
            let session = URLSession(configuration: configuration); sessions.append(session)
            client = HTTPClient(testingSession: session, retryPolicy: .init(maximumAttempts: 1))
            PublicationImageCache.fixtureClient = client
        }
        PublicationImageCache.clearMemory()
        let state = try ExtensionStateStore(rootDirectory: paths.sourceExtensionStateDirectory)
        let secure = ExtensionSecureStateStore(service: "com.k800k.manko.extension-audit.\(id)", isPrivate: true)
        let connection = fixture.connection.map { SourceEndpointConfiguration(id: sourceID, name: metadata.name,
            kind: kind, baseURL: URL(string: $0.baseURL)!, languageCodes: [], options: $0.options) }
        let runtimeConfiguration = MankoExtensionRuntime.Configuration(namespace: "extension-audit.\(id)", entryID: id,
            apiVersion: metadata.apiVersion, kind: metadata.kind == "tracker" ? .tracker : .content, scriptURL: inputs.appending(path: "main.wasm"),
            allowedHTTPSHosts: Set(metadata.allowedHTTPSHosts), permissions: permissions,
            connectorKind: metadata.connectorKind.flatMap(SourceKind.init(rawValue:)), connection: connection, accountPolicy: metadata.accountPolicy)
        let factory: MankoExtensionSourceAdapter.RuntimeFactory = {
            MankoExtensionRuntime(configuration: runtimeConfiguration, httpClient: client, stateStore: state, secureStateStore: secure)
        }
        if metadata.kind == "tracker" {
            try await secure.setIndexed(try JSONEncoder().encode("audit-fixture-token"), namespace: "extension-audit.\(id)", key: "__native_oauth_access_token")
            let registry = ExtensionRuntimeRegistry(packageStore: try ExtensionPackageStore(rootDirectory: paths.sourceExtensionsDirectory), stateStore: state, secureStateStore: secure)
            let adapter = MankoExtensionTrackerAdapter(installedExtension: installed, runtimeFactory: factory)
            await registry.registerPreparedTracker(adapter, installedID: installed.id)
            model.extensionRuntimeRegistry = registry
            model.sourcesModel.extensionRuntimeRegistry = registry
            model.trackingModel.extensionRuntimeRegistry = registry
            let work = Work(id: WorkID(rawValue: UUID(uuidString: "EA000000-0000-0000-0000-000000000001")!),
                sourceID: .local, title: "Placeholder Title", kind: .manga)
            try await database.save(work: work, entry: LibraryEntry(workID: work.id), installments: [])
        } else if let connection {
            model.sourcesModel.sourceOptions[sourceID.rawValue] = connection.options.merging(["connectorExtensionID": id]) { _, fixture in fixture }
            sources[sourceID] = MankoConnectorSourceAdapter(configuration: connection, imageClient: client, runtimeFactory: factory)
        } else {
            sources[sourceID] = MankoExtensionSourceAdapter(installedSource: installed, runtimeFactory: factory)
        }
        model.sourcesModel.sources = metadata.kind == "tracker" ? [] : [descriptor]
        model.sourcesModel.installedRepositorySources = [installed]
        model.sourcesModel.sourceRepositories = [record]
        await model.libraryModel.refreshLibrary()
        try Data("ready".utf8).write(to: inputs.appending(path: "ready.txt"))
    }
    static func image(label: String, page: Int, scale: CGFloat = 1) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = scale
        return UIGraphicsImageRenderer(size: CGSize(width: 600, height: 900), format: format).pngData { context in
            let colors: [UIColor] = [UIColor(red: 0.78, green: 0.85, blue: 0.94, alpha: 1), UIColor(red: 0.83, green: 0.91, blue: 0.81, alpha: 1), UIColor(red: 0.96, green: 0.83, blue: 0.73, alpha: 1)]
            colors[abs(page % colors.count)].setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 900))
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            ("Placeholder Image" as NSString).draw(in: CGRect(x: 30, y: 380, width: 540, height: 80),
                withAttributes: [.font: UIFont.systemFont(ofSize: 40), .foregroundColor: UIColor.darkGray, .paragraphStyle: paragraph])
            ("Page \(page) · 600 × 900" as NSString).draw(in: CGRect(x: 30, y: 470, width: 540, height: 60),
                withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.darkGray, .paragraphStyle: paragraph])
        }
    }
}

nonisolated struct ExtensionAuditPayload: Decodable, Sendable {
    struct Manifest: Decodable, Sendable {
        let id, name, kind, version, apiVersion: String
        let connectorKind: String?
        let accountPolicy: ExtensionAccountPolicy?
        let allowedHTTPSHosts, capabilities, permissions: [String]
    }
    struct Connection: Decodable, Sendable { let baseURL: String; let options: [String: String] }
    struct Response: Decodable, Sendable { let status: Int; let headers: [String: String]; let mimeType: String?; let dataBase64: String }
    struct Exchange: Decodable, Sendable { let method, url: String; let bodyBase64, range, asset: String?; let response: Response }
    let schemaVersion: Int
    /// Developer-kit previews use their recorded placeholder PNGs; older audits use labelled placeholders.
    let preserveRecordedImages: Bool?
    let downloads: [String]?
    let manifest: Manifest
    let connection: Connection?
    let exchanges: [Exchange]
}

/// Exercises normal publication validation, installation and reading without a live server.
private actor ExtensionAuditDownloadTransport: DownloadTransport {
    let allowedURLs: Set<String>
    let publication: URL
    let directory: URL
    let stream: AsyncStream<DownloadTransportEvent>
    let continuation: AsyncStream<DownloadTransportEvent>.Continuation
    init(allowedURLs: Set<String>, publication: URL, directory: URL) {
        self.allowedURLs = allowedURLs; self.publication = publication; self.directory = directory
        (stream, continuation) = AsyncStream.makeStream()
    }
    func events() async -> AsyncStream<DownloadTransportEvent> { stream }
    func prepare() async -> Set<UUID> { [] }
    func start(_ transfer: DownloadTransfer, resumeData: Data?, wifiOnly: Bool) async throws {
        guard allowedURLs.contains(transfer.remoteURL.absoluteString) else { throw SourceError.unsupportedResponse }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = directory.appending(path: "\(transfer.id).epub")
        try FileManager.default.copyItem(at: publication, to: staged)
        continuation.yield(.finished(id: transfer.id, stagedFile: staged,
            response: .init(url: transfer.remoteURL, statusCode: 200, suggestedFilename: "observatory.epub", mimeType: "application/epub+zip")))
    }
    func pause(_ id: UUID) async -> Data? { nil }
    func cancel(_ id: UUID) async {}
    func setPriority(_ priority: Int, for id: UUID) async {}
    func setBackgroundEventsCompletionHandler(_ handler: (@MainActor @Sendable () -> Void)?) async {}
}

nonisolated final class ExtensionAuditURLProtocol: URLProtocol, @unchecked Sendable {
    struct Payload: Sendable {
        let exchanges: [ExtensionAuditPayload.Exchange]
        let artwork: [String: Data]
        var fault: String = ""
    }
    static let failedTokens = Mutex<Set<String>>([])
    static func failure(for exchange: ExtensionAuditPayload.Exchange, fault: String, token: String) -> (status: Int, body: Data)? {
        if exchange.asset == "image" {
            let fullCoverUnavailable = fault == "full-covers-unavailable" && exchange.url.contains("/avifbigtn/")
            return fault == "missing-images" || fullCoverUnavailable ? (404, Data()) : nil
        }
        let status: Int
        switch fault {
        case "retry":
            guard failedTokens.withLock({ $0.insert(token).inserted }) else { return nil }
            status = 503
        case "unavailable": status = 503
        case "expired": status = 401
        case "challenge": status = 403
        case "malformed": status = 200
        default: return nil
        }
        let body = fault == "challenge" ? "<html><title>Just a moment...</title><div id=\"cf-challenge-running\">Verify you are human</div></html>" : "Fixture response unavailable"
        return (status, Data(body.utf8))
    }
    static let payloads = Mutex<[String: Payload]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let token = request.value(forHTTPHeaderField: "X-Manko-Audit"),
              let payload = Self.payloads.withLock({ $0[token] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        guard let exchange = Self.exchange(for: request, in: payload),
              var bytes = payload.artwork[exchange.url] ?? Data(base64Encoded: exchange.response.dataBase64) else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "ExtensionAudit", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unrecorded fixture request: \(request.httpMethod ?? "GET") \(url.absoluteString)"])); return
        }
        let failure = Self.failure(for: exchange, fault: payload.fault, token: token)
        if let failure { bytes = failure.body }
        var headers = exchange.response.headers
        headers["Content-Type"] = exchange.asset == "image" ? "image/png" : exchange.response.mimeType ?? "text/html"
        headers["Content-Length"] = String(bytes.count)
        let response = HTTPURLResponse(url: url, statusCode: failure?.status ?? exchange.response.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    static func exchange(for request: URLRequest, in payload: Payload) -> ExtensionAuditPayload.Exchange? {
        let body = bodyData(for: request)?.base64EncodedString()
        return payload.exchanges.first { exchange in
            exchange.method == (request.httpMethod ?? "GET") && exchange.url == request.url?.absoluteString
                && exchange.bodyBase64 == body
                && exchange.range == request.value(forHTTPHeaderField: "Range")
        }
    }
    private static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0, data.count + count <= 2 * 1_024 * 1_024 else { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
    override func stopLoading() {}
}
#endif

#if DEBUG
/// Opt-in, process-local timing. Tool round trips never enter these durations.
@MainActor final class SourcePerformanceAudit: NSObject {
    static let shared = SourcePerformanceAudit()
    static var enabled: Bool { ProcessInfo.processInfo.environment["MANKO_PERFORMANCE_RUN"] != nil && ExtensionAuditFixture.isLive }
    private var link: CADisplayLink?
    private var flow: String?
    private var started: TimeInterval = 0
    private var stableFrames = 0
    private var counts: [String: Int] = [:]
    private var expectedCovers: Set<String> = []
    private var markers: [String: WeakView] = [:]
    private var contentKey = ""
    private var readySignal = false
    private var imagePage: Int?
    private final class WeakView { weak var view: UIView?; init(_ view: UIView) { self.view = view } }

    func install() {
        guard Self.enabled, link == nil else { return }
        let display = CADisplayLink(target: self, selector: #selector(tick(_:)))
        display.add(to: .main, forMode: .common); link = display
        NotificationCenter.default.addObserver(self, selector: #selector(receive(_:)), name: Notification.Name("MankoPerformance"), object: nil)
    }
    @objc private func receive(_ event: Notification) {
        if let page = event.userInfo?["nextPage"] as? Int { begin("next-page", key: "page-\(page)"); imagePage = page }
        if event.userInfo?["textPaint"] as? Bool == true { readySignal = true }
        if let view = event.object as? UIView, let page = event.userInfo?["page"] as? Int {
            markers["page-\(page)"] = WeakView(view)
        }
    }
    func begin(_ flow: String, key: String = "") {
        guard Self.enabled else { return }
        install(); self.flow = flow; started = ProcessInfo.processInfo.systemUptime
        stableFrames = 0; expectedCovers = []; contentKey = key; readySignal = false; imagePage = nil
    }
    func covers(_ keys: [String]) {
        guard flow == "catalog" else { return }
        expectedCovers = Set(keys.prefix(1)); contentKey = keys.prefix(1).joined(separator: "|")
    }
    func register(_ view: UIView, key: String) { guard Self.enabled else { return }; markers[key] = WeakView(view) }
    func details(_ key: String) { guard flow == "details" else { return }; contentKey = key; readySignal = true }
    private func visible(_ view: UIView?) -> Bool {
        guard let view, let window = view.window, view.bounds.width > 1, view.bounds.height > 1,
              view.convert(view.bounds, to: window).intersection(window.bounds).height > 10 else { return false }
        var parent: UIView? = view
        while let node = parent { if node.isHidden || node.alpha < 0.01 { return false }; parent = node.superview }
        return true
    }
    @objc private func tick(_ display: CADisplayLink) {
        guard let flow else { return }
        let ready: Bool
        switch flow {
        case "catalog": ready = expectedCovers.count == 1 && expectedCovers.allSatisfy { visible(markers[$0]?.view) }
        case "details": ready = readySignal && visible(markers["details"]?.view)
        case "reader", "next-page":
            if readySignal { ready = true }
            else { ready = visible(markers["page-\(imagePage ?? 0)"]?.view) }
        default: ready = false
        }
        stableFrames = ready ? stableFrames + 1 : 0
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        guard stableFrames >= 2 || elapsed > 45_000 else { return }
        counts[flow, default: 0] += 1
        Self.record(["surface": "app", "flow": flow, "sequence": counts[flow]!, "durationMs": elapsed,
            "status": ready ? "ready" : "timeout", "contentKey": contentKey,
            "frameIntervalMs": display.duration * 1_000,
            "viewport": ["width": displayViewport.width, "height": displayViewport.height]])
        self.flow = nil
    }
    private var displayViewport: CGSize {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.bounds.size ?? .zero
    }
    static func record(_ value: [String: Any]) {
        var result = value
        result["source"] = ProcessInfo.processInfo.environment["MANKO_PUBLIC_SOURCE_AUDIT"]
        result["run"] = ProcessInfo.processInfo.environment["MANKO_PERFORMANCE_RUN"]
        result["clock"] = "in-process-monotonic"
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "ExtensionAudit/performance.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let file = try? FileHandle(forWritingTo: url) {
            do { try file.seekToEnd(); try file.write(contentsOf: data + Data([10])); try file.close() }
            catch { print("Performance evidence write failed: \(error)") }
        }
        print("SourcePerformance \(String(decoding: data, as: UTF8.self))")
    }
}

private struct SourcePerformanceMarker: UIViewRepresentable {
    let key: String
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) { SourcePerformanceAudit.shared.register(view, key: key) }
}

/// A reference website on the same Simulator/WebKit/viewport as native Manko.
/// Configuration is staged locally alongside the audit inputs, never supplied by a website.
struct SourceWebsiteTimingView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = configuration.userContentController
        controller.add(context.coordinator, name: "performance")
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "ExtensionAudit")
        do {
            let data = try Data(contentsOf: root.appending(path: "website-timing.json"))
            let spec = try JSONDecoder().decode(Spec.self, from: data)
            guard let url = URL(string: spec.url), url.scheme == "https", let host = url.host,
                  ExtensionAuditFixture.publicSourceIDs.contains(spec.source),
                  spec.source == ProcessInfo.processInfo.environment["MANKO_PUBLIC_SOURCE_AUDIT"] else { throw SourceError.unsupportedResponse }
            let fixture = try JSONDecoder().decode(ExtensionAuditPayload.self, from: Data(contentsOf: root.appending(path: "\(spec.source)/fixture.json")))
            guard fixture.manifest.allowedHTTPSHosts.contains(host) else { throw SourceError.unsupportedResponse }
            context.coordinator.spec = spec
            context.coordinator.prerequisites = try (spec.primeURLs ?? []).map { value in
                guard let candidate = URL(string: value), candidate.scheme == "https",
                      let candidateHost = candidate.host, fixture.manifest.allowedHTTPSHosts.contains(candidateHost) else {
                    throw SourceError.unsupportedResponse
                }
                return candidate
            }
            let script = """
            (() => {
              let frames = 0, last = 0, interval = 16.67, done = false;
              const decoded = new WeakSet(), decoding = new WeakSet();
              function decodedImage(image) {
                if (!image || !image.complete || !image.naturalWidth) return false;
                if (decoded.has(image)) return true;
                if (!decoding.has(image)) {
                  decoding.add(image);
                  image.decode().then(() => decoded.add(image)).catch(() => decoding.delete(image));
                }
                return false;
              }
              function tick(now) {
                if (done) return;
                if (last) interval = now - last;
                last = now;
                let result = false;
                try { result = (() => { \(spec.predicate) })(); } catch (_) {}
                frames = result && interval <= 34 ? frames + 1 : 0;
                if (frames >= 2 || now > 45000) {
                  done = true;
                  window.webkit.messageHandlers.performance.postMessage({durationMs: now, status: frames >= 2 ? 'ready' : 'timeout', frameIntervalMs: interval, viewport: {width: innerWidth, height: innerHeight}});
                } else requestAnimationFrame(tick);
              }
              if (\(spec.flow == "next-page" ? "true" : "false")) {
                document.addEventListener('click', () => {
                  window.webkit.messageHandlers.performance.postMessage({action: 'begin'});
                }, true);
              }
              requestAnimationFrame(tick);
            })();
            """
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = context.coordinator
            context.coordinator.view = view
            context.coordinator.url = url
            view.scrollView.contentInsetAdjustmentBehavior = .never
            // Start the browser process before measuring a page navigation. The
            // empty document populates no source HTTP or media cache.
            view.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
            return view
        } catch {
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.loadHTMLString("<p>Timing configuration unavailable.</p>", baseURL: nil)
            print("Website timing configuration failed: \(error)")
            return view
        }
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.task?.cancel(); view.stopLoading(); view.configuration.userContentController.removeScriptMessageHandler(forName: "performance")
    }
    struct Spec: Decodable {
        let source, url, flow, contentKey, predicate: String
        let runs: Int?
        let primeURLs: [String]?
    }
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var spec: Spec?
        weak var view: WKWebView?
        var url: URL?
        var sequence = 0
        var prerequisites: [URL] = []
        var priming = true
        var started: TimeInterval = 0
        func start(_ view: WKWebView) {
            guard let url else { return }
            started = ProcessInfo.processInfo.systemUptime
            view.load(URLRequest(url: url))
        }
        var task: Task<Void, Never>?
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !priming, message.frameInfo.isMainFrame, var value = message.body as? [String: Any], let spec else { return }
            if value["action"] as? String == "begin" {
                started = ProcessInfo.processInfo.systemUptime
                return
            }
            value["documentDurationMs"] = value["durationMs"]
            value["durationMs"] = (ProcessInfo.processInfo.systemUptime - started) * 1_000
            value["contentViewport"] = value["viewport"]
            if let window = view?.window { value["viewport"] = ["width": window.bounds.width, "height": window.bounds.height] }
            sequence += 1; value["sequence"] = sequence; value["surface"] = "website"
            value["flow"] = spec.flow; value["contentKey"] = spec.contentKey
            value["cache"] = sequence == 1 ? "cold" : "warm"
            SourcePerformanceAudit.record(value)
            guard value["status"] as? String == "ready", sequence < min(max(spec.runs ?? 6, 1), 6) else { return }
            // Deliberate request pacing, not a readiness guess.
            task = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, let view else { return }
                start(view)
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard priming else { return }
            if !prerequisites.isEmpty { webView.load(URLRequest(url: prerequisites.removeFirst())) }
            else { priming = false; start(webView) }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            SourcePerformanceAudit.record(["surface": "website", "status": "navigation-failed", "error": error.localizedDescription])
        }
    }
}
#endif

import SwiftUI
extension View {
    @ViewBuilder func sourcePerformanceMarker(_ key: String) -> some View {
#if DEBUG
        if SourcePerformanceAudit.enabled { background(SourcePerformanceMarker(key: key)) } else { self }
#else
        self
#endif
    }
}

#if DEBUG
/// Opt-in local server verification using production services and an isolated database.
@MainActor
enum ServerLabFixture {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["MANKO_SERVER_LAB"] == "1" }
    static var inputs: URL { URL.documentsDirectory.appending(path: "ServerLab") }

    private static var cachedModel: AppModel?

    static func makeModel() -> AppModel {
        if let cachedModel { return cachedModel }
        let defaults = UserDefaults(suiteName: "manko.server-lab")!
        let root = inputs.appending(path: "State")
        if ProcessInfo.processInfo.environment["MANKO_SERVER_LAB_RESET"] == "1" {
            defaults.removePersistentDomain(forName: "manko.server-lab")
            try? FileManager.default.removeItem(at: root)
        }
        let paths = StoragePaths(applicationSupportDirectory: root.appending(path: "Storage"), cachesDirectory: root.appending(path: "Caches"))
        let model = AppModel(defaults: defaults, isPrivate: true, serviceProvider: SharedAppServices(storagePaths: paths, isPrivate: true))
        cachedModel = model
        return model
    }

    private struct Manifest: Decodable {
        let id: String, name: String, version: String, apiVersion: String, connectorKind: String
        let capabilities: [String], permissions: [String], authenticationModes: [String]
    }

    static func prepare(services: AppServiceBundle) async throws {
        let packages = try ExtensionPackageStore(rootDirectory: services.storagePaths.sourceExtensionsDirectory, isPrivate: true)
        var entries: [SourceRepositoryEntry] = []
        var modules: [(InstalledRepositorySource, Data)] = []
        for id in ["Komga", "Kavita", "Suwayomi", "OPDS"] {
            let folder = inputs.appending(path: id)
            let metadata = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: folder.appending(path: "extension.json")))
            guard metadata.id == id, let connector = SourceKind(rawValue: metadata.connectorKind) else { throw SourceError.unsupportedResponse }
            let module = try Data(contentsOf: folder.appending(path: "main.wasm"))
            let hash = SHA256.hash(data: module).map { String(format: "%02x", $0) }.joined()
            let permissions = ExtensionPermissionSet(Set(metadata.permissions.compactMap(ExtensionPermission.init(rawValue:))))
            var installed = InstalledRepositorySource(repositoryID: "server-lab", sourceID: id,
                descriptor: SourceDescriptor(id: SourceID(rawValue: "server-lab." + id), name: metadata.name, kind: .mankoExtension,
                    capabilities: Set(metadata.capabilities.compactMap(SourceCapability.init(rawValue:)))),
                entryType: .mankoExtension, kind: .content, version: metadata.version, apiVersion: metadata.apiVersion, scriptSHA256: hash,
                capabilities: Set(metadata.capabilities.compactMap(RepositoryCapability.init(rawValue:))), allowedHTTPSHosts: [],
                authenticationModes: Set(metadata.authenticationModes.compactMap(ExtensionAuthenticationMode.init(rawValue:))), permissions: permissions)
            installed.connectorKind = connector
            let entry = SourceRepositoryEntry(id: id, name: metadata.name, description: "Local native server verification", version: metadata.version,
                icon: "", languages: ["en"], maturityRating: .safe, capabilities: installed.capabilities, developers: [],
                rightsDeclaration: "Original server-lab samples", rightsURL: "", reportURL: "", entryType: .mankoExtension,
                kind: .content, permissions: permissions,
                mankoExtension: .init(moduleURL: "main.wasm", sha256: hash, size: module.count, allowedHTTPSHosts: [],
                    authenticationModes: installed.authenticationModes, connectorKind: connector))
            entries.append(entry); modules.append((installed, module))
        }
        let record = RepositoryRecord(manifest: .init(repository: .init(id: "server-lab", name: "Server Lab",
            description: "Local server verification", homepage: "", privacyURL: "", publisher: .init(name: "Manko")), sources: entries),
            repositoryURL: URL(string: "https://server-lab.invalid/")!, manifestURL: URL(string: "https://server-lab.invalid/versioning.json")!)
        try await services.repositoryStore.upsert(record)
        for (index, pair) in modules.enumerated() {
            var (installed, module) = pair
            installed.accessGrant = try ExtensionAccessGrant(entry: entries[index], record: record)
            let staged = try await packages.stage(script: module, repositoryID: record.id, sourceID: installed.sourceID,
                version: installed.version, expectedSHA256: installed.scriptSHA256!, expectedSize: module.count)
            let runtime = try await services.extensionRuntimeRegistry.makeStagedRuntime(for: installed, scriptURL: staged.url)
            try await runtime.initialize()
            runtime.invalidate()
            let receipt = try await packages.activate(staged)
            try await services.repositoryStore.install(installed, reviewedRepository: record)
            try await packages.commit(receipt)
        }
    }
}
#endif
