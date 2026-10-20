import CryptoKit
import Foundation
import MangoReaderDomain

public struct SourceEndpointConfiguration: Codable, Hashable, Sendable {
    public var id: SourceID
    public var name: String
    public var kind: SourceKind
    public var baseURL: URL
    public var languageCodes: [String]
    public var credentialAccount: String?
    public var endpointAccess: EndpointAccess
    public var options: [String: String]

    public init(
        id: SourceID,
        name: String,
        kind: SourceKind,
        baseURL: URL,
        languageCodes: [String] = [],
        credentialAccount: String? = nil,
        endpointAccess: EndpointAccess = EndpointAccess(),
        options: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.languageCodes = languageCodes
        self.credentialAccount = credentialAccount
        self.endpointAccess = endpointAccess
        self.options = options
    }
}

public protocol SourceCapabilityDiscovering: Sendable {
    func discoverCapabilities() async throws -> Set<SourceCapability>
}

/// Builds request headers for source-owned publication downloads without
/// exposing Keychain implementation details to the download coordinator.
public struct SourceRequestAuthorizer: Sendable {
    public init() {}

    /// Server-specific credential exchange stays native; guests receive no secrets.
    public func resolvedServerCredential(_ credential: SourceCredential, kind: SourceKind,
        baseURL: URL, endpointAccess: EndpointAccess, httpClient: HTTPClient = HTTPClient()) async throws -> SourceCredential {
        guard kind == .kavita, case let .apiKey(_, value) = credential else { return credential }
        let url = try SourceRequestSupport.url(baseURL: baseURL, path: "api/Plugin/authenticate",
            queryItems: [URLQueryItem(name: "apiKey", value: value), URLQueryItem(name: "pluginName", value: "manko")])
        try EndpointPolicy().validate(url, access: endpointAccess)
        struct Token: Decodable, Sendable { let token: String }
        let token: Token
        do {
            token = try await httpClient.decode(from: HTTPRequest(url: url,
                headers: ["Accept": "application/json"], endpointAccess: endpointAccess,
                credentialOrigin: baseURL, usesConditionalCache: false))
        } catch HTTPClientError.notFound {
            let loginURL = try SourceRequestSupport.url(baseURL: baseURL, path: "api/Account/login")
            try EndpointPolicy().validate(loginURL, access: endpointAccess)
            // Current Kavita validates these fields before selecting API-key login.
            let body = try JSONEncoder().encode(["apiKey": value, "username": "manko", "password": "api-key"])
            token = try await httpClient.decode(from: HTTPRequest(url: loginURL, method: .post,
                headers: ["Accept": "application/json", "Content-Type": "application/json"], body: body,
                endpointAccess: endpointAccess, credentialOrigin: baseURL, usesConditionalCache: false))
        }
        guard !token.token.isEmpty, !token.token.contains("\n"), !token.token.contains("\r") else {
            throw SourceError.unauthorized
        }
        return .bearer(token: token.token)
    }

    public static func isSameOrigin(_ url: URL, as origin: URL) -> Bool {
        SourceCredentialOriginPolicy.isSameOrigin(url, as: origin)
    }

    public func headers(
        for configuration: SourceEndpointConfiguration,
        credentialLoader: (any SourceCredentialLoading)?,
        accepting: String = "application/epub+zip, application/pdf, application/vnd.comicbook+zip, application/zip, application/octet-stream;q=0.8"
    ) async throws -> [String: String] {
        try await SourceRequestSupport.headers(
            configuration: configuration,
            credentialLoader: credentialLoader,
            accepting: accepting
        )
    }
}

public enum SourceContentClassifier {
    public static func kind(from values: [String], fallback: ContentKind = .book) -> ContentKind {
        let joined = normalizedTokens(values).joined(separator: " ")
        if joined.contains("light novel") || joined.contains("web novel") || joined.contains("novel") || joined.contains("epub") {
            return .lightNovel
        }
        if joined.contains("manga") {
            return .manga
        }
        if joined.contains("comic") || joined.contains("cbz") || joined.contains("zip") {
            return .comic
        }
        return fallback
    }

