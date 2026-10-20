import CryptoKit
import Foundation
import MangoReaderDomain
import MangoReaderSources
import OSLog

private struct DiscoverPaginationKey: Hashable, Sendable {
    let sectionID: String
    let query: SourceQuery

    init(sectionID: String, query: SourceQuery) {
        self.sectionID = sectionID
        var normalizedQuery = query
        normalizedQuery.page = 1
        normalizedQuery.cursor = nil
        self.query = normalizedQuery
    }
}

public struct MangoReaderExtensionContentContext: Sendable {
    public var work: Work
    public var installments: [Installment]
    public var selectedInstallment: Installment
    public var didRefresh: Bool

    public init(
        work: Work,
        installments: [Installment],
        selectedInstallment: Installment,
        didRefresh: Bool
    ) {
        self.work = work
        self.installments = installments
        self.selectedInstallment = selectedInstallment
        self.didRefresh = didRefresh
    }
}

public actor MangoReaderExtensionSourceAdapter: ContentSource, SourceDiscoverSectionProviding, SourceSearchFormProviding, SourceSearchConfigurationProviding, SourceUpdateProcessing, SourceManagedCollectionProviding {
    public typealias RuntimeFactory = @MainActor @Sendable () throws -> MangoReaderExtensionRuntime

    private static let resourceLogger = Logger(
        subsystem: "com.k800k.manko",
        category: "ExtensionResourcePolicy"
    )
    private static let performanceLog = OSLog(
        subsystem: "com.k800k.manko",
        category: "ExtensionPerformance"
    )

    public let installedSource: InstalledRepositorySource
    private let sourceDescriptor: SourceDescriptor
    private let runtimeFactory: RuntimeFactory
    private var runtime: MangoReaderExtensionRuntime?
    private var runtimeInitialization: Task<MangoReaderExtensionRuntime, Error>?
    private var runtimeInitializationID: UUID?
    private var searchMetadata: [String: [Int: JSONValue]] = [:]
    private var discoverMetadata: [DiscoverPaginationKey: [Int: JSONValue]] = [:]
    private var searchConfigurationCache: SourceSearchConfiguration?
    private var didLoadSearchConfiguration = false
    private var searchConfigurationLoadedAt = Date.distantPast
    private var resolvedSearchValues: [String: Date] = [:]
    private var discoverSectionCache: [MangoReaderDiscoverSection]?
    private var workCache: [String: MangoReaderSourceWork] = [:]
    private var domainWorkCache: [WorkID: Work] = [:]
    private var workRemoteIDs: [WorkID: String] = [:]
    private struct ChapterKey: Hashable { let workID: WorkID; let remoteID: String }
    private var installmentCache: [ChapterKey: MangoReaderInstallment] = [:]
    private var domainInstallmentCache: [WorkID: [Installment]] = [:]
    private var imagePageListCache: [ChapterKey: MangoReaderImagePageList] = [:]

    public init(installedSource: InstalledRepositorySource, runtimeFactory: @escaping RuntimeFactory) {
        self.installedSource = installedSource
        sourceDescriptor = installedSource.descriptor
        self.runtimeFactory = runtimeFactory
    }

    public var descriptor: SourceDescriptor { sourceDescriptor }

    public func browse(_ query: SourceQuery) async throws -> SourcePage<Work> {
        try await browse(query, onProgress: nil)
    }

    public func browse(_ query: SourceQuery, onProgress: (@Sendable ([Work]) async -> Void)?) async throws -> SourcePage<Work> {
        try await validateFilters(query)
        let runtime = try await activeRuntime()
        let sections: [MangoReaderDiscoverSection]
        if let discoverSectionCache {
            sections = discoverSectionCache
        } else {
            sections = try await runtime.discoverSections()
            discoverSectionCache = sections
        }
        guard let section = sections.first else { return SourcePage(items: []) }
        let paginationKey = DiscoverPaginationKey(sectionID: section.id, query: query)
        let metadata = cursorValue(query.cursor) ?? (query.page == 1 ? nil : discoverMetadata[paginationKey]?[query.page])
        guard query.page == 1 || query.cursor != nil || metadata != nil else { return SourcePage(items: []) }
        let page = try await runtime.discover(
            section: section,
            selections: query.searchSelections,
            filters: query.filters,
            sortID: query.sortID,
            metadata: metadata,
            onProgress: onProgress.map { callback -> @Sendable ([MangoReaderDiscoverItem]) async -> Void in
                { [self] items in
                    await deliverDiscoverProgress(items, query: query, to: callback)
                }
            }
        )
        if let nextMetadata = page.metadata, nextMetadata != .null {
            discoverMetadata[paginationKey, default: [:]][query.page + 1] = nextMetadata
        }
        let works = page.items.compactMap { item -> Work? in
            guard let remoteID = item.workId,
                  let title = item.title,
                  let image = item.imageUrl
            else { return nil }
            return makeWork(
                remoteID: remoteID,
                title: title,
                subtitle: item.subtitle,
                imageURL: image,
                previewImageURL: item.previewImageUrl
            )
        }
        return filteredPage(works, query: query, nextMetadata: page.metadata)
    }

    public func search(_ query: SourceQuery) async throws -> SourcePage<Work> {
        try await search(query, onProgress: nil)
    }

    public func search(_ query: SourceQuery, onProgress: (@Sendable ([Work]) async -> Void)?) async throws -> SourcePage<Work> {
        try await validateFilters(query)
        if query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           query.searchSelections.isEmpty,
           query.sortID == nil {
            return try await browse(query, onProgress: onProgress)
        }
        let runtime = try await activeRuntime()
        let key = searchIdentity(for: query)
        let metadata = cursorValue(query.cursor) ?? (query.page == 1 ? nil : searchMetadata[key]?[query.page])
        guard query.page == 1 || query.cursor != nil || metadata != nil else { return SourcePage(items: []) }
        let page = try await runtime.search(
            title: query.text,
            selections: query.searchSelections,
            filters: query.filters,
            sortID: query.sortID,
            metadata: metadata,
            onProgress: onProgress.map { callback -> @Sendable ([MangoReaderSearchItem]) async -> Void in
                { [self] items in
                    await deliverSearchProgress(items, query: query, to: callback)
                }
            }
        )
        if let nextMetadata = page.metadata, nextMetadata != .null {
            searchMetadata[key, default: [:]][query.page + 1] = nextMetadata
        }
        let works = page.items.map {
            makeWork(
                remoteID: $0.workId,
                title: $0.title,
                subtitle: $0.subtitle,
                imageURL: $0.imageUrl,
                previewImageURL: $0.previewImageUrl,
                kind: Self.kind($0.mediaKind)
            )
        }
        return filteredPage(works, query: query, nextMetadata: page.metadata)
    }

    public func discoverSections() async throws -> [SourceDiscoverSection] {
        let runtime = try await activeRuntime()
        let sections = try await runtime.discoverSections()
        discoverSectionCache = sections
        return sections.map { section in
            SourceDiscoverSection(
                id: section.id,
                title: section.title,
                subtitle: section.subtitle,
                presentation: section.presentation
                    ?? (section.type == 3 ? .latestGallery : .automatic)
            )
        }
    }

    public func discover(sectionID: String, query: SourceQuery) async throws -> SourcePage<Work> {
        try await discover(sectionID: sectionID, query: query, onProgress: nil)
    }

    public func discover(sectionID: String, query: SourceQuery, onProgress: (@Sendable ([Work]) async -> Void)?) async throws -> SourcePage<Work> {
        try await validateFilters(query)
        let runtime = try await activeRuntime()
        let sections: [MangoReaderDiscoverSection]
        if let discoverSectionCache {
            sections = discoverSectionCache
        } else {
            sections = try await runtime.discoverSections()
        }
        discoverSectionCache = sections
        guard let section = sections.first(where: { $0.id == sectionID }) else { throw SourceError.notFound }
        let paginationKey = DiscoverPaginationKey(sectionID: section.id, query: query)
        let metadata = cursorValue(query.cursor) ?? (query.page == 1 ? nil : discoverMetadata[paginationKey]?[query.page])
        let page = try await runtime.discover(
            section: section,
            selections: query.searchSelections,
            filters: query.filters,
            sortID: query.sortID,
            metadata: metadata,
            onProgress: onProgress.map { callback -> @Sendable ([MangoReaderDiscoverItem]) async -> Void in
                { [self] items in
                    await deliverDiscoverProgress(items, query: query, to: callback)
                }
            }
        )
        if let next = page.metadata, next != .null {
            discoverMetadata[paginationKey, default: [:]][query.page + 1] = next
        }
        let works = page.items.compactMap { item -> Work? in
            guard let remoteID = item.workId, let title = item.title, let image = item.imageUrl else { return nil }
            return makeWork(
                remoteID: remoteID,
                title: title,
                subtitle: item.subtitle,
                imageURL: image,
                previewImageURL: item.previewImageUrl
            )
        }
        return filteredPage(works, query: query, nextMetadata: page.metadata)
    }

    private func deliverDiscoverProgress(
        _ items: [MangoReaderDiscoverItem], query: SourceQuery,
        to callback: @Sendable ([Work]) async -> Void
    ) async {
        guard !Task.isCancelled else { return }
        let works = items.compactMap { item -> Work? in
            guard let id = item.workId, let title = item.title, let image = item.imageUrl else { return nil }
            return makeWork(remoteID: id, title: title, subtitle: item.subtitle,
                            imageURL: image, previewImageURL: item.previewImageUrl)
        }
        await callback(filteredPage(works, query: query, nextMetadata: nil).items)
    }

    private func deliverSearchProgress(
        _ items: [MangoReaderSearchItem], query: SourceQuery,
        to callback: @Sendable ([Work]) async -> Void
    ) async {
        guard !Task.isCancelled else { return }
        let works = items.map {
            makeWork(remoteID: $0.workId, title: $0.title, subtitle: $0.subtitle,
                     imageURL: $0.imageUrl, previewImageURL: $0.previewImageUrl, kind: Self.kind($0.mediaKind))
        }
        await callback(filteredPage(works, query: query, nextMetadata: nil).items)
    }

    private func validateFilters(_ query: SourceQuery) async throws {
        guard !query.searchSelections.isEmpty || query.sortID != nil else { return }
        guard let configuration = try await searchConfiguration() else {
            throw SourceSearchValidationError("This source does not provide these filters.")
        }
        try configuration.validate(selections: query.searchSelections, sortID: query.sortID, query: query.text)
        for selection in query.searchSelections {
            // New lookup metadata opts into canonical-value validation. Older
            // packages may have empty option lists without implementing lookup.
            guard configuration.fields.first(where: { $0.id == selection.fieldID })?.inputKind == .lookup else { continue }
            let key = "\(selection.fieldID)\u{0}\(selection.value)"
            if let resolved = resolvedSearchValues[key], Date().timeIntervalSince(resolved) < 300 { continue }
            let candidates = try await searchSuggestions(for: .init(fieldID: selection.fieldID, query: selection.title, limit: 30))
            guard candidates.contains(where: { $0.fieldID == selection.fieldID && $0.value == selection.value }) else {
                throw SourceSearchValidationError("Choose a matching tag for \(selection.title) in Filters. The saved value is no longer available.")
            }
        }
    }

    public func searchForm() async throws -> ExtensionFormSchema? {
        let runtime = try await activeRuntime()
        let value = try await runtime.searchFilters()
        guard value != .null, case .object = value else { return nil }
        return try? decode(ExtensionFormSchema.self, from: value)
    }

    public func searchConfiguration() async throws -> SourceSearchConfiguration? {
        if didLoadSearchConfiguration, Date().timeIntervalSince(searchConfigurationLoadedAt) < 300 { return searchConfigurationCache }
        let runtime = try await activeRuntime()
        let value = try await runtime.searchFilters()
        guard value != .null, case .object = value else { return nil }
        let configuration = try Self.validatedSearchConfiguration(decode(SourceSearchConfiguration.self, from: value))
        searchConfigurationCache = configuration
        didLoadSearchConfiguration = true
        searchConfigurationLoadedAt = Date()
        return configuration
    }

    public func searchSuggestions(
        for request: SourceSearchSuggestionRequest
    ) async throws -> [SourceSearchSuggestion] {
        let bounded = SourceSearchSuggestionRequest(
            fieldID: request.fieldID.map { String($0.prefix(64)) },
            query: String(request.query.prefix(256)),
            selections: Array(request.selections.prefix(24)),
            limit: request.limit
        )
        let runtime = try await activeRuntime()
        let value = try await runtime.searchSuggestions(bounded)
        guard case .array = value else {
            throw SourceSearchValidationError("The source returned invalid suggestions. Try again.")
        }
        let suggestions = try decode([SourceSearchSuggestion].self, from: value)
        let validated = suggestions
            .filter {
                !$0.fieldID.isEmpty && $0.fieldID.count <= 64
                    && !$0.value.isEmpty && $0.value.count <= 256
                    && !$0.title.isEmpty && $0.title.count <= 256
                    && ($0.subtitle?.count ?? 0) <= 256
            }
            .uniqued(on: \SourceSearchSuggestion.id)
            .prefix(bounded.limit)
            .map { $0 }
        let now = Date()
        resolvedSearchValues = resolvedSearchValues.filter { now.timeIntervalSince($0.value) < 300 }
        for suggestion in validated {
            resolvedSearchValues["\(suggestion.fieldID)\u{0}\(suggestion.value)"] = now
        }
        if resolvedSearchValues.count > 500 {
            resolvedSearchValues = Dictionary(uniqueKeysWithValues: resolvedSearchValues.sorted { $0.value > $1.value }.prefix(500).map { ($0.key, $0.value) })
        }
        return validated
    }

    public func updates(since: Date?, cursor: SourceCursor?) async throws -> SourcePage<SourceUpdate> {
        let runtime = try await activeRuntime()
        let value = try await runtime.updates(since: since?.ISO8601Format(), cursor: cursorValue(cursor))
        return try decode(SourcePage<SourceUpdate>.self, from: value)
    }

    public func managedCollections(cursor: SourceCursor?) async throws -> SourcePage<ManagedSourceCollection> {
        let runtime = try await activeRuntime()
        let value = try await runtime.managedCollections(cursor: cursorValue(cursor))
        return try decode(SourcePage<ManagedSourceCollection>.self, from: value)
    }

    public func synchronizeManagedCollection(_ collection: ManagedSourceCollection) async throws {
        let runtime = try await activeRuntime()
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(collection))
        try await runtime.synchronizeManagedCollection(value)
    }

    public func details(for remoteID: String) async throws -> Work {
        let runtime = try await activeRuntime()
        let sourceWork = try await runtime.details(workID: remoteID)
        guard sourceWork.workId == remoteID else { throw SourceError.unsupportedResponse }
        workCache[remoteID] = sourceWork
        let info = sourceWork.workInfo
        let facets = Self.validatedFacets(info.searchFacets ?? [])
        let facetAuthors = facets
            .filter { $0.presentation == .creator }
            .map(\.title)
            .uniqued()
        let legacyAuthors = [info.author, info.artist]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let authors = facetAuthors.isEmpty ? legacyAuthors : facetAuthors
        let tags = facets
            .filter { $0.presentation == .tag }
            .map(\.title)
            .uniqued()
        let work = Work(
            id: StableMangoReaderIdentifier.workID(sourceID: sourceDescriptor.id, remoteID: sourceWork.workId),
            sourceID: sourceDescriptor.id,
            remoteID: sourceWork.workId,
            title: info.primaryTitle,
            readingMode: info.readingMode.flatMap { ["rtl", "ltr", "verticalPaged", "webtoon", "continuous"].contains($0) ? $0 : ($0 == "vertical" ? "verticalPaged" : nil) },
            alternativeTitles: info.secondaryTitles,
            authors: authors.uniqued(),
            summary: info.synopsis,
            tags: tags,
            searchFacets: facets,
            languageCode: sourceDescriptor.languageCodes.first,
            kind: Self.kind(info.mediaKind),
            status: Self.status(info.status),
            coverURL: approvedURL(info.thumbnailUrl),
            shareURL: info.shareUrl.flatMap(approvedURL)
        )
        domainWorkCache[work.id] = work
        workRemoteIDs[work.id] = sourceWork.workId
        return work
    }

    public func installments(for work: Work, page: Int) async throws -> SourcePage<Installment> {
        guard page == 1, let remoteID = work.remoteID else { return SourcePage(items: []) }
        workRemoteIDs[work.id] = remoteID
        let runtime = try await activeRuntime()
        let sourceWork: MangoReaderSourceWork
        if !SourceCachePolicy.reload, let cached = workCache[remoteID] { sourceWork = cached }
        else {
            sourceWork = try await runtime.details(workID: remoteID)
        }
        guard sourceWork.workId == remoteID else { throw SourceError.unsupportedResponse }
        workCache[remoteID] = sourceWork
        guard work.sourceID == sourceDescriptor.id else { throw SourceError.unsupportedResponse }
        let remoteInstallments = try await runtime.installments(sourceWork: sourceWork)
        guard !remoteInstallments.contains(where: { $0.installmentId.isEmpty }),
              Set(remoteInstallments.map(\.installmentId)).count == remoteInstallments.count,
              remoteInstallments.allSatisfy({ $0.workId == nil || $0.workId == remoteID }) else { throw SourceError.unsupportedResponse }
        if SourceCachePolicy.reload {
            installmentCache = installmentCache.filter { $0.key.workID != work.id }
            imagePageListCache = imagePageListCache.filter { $0.key.workID != work.id }
        }
        let installments = remoteInstallments.map { extensionInstallment -> Installment in
            installmentCache[ChapterKey(workID: work.id, remoteID: extensionInstallment.installmentId)] = extensionInstallment
            return Installment(
                id: ExtensionChapterIdentity.id(sourceID: sourceDescriptor.id, workID: work.id, remoteID: extensionInstallment.installmentId),
                workID: work.id,
                remoteID: extensionInstallment.installmentId,
                title: extensionInstallment.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                    ?? "Chapter \(extensionInstallment.number.formatted())",
                scanlators: extensionInstallment.scanlators,
                volume: extensionInstallment.volume,
                number: extensionInstallment.number,
                publishedAt: Self.date(extensionInstallment.publishDate),
                languageCode: extensionInstallment.langCode,
                format: extensionInstallment.format == "xhtml" ? .epub : .remoteImageSequence
            )
        }
        domainWorkCache[work.id] = work
        domainInstallmentCache[work.id] = installments
        return SourcePage(items: installments, totalCount: installments.count)
    }

    /// Rebuilds the transient extension objects required to open a chapter that
    /// was restored from durable library storage after the app relaunched.
    public func rehydrate(
        work: Work,
        installment: Installment
    ) async throws -> MangoReaderExtensionContentContext {
        guard work.sourceID == sourceDescriptor.id,
              installment.workID == work.id,
              let remoteWorkID = work.remoteID,
              let remoteInstallmentID = installment.remoteID
        else { throw SourceError.notFound }

        if !SourceCachePolicy.reload, let cachedWork = domainWorkCache[work.id],
           let cachedInstallments = domainInstallmentCache[work.id],
           let selected = cachedInstallments.first(where: { $0.remoteID == remoteInstallmentID }),
           workCache[remoteWorkID] != nil,
           installmentCache[ChapterKey(workID: work.id, remoteID: remoteInstallmentID)] != nil
        {
            return MangoReaderExtensionContentContext(
                work: cachedWork,
                installments: cachedInstallments,
                selectedInstallment: selected,
                didRefresh: false
            )
        }

        var refreshedWork = try await details(for: remoteWorkID)
        // Source migrations may preserve a library-owned WorkID. Keep that
        // identity while repopulating the extension's remote lookup tables.
        refreshedWork.id = work.id
        workRemoteIDs[work.id] = remoteWorkID
        domainWorkCache[work.id] = refreshedWork

        let page = try await installments(for: refreshedWork, page: 1)
        guard let selected = page.items.first(where: { $0.remoteID == remoteInstallmentID }) else {
            throw SourceError.notFound
        }
        return MangoReaderExtensionContentContext(
            work: refreshedWork,
            installments: page.items,
            selectedInstallment: selected,
            didRefresh: true
        )
    }

    public func acquisitionURL(for installment: Installment) async throws -> URL {
        let content = try await publicationContent(for: installment)
        return try await MangoReaderExtensionEPUBBuilder().build(
            content: content,
            title: installment.title,
            sourceNamespace: installedSource.id,
            sectioned: installedSource.sourceID == "LNori"
        )
    }

    /// Fetching is separate from packaging so the app can cache the source text
    /// before rebuilding disposable EPUBs, without changing the extension API.
    public func streamPublication(work: Work, installment: Installment,
        onChunk: @escaping @Sendable (HTTPResponse, Data) async throws -> Void) async throws {
        guard installedSource.sourceID == "LNori", installment.workID == work.id,
              let bookID = installment.remoteID, let workID = work.remoteID else { throw SourceError.unsupportedResponse }
        let runtime = try await activeRuntime()
        let descriptor = try await runtime.publicationStream(bookID: bookID, workID: workID)
        guard descriptor.id == bookID, descriptor.workId == workID else { throw SourceError.unsupportedResponse }
        try await runtime.streamPublication(descriptor, onChunk: onChunk)
    }

    public func publicationContent(for installment: Installment) async throws -> MangoReaderPublicationContent {
        guard installment.format == .epub,
              let chapterID = installment.remoteID,
              let extensionInstallment = installmentCache[ChapterKey(workID: installment.workID, remoteID: chapterID)],
              let sourceWork = sourceWork(for: installment)
        else { throw SourceError.unsupportedResponse }
        let runtime = try await activeRuntime()
        guard extensionInstallment.workId == nil || extensionInstallment.workId == sourceWork.workId else { throw SourceError.unsupportedResponse }
        let content = try await runtime.publicationContent(extensionInstallment: extensionInstallment, sourceWork: sourceWork)
        guard content.workId == sourceWork.workId else { throw SourceError.unsupportedResponse }
        return content
    }

    public func imagePages(
        for installment: Installment,
        query: RemoteImagePageQuery
    ) async throws -> SourcePage<RemoteImagePageDescriptor> {
        guard let chapterID = installment.remoteID,
              let extensionInstallment = installmentCache[ChapterKey(workID: installment.workID, remoteID: chapterID)]
        else { throw SourceError.notFound }
        let runtime = try await activeRuntime()
        let details: MangoReaderImagePageList
        if !SourceCachePolicy.reload, let cached = imagePageListCache[ChapterKey(workID: installment.workID, remoteID: chapterID)] { details = cached }
        else {
            guard let sourceWork = sourceWork(for: installment) else { throw SourceError.notFound }
            guard extensionInstallment.workId == nil || extensionInstallment.workId == sourceWork.workId else { throw SourceError.unsupportedResponse }
            details = try await runtime.imagePages(extensionInstallment: extensionInstallment, sourceWork: sourceWork)
            guard details.workId == sourceWork.workId, details.id == chapterID,
                  !details.pages.isEmpty, details.pages.allSatisfy({ approvedURL($0) != nil }) else {
                #if DEBUG
                Self.cacheOwnershipLogger.debug("Chapter ownership or page validation rejected")
                #endif
                throw SourceError.unsupportedResponse
            }
            imagePageListCache[ChapterKey(workID: installment.workID, remoteID: chapterID)] = details
        }

        let start = (query.page - 1) * query.pageSize
        guard start < details.pages.count else {
            return SourcePage(items: [], totalCount: details.pages.count)
        }
        let end = min(details.pages.count, start + query.pageSize)
        let pages = try details.pages[start ..< end].enumerated().map { offset, rawURL in
            guard let url = approvedURL(rawURL) else { throw SourceError.unsafeResourceURL }
            let index = start + offset
            return RemoteImagePageDescriptor(
                id: ContentCache.key([sourceDescriptor.id.rawValue, installment.workID.description, installment.id.description, String(index)]),
                sourceID: sourceDescriptor.id,
                installmentID: installment.id,
                index: index,
                resourceURL: url
            )
        }
        return SourcePage(
            items: pages,
            nextPage: end < details.pages.count ? query.page + 1 : nil,
            totalCount: details.pages.count
        )
    }

    public func imagePageContent(for page: RemoteImagePageDescriptor) async throws -> RemoteImagePageContent {
        try await imagePageContent(for: page, priority: .prefetch)
    }

    public func imagePageContent(for page: RemoteImagePageDescriptor, priority: RemoteImageRequestPriority) async throws -> RemoteImagePageContent {
        guard page.sourceID == sourceDescriptor.id,
              let approvedURL = approvedURL(page.resourceURL.absoluteString)
        else { throw SourceError.unsafeResourceURL }
        return try await brokeredImageContent(at: approvedURL, requiresImageMIMEType: false, priority: priority)
    }

    public func setImagePagePriority(for page: RemoteImagePageDescriptor, priority: RemoteImageRequestPriority) async {
        await runtime?.setImagePriority(at: page.resourceURL, priority: priority)
    }

    public func streamImagePageContent(for page: RemoteImagePageDescriptor, priority: RemoteImageRequestPriority,
        onPartial: @escaping RemoteImagePageProgress) async throws -> RemoteImagePageContent {
        guard page.sourceID == sourceDescriptor.id, let url = approvedURL(page.resourceURL.absoluteString) else {
            throw SourceError.unsafeResourceURL
        }
        let runtime = try await activeRuntime()
        return try await runtime.imagePageData(at: url, priority: priority, onPartial: onPartial)
    }

    public func streamImagePageContent(for page: RemoteImagePageDescriptor, priority: RemoteImageRequestPriority,
        onPartial: @escaping RemoteImagePageProgress,
        onProgress: @escaping RemoteImageDownloadProgressHandler) async throws -> RemoteImagePageContent {
        guard page.sourceID == sourceDescriptor.id, let url = approvedURL(page.resourceURL.absoluteString) else {
            throw SourceError.unsafeResourceURL
        }
        let runtime = try await activeRuntime()
        return try await runtime.imagePageData(at: url, priority: priority, onProgress: onProgress, onPartial: onPartial)
    }

    public func invalidateContentCache() async throws {
        workCache.removeAll()
        domainWorkCache.removeAll()
        domainInstallmentCache.removeAll()
        installmentCache.removeAll()
        imagePageListCache.removeAll()
        let runtime = try await activeRuntime()
        try await runtime.invalidateContentCache()
    }

    /// Loads a source-owned cover through the extension broker so request
    /// interceptors, cookies, and reviewed referrer headers are retained.
    public func coverImageContent(at url: URL) async throws -> RemoteImagePageContent {
        guard let approvedURL = approvedURL(url.absoluteString) else { throw SourceError.unsafeResourceURL }
        let signpostID = OSSignpostID(log: Self.performanceLog)
        os_signpost(.begin, log: Self.performanceLog, name: "Cover Request", signpostID: signpostID)
        do {
            let content = try await brokeredImageContent(at: approvedURL, requiresImageMIMEType: true)
            os_signpost(
                .end,
                log: Self.performanceLog,
                name: "Cover Request",
                signpostID: signpostID,
                "success"
            )
            return content
        } catch {
            if error is CancellationError {
                os_signpost(
                    .end,
                    log: Self.performanceLog,
                    name: "Cover Request",
                    signpostID: signpostID,
                    "cancel"
                )
            } else {
                os_signpost(
                    .end,
                    log: Self.performanceLog,
                    name: "Cover Request",
                    signpostID: signpostID,
                    "failure"
                )
            }
            throw error
        }
    }

    private static let cacheOwnershipLogger = Logger(subsystem: "com.k800k.manko", category: "ChapterOwnership")

    private func brokeredImageContent(
        at url: URL,
        requiresImageMIMEType: Bool,
        priority: RemoteImageRequestPriority = .cover
    ) async throws -> RemoteImagePageContent {
        let runtime = try await activeRuntime()
        let resource: RemoteImagePageContent
        do { resource = try await runtime.imagePageData(at: url, priority: priority) }
        catch MangoReaderExtensionRuntimeError.operationFailed("Invalid image data.") { throw SourceError.unsupportedResponse }
        let data = resource.data
        guard data.count <= 16 * 1_024 * 1_024 else {
            throw SourceError.resourceLimitExceeded("image response exceeds 16 MiB")
        }
        if requiresImageMIMEType {
            let mediaType = resource.mediaType?
                .split(separator: ";", maxSplits: 1)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard mediaType?.hasPrefix("image/") == true || mediaType == "application/octet-stream" else {
                throw SourceError.unsupportedResponse
            }
        }
        return RemoteImagePageContent(data: data, mediaType: resource.mediaType)
    }

    public func resetRuntime() async {
        runtimeInitialization?.cancel()
        runtimeInitialization = nil
        runtimeInitializationID = nil
        if let runtime { await runtime.invalidate() }
        runtime = nil
        searchMetadata = [:]
        discoverMetadata = [:]
        discoverSectionCache = nil
        searchConfigurationCache = nil
        resolvedSearchValues.removeAll()
        didLoadSearchConfiguration = false
        workCache = [:]
        domainWorkCache = [:]
        workRemoteIDs = [:]
        installmentCache = [:]
        domainInstallmentCache = [:]
        imagePageListCache = [:]
    }

    private func activeRuntime() async throws -> MangoReaderExtensionRuntime {
        if let runtime {
            let valid = await runtime.isValid
            if valid { return runtime }
        }
        if let runtimeInitialization, let runtimeInitializationID {
            return try await finishRuntimeInitialization(runtimeInitialization, id: runtimeInitializationID)
        }
        let id = UUID()
        let runtimeFactory = runtimeFactory
        let task = Task { @MainActor in
            let created = try runtimeFactory()
            do {
                try await created.initialize()
                return created
            } catch {
                created.invalidate()
                throw error
            }
        }
        runtimeInitialization = task
        runtimeInitializationID = id
        return try await finishRuntimeInitialization(task, id: id)
    }

    private func finishRuntimeInitialization(
        _ task: Task<MangoReaderExtensionRuntime, Error>,
        id: UUID
    ) async throws -> MangoReaderExtensionRuntime {
        do {
            let created = try await task.value
            if let runtime, runtime === created { return created }
            guard runtimeInitializationID == id else {
                await created.invalidate()
                throw CancellationError()
            }
            runtime = created
            runtimeInitialization = nil
            runtimeInitializationID = nil
            return created
        } catch {
            if runtimeInitializationID == id {
                runtimeInitialization = nil
                runtimeInitializationID = nil
            }
            throw error
        }
    }

    private func makeWork(
        remoteID: String,
        title: String,
        subtitle: String?,
        imageURL: String,
        previewImageURL: String? = nil,
        kind: ContentKind = .manga
    ) -> Work {
        Work(
            id: StableMangoReaderIdentifier.workID(sourceID: sourceDescriptor.id, remoteID: remoteID),
            sourceID: sourceDescriptor.id,
            remoteID: remoteID,
            title: title,
            latestChapterTitle: subtitle?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfBlank,
            languageCode: sourceDescriptor.languageCodes.first,
            kind: kind,
            coverURL: approvedURL(imageURL),
            coverPreviewURL: previewImageURL.flatMap(approvedURL)
        )
    }

    private func filteredPage(_ works: [Work], query: SourceQuery, nextMetadata: JSONValue?) -> SourcePage<Work> {
        let filtered = works.uniqued(on: \.id).filter { work in
            (query.languageCodes.isEmpty || work.languageCode.map(query.languageCodes.contains) == true)
                && (query.kinds.isEmpty || query.kinds.contains(work.kind))
        }
        let hasNext = nextMetadata != nil && nextMetadata != .null
        return SourcePage(
            items: filtered,
            nextPage: hasNext ? query.page + 1 : nil,
            nextCursor: cursor(nextMetadata)
        )
    }

    private func searchIdentity(for query: SourceQuery) -> String {
        let selections = query.searchSelections
            .map { "\($0.fieldID)=\($0.polarity.rawValue):\($0.value)" }
            .sorted()
            .joined(separator: "&")
        let filters = query.filters
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        return [query.text, selections, filters, query.sortID ?? ""]
            .joined(separator: "|")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func cursor(_ value: JSONValue?) -> SourceCursor? {
        guard let value, value != .null,
              let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return SourceCursor(value: string)
    }

    private func cursorValue(_ cursor: SourceCursor?) -> JSONValue? {
        guard let cursor, let data = cursor.value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func decode<Value: Decodable & Sendable>(_ type: Value.Type, from value: JSONValue) throws -> Value {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    private static func validatedSearchConfiguration(
        _ configuration: SourceSearchConfiguration
    ) throws -> SourceSearchConfiguration {
        guard !configuration.id.isEmpty,
              configuration.id.count <= 64,
              !configuration.title.isEmpty,
              configuration.title.count <= 128,
              configuration.fields.count <= 24,
              configuration.sortOptions.count <= 64,
              (configuration.sortedBrowseSectionID.map { !$0.isEmpty && $0.count <= 64 } ?? true)
        else { throw SourceError.unsupportedResponse }

        let fields = configuration.fields.filter { field in
            !field.id.isEmpty && field.id.count <= 64
                && !field.title.isEmpty && field.title.count <= 128
                && !field.queryPrefix.isEmpty && field.queryPrefix.count <= 64
                && field.queryPrefix.hasSuffix(":")
                && (field.placeholder?.count ?? 0) <= 256
                && (field.maximumSelections == nil || (1...24).contains(field.maximumSelections!))
                && (field.resolvedInputKind != .choice || !field.options.isEmpty)
                && field.options.count <= 100
                && field.options.allSatisfy {
                    !$0.id.isEmpty && $0.id.count <= 256
                        && !$0.title.isEmpty && $0.title.count <= 256
                        && ($0.subtitle?.count ?? 0) <= 256
                }
        }
        guard fields.count == configuration.fields.count,
              Set(fields.map(\.id)).count == fields.count,
              Set(fields.map { $0.queryPrefix.lowercased() }).count == fields.count
        else { throw SourceError.unsupportedResponse }

        let sorts = configuration.sortOptions.filter {
            !$0.id.isEmpty && $0.id.count <= 64
                && !$0.title.isEmpty && $0.title.count <= 128
        }
        guard sorts.count == configuration.sortOptions.count,
              Set(sorts.map(\.id)).count == sorts.count,
              configuration.defaultSortID == nil
                || sorts.contains(where: { $0.id == configuration.defaultSortID })
        else { throw SourceError.unsupportedResponse }

        return SourceSearchConfiguration(
            id: configuration.id,
            title: configuration.title,
            fields: fields,
            sortOptions: sorts,
            defaultSortID: configuration.defaultSortID,
            supportsTextWithFilters: configuration.supportsTextWithFilters,
            sortedBrowseSectionID: configuration.sortedBrowseSectionID
        )
    }

    private static func validatedFacets(_ facets: [WorkSearchFacet]) -> [WorkSearchFacet] {
        facets
            .filter {
                !$0.fieldID.isEmpty && $0.fieldID.count <= 64
                    && !$0.value.isEmpty && $0.value.count <= 256
                    && !$0.title.isEmpty && $0.title.count <= 256
                    && ($0.groupTitle?.count ?? 0) <= 128
            }
            .uniqued(on: \WorkSearchFacet.id)
            .prefix(100)
            .map { $0 }
    }

    private func approvedURL(_ value: String) -> URL? {
        let normalizedValue: String
        if value.hasPrefix("//") {
            normalizedValue = "https:\(value)"
        } else {
            normalizedValue = value
        }

        guard !normalizedValue.isEmpty else {
            logRejectedURL(category: "empty", host: nil)
            return nil
        }
        guard !normalizedValue.hasPrefix("/") else {
            logRejectedURL(category: "relative", host: nil)
            return nil
        }
        guard let url = URL(string: normalizedValue) else {
            logRejectedURL(category: "malformed", host: nil)
            return nil
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            logRejectedURL(category: "scheme", host: url.host)
            return nil
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            logRejectedURL(category: "missing-host", host: nil)
            return nil
        }
        guard ExtensionNetworkPolicy(hosts: Set(installedSource.allowedHTTPSHosts)).allows(url) else {
            logRejectedURL(category: "endpoint-policy", host: host)
            return nil
        }
        return url
    }

    private func logRejectedURL(category: String, host: String?) {
        let displayHost = host ?? "none"
        Self.resourceLogger.warning(
            "Rejected extension resource category=\(category, privacy: .public) host=\(displayHost, privacy: .public)"
        )
    }

    private func sourceWork(for installment: Installment) -> MangoReaderSourceWork? {
        guard let remoteWorkID = workRemoteIDs[installment.workID] else { return nil }
        return workCache[remoteWorkID]
    }

    private static func status(_ value: String?) -> WorkStatus {
        switch value?.lowercased() {
        case "ongoing", "releasing": .ongoing
        case "completed", "finished": .completed
        case "hiatus": .hiatus
        case "cancelled", "canceled": .cancelled
        default: .unknown
        }
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private static func kind(_ value: String?) -> ContentKind {
        switch value?.lowercased() {
        case "lightnovel", "light_novel", "novel": .lightNovel
        case "book": .book
        case "comic": .comic
        default: .manga
        }
    }
}

private enum StableMangoReaderIdentifier {
    static func workID(sourceID: SourceID, remoteID: String) -> WorkID {
        WorkID(rawValue: uuid(seed: "\(sourceID.rawValue)|\(remoteID)"))
    }

    static func installmentID(sourceID: SourceID, remoteID: String) -> InstallmentID {
        InstallmentID(rawValue: uuid(seed: "installment|\(sourceID.rawValue)|\(remoteID)"))
    }

    private static func uuid(seed: String) -> UUID {
        let hex = SHA256.hash(data: Data(seed.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
        let string = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: string)!
    }
}

private extension Sequence {
    func uniqued<ID: Hashable>(on keyPath: KeyPath<Element, ID>) -> [Element] {
        var seen: Set<ID> = []
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
