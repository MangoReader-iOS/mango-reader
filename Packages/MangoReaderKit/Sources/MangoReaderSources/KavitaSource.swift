#if DEBUG
import Foundation
import MangoReaderDomain

private struct KavitaPage<Element: Decodable & Sendable>: Decodable, Sendable {
    var items: [Element]
    var totalCount: Int?

    private enum CodingKeys: String, CodingKey {
        case content
        case items
        case results
        case totalCount
        case totalElements
    }

    init(from decoder: Decoder) throws {
        if var container = try? decoder.unkeyedContainer() {
            var values: [Element] = []
            while !container.isAtEnd {
                values.append(try container.decode(Element.self))
            }
            items = values
            totalCount = values.count
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([Element].self, forKey: .content)
            ?? container.decodeIfPresent([Element].self, forKey: .items)
            ?? container.decodeIfPresent([Element].self, forKey: .results)
            ?? []
        totalCount = try container.decodeIfPresent(Int.self, forKey: .totalCount)
            ?? container.decodeIfPresent(Int.self, forKey: .totalElements)
    }
}

private struct KavitaNamedValue: Decodable, Sendable {
    var title: String?
    var name: String?

    var value: String? { title?.nilIfBlank ?? name?.nilIfBlank }
}

private struct KavitaPerson: Decodable, Sendable {
    var name: String
    var role: String?
}

private struct KavitaSeriesDTO: Decodable, Sendable {
    var id: Int
    var name: String
    var originalName: String?
    var localizedName: String?
    var summary: String?
    var libraryId: Int?
    var libraryName: String?
    var pages: Int?
    var format: Int?
    var publicationStatus: Int?
    var genres: [KavitaNamedValue]?
    var tags: [KavitaNamedValue]?
    var writers: [KavitaPerson]?
}

private struct KavitaFileDTO: Decodable, Sendable {
    var id: Int?
    var filePath: String?
    var format: Int?
}

private struct KavitaChapterDTO: Decodable, Sendable {
    var id: Int
    var title: String?
    var range: String?
    var number: String?
    var pages: Int?
    var files: [KavitaFileDTO]?
    var releaseDate: String?
}

private struct KavitaVolumeDTO: Decodable, Sendable {
    var id: Int
    var name: String?
    var number: Int?
    var chapters: [KavitaChapterDTO]?
}

private struct KavitaLibraryDTO: Decodable, Sendable {
    var id: Int
    var name: String
}

private struct KavitaAuthenticationResponse: Decodable, Sendable {
    var token: String
    var refreshToken: String?
}

private struct KavitaFilterRequest: Encodable, Sendable {
    struct Statement: Encodable, Sendable {
        var comparison: Int
        var field: Int
        var value: String
    }

    struct SortOptions: Encodable, Sendable {
        var sortField: Int = 1
        var isAscending: Bool = true
    }

