import Foundation
import MankoDomain

public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

public enum MankoExtensionRuntimeError: Error, Equatable, Sendable, LocalizedError {
    case sourceUnavailable
    case invalidPackage
    case initializationFailed(String)
    case operationFailed(String)
    case operationTimedOut
    case executionBudgetExceeded
    case heartbeatLost
    case runtimeTerminated
    case undeclaredHost(String)
    case responseTooLarge
    case webExecutionDenied
    case webExecutionTimedOut
    case webExecutionResultTooLarge
    case cloudflareHandoff(CloudflareChallengeContext)

    public var errorDescription: String? {
        switch self {
        case .sourceUnavailable: "The Manko extension is not available."
        case .invalidPackage: "The Manko extension script could not be loaded."
        case let .initializationFailed(message): "The Manko source could not initialize: \(message)"
        case let .operationFailed(message): message
        case .operationTimedOut: "The Manko source exceeded the operation time limit."
        case .executionBudgetExceeded: "The Manko source exceeded its processing limit. Try updating the source."
        case .heartbeatLost: "The Manko source stopped responding and its runtime was replaced."
        case .runtimeTerminated: "The Manko source runtime ended unexpectedly."
        case let .undeclaredHost(host): "The source tried to contact undeclared host \(host)."
        case .responseTooLarge: "The source response exceeded 16 MiB."
        case .webExecutionDenied: "The source does not have web-execution permission."
        case .webExecutionTimedOut: "The source exceeded the 30-second web-execution limit."
        case .webExecutionResultTooLarge: "The source web-execution result exceeded 24 MiB."
        case .cloudflareHandoff: "This source needs a visible Cloudflare verification handoff."
        }
    }
}

public struct MankoPagedValue<Element: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var items: [Element]
    public var metadata: JSONValue?
}

public struct MankoSearchItem: Codable, Hashable, Sendable {
    public var workId: String
    public var title: String
    public var subtitle: String?
    public var imageUrl: String
    public var previewImageUrl: String? = nil
    public var mediaKind: String?
}

public struct MankoWorkInfo: Codable, Hashable, Sendable {
    public var readingMode: String? = nil
    public var thumbnailUrl: String
    public var synopsis: String
    public var primaryTitle: String
    public var secondaryTitles: [String]
    public var status: String?
    public var artist: String?
    public var author: String?
    public var shareUrl: String?
    public var mediaKind: String?
    public var searchFacets: [WorkSearchFacet]?
}

public struct MankoSourceWork: Codable, Hashable, Sendable {
    public var workId: String
    public var workInfo: MankoWorkInfo
}

public struct MankoInstallment: Codable, Hashable, Sendable {
    public var scanlators: [String]? = nil
    public var installmentId: String
    public var langCode: String
    public var number: Double
    public var title: String?
    public var volume: Double?
    public var publishDate: String?
    public var workId: String?
    public var format: String?
}

public struct MankoPublicationContent: Codable, Hashable, Sendable {
    public var id: String
    public var workId: String
    public var mimeType: String
    public var text: String

    public init(id: String, workId: String, mimeType: String, text: String) {
        self.id = id
        self.workId = workId
        self.mimeType = mimeType
        self.text = text
    }
}

public struct MankoImagePageList: Codable, Hashable, Sendable {
    public var id: String
    public var workId: String
    public var pages: [String]
}

public struct MankoResource: Codable, Hashable, Sendable {
    public var dataBase64: String
    public var mimeType: String?
}

public struct MankoDiscoverSection: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var type: Int
    public var presentation: SourceDiscoverSectionPresentation?
}

public struct MankoDiscoverItem: Codable, Hashable, Sendable {
    public var type: String
    public var workId: String?
    public var imageUrl: String?
    public var previewImageUrl: String?
    public var title: String?
    public var subtitle: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case workId
        case imageUrl
        case previewImageUrl
        case title
        case subtitle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "work"
        workId = try container.decodeIfPresent(String.self, forKey: .workId)
        imageUrl = try container.decodeIfPresent(String.self, forKey: .imageUrl)
        previewImageUrl = try container.decodeIfPresent(String.self, forKey: .previewImageUrl)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(workId, forKey: .workId)
        try container.encodeIfPresent(imageUrl, forKey: .imageUrl)
        try container.encodeIfPresent(previewImageUrl, forKey: .previewImageUrl)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
    }
}

struct MankoInvocationEnvelope: Decodable {
    var ok: Bool
    var value: JSONValue?
    var error: MankoInvocationError?
}

struct MankoInvocationError: Decodable {
    var code: String?
    var name: String?
    var message: String?
    var type: String?
    var url: String?
    var host: String?
    var stack: String?

    private enum CodingKeys: String, CodingKey {
        case code
        case name
        case message
        case type
        case url
        case host
        case stack
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try Self.decodeBoundedString(from: container, forKey: .code, maximumBytes: 128)
        name = try Self.decodeBoundedString(from: container, forKey: .name, maximumBytes: 128)
        message = try Self.decodeBoundedString(from: container, forKey: .message, maximumBytes: 2 * 1_024)
        type = try Self.decodeBoundedString(from: container, forKey: .type, maximumBytes: 128)
        url = try Self.decodeBoundedString(from: container, forKey: .url, maximumBytes: 2 * 1_024)
        host = try Self.decodeBoundedString(from: container, forKey: .host, maximumBytes: 128)
        stack = try Self.decodeBoundedString(from: container, forKey: .stack, maximumBytes: 4 * 1_024)
    }

    private static func decodeBoundedString(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        maximumBytes: Int
    ) throws -> String? {
        guard let value = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return MankoRuntimeText.boundedUTF8(value, maximumBytes: maximumBytes)
    }
}

enum MankoRuntimeText {
    static func boundedUTF8(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var scalars = String.UnicodeScalarView()
        var byteCount = 0
        for scalar in value.unicodeScalars {
            let count = scalar.utf8.count
            guard byteCount + count <= maximumBytes else { break }
            scalars.append(scalar)
            byteCount += count
        }
        return String(scalars)
    }
}

/// Optional descriptor; the volume body remains in the native streaming transport.
public struct MankoPublicationStream: Codable, Hashable, Sendable {
    public var id: String
    public var workId: String
    public var url: String
    public var headers: [String: String]
}
