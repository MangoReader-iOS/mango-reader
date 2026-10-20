import Foundation
import MangoReaderDomain
import MangoReaderSources

/// A downloaded connector supplies remote metadata. Native code owns durable
/// identities, endpoint policy, credentials and publication transfers.
public actor MangoReaderConnectorSourceAdapter: ContentSource, SourceCapabilityDiscovering, SourceDiscoverSectionProviding {
    public typealias RuntimeFactory = @MainActor @Sendable () throws -> MangoReaderExtensionRuntime
    public let descriptor: SourceDescriptor
    let configuration: SourceEndpointConfiguration
    private let runtimeFactory: RuntimeFactory
    private let credentialLoader: (any SourceCredentialLoading)?
    private let imageClient: HTTPClient
    private var runtime: MangoReaderExtensionRuntime?
    private var initialization: Task<MangoReaderExtensionRuntime, Error>?
    private var initializationID: UUID?
    private var imageRequests: [UUID: Task<HTTPResponse, Error>] = [:]
    private var generation: UInt64 = 0

    public init(configuration: SourceEndpointConfiguration, credentialLoader: (any SourceCredentialLoading)? = nil,
        imageClient: HTTPClient = HTTPClient(), runtimeFactory: @escaping RuntimeFactory) {
        self.configuration = configuration
        self.credentialLoader = credentialLoader
        self.imageClient = imageClient
        self.runtimeFactory = runtimeFactory
        descriptor = SourceDescriptor(id: configuration.id, name: configuration.name,
            kind: configuration.kind, baseURL: configuration.baseURL,
            languageCodes: configuration.languageCodes,
            capabilities: configuration.kind == .suwayomi
                ? [.browse, .search, .filters, .authentication, .acquisition, .imageSequence]
                : [.browse, .search, .filters, .authentication, .acquisition])
    }

    public func discoverCapabilities() async throws -> Set<SourceCapability> {
        let runtime = try await activeRuntime()
        let capabilities = try await runtime.connector([SourceCapability].self, operation: "capabilities")
        return Set(capabilities).intersection(descriptor.capabilities)
    }

    public func browse(_ query: SourceQuery) async throws -> SourcePage<Work> {
        try await works(query, operation: "browse")
    }

    public func discoverSections() -> [SourceDiscoverSection] {
        [.init(id: "library", title: "Library", presentation: .latestGallery)]
    }

    public func discover(sectionID: String, query: SourceQuery) async throws -> SourcePage<Work> {
        guard sectionID == "library" else { throw SourceError.unsupportedResponse }
        return try await browse(query)
    }

    public func search(_ query: SourceQuery) async throws -> SourcePage<Work> {
        try await works(query, operation: "search")
    }

    private func works(_ query: SourceQuery, operation: String) async throws -> SourcePage<Work> {
        let query = try CompiledSourceFilterCatalog.shared.normalizedQuery(query, for: configuration.kind)
        let runtime = try await activeRuntime()
        let page = try await runtime.connector(SourcePage<ConnectorWork>.self, operation: operation,
            arguments: ["query": try json(query)])
        guard Set(page.items.map(\.remoteID)).count == page.items.count else { throw SourceError.unsupportedResponse }
        let works = try page.items.map(makeWork).filter {
            (query.kinds.isEmpty || query.kinds.contains($0.kind)) &&
            (query.languageCodes.isEmpty || $0.languageCode.map(query.languageCodes.contains) == true) &&
            (query.text.isEmpty || ([$0.title] + $0.authors + $0.tags).joined(separator: " ")
                .mangoReaderSearchNormalized.contains(query.text.mangoReaderSearchNormalized))
        }
        return SourcePage(items: works, nextPage: page.nextPage, totalCount: page.totalCount)
    }

    public func details(for remoteID: String) async throws -> Work {
        let runtime = try await activeRuntime()
        let work = try await runtime.connector(ConnectorWork.self, operation: "details",
            arguments: ["remoteID": .string(remoteID)])
        guard work.remoteID == remoteID else { throw SourceError.unsupportedResponse }
        return try makeWork(work)
    }

    public func installments(for work: Work, page: Int) async throws -> SourcePage<Installment> {
        guard work.sourceID == descriptor.id, let remoteID = work.remoteID else { throw SourceError.notFound }
        let runtime = try await activeRuntime()
        let result = try await runtime.connector(SourcePage<ConnectorInstallment>.self, operation: "installments",
            arguments: ["remoteID": .string(remoteID), "page": .number(Double(max(1, page)))])
        guard Set(result.items.map(\.remoteID)).count == result.items.count else { throw SourceError.unsupportedResponse }
        let installments = try result.items.map { item in
            guard !item.remoteID.isEmpty, item.format != .remoteImageSequence || configuration.kind == .suwayomi else { throw SourceError.unsupportedResponse }
            return Installment(id: StableSourceIdentifier.installmentID(sourceID: descriptor.id, remoteID: item.remoteID),
                workID: work.id, remoteID: item.remoteID, title: item.title, volume: item.volume, number: item.number,
                publishedAt: item.publishedAt.flatMap { ISO8601DateFormatter().date(from: $0) },
                languageCode: work.languageCode, format: item.format,
                acquisitionURL: try item.acquisitionURL.map(validatedURL), pageCount: item.pageCount)
        }
        return SourcePage(items: installments, nextPage: result.nextPage, totalCount: result.totalCount)
    }

    public func acquisitionURL(for installment: Installment) async throws -> URL {
        guard let remoteID = installment.remoteID,
              installment.id == StableSourceIdentifier.installmentID(sourceID: descriptor.id, remoteID: remoteID)
        else { throw SourceError.notFound }
        let runtime = try await activeRuntime()
        let value = try await runtime.connector(String.self, operation: "acquisition",
            arguments: ["remoteID": .string(remoteID)])
        return try validatedURL(value)
    }

    public func imagePages(for installment: Installment, query: RemoteImagePageQuery) async throws -> SourcePage<RemoteImagePageDescriptor> {
        guard configuration.kind == .suwayomi, installment.format == .remoteImageSequence,
              let remoteID = installment.remoteID,
              installment.id == StableSourceIdentifier.installmentID(sourceID: descriptor.id, remoteID: remoteID)
        else { throw SourceError.notFound }
        let runtime = try await activeRuntime()
        let result = try await runtime.connector(SourcePage<ConnectorImagePage>.self, operation: "imagePages",
            arguments: ["remoteID": .string(remoteID), "query": try json(query),
                "pageCount": installment.pageCount.map { .number(Double($0)) } ?? .null])
        guard result.items.count <= query.pageSize, (result.totalCount ?? 0) <= 50_000,
              Set(result.items.map(\.index)).count == result.items.count else { throw SourceError.unsupportedResponse }
        let pages = try result.items.map { item in
            guard item.index >= 0, item.index < 50_000 else { throw SourceError.unsupportedResponse }
            return RemoteImagePageDescriptor(id: "\(descriptor.id.rawValue):\(remoteID):\(item.index)",
                sourceID: descriptor.id, installmentID: installment.id, index: item.index,
                resourceURL: try validatedURL(item.resourceURL))
        }
        return SourcePage(items: pages, nextPage: result.nextPage, totalCount: result.totalCount)
    }

    public func coverImageContent(at url: URL) async throws -> RemoteImagePageContent {
        let page = RemoteImagePageDescriptor(id: "\(descriptor.id.rawValue):cover:0", sourceID: descriptor.id,
            installmentID: StableSourceIdentifier.installmentID(sourceID: descriptor.id, remoteID: "__cover__"), index: 0, resourceURL: try validatedURL(url.absoluteString))
        return try await imagePageContent(for: page)
    }

    public func imagePageContent(for page: RemoteImagePageDescriptor) async throws -> RemoteImagePageContent {
        try await streamImagePageContent(for: page, priority: .visible, onPartial: { _ in }, onProgress: { _ in })
    }

    public func streamImagePageContent(for page: RemoteImagePageDescriptor, priority: RemoteImageRequestPriority,
        onPartial: @escaping RemoteImagePageProgress,
        onProgress: @escaping RemoteImageDownloadProgressHandler) async throws -> RemoteImagePageContent {
        guard page.sourceID == descriptor.id, page.index >= 0, page.index < 50_000,
              page.id.hasPrefix(descriptor.id.rawValue + ":") else { throw SourceError.notFound }
        let requestGeneration = generation
        _ = try await activeRuntime()
        let url = try validatedURL(page.resourceURL.absoluteString)
        let headers = try await SourceRequestAuthorizer().headers(for: configuration,
            credentialLoader: credentialLoader, accepting: "image/*")
        guard generation == requestGeneration else { throw CancellationError() }
        try Task.checkCancellation()
        let requestID = UUID()
        let client = imageClient
        let access = configuration.endpointAccess
        let origin = configuration.baseURL
        let partition = configuration.credentialAccount
        let task = Task {
            try await client.response(for: HTTPRequest(url: url, headers: headers,
                endpointAccess: access, credentialOrigin: origin,
                cachePartition: partition, usesConditionalCache: false,
                networkPolicy: ExtensionNetworkPolicy(hosts: [], serverOrigin: origin),
                maximumResponseBytes: 128 * 1_024 * 1_024), onProgress: onProgress)
        }
        imageRequests[requestID] = task
        defer { imageRequests[requestID] = nil }
        let response = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        guard !response.data.isEmpty, response.data.count <= 128 * 1_024 * 1_024 else {
            throw SourceError.resourceLimitExceeded("the image page is too large")
        }
        let type = response.header("Content-Type")?.split(separator: ";").first.map(String.init)?.lowercased()
        guard type == nil || type?.hasPrefix("image/") == true || type == "application/octet-stream" else {
            throw SourceError.unsupportedResponse
        }
        return RemoteImagePageContent(data: response.data, mediaType: type)
    }

    private func makeWork(_ value: ConnectorWork) throws -> Work {
        guard !value.remoteID.isEmpty else { throw SourceError.unsupportedResponse }
        return Work(id: StableSourceIdentifier.workID(sourceID: descriptor.id, remoteID: value.remoteID),
            sourceID: descriptor.id, remoteID: value.remoteID, title: value.title,
            alternativeTitles: value.alternativeTitles ?? [], authors: value.authors, summary: value.summary, tags: value.tags,
            languageCode: value.languageCode, kind: value.kind, status: value.status,
            coverURL: try value.coverURL.map(validatedURL))
    }

    private func validatedURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), SourceRequestAuthorizer.isSameOrigin(url, as: configuration.baseURL)
        else { throw SourceError.invalidURL }
        try EndpointPolicy().validate(url, access: configuration.endpointAccess)
        return url
    }

    private func json<Value: Encodable>(_ value: Value) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    private func activeRuntime() async throws -> MangoReaderExtensionRuntime {
        if let runtime, await runtime.isValid { return runtime }
        if let initialization, let initializationID {
            return try await finishInitialization(initialization, id: initializationID)
        }
        let id = UUID()
        let factory = runtimeFactory
        let task = Task { @MainActor in
            let runtime = try factory()
            do {
                try await runtime.initialize()
                return runtime
            } catch {
                runtime.invalidate()
                throw error
            }
        }
        initialization = task
        initializationID = id
        return try await finishInitialization(task, id: id)
    }

    private func finishInitialization(_ task: Task<MangoReaderExtensionRuntime, Error>, id: UUID) async throws -> MangoReaderExtensionRuntime {
        do {
            let created = try await task.value
            if let runtime, runtime === created { return created }
            guard initializationID == id else { await created.invalidate(); throw CancellationError() }
            runtime = created
            initialization = nil
            initializationID = nil
            return created
        } catch {
            if initializationID == id { initialization = nil; initializationID = nil }
            throw error
        }
    }

    func resetRuntime() async {
        generation &+= 1
        for task in imageRequests.values { task.cancel() }
        imageRequests.removeAll()
        initialization?.cancel()
        initialization = nil
        initializationID = nil
        if let runtime { await runtime.invalidate() }
        runtime = nil
    }
}

private struct ConnectorWork: Codable, Hashable, Sendable {
    var remoteID: String
    var title: String
    var authors: [String]
    var summary: String
    var tags: [String]
    var languageCode: String?
    var kind: ContentKind
    var status: WorkStatus
    var coverURL: String?
    var alternativeTitles: [String]?
}

private struct ConnectorInstallment: Codable, Hashable, Sendable {
    var remoteID: String
    var title: String
    var volume: Double?
    var number: Double?
    var publishedAt: String?
    var format: PublicationFormat
    var acquisitionURL: String?
    var pageCount: Int?
}

private struct ConnectorImagePage: Codable, Hashable, Sendable {
    var index: Int
    var resourceURL: String
}
