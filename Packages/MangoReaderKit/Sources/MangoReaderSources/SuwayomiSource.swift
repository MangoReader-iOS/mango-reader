#if DEBUG
import Foundation
import MangoReaderDomain

private enum GraphQLValue: Encodable, Sendable {
    case string(String)
    case integer(Int)
    case boolean(Bool)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        }
    }
}

private struct GraphQLRequest: Encodable, Sendable {
    var query: String
    var variables: [String: GraphQLValue]
}

private struct GraphQLError: Decodable, Sendable {
    var message: String
}

private struct GraphQLResponse<Payload: Decodable & Sendable>: Decodable, Sendable {
    var data: Payload?
    var errors: [GraphQLError]?
}

private struct SuwayomiMangaPage: Decodable, Sendable {
    var mangas: [SuwayomiManga]
    var hasNextPage: Bool
}

private struct SuwayomiMangaListPayload: Decodable, Sendable {
    var fetchSourceManga: SuwayomiMangaPage?
    var searchSourceManga: SuwayomiMangaPage?
}

private struct SuwayomiMangaPayload: Decodable, Sendable {
    var manga: SuwayomiManga?
}

private struct SuwayomiManga: Decodable, Sendable {
    var id: Int
    var title: String
    var thumbnailUrl: String?
    var author: String?
    var artist: String?
    var description: String?
    var genre: [String]?
    var status: String?
    var sourceId: String?
}

private struct SuwayomiChapterEdge: Decodable, Sendable {
    var node: SuwayomiChapter
}

private struct SuwayomiChapterConnection: Decodable, Sendable {
    var nodes: [SuwayomiChapter]?
    var edges: [SuwayomiChapterEdge]?
}

private struct SuwayomiChaptersPayload: Decodable, Sendable {
    var chapters: SuwayomiChapterConnection?
}

private struct SuwayomiChapter: Decodable, Sendable {
    var id: Int
    var name: String
    var chapterNumber: Double?
    var volumeNumber: Double?
    var sourceOrder: Int?
    var uploadDate: String?
    var pageCount: Int?
}

private struct SuwayomiDiscoveryPayload: Decodable, Sendable {
    var serverSettings: SuwayomiServerSettings?
}

private struct SuwayomiServerSettings: Decodable, Sendable {
    var ip: String?
}

private struct SuwayomiChapterPagePayload: Decodable, Sendable {
    var pageCount: Int?
}

struct SuwayomiChapterReference: Hashable, Sendable {
    var mangaID: Int
    var sourceOrder: Int
    var chapterID: Int

    init(mangaID: Int, sourceOrder: Int, chapterID: Int) {
        self.mangaID = mangaID
        self.sourceOrder = sourceOrder
        self.chapterID = chapterID
    }

    init?(remoteID: String) {
        let parts = remoteID.split(separator: ":", omittingEmptySubsequences: false)
        guard
            parts.count == 3,
            let mangaID = Int(parts[0]),
            let sourceOrder = Int(parts[1]),
            let chapterID = Int(parts[2])
        else {
            return nil
        }
        self.init(mangaID: mangaID, sourceOrder: sourceOrder, chapterID: chapterID)
    }

    var remoteID: String {
        "\(mangaID):\(sourceOrder):\(chapterID)"
    }
}

