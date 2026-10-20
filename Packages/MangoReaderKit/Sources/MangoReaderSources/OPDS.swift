#if DEBUG
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import MangoReaderDomain

struct OPDSLink: Hashable, Sendable {
    var href: URL
    var relation: String
    var type: String?
    var title: String?

    var isAcquisition: Bool {
        relation
            .split(separator: " ")
            .contains { $0 == "http://opds-spec.org/acquisition" || $0.hasPrefix("http://opds-spec.org/acquisition/") }
    }

    var isCover: Bool {
        relation.contains("http://opds-spec.org/image") || relation.split(separator: " ").contains("cover")
    }
}

struct OPDSPublication: Hashable, Sendable {
    var identifier: String
    var title: String
    var summary: String
    var authors: [String]
    var languageCode: String?
    var subjects: [String]
    var links: [OPDSLink]
    var modifiedAt: Date?

    var acquisitionLink: OPDSLink? {
        links.first { $0.isAcquisition && SourceContentClassifier.format(mimeType: $0.type, href: $0.href) != nil }
    }

    func work(source: SourceDescriptor) -> Work {
        let mimeTypes = links.compactMap(\.type)
        let kind = SourceContentClassifier.kind(from: subjects + mimeTypes, fallback: .book)
        let remoteID = identifier.nilIfBlank ?? acquisitionLink?.href.absoluteString ?? title
        return Work(
            id: StableSourceIdentifier.workID(sourceID: source.id, remoteID: remoteID),
            sourceID: source.id,
            remoteID: remoteID,
            title: title.nilIfBlank ?? "Untitled",
            authors: authors,
            summary: summary,
            tags: subjects,
            languageCode: languageCode,
            kind: kind,
            coverURL: links.first(where: \.isCover)?.href,
            modifiedAt: modifiedAt ?? .now
        )
    }

    func installment(work: Work) -> Installment? {
        guard let link = acquisitionLink,
              let format = SourceContentClassifier.format(mimeType: link.type, href: link.href) else {
            return nil
        }
        let remoteID = "\(identifier)|\(link.href.absoluteString)"
        return Installment(
            id: StableSourceIdentifier.installmentID(sourceID: work.sourceID, remoteID: remoteID),
            workID: work.id,
            remoteID: remoteID,
            title: title.nilIfBlank ?? "Publication",
            languageCode: languageCode,
            format: format,
            acquisitionURL: link.href
        )
    }
}

struct OPDSFeed: Sendable {
    var title: String?
    var publications: [OPDSPublication]
    var links: [OPDSLink]
    var totalCount: Int?

    var nextURL: URL? {
        links.first { $0.relation.split(separator: " ").contains("next") }?.href
    }

    var searchLink: OPDSLink? {
        links.first {
            $0.relation.split(separator: " ").contains("search") ||
                $0.relation.contains("opensearch")
        }
    }
}

enum OPDSParser {
    static func parse(data: Data, baseURL: URL, contentType: String?) throws -> OPDSFeed {
        let contentType = contentType?.lowercased() ?? ""
        let firstByte = data.first { ![0x09, 0x0A, 0x0D, 0x20].contains($0) }
        if contentType.contains("json") || firstByte == Character("{").asciiValue || firstByte == Character("[").asciiValue {
            return try parseJSON(data: data, baseURL: baseURL)
        }
        return try parseAtom(data: data, baseURL: baseURL)
    }

    private static func parseAtom(data: Data, baseURL: URL) throws -> OPDSFeed {
        let delegate = AtomFeedDelegate(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse() else {
            throw parser.parserError ?? SourceError.unsupportedResponse
        }
        return delegate.feed
    }

    private static func parseJSON(data: Data, baseURL: URL) throws -> OPDSFeed {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.unsupportedResponse
        }

        let metadata = root["metadata"] as? [String: Any]
        let title = string(metadata?["title"])
        let total = integer(metadata?["numberOfItems"]) ?? integer(metadata?["numberOfPublications"])
        let links = parseLinks(root["links"], baseURL: baseURL)
        let rawPublications = root["publications"] as? [[String: Any]] ?? []
        let publications = rawPublications.compactMap { publication($0, baseURL: baseURL) }
        return OPDSFeed(title: title, publications: publications, links: links, totalCount: total)
    }

