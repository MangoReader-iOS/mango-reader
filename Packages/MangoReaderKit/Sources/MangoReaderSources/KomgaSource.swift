#if DEBUG
import Foundation
import MangoReaderDomain

private struct FlexiblePage<Element: Decodable & Sendable>: Decodable, Sendable {
    var items: [Element]
    var totalElements: Int?
    var totalPages: Int?
    var last: Bool?

    private enum CodingKeys: String, CodingKey {
        case content
        case items
        case results
        case totalElements
        case totalCount
        case totalPages
        case last
    }

    init(from decoder: Decoder) throws {
        if var container = try? decoder.unkeyedContainer() {
            var values: [Element] = []
            while !container.isAtEnd {
                values.append(try container.decode(Element.self))
            }
            items = values
            totalElements = values.count
            totalPages = 1
            last = true
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([Element].self, forKey: .content)
            ?? container.decodeIfPresent([Element].self, forKey: .items)
            ?? container.decodeIfPresent([Element].self, forKey: .results)
            ?? []
        totalElements = try container.decodeIfPresent(Int.self, forKey: .totalElements)
            ?? container.decodeIfPresent(Int.self, forKey: .totalCount)
        totalPages = try container.decodeIfPresent(Int.self, forKey: .totalPages)
        last = try container.decodeIfPresent(Bool.self, forKey: .last)
    }
}

private struct KomgaAuthor: Decodable, Sendable {
    var name: String
    var role: String?
}

private struct KomgaSeriesMetadata: Decodable, Sendable {
    var title: String?
    var titleSort: String?
    var summary: String?
    var status: String?
    var language: String?
    var authors: [KomgaAuthor]?
    var tags: [String]?
    var genres: [String]?
}

private struct KomgaSeries: Decodable, Sendable {
    var id: String
    var name: String
    var url: String?
    var metadata: KomgaSeriesMetadata?
}

private struct KomgaBookMetadata: Decodable, Sendable {
    var title: String?
    var number: String?
    var numberSort: Double?
    var releaseDate: String?
    var summary: String?
}

private struct KomgaBookMedia: Decodable, Sendable {
    var mediaType: String?
    var pagesCount: Int?
}

private struct KomgaBook: Decodable, Sendable {
    var id: String
    var name: String
    var number: Int?
    var fileHash: String?
    var metadata: KomgaBookMetadata?
    var media: KomgaBookMedia?
}

private struct KomgaLibrary: Decodable, Sendable {
    var id: String
    var name: String
}

public actor KomgaSource: ContentSource, SourceCapabilityDiscovering {
    public let descriptor: SourceDescriptor

    private let configuration: SourceEndpointConfiguration
    private let httpClient: HTTPClient
    private let credentialLoader: (any SourceCredentialLoading)?

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
            kind: .komga,
            baseURL: configuration.baseURL,
            languageCodes: configuration.languageCodes,
            capabilities: [.browse, .search, .filters, .authentication, .acquisition]
        )
    }

    public func discoverCapabilities() async throws -> Set<SourceCapability> {
        do {
            let url = try SourceRequestSupport.url(baseURL: configuration.baseURL, path: "api/v1/libraries")
            let _: [KomgaLibrary] = try await get(url)
            return descriptor.capabilities
        } catch {
            throw SourceRequestSupport.map(error)
        }
    }

    public func browse(_ query: SourceQuery) async throws -> SourcePage<Work> {
        try await series(query: query, searchText: nil)
    }

    public func search(_ query: SourceQuery) async throws -> SourcePage<Work> {
        try await series(query: query, searchText: query.text.nilIfBlank)
    }

    public func details(for remoteID: String) async throws -> Work {
        do {
            let url = try SourceRequestSupport.url(baseURL: configuration.baseURL, path: "api/v1/series/\(remoteID)")
            let series: KomgaSeries = try await get(url)
            return map(series)
        } catch {
            throw SourceRequestSupport.map(error)
        }
    }

    public func installments(for work: Work, page: Int) async throws -> SourcePage<Installment> {
        guard let seriesID = work.remoteID else { throw SourceError.notFound }
        do {
            let url = try SourceRequestSupport.url(
                baseURL: configuration.baseURL,
                path: "api/v1/series/\(seriesID)/books",
                queryItems: [
                    URLQueryItem(name: "page", value: String(max(0, page - 1))),
                    URLQueryItem(name: "size", value: "100"),
                    URLQueryItem(name: "sort", value: "metadata.numberSort,asc"),
                ]
            )
            let response: FlexiblePage<KomgaBook> = try await get(url)
            let items = response.items.map { map($0, work: work) }
            let hasNext = response.last == false || (response.totalPages.map { page < $0 } ?? false)
            return SourcePage(items: items, nextPage: hasNext ? page + 1 : nil, totalCount: response.totalElements)
        } catch {
            throw SourceRequestSupport.map(error)
        }
    }

    public func acquisitionURL(for installment: Installment) async throws -> URL {
        guard let bookID = installment.remoteID else { throw SourceError.notFound }
        return try SourceRequestSupport.url(baseURL: configuration.baseURL, path: "api/v1/books/\(bookID)/file")
    }

    private func series(query: SourceQuery, searchText: String?) async throws -> SourcePage<Work> {
        do {
            let query = try CompiledSourceFilterCatalog.shared.normalizedQuery(query, for: .komga)
            let sort = try CompiledSourceFilterCatalog.shared.resolvedValue(
                key: KomgaFilterKey.sort.rawValue,
                source: .komga,
                querySelections: query.filters,
                configurationSelections: configuration.options
            ) ?? KomgaSeriesSort.titleAscending.rawValue
            let libraryID = try CompiledSourceFilterCatalog.shared.resolvedValue(
                key: KomgaFilterKey.libraryID.rawValue,
                source: .komga,
                querySelections: query.filters,
                configurationSelections: configuration.options
            )
            var items = [
                URLQueryItem(name: "page", value: String(max(0, query.page - 1))),
                URLQueryItem(name: "size", value: String(query.pageSize)),
                URLQueryItem(name: "sort", value: sort),
            ]
            if let searchText {
                items.append(URLQueryItem(name: "search", value: searchText))
            }
            if let libraryID {
                items.append(URLQueryItem(name: "library_id", value: libraryID))
            }
            let url = try SourceRequestSupport.url(baseURL: configuration.baseURL, path: "api/v1/series", queryItems: items)
            let response: FlexiblePage<KomgaSeries> = try await get(url)
            let works = SourceRequestSupport.filtered(response.items.map(map), query: query)
            let hasNext = response.last == false || (response.totalPages.map { query.page < $0 } ?? false)
            return SourcePage(items: works, nextPage: hasNext ? query.page + 1 : nil, totalCount: response.totalElements)
        } catch {
            throw SourceRequestSupport.map(error)
        }
    }

    private func get<Value: Decodable & Sendable>(_ url: URL) async throws -> Value {
        let headers = try await SourceRequestSupport.headers(configuration: configuration, credentialLoader: credentialLoader)
        let request = SourceRequestSupport.request(configuration: configuration, url: url, headers: headers)
        return try await httpClient.decode(Value.self, from: request)
    }

    private func map(_ series: KomgaSeries) -> Work {
        let metadata = series.metadata
        let tags = (metadata?.tags ?? []) + (metadata?.genres ?? [])
        return Work(
            id: StableSourceIdentifier.workID(sourceID: descriptor.id, remoteID: series.id),
            sourceID: descriptor.id,
            remoteID: series.id,
            title: metadata?.title?.nilIfBlank ?? series.name,
            authors: (metadata?.authors ?? []).filter { $0.role?.lowercased() != "penciller" }.map(\.name),
            summary: metadata?.summary ?? "",
            tags: tags,
            languageCode: metadata?.language,
            kind: SourceContentClassifier.kind(from: tags, fallback: .manga),
            status: status(metadata?.status),
            coverURL: try? SourceRequestSupport.url(baseURL: configuration.baseURL, path: "api/v1/series/\(series.id)/thumbnail")
        )
    }

    private func map(_ book: KomgaBook, work: Work) -> Installment {
        let format = SourceContentClassifier.format(mimeType: book.media?.mediaType, href: nil) ?? .cbz
        let number = book.metadata?.numberSort ?? book.metadata?.number.flatMap(Double.init) ?? book.number.map(Double.init)
        return Installment(
            id: StableSourceIdentifier.installmentID(sourceID: descriptor.id, remoteID: book.id),
            workID: work.id,
            remoteID: book.id,
            title: book.metadata?.title?.nilIfBlank ?? book.name,
            number: number,
            publishedAt: book.metadata?.releaseDate.flatMap(Self.date),
            languageCode: work.languageCode,
            format: format,
            acquisitionURL: try? SourceRequestSupport.url(baseURL: configuration.baseURL, path: "api/v1/books/\(book.id)/file"),
            pageCount: book.media?.pagesCount
        )
    }

    private func status(_ value: String?) -> WorkStatus {
        switch value?.lowercased() {
        case "ended", "completed": .completed
        case "ongoing": .ongoing
        case "hiatus": .hiatus
        case "abandoned", "cancelled": .cancelled
        default: .unknown
        }
    }

    private static func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}

#endif