public actor SuwayomiSource: ContentSource, SourceCapabilityDiscovering {
    public let descriptor: SourceDescriptor

    private static let maximumSequencePages = 50_000
    private static let maximumPageBytes = 128 * 1_024 * 1_024

    private let configuration: SourceEndpointConfiguration
    private let httpClient: HTTPClient
    private let credentialLoader: (any SourceCredentialLoading)?
    private var pageCountsByRemoteID: [String: Int] = [:]

    public init(
        configuration: SourceEndpointConfiguration,
        httpClient: HTTPClient,
        credentialLoader: (any SourceCredentialLoading)? = nil
    ) {
        self.configuration = configuration
        self.httpClient = httpClient
        self.credentialLoader = credentialLoader
        self.descriptor = SourceDescriptor(
            id: configuration.id,
            name: configuration.name,
            kind: .suwayomi,
            baseURL: configuration.baseURL,
            languageCodes: configuration.languageCodes,
            capabilities: [.browse, .search, .filters, .authentication, .acquisition, .imageSequence]
        )
    }

    public func discoverCapabilities() async throws -> Set<SourceCapability> {
        let query = "query MangoReaderDiscovery { serverSettings { ip } }"
        let _: SuwayomiDiscoveryPayload = try await graphQL(query: query, variables: [:])
        return descriptor.capabilities
    }

    public func browse(_ query: SourceQuery) async throws -> SourcePage<Work> {
        do {
            let query = try CompiledSourceFilterCatalog.shared.normalizedQuery(query, for: .suwayomi)
            let remoteSourceID = try sourceID()
            let rawListing = try CompiledSourceFilterCatalog.shared.resolvedValue(
                key: SuwayomiFilterKey.listing.rawValue,
                source: .suwayomi,
                querySelections: query.filters,
                configurationSelections: configuration.options
            ) ?? SuwayomiListing.popular.rawValue
            guard let listing = SuwayomiListing(rawValue: rawListing) else {
                throw SourceFilterValidationError.invalidValue(
                    source: .suwayomi,
                    key: SuwayomiFilterKey.listing.rawValue,
                    title: "Browse listing"
                )
            }
            let operation = """
            query MangoReaderBrowse($source: Long!, $type: FetchSourceMangaType!, $page: Int!) {
              fetchSourceManga(source: $source, type: $type, page: $page) {
                mangas { id title thumbnailUrl author artist description genre status sourceId }
                hasNextPage
              }
            }
            """
            let payload: SuwayomiMangaListPayload = try await graphQL(
                query: operation,
                variables: [
                    "source": .integer(remoteSourceID),
                    "type": .string(listing.rawValue),
                    "page": .integer(query.page),
                ]
            )
            guard let page = payload.fetchSourceManga else { throw SourceError.unsupportedResponse }
            let works = SourceRequestSupport.filtered(page.mangas.map(map), query: query)
            return SourcePage(items: works, nextPage: page.hasNextPage ? query.page + 1 : nil)
        } catch {
            throw SourceRequestSupport.map(error)
        }
    }

    public func search(_ query: SourceQuery) async throws -> SourcePage<Work> {
        do {
            let query = try CompiledSourceFilterCatalog.shared.normalizedQuery(query, for: .suwayomi)
            guard let text = query.text.nilIfBlank else { return try await browse(query) }
            let remoteSourceID = try sourceID()
            let operation = """
            query MangoReaderSearch($source: Long!, $query: String!, $page: Int!) {
              searchSourceManga(source: $source, query: $query, page: $page) {
                mangas { id title thumbnailUrl author artist description genre status sourceId }
                hasNextPage
              }
            }
            """
            let payload: SuwayomiMangaListPayload = try await graphQL(
                query: operation,
                variables: [
                    "source": .integer(remoteSourceID),
                    "query": .string(text),
                    "page": .integer(query.page),
                ]
            )
            guard let page = payload.searchSourceManga else { throw SourceError.unsupportedResponse }
            let works = SourceRequestSupport.filtered(page.mangas.map(map), query: query)
            return SourcePage(items: works, nextPage: page.hasNextPage ? query.page + 1 : nil)
        } catch {
            throw SourceRequestSupport.map(error)
        }
    }

    public func details(for remoteID: String) async throws -> Work {
        guard let mangaID = Int(remoteID) else { throw SourceError.notFound }
        do {
            let operation = """
            query MangoReaderDetails($id: Int!) {
              manga(id: $id) { id title thumbnailUrl author artist description genre status sourceId }
            }
            """
            let payload: SuwayomiMangaPayload = try await graphQL(query: operation, variables: ["id": .integer(mangaID)])
            guard let manga = payload.manga else { throw SourceError.notFound }
            return map(manga)
        } catch {
            throw SourceRequestSupport.map(error)
        }
    }

    public func installments(for work: Work, page: Int) async throws -> SourcePage<Installment> {
        guard page == 1, let remoteID = work.remoteID, let mangaID = Int(remoteID) else {
            return SourcePage(items: [])
        }
        do {
            let operation = """
            query MangoReaderChapters($mangaId: Int!) {
              chapters(condition: { mangaId: $mangaId }, order: [{ by: SOURCE_ORDER, byType: ASC }]) {
                nodes { id name chapterNumber volumeNumber sourceOrder uploadDate pageCount }
              }
            }
            """
            let payload: SuwayomiChaptersPayload = try await graphQL(query: operation, variables: ["mangaId": .integer(mangaID)])
            let connection = payload.chapters
            let chapters = connection?.nodes ?? connection?.edges?.map(\.node) ?? []
            let installments = chapters.map { map($0, mangaID: mangaID, work: work) }
            return SourcePage(items: installments, totalCount: installments.count)
        } catch {
            throw SourceRequestSupport.map(error)
        }
    }

    public func acquisitionURL(for installment: Installment) async throws -> URL {
        guard
            let remoteID = installment.remoteID,
            let reference = SuwayomiChapterReference(remoteID: remoteID)
        else {
            throw SourceError.notFound
        }
        return try chapterDownloadURL(reference)
    }

    public func imagePages(
        for installment: Installment,
        query: RemoteImagePageQuery
    ) async throws -> SourcePage<RemoteImagePageDescriptor> {
        guard
            installment.format == .remoteImageSequence,
            let remoteID = installment.remoteID,
            let reference = SuwayomiChapterReference(remoteID: remoteID)
        else {
            throw SourceError.notFound
        }

        do {
            try Task.checkCancellation()
            let count: Int
            if let knownCount = installment.pageCount, knownCount > 0 {
                count = knownCount
                pageCountsByRemoteID[remoteID] = knownCount
            } else if let cachedCount = pageCountsByRemoteID[remoteID] {
                count = cachedCount
            } else {
                count = try await chapterPageCount(reference)
                pageCountsByRemoteID[remoteID] = count
            }
            guard count > 0 else { throw SourceError.unsupportedResponse }
            guard count <= Self.maximumSequencePages else {
                throw SourceError.resourceLimitExceeded("the chapter contains too many pages")
            }

            let zeroBasedPage = query.page - 1
            guard zeroBasedPage <= Int.max / query.pageSize else {
                return SourcePage(items: [], totalCount: count)
            }
            let start = zeroBasedPage * query.pageSize
            guard start < count else {
                return SourcePage(items: [], totalCount: count)
            }
            let end = min(count, start + query.pageSize)

            var pages: [RemoteImagePageDescriptor] = []
            pages.reserveCapacity(end - start)
            for index in start ..< end {
                try Task.checkCancellation()
                let resourceURL = try chapterPageURL(reference, index: index)
                try EndpointPolicy().validate(resourceURL, access: configuration.endpointAccess)
                pages.append(
                    RemoteImagePageDescriptor(
                        id: "\(descriptor.id.rawValue):\(remoteID):\(index)",
                        sourceID: descriptor.id,
                        installmentID: installment.id,
                        index: index,
                        resourceURL: resourceURL
                    )
                )
            }

            return SourcePage(
                items: pages,
                nextPage: end < count ? query.page + 1 : nil,
                totalCount: count
            )
        } catch {
            throw SourceRequestSupport.map(error)
        }
    }

    public func imagePageContent(for page: RemoteImagePageDescriptor) async throws -> RemoteImagePageContent {
        try await loadImagePage(page)
    }

    public func streamImagePageContent(for page: RemoteImagePageDescriptor, priority: RemoteImageRequestPriority,
        onPartial: @escaping RemoteImagePageProgress,
        onProgress: @escaping RemoteImageDownloadProgressHandler) async throws -> RemoteImagePageContent {
        try await loadImagePage(page, onProgress: onProgress)
    }

    private func loadImagePage(_ page: RemoteImagePageDescriptor,
        onProgress: RemoteImageDownloadProgressHandler? = nil) async throws -> RemoteImagePageContent {
        do {
            try Task.checkCancellation()
            guard
                page.sourceID == descriptor.id,
                SourceCredentialOriginPolicy.isSameOrigin(page.resourceURL, as: configuration.baseURL)
            else {
                throw SourceError.unsafeResourceURL
            }
            try EndpointPolicy().validate(page.resourceURL, access: configuration.endpointAccess)

            let headers = try await SourceRequestSupport.headers(
                configuration: configuration,
                credentialLoader: credentialLoader,
                accepting: "image/avif, image/webp, image/*, application/octet-stream;q=0.8"
            )
            let request = SourceRequestSupport.request(
                configuration: configuration,
                url: page.resourceURL,
                headers: headers,
                usesConditionalCache: false
            )
            let response = try await httpClient.response(for: request, onProgress: onProgress)
            try Task.checkCancellation()

            if let contentLength = response.header("Content-Length").flatMap(Int.init),
               contentLength > Self.maximumPageBytes
            {
                throw SourceError.resourceLimitExceeded("the image page is too large")
            }
            guard !response.data.isEmpty else { throw SourceError.unsupportedResponse }
            guard response.data.count <= Self.maximumPageBytes else {
                throw SourceError.resourceLimitExceeded("the image page is too large")
            }

            let mediaType = response.header("Content-Type")?
                .split(separator: ";", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if let mediaType,
               !mediaType.hasPrefix("image/"),
               mediaType != "application/octet-stream"
            {
                throw SourceError.unsupportedResponse
            }
            return RemoteImagePageContent(data: response.data, mediaType: mediaType)
        } catch {
            throw SourceRequestSupport.map(error)
        }
    }

    private func chapterDownloadURL(_ reference: SuwayomiChapterReference) throws -> URL {
        try SourceRequestSupport.url(
            baseURL: configuration.baseURL,
            path: "api/v1/chapter/\(reference.chapterID)/download",
            queryItems: [URLQueryItem(name: "markAsRead", value: "false")]
        )
    }

    private func chapterPageCount(_ reference: SuwayomiChapterReference) async throws -> Int {
        let url = try SourceRequestSupport.url(
            baseURL: configuration.baseURL,
            path: "api/v1/manga/\(reference.mangaID)/chapter/\(reference.sourceOrder)"
        )
        guard SourceCredentialOriginPolicy.isSameOrigin(url, as: configuration.baseURL) else {
            throw SourceError.unsafeResourceURL
        }
        let headers = try await SourceRequestSupport.headers(
            configuration: configuration,
            credentialLoader: credentialLoader
        )
        let request = SourceRequestSupport.request(
            configuration: configuration,
            url: url,
            headers: headers,
            usesConditionalCache: false
        )
        let payload: SuwayomiChapterPagePayload = try await httpClient.decode(from: request)
        try Task.checkCancellation()
        guard let count = payload.pageCount, count > 0 else {
            throw SourceError.unsupportedResponse
        }
        return count
    }

    private func chapterPageURL(_ reference: SuwayomiChapterReference, index: Int) throws -> URL {
        guard index >= 0 else { throw SourceError.notFound }
        let url = try SourceRequestSupport.url(
            baseURL: configuration.baseURL,
            path: "api/v1/manga/\(reference.mangaID)/chapter/\(reference.sourceOrder)/page/\(index)",
            queryItems: [URLQueryItem(name: "updateProgress", value: "false")]
        )
        guard SourceCredentialOriginPolicy.isSameOrigin(url, as: configuration.baseURL) else {
            throw SourceError.unsafeResourceURL
        }
        return url
    }

    private func graphQL<Payload: Decodable & Sendable>(
        query: String,
        variables: [String: GraphQLValue]
    ) async throws -> Payload {
        let url = try SourceRequestSupport.url(baseURL: configuration.baseURL, path: "api/graphql")
        let headers = try await SourceRequestSupport.headers(configuration: configuration, credentialLoader: credentialLoader)
        var request = SourceRequestSupport.request(
            configuration: configuration,
            url: url,
            method: .post,
            headers: headers,
            usesConditionalCache: false
        )
        request.headers["Content-Type"] = "application/json"
        let response: GraphQLResponse<Payload> = try await httpClient.jsonResponse(
            for: request,
            body: GraphQLRequest(query: query, variables: variables)
        )
        if let errors = response.errors, !errors.isEmpty {
            let message = errors.map(\.message).joined(separator: "\n")
            if message.localizedCaseInsensitiveContains("unauthorized") || message.localizedCaseInsensitiveContains("authentication") {
                throw SourceError.unauthorized
            }
            throw SourceError.transport(message)
        }
        guard let data = response.data else { throw SourceError.unsupportedResponse }
        return data
    }

    private func sourceID() throws -> Int {
        let value = try CompiledSourceFilterCatalog.shared.resolvedValue(
            key: SuwayomiFilterKey.sourceID.rawValue,
            source: .suwayomi,
            querySelections: [:],
            configurationSelections: configuration.options
        )
        guard let value, let id = Int(value) else {
            throw SourceError.transport("Choose a Suwayomi source before browsing.")
        }
        return id
    }

    private func map(_ manga: SuwayomiManga) -> Work {
        let remoteID = String(manga.id)
        let tags = manga.genre ?? []
        let coverURL = manga.thumbnailUrl.flatMap { URL(string: $0, relativeTo: configuration.baseURL)?.absoluteURL }
        return Work(
            id: StableSourceIdentifier.workID(sourceID: descriptor.id, remoteID: remoteID),
            sourceID: descriptor.id,
            remoteID: remoteID,
            title: manga.title,
            authors: [manga.author, manga.artist].compactMap { $0?.nilIfBlank },
            summary: manga.description ?? "",
            tags: tags,
            kind: SourceContentClassifier.kind(from: tags, fallback: .manga),
            status: status(manga.status),
            coverURL: coverURL
        )
    }

    private func map(_ chapter: SuwayomiChapter, mangaID: Int, work: Work) -> Installment {
        let index = chapter.sourceOrder ?? chapter.id
        let reference = SuwayomiChapterReference(
            mangaID: mangaID,
            sourceOrder: index,
            chapterID: chapter.id
        )
        return Installment(
            id: StableSourceIdentifier.installmentID(sourceID: descriptor.id, remoteID: reference.remoteID),
            workID: work.id,
            remoteID: reference.remoteID,
            title: chapter.name,
            volume: chapter.volumeNumber,
            number: chapter.chapterNumber,
            publishedAt: chapter.uploadDate.flatMap { ISO8601DateFormatter().date(from: $0) },
            languageCode: work.languageCode,
            // Reading streams Suwayomi's ordered page route. Explicit offline
            // acquisition still uses the server's side-effect-free CBZ route.
            format: .remoteImageSequence,
            acquisitionURL: try? chapterDownloadURL(reference),
            pageCount: chapter.pageCount
        )
    }

    private func status(_ raw: String?) -> WorkStatus {
        switch raw?.lowercased() {
        case "ongoing": .ongoing
        case "completed": .completed
        case "hiatus": .hiatus
        case "cancelled", "canceled": .cancelled
        default: .unknown
        }
    }
}

#endif