    private static func publication(_ raw: [String: Any], baseURL: URL) -> OPDSPublication? {
        let metadata = raw["metadata"] as? [String: Any] ?? [:]
        guard let title = string(metadata["title"])?.nilIfBlank else { return nil }

        let links = parseLinks(raw["links"], baseURL: baseURL) + parseLinks(raw["images"], baseURL: baseURL, defaultRelation: "cover")
        let identifier = string(metadata["identifier"]) ?? links.first(where: \.isAcquisition)?.href.absoluteString ?? title
        let authors = contributorNames(metadata["author"] ?? metadata["authors"])
        let languages = stringArray(metadata["language"])
        let subjects = subjectNames(metadata["subject"] ?? metadata["subjects"])
        let modified = date(string(metadata["modified"]) ?? string(metadata["published"]))

        return OPDSPublication(
            identifier: identifier,
            title: title,
            summary: string(metadata["description"]) ?? "",
            authors: authors,
            languageCode: languages.first,
            subjects: subjects,
            links: links,
            modifiedAt: modified
        )
    }

    private static func parseLinks(_ raw: Any?, baseURL: URL, defaultRelation: String = "") -> [OPDSLink] {
        guard let links = raw as? [[String: Any]] else { return [] }
        return links.compactMap { value in
            guard let hrefString = string(value["href"]),
                  let href = URL(string: hrefString, relativeTo: baseURL)?.absoluteURL else {
                return nil
            }
            let relation: String
            if let rel = value["rel"] as? [String] {
                relation = rel.joined(separator: " ")
            } else {
                relation = string(value["rel"]) ?? defaultRelation
            }
            return OPDSLink(href: href, relation: relation, type: string(value["type"]), title: string(value["title"]))
        }
    }

    private static func contributorNames(_ raw: Any?) -> [String] {
        if let name = string(raw) {
            return [name]
        }
        if let object = raw as? [String: Any], let name = string(object["name"]) {
            return [name]
        }
        guard let values = raw as? [Any] else { return [] }
        return values.compactMap { value in
            if let name = string(value) { return name }
            return string((value as? [String: Any])?["name"])
        }
    }

    private static func subjectNames(_ raw: Any?) -> [String] {
        if let value = string(raw) { return [value] }
        guard let values = raw as? [Any] else { return [] }
        return values.compactMap { value in
            if let value = string(value) { return value }
            let object = value as? [String: Any]
            return string(object?["name"]) ?? string(object?["code"])
        }
    }

    private static func stringArray(_ raw: Any?) -> [String] {
        if let string = string(raw) { return [string] }
        return (raw as? [Any])?.compactMap(string) ?? []
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String: value
        case let value as NSNumber: value.stringValue
        case let value as [String: Any]:
            string(value["value"]) ?? string(value["name"]) ?? string(value["title"])
        default: nil
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}

private final class AtomFeedDelegate: NSObject, XMLParserDelegate {
    private struct Entry {
        var identifier = ""
        var title = ""
        var summary = ""
        var authors: [String] = []
        var languageCode: String?
        var subjects: [String] = []
        var links: [OPDSLink] = []
        var modifiedAt: Date?
    }

    private let baseURL: URL
    private var elementStack: [String] = []
    private var entry: Entry?
    private var feedTitle = ""
    private var feedLinks: [OPDSLink] = []
    private var publications: [OPDSPublication] = []

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    var feed: OPDSFeed {
        OPDSFeed(title: feedTitle.nilIfBlank, publications: publications, links: feedLinks, totalCount: nil)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = localName(elementName, qualifiedName: qName)
        elementStack.append(name)
        if name == "entry" {
            entry = Entry()
        } else if name == "link" {
            appendLink(attributes: attributeDict)
        } else if name == "name", elementStack.contains("author"), var value = entry {
            value.authors.append("")
            entry = value
        } else if name == "category", var value = entry {
            if let term = attributeDict["term"] ?? attributeDict["label"], !term.isEmpty {
                value.subjects.append(term)
            }
            entry = value
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let name = elementStack.last else { return }
        if var value = entry {
            switch name {
            case "id": value.identifier += string
            case "title": value.title += string
            case "summary", "content": value.summary += string
            case "name" where elementStack.contains("author"):
                if value.authors.isEmpty { value.authors.append("") }
                value.authors[value.authors.count - 1] += string
            case "language": value.languageCode = (value.languageCode ?? "") + string
            case "updated", "published":
                let candidate = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if let date = ISO8601DateFormatter().date(from: candidate) {
                    value.modifiedAt = date
                }
            default: break
            }
            entry = value
        } else if name == "title" {
            feedTitle += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = localName(elementName, qualifiedName: qName)
        if name == "entry", let entry {
            let publication = OPDSPublication(
                identifier: entry.identifier.trimmingCharacters(in: .whitespacesAndNewlines),
                title: entry.title.trimmingCharacters(in: .whitespacesAndNewlines),
                summary: entry.summary.trimmingCharacters(in: .whitespacesAndNewlines),
                authors: entry.authors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                languageCode: entry.languageCode?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                subjects: entry.subjects,
                links: entry.links,
                modifiedAt: entry.modifiedAt
            )
            publications.append(publication)
            self.entry = nil
        }
        if !elementStack.isEmpty {
            elementStack.removeLast()
        }
    }

    private func appendLink(attributes: [String: String]) {
        guard let hrefValue = attributes["href"],
              let href = URL(string: hrefValue, relativeTo: baseURL)?.absoluteURL else {
            return
        }
        let link = OPDSLink(
            href: href,
            relation: attributes["rel"] ?? "",
            type: attributes["type"],
            title: attributes["title"]
        )
        if var entry {
            entry.links.append(link)
            self.entry = entry
        } else {
            feedLinks.append(link)
        }
    }

    private func localName(_ elementName: String, qualifiedName: String?) -> String {
        let candidate = elementName.isEmpty ? (qualifiedName ?? "") : elementName
        return candidate.split(separator: ":").last.map(String.init) ?? candidate
    }
}

public actor OPDSSource: ContentSource, SourceCapabilityDiscovering {
    public let descriptor: SourceDescriptor

    private let configuration: SourceEndpointConfiguration
    private let httpClient: HTTPClient
    private let credentialLoader: (any SourceCredentialLoading)?
    private var publications: [String: OPDSPublication] = [:]
    private var pagination: [String: [Int: URL]] = [:]

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
            kind: .opds,
            baseURL: configuration.baseURL,
            languageCodes: configuration.languageCodes,
            capabilities: [.browse, .search, .filters, .authentication, .acquisition]
        )
    }