    public static func format(mimeType: String?, href: URL?) -> PublicationFormat? {
        let mime = mimeType?.lowercased() ?? ""
        let pathExtension = href?.pathExtension.lowercased() ?? ""
        if mime.contains("epub") || pathExtension == "epub" {
            return .epub
        }
        if mime.contains("pdf") || pathExtension == "pdf" {
            return .pdf
        }
        if mime.contains("comicbook+zip") || mime.contains("cbz") || pathExtension == "cbz" || pathExtension == "zip" {
            return .cbz
        }
        return nil
    }

    private static func normalizedTokens(_ values: [String]) -> [String] {
        values
            .flatMap { $0.split(separator: ",").map(String.init) }
            .map {
                $0.lowercased()
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).subtracting(CharacterSet(charactersIn: "+")))
            }
            .filter { !$0.isEmpty }
    }
}

#if DEBUG
public struct CompiledSourceRegistry: Sendable {
    public static let shared = CompiledSourceRegistry()

    public let supportedKinds: Set<SourceKind> = [.opds, .komga, .kavita, .suwayomi]

    public init() {}

    public func supports(_ kind: SourceKind) -> Bool {
        supportedKinds.contains(kind)
    }

    public func makeSource(
        configuration: SourceEndpointConfiguration,
        httpClient: HTTPClient,
        credentialLoader: (any SourceCredentialLoading)? = nil
    ) throws -> any ContentSource {
        switch configuration.kind {
        case .opds:
            return OPDSSource(configuration: configuration, httpClient: httpClient, credentialLoader: credentialLoader)
        case .komga:
            return KomgaSource(configuration: configuration, httpClient: httpClient, credentialLoader: credentialLoader)
        case .kavita:
            return KavitaSource(configuration: configuration, httpClient: httpClient, credentialLoader: credentialLoader)
        case .suwayomi:
            return SuwayomiSource(configuration: configuration, httpClient: httpClient, credentialLoader: credentialLoader)
        case .local, .mangoReaderExtension:
            throw SourceError.unsupportedResponse
        }
    }
}

#endif

