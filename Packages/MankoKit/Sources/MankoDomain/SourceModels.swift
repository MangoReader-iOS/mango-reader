import Foundation

public enum SourceKind: String, Codable, CaseIterable, Sendable {
    case local
    case opds
    case komga
    case kavita
    case suwayomi
    case mankoExtension

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        // Decode the original persisted spelling without changing source IDs
        // or the storage/credential namespaces associated with those IDs.
        if value == "mangaReaderExtension" {
            self = .mankoExtension
        } else if let kind = Self(rawValue: value) {
            self = kind
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported source kind."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum SourceCapability: String, Codable, CaseIterable, Sendable {
    case browse
    case search
    case filters
    case authentication
    case acquisition
    case imageSequence
    case progressSync
    case updates
    case discover
    case managedCollections
}

/// Opaque pagination state returned by a source. Compiled adapters can keep
/// using page numbers while downloaded extensions preserve service cursors.
public struct SourceCursor: Codable, Hashable, Sendable {
    public var value: String
    public var metadata: [String: String]

    public init(value: String, metadata: [String: String] = [:]) {
        self.value = value
        self.metadata = metadata
    }
}

public struct SourceDescriptor: Codable, Hashable, Sendable, Identifiable {
    public var id: SourceID
    public var name: String
    public var kind: SourceKind
    public var baseURL: URL?
    public var languageCodes: [String]
    public var capabilities: Set<SourceCapability>
    public var isEnabled: Bool

    public init(id: SourceID, name: String, kind: SourceKind, baseURL: URL? = nil, languageCodes: [String] = [], capabilities: Set<SourceCapability> = [], isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.languageCodes = languageCodes
        self.capabilities = capabilities
        self.isEnabled = isEnabled
    }
}

public enum SourceSearchPolarity: String, Codable, CaseIterable, Sendable {
    case include
    case exclude
}

public struct SourceSearchSelection: Codable, Hashable, Sendable, Identifiable {
    public var fieldID: String
    public var value: String
    public var title: String
    public var polarity: SourceSearchPolarity

    public var id: String {
        "\(fieldID)|\(polarity.rawValue)|\(value)"
    }

    public init(
        fieldID: String,
        value: String,
        title: String? = nil,
        polarity: SourceSearchPolarity = .include
    ) {
        self.fieldID = fieldID
        self.value = value
        self.title = title ?? value
        self.polarity = polarity
    }
}

public struct SourceQuery: Codable, Hashable, Sendable {
    public var text: String
    public var page: Int
    public var pageSize: Int
    public var languageCodes: Set<String>
    public var kinds: Set<ContentKind>
    public var filters: [String: String]
    public var searchSelections: [SourceSearchSelection]
    public var sortID: String?
    public var cursor: SourceCursor?

    public init(
        text: String = "",
        page: Int = 1,
        pageSize: Int = 40,
        languageCodes: Set<String> = [],
        kinds: Set<ContentKind> = [],
        filters: [String: String] = [:],
        searchSelections: [SourceSearchSelection] = [],
        sortID: String? = nil,
        cursor: SourceCursor? = nil
    ) {
        self.text = text
        self.page = max(1, page)
        self.pageSize = max(1, pageSize)
        self.languageCodes = languageCodes
        self.kinds = kinds
        self.filters = filters
        self.searchSelections = searchSelections
        self.sortID = sortID
        self.cursor = cursor
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case page
        case pageSize
        case languageCodes
        case kinds
        case filters
        case searchSelections
        case sortID
        case cursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        page = max(1, try container.decodeIfPresent(Int.self, forKey: .page) ?? 1)
        pageSize = max(1, try container.decodeIfPresent(Int.self, forKey: .pageSize) ?? 40)
        languageCodes = try container.decodeIfPresent(Set<String>.self, forKey: .languageCodes) ?? []
        kinds = try container.decodeIfPresent(Set<ContentKind>.self, forKey: .kinds) ?? []
        filters = try container.decodeIfPresent([String: String].self, forKey: .filters) ?? [:]
        searchSelections = try container.decodeIfPresent(
            [SourceSearchSelection].self,
            forKey: .searchSelections
        ) ?? []
        sortID = try container.decodeIfPresent(String.self, forKey: .sortID)
        cursor = try container.decodeIfPresent(SourceCursor.self, forKey: .cursor)
    }
}

public struct SourcePage<Element: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var items: [Element]
    public var nextPage: Int?
    public var totalCount: Int?
    public var nextCursor: SourceCursor?

    public init(items: [Element], nextPage: Int? = nil, totalCount: Int? = nil, nextCursor: SourceCursor? = nil) {
        self.items = items
        self.nextPage = nextPage
        self.totalCount = totalCount
        self.nextCursor = nextCursor
    }
}

/// A bounded request for one slice of a remote image sequence.
///
/// Sources may expose thousands of pages across long installments, so callers
/// never receive an implicitly unbounded collection. Page numbering is
/// one-based while page descriptor indices are zero-based.
public struct RemoteImagePageQuery: Codable, Hashable, Sendable {
    public var page: Int
    public var pageSize: Int

    public init(page: Int = 1, pageSize: Int = 100) {
        self.page = min(1_000_000, max(1, page))
        self.pageSize = min(200, max(1, pageSize))
    }
}

/// Public, non-secret identity for a single remotely served image page.
///
/// Credentials and request headers are deliberately absent. Consumers must
/// pass the descriptor back to its `RemoteImagePageLoading` source, which is
/// responsible for enforcing endpoint and credential-origin policy.
public struct RemoteImagePageDescriptor: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var sourceID: SourceID
    public var installmentID: InstallmentID
    public var index: Int
    public var resourceURL: URL

    public init(
        id: String,
        sourceID: SourceID,
        installmentID: InstallmentID,
        index: Int,
        resourceURL: URL
    ) {
        self.id = id
        self.sourceID = sourceID
        self.installmentID = installmentID
        self.index = max(0, index)
        self.resourceURL = resourceURL
    }
}

public struct RemoteImagePageContent: Hashable, Sendable {
    public var data: Data
    public var mediaType: String?

    public init(data: Data, mediaType: String? = nil) {
        self.data = data
        self.mediaType = mediaType
    }
}

public enum SourceCredential: Codable, Hashable, Sendable {
    case basic(username: String, password: String)
    case bearer(token: String)
    case apiKey(name: String, value: String)
}

public enum SourceError: Error, Codable, Hashable, Sendable, LocalizedError {
    case invalidURL
    case insecurePublicEndpoint
    case unsafeResourceURL
    case unauthorized
    case forbidden
    case notFound
    case rateLimited(retryAfterSeconds: Double?)
    case resourceLimitExceeded(String)
    case cancelled
    case unsupportedResponse
    case server(statusCode: Int)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The source address is invalid."
        case .insecurePublicEndpoint: "Public sources must use HTTPS."
        case .unsafeResourceURL: "The source returned a publication resource outside its configured origin."
        case .unauthorized: "Sign in to this source and try again."
        case .forbidden: "This source denied access."
        case .notFound: "The requested publication was not found."
        case let .rateLimited(seconds): seconds.map { "Try again in \(Int($0)) seconds." } ?? "The source is temporarily rate limited."
        case let .resourceLimitExceeded(reason): "The source resource exceeds a safety limit: \(reason)"
        case .cancelled: "The source request was cancelled."
        case .unsupportedResponse: "The source returned an unsupported response."
        case let .server(statusCode): "The source returned HTTP \(statusCode)."
        case let .transport(message): message
        }
    }
}