    public func discoverCapabilities() async throws -> Set<SourceCapability> {
        do {
            let feed = try await fetchFeed(at: configuration.baseURL)
            var capabilities: Set<SourceCapability> = [.browse, .filters, .acquisition]
            if feed.searchLink != nil {
                capabilities.insert(.search)
            }
            if configuration.credentialAccount != nil {
                capabilities.insert(.authentication)
            }
            return capabilities
        } catch {
            throw SourceRequestSupport.map(error)
        }
    }

    public func browse(_ query: SourceQuery) async throws -> SourcePage<Work> {
        do {
            let query = try CompiledSourceFilterCatalog.shared.normalizedQuery(query, for: .opds)
            let key = "browse"
            let url = pageURL(for: key, query: query, fallback: configuration.baseURL)
            let feed = try await fetchFeed(at: url)
            remember(feed: feed, key: key, page: query.page)
            let works = try ordered(
                SourceRequestSupport.filtered(feed.publications.map { $0.work(source: descriptor) }, query: query),
                query: query
            )
            return SourcePage(items: works, nextPage: feed.nextURL == nil ? nil : query.page + 1, totalCount: feed.totalCount)
        } catch {
            throw SourceRequestSupport.map(error)
        }
    }

    public func search(_ query: SourceQuery) async throws -> SourcePage<Work> {
        let normalizedQuery: SourceQuery
        do {
            normalizedQuery = try CompiledSourceFilterCatalog.shared.normalizedQuery(query, for: .opds)
        } catch {
            throw SourceRequestSupport.map(error)
        }
        guard !normalizedQuery.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return try await browse(normalizedQuery)
        }
        do {
            let key = "search|\(normalizedQuery.text.mangoReaderSearchNormalized)"
            let url: URL
            if let remembered = pagination[key]?[normalizedQuery.page] {
                url = remembered
            } else if normalizedQuery.page == 1 {
                let root = try await fetchFeed(at: configuration.baseURL)
                if let searchLink = root.searchLink {
                    url = try searchURL(from: searchLink.href, query: normalizedQuery)
                } else {
                    let works = try ordered(
                        SourceRequestSupport.filtered(root.publications.map { $0.work(source: descriptor) }, query: normalizedQuery),
                        query: normalizedQuery
                    )
                    return SourcePage(items: works, totalCount: works.count)
                }
            } else {
                url = try paginatedURL(
                    configuration.baseURL,
                    query: normalizedQuery,
                    searchText: normalizedQuery.text
                )
            }

            let feed = try await fetchFeed(at: url)
            remember(feed: feed, key: key, page: normalizedQuery.page)
            let works = try ordered(
                SourceRequestSupport.filtered(feed.publications.map { $0.work(source: descriptor) }, query: normalizedQuery),
                query: normalizedQuery
            )
            return SourcePage(
                items: works,
                nextPage: feed.nextURL == nil ? nil : normalizedQuery.page + 1,
                totalCount: feed.totalCount
            )
        } catch {
            throw SourceRequestSupport.map(error)
        }
    }

    public func details(for remoteID: String) async throws -> Work {
        if let publication = publications[remoteID] {
            return publication.work(source: descriptor)
        }
        _ = try await browse(SourceQuery(pageSize: 100))
        guard let publication = publications[remoteID] else {
            throw SourceError.notFound
        }
        return publication.work(source: descriptor)
    }