public actor SourceRegistry {
    private var sources: [SourceID: any ContentSource]

    public init() {
        self.sources = [:]
    }

    public init(sources: [any ContentSource]) async {
        var indexed: [SourceID: any ContentSource] = [:]
        for source in sources {
            indexed[await source.descriptor.id] = source
        }
        self.sources = indexed
    }

    public func register(_ source: any ContentSource) async {
        sources[await source.descriptor.id] = source
    }

    public func remove(id: SourceID) {
        sources.removeValue(forKey: id)
    }

    public func source(id: SourceID) -> (any ContentSource)? {
        sources[id]
    }

    public func descriptors() async -> [SourceDescriptor] {
        var result: [SourceDescriptor] = []
        result.reserveCapacity(sources.count)
        for source in sources.values {
            result.append(await source.descriptor)
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum SourceRequestSupport {
    static func headers(
        configuration: SourceEndpointConfiguration,
        credentialLoader: (any SourceCredentialLoading)?,
        accepting accept: String = "application/json"
    ) async throws -> [String: String] {
        let headers = [
            "Accept": accept,
            "User-Agent": "MangoReader/1",
        ]
        guard
            let account = configuration.credentialAccount,
            let credentialLoader,
            let credential = try await credentialLoader.credential(account: account)
        else {
            return headers
        }

        return try applying(credential: credential, to: headers)
    }

    static func applying(
        credential: SourceCredential,
        to originalHeaders: [String: String]
    ) throws -> [String: String] {
        var headers = originalHeaders
        switch credential {
        case let .basic(username, password):
            let value = Data("\(username):\(password)".utf8).base64EncodedString()
            headers["Authorization"] = "Basic \(value)"
        case let .bearer(token):
            guard isSafeHeaderValue(token) else {
                throw SourceError.transport("The bearer token is invalid.")
            }
            headers["Authorization"] = "Bearer \(token)"
        case let .apiKey(name, value):
            guard
                isSafeHeaderName(name),
                !crossOriginPreservedHeaderNames.contains(name.lowercased()),
                isSafeHeaderValue(value)
            else {
                throw SourceError.transport("The API key header name is invalid.")
            }
            headers[name] = value
        }
        return headers
    }

    /// API-key credentials must use a credential-specific field. These
    /// standard representation/cache fields are deliberately preserved on a
    /// cross-origin redirect, so accepting one as an API-key name would make
    /// it impossible to distinguish the secret from ordinary request metadata.
    private static let crossOriginPreservedHeaderNames: Set<String> = [
        "accept", "accept-charset", "accept-encoding", "accept-language",
        "cache-control", "content-type", "if-match", "if-modified-since",
        "if-none-match", "if-range", "if-unmodified-since", "pragma",
        "range", "user-agent",
    ]

    static func url(baseURL: URL, path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        var url = baseURL
        for component in path.split(separator: "/") where !component.isEmpty {
            url.appendPathComponent(String(component))
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SourceError.invalidURL
        }
        if !queryItems.isEmpty {
            components.queryItems = (components.queryItems ?? []) + queryItems
        }
        guard let result = components.url else {
            throw SourceError.invalidURL
        }
        return result
    }

    static func request(
        configuration: SourceEndpointConfiguration,
        url: URL,
        method: HTTPMethod = .get,
        headers: [String: String],
        body: Data? = nil,
        usesConditionalCache: Bool = true
    ) -> HTTPRequest {
        HTTPRequest(
            url: url,
            method: method,
            headers: headers,
            body: body,
            endpointAccess: configuration.endpointAccess,
            credentialOrigin: configuration.credentialAccount == nil ? nil : configuration.baseURL,
            cachePartition: configuration.credentialAccount,
            usesConditionalCache: usesConditionalCache
        )
    }

    static func filtered(_ works: [Work], query: SourceQuery) -> [Work] {
        works.filter { work in
            if !query.languageCodes.isEmpty {
                guard let language = work.languageCode, query.languageCodes.contains(language) else { return false }
            }
            guard query.kinds.isEmpty || query.kinds.contains(work.kind) else { return false }
            guard !query.text.isEmpty else { return true }
            let needle = query.text.mangoReaderSearchNormalized
            let haystack = ([work.title] + work.alternativeTitles + work.authors + work.tags)
                .joined(separator: " ")
                .mangoReaderSearchNormalized
            return haystack.contains(needle)
        }
    }

    static func map(_ error: Error) -> SourceError {
        if let sourceError = error as? SourceError {
            return sourceError
        }
        if error is CancellationError {
            return .cancelled
        }
        guard let error = error as? HTTPClientError else {
            return .transport(error.localizedDescription)
        }
        return switch error {
        case .invalidURL: .invalidURL
        case .unsupportedScheme, .insecurePublicEndpoint: .insecurePublicEndpoint
        case .cancelled: .cancelled
        case .unauthorized: .unauthorized
        case .forbidden: .forbidden
        case .notFound: .notFound
        case let .rateLimited(delay): .rateLimited(retryAfterSeconds: delay)
        case let .server(code, _), let .client(code): .server(statusCode: code)
        case .invalidResponse, .decoding: .unsupportedResponse
        default: .transport(error.localizedDescription)
        }
    }

    private static func isSafeHeaderValue(_ value: String) -> Bool {
        !value.contains("\n") && !value.contains("\r")
    }

    private static func isSafeHeaderName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        let allowedPunctuation = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~")
        return value.unicodeScalars.allSatisfy {
            (0x30 ... 0x39).contains($0.value) ||
                (0x41 ... 0x5A).contains($0.value) ||
                (0x61 ... 0x7A).contains($0.value) ||
                allowedPunctuation.contains($0)
        }
    }
}

public enum StableSourceIdentifier {
    public static func workID(sourceID: SourceID, remoteID: String) -> WorkID {
        WorkID(rawValue: uuid(for: "\(sourceID.rawValue)|\(remoteID)"))
    }

    public static func installmentID(sourceID: SourceID, remoteID: String) -> InstallmentID {
        InstallmentID(rawValue: uuid(for: "installment|\(sourceID.rawValue)|\(remoteID)"))
    }

    private static func uuid(for key: String) -> UUID {
        let bytes = SHA256.hash(data: Data(key.utf8))
        let hex = bytes.prefix(16).map { String(format: "%02x", $0) }.joined()
        let uuidString = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: uuidString) ?? UUID()
    }
}

extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