    var statements: [Statement]
    var combination: Int = 0
    var sortOptions = SortOptions()
}

public actor KavitaSource: ContentSource, SourceCapabilityDiscovering {
    public let descriptor: SourceDescriptor

    private let configuration: SourceEndpointConfiguration
    private let httpClient: HTTPClient
    private let credentialLoader: (any SourceCredentialLoading)?
    private var exchangedBearerToken: String?

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
            kind: .kavita,
            baseURL: configuration.baseURL,
            languageCodes: configuration.languageCodes,
            capabilities: [.browse, .search, .filters, .authentication, .acquisition]
        )
    }

    public func discoverCapabilities() async throws -> Set<SourceCapability> {
        do {
            let url = try SourceRequestSupport.url(baseURL: configuration.baseURL, path: "api/Library/libraries")
            let _: [KavitaLibraryDTO] = try await get(url)
            return descriptor.capabilities
        } catch {
            throw SourceRequestSupport.map(error)
        }
    }

    public func browse(_ query: SourceQuery) async throws -> SourcePage<Work> {
        try await allSeries(query: query, searchText: nil)
    }

    public func search(_ query: SourceQuery) async throws -> SourcePage<Work> {
        try await allSeries(query: query, searchText: query.text.nilIfBlank)
    }

    public func details(for remoteID: String) async throws -> Work {
        do {
            let url = try SourceRequestSupport.url(baseURL: configuration.baseURL, path: "api/Series/\(remoteID)")
            let series: KavitaSeriesDTO = try await get(url)
            return map(series)
        } catch {
            throw SourceRequestSupport.map(error)
        }
    }

    public func installments(for work: Work, page: Int) async throws -> SourcePage<Installment> {
        guard page == 1, let seriesID = work.remoteID else {
            return SourcePage(items: [])
        }
        do {
            let url = try SourceRequestSupport.url(
                baseURL: configuration.baseURL,
                path: "api/Series/volumes",
                queryItems: [URLQueryItem(name: "seriesId", value: seriesID)]
            )
            let volumes: [KavitaVolumeDTO] = try await get(url)
            let chapters = volumes.flatMap { volume in
                (volume.chapters ?? []).map { chapter in
                    map(chapter, volume: volume, work: work)
                }
            }
            return SourcePage(items: chapters, totalCount: chapters.count)
        } catch {
            throw SourceRequestSupport.map(error)
        }
    }

    public func acquisitionURL(for installment: Installment) async throws -> URL {
        guard let chapterID = installment.remoteID else { throw SourceError.notFound }
        return try SourceRequestSupport.url(
            baseURL: configuration.baseURL,
            path: "api/Download/chapter",
            queryItems: [URLQueryItem(name: "chapterId", value: chapterID)]
        )
    }

    private func allSeries(query: SourceQuery, searchText: String?) async throws -> SourcePage<Work> {
        do {
            let query = try CompiledSourceFilterCatalog.shared.normalizedQuery(query, for: .kavita)
            let libraryID = try CompiledSourceFilterCatalog.shared.resolvedValue(
                key: KavitaFilterKey.libraryID.rawValue,
                source: .kavita,
                querySelections: query.filters,
                configurationSelections: configuration.options
            )
            let rawSort = try CompiledSourceFilterCatalog.shared.resolvedValue(
                key: KavitaFilterKey.sort.rawValue,
                source: .kavita,
                querySelections: query.filters,
                configurationSelections: configuration.options
            ) ?? KavitaSeriesSort.titleAscending.rawValue
            guard let sort = KavitaSeriesSort(rawValue: rawSort) else {
                throw SourceFilterValidationError.invalidValue(
                    source: .kavita,
                    key: KavitaFilterKey.sort.rawValue,
                    title: "Series order"
                )
            }
            var queryItems = [
                URLQueryItem(name: "PageNumber", value: String(query.page)),
                URLQueryItem(name: "PageSize", value: String(query.pageSize)),
            ]
            if let libraryID {
                queryItems.append(URLQueryItem(name: "libraryId", value: libraryID))
            }
            let url = try SourceRequestSupport.url(baseURL: configuration.baseURL, path: "api/Series/all-v2", queryItems: queryItems)
            let statements = searchText.map { [KavitaFilterRequest.Statement(comparison: 0, field: 1, value: $0)] } ?? []
            let body = KavitaFilterRequest(
                statements: statements,
                sortOptions: KavitaFilterRequest.SortOptions(
                    isAscending: sort == .titleAscending
                )
            )
            let headers = try await authorizationHeaders()
            var request = SourceRequestSupport.request(
                configuration: configuration,
                url: url,
                method: .post,
                headers: headers,
                usesConditionalCache: false
            )
            request.headers["Content-Type"] = "application/json"
            let response: KavitaPage<KavitaSeriesDTO> = try await httpClient.jsonResponse(for: request, body: body)
            let works = SourceRequestSupport.filtered(response.items.map(map), query: query)
            let hasNext = response.items.count >= query.pageSize
            return SourcePage(items: works, nextPage: hasNext ? query.page + 1 : nil, totalCount: response.totalCount)
        } catch {
            throw SourceRequestSupport.map(error)
        }
    }

    private func get<Value: Decodable & Sendable>(_ url: URL) async throws -> Value {
        let headers = try await authorizationHeaders()
        let request = SourceRequestSupport.request(configuration: configuration, url: url, headers: headers)
        return try await httpClient.decode(Value.self, from: request)
    }

    private func authorizationHeaders() async throws -> [String: String] {
        var headers = ["Accept": "application/json", "User-Agent": "MangoReader/1"]
        if let exchangedBearerToken {
            headers["Authorization"] = "Bearer \(exchangedBearerToken)"
            return headers
        }
        guard
            let account = configuration.credentialAccount,
            let credentialLoader,
            let credential = try await credentialLoader.credential(account: account)
        else {
            return headers
        }

        switch credential {
        case let .bearer(token):
            guard !token.contains("\n"), !token.contains("\r") else {
                throw SourceError.transport("The bearer token is invalid.")
            }
            headers["Authorization"] = "Bearer \(token)"
        case let .basic(username, password):
            headers["Authorization"] = "Basic \(Data("\(username):\(password)".utf8).base64EncodedString())"
        case let .apiKey(_, value):
            let token = try await exchange(apiKey: value)
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }

    private func exchange(apiKey: String) async throws -> String {
        if let exchangedBearerToken { return exchangedBearerToken }
        let url = try SourceRequestSupport.url(
            baseURL: configuration.baseURL,
            path: "api/Plugin/authenticate",
            queryItems: [
                URLQueryItem(name: "apiKey", value: apiKey),
                URLQueryItem(name: "pluginName", value: "manko"),
            ]
        )
        let request = SourceRequestSupport.request(
            configuration: configuration,
            url: url,
            headers: ["Accept": "application/json", "User-Agent": "MangoReader/1"],
            usesConditionalCache: false
        )
        let response: KavitaAuthenticationResponse = try await httpClient.decode(from: request)
        exchangedBearerToken = response.token
        return response.token
    }

    private func map(_ series: KavitaSeriesDTO) -> Work {
        let tags = (series.genres ?? []).compactMap(\.value) + (series.tags ?? []).compactMap(\.value)
        let hints = tags + [series.libraryName ?? ""]
        let kind = SourceContentClassifier.kind(from: hints, fallback: series.format == 3 ? .lightNovel : .manga)
        let remoteID = String(series.id)
        return Work(
            id: StableSourceIdentifier.workID(sourceID: descriptor.id, remoteID: remoteID),
            sourceID: descriptor.id,
            remoteID: remoteID,
            title: series.localizedName?.nilIfBlank ?? series.name,
            alternativeTitles: [series.originalName].compactMap { $0?.nilIfBlank },
            authors: (series.writers ?? []).map(\.name),
            summary: series.summary ?? "",
            tags: tags,
            kind: kind,
            status: publicationStatus(series.publicationStatus),
            coverURL: try? SourceRequestSupport.url(
                baseURL: configuration.baseURL,
                path: "api/Image/series-cover",
                queryItems: [URLQueryItem(name: "seriesId", value: remoteID)]
            )
        )
    }

    private func map(_ chapter: KavitaChapterDTO, volume: KavitaVolumeDTO, work: Work) -> Installment {
        let remoteID = String(chapter.id)
        let file = chapter.files?.first
        let format = publicationFormat(path: file?.filePath, rawFormat: file?.format)
        return Installment(
            id: StableSourceIdentifier.installmentID(sourceID: descriptor.id, remoteID: remoteID),
            workID: work.id,
            remoteID: remoteID,
            title: chapter.title?.nilIfBlank ?? chapter.range?.nilIfBlank ?? "Chapter \(chapter.number ?? remoteID)",
            volume: volume.number.map(Double.init),
            number: chapter.number.flatMap(Double.init),
            publishedAt: chapter.releaseDate.flatMap { ISO8601DateFormatter().date(from: $0) },
            languageCode: work.languageCode,
            format: format,
            acquisitionURL: try? SourceRequestSupport.url(
                baseURL: configuration.baseURL,
                path: "api/Download/chapter",
                queryItems: [URLQueryItem(name: "chapterId", value: remoteID)]
            ),
            pageCount: chapter.pages
        )
    }

    private func publicationFormat(path: String?, rawFormat: Int?) -> PublicationFormat {
        if let path, let format = SourceContentClassifier.format(mimeType: nil, href: URL(fileURLWithPath: path)) {
            return format
        }
        switch rawFormat {
        case 2: return .pdf
        case 3, 4: return .epub
        default: return .cbz
        }
    }

    private func publicationStatus(_ value: Int?) -> WorkStatus {
        switch value {
        case 1: .ongoing
        case 2: .completed
        case 3: .hiatus
        case 4: .cancelled
        default: .unknown
        }
    }
}

#endif