    public func installments(for work: Work, page: Int) async throws -> SourcePage<Installment> {
        guard page == 1, let remoteID = work.remoteID else {
            return SourcePage(items: [])
        }
        if publications[remoteID] == nil {
            _ = try await details(for: remoteID)
        }
        let installment = publications[remoteID]?.installment(work: work)
        return SourcePage(items: installment.map { [$0] } ?? [], totalCount: installment == nil ? 0 : 1)
    }

    public func acquisitionURL(for installment: Installment) async throws -> URL {
        guard let url = installment.acquisitionURL else {
            throw SourceError.notFound
        }
        return url
    }

    private func fetchFeed(at url: URL) async throws -> OPDSFeed {
        let headers = try await SourceRequestSupport.headers(
            configuration: configuration,
            credentialLoader: credentialLoader,
            accepting: "application/opds+json, application/atom+xml;profile=opds-catalog, application/atom+xml, application/json;q=0.9"
        )
        let request = SourceRequestSupport.request(configuration: configuration, url: url, headers: headers)
        let response = try await httpClient.response(for: request)
        let feed = try OPDSParser.parse(data: response.data, baseURL: response.url, contentType: response.header("Content-Type"))
        for publication in feed.publications {
            let remoteID = publication.identifier.nilIfBlank ?? publication.acquisitionLink?.href.absoluteString ?? publication.title
            publications[remoteID] = publication
        }
        return feed
    }

    private func remember(feed: OPDSFeed, key: String, page: Int) {
        if let next = feed.nextURL {
            pagination[key, default: [:]][page + 1] = next
        }
    }

    private func pageURL(for key: String, query: SourceQuery, fallback: URL) -> URL {
        if let remembered = pagination[key]?[query.page] {
            return remembered
        }
        return (try? paginatedURL(fallback, query: query, searchText: nil)) ?? fallback
    }

    private func paginatedURL(_ baseURL: URL, query: SourceQuery, searchText: String?) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw SourceError.invalidURL
        }
        var items = components.queryItems ?? []
        if query.page > 1 {
            items.removeAll { $0.name == "page" || $0.name == "startPage" }
            items.append(URLQueryItem(name: "page", value: String(query.page)))
        }
        if let searchText {
            items.removeAll { $0.name == "q" || $0.name == "searchTerms" }
            items.append(URLQueryItem(name: "q", value: searchText))
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw SourceError.invalidURL }
        return url
    }

    private func searchURL(from templateURL: URL, query: SourceQuery) throws -> URL {
        let raw = templateURL.absoluteString
        let encoded = query.text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query.text
        var expanded = raw
            .replacingOccurrences(of: "{searchTerms}", with: encoded)
            .replacingOccurrences(of: "%7BsearchTerms%7D", with: encoded, options: .caseInsensitive)
            .replacingOccurrences(of: "{count}", with: String(query.pageSize))
            .replacingOccurrences(of: "%7Bcount%7D", with: String(query.pageSize), options: .caseInsensitive)
            .replacingOccurrences(of: "{startPage}", with: String(query.page))
            .replacingOccurrences(of: "%7BstartPage%7D", with: String(query.page), options: .caseInsensitive)
            .replacingOccurrences(of: "{startIndex}", with: String((query.page - 1) * query.pageSize))
            .replacingOccurrences(of: "%7BstartIndex%7D", with: String((query.page - 1) * query.pageSize), options: .caseInsensitive)
        if expanded.contains("{?searchTerms}") {
            expanded = expanded.replacingOccurrences(of: "{?searchTerms}", with: "?searchTerms=\(encoded)")
        }
        expanded = expanded.replacingOccurrences(
            of: "%7B?searchTerms%7D",
            with: "?searchTerms=\(encoded)",
            options: .caseInsensitive
        )
        if !expanded.contains("{") && expanded != raw {
            guard let result = URL(string: expanded) else { throw SourceError.invalidURL }
            return result
        }
        return try paginatedURL(templateURL, query: query, searchText: query.text)
    }

    private func ordered(_ works: [Work], query: SourceQuery) throws -> [Work] {
        let rawValue = try CompiledSourceFilterCatalog.shared.resolvedValue(
            key: OPDSFilterKey.order.rawValue,
            source: .opds,
            querySelections: query.filters,
            configurationSelections: configuration.options
        ) ?? OPDSCatalogOrder.feed.rawValue
        guard let order = OPDSCatalogOrder(rawValue: rawValue) else {
            throw SourceFilterValidationError.invalidValue(
                source: .opds,
                key: OPDSFilterKey.order.rawValue,
                title: "Current page order"
            )
        }
        return CompiledSourceFilterApplication.orderedOPDSPage(works, order: order)
    }
}

#endif
