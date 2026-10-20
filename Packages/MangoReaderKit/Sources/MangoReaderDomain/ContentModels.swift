import Foundation
import CryptoKit

public enum ContentKind: String, Codable, CaseIterable, Sendable {
    case manga
    case comic
    case lightNovel
    case book
}

public enum PublicationFormat: String, Codable, CaseIterable, Sendable {
    case remoteImageSequence
    case cbz
    case epub
    case pdf

    public var isTextPublication: Bool {
        self == .epub || self == .pdf
    }
}

public enum WorkStatus: String, Codable, CaseIterable, Sendable {
    case unknown
    case ongoing
    case completed
    case hiatus
    case cancelled
}

public enum WorkSearchFacetPresentation: String, Codable, CaseIterable, Sendable {
    case creator
    case tag
    case metadata
}

public struct WorkSearchFacet: Codable, Hashable, Sendable, Identifiable {
    public var fieldID: String
    public var value: String
    public var title: String
    public var groupTitle: String?
    public var presentation: WorkSearchFacetPresentation

    public var id: String { "\(fieldID)|\(value)" }

    public init(
        fieldID: String,
        value: String,
        title: String? = nil,
        groupTitle: String? = nil,
        presentation: WorkSearchFacetPresentation
    ) {
        self.fieldID = fieldID
        self.value = value
        self.title = title ?? value
        self.groupTitle = groupTitle
        self.presentation = presentation
    }
}

public struct Work: Codable, Hashable, Sendable, Identifiable {
    public var id: WorkID
    public var sourceID: SourceID
    public var remoteID: String?
    public var title: String
    public var readingMode: String?
    public var alternativeTitles: [String]
    public var authors: [String]
    public var summary: String
    public var latestChapterTitle: String?
    public var tags: [String]
    public var searchFacets: [WorkSearchFacet]
    public var languageCode: String?
    public var kind: ContentKind
    public var status: WorkStatus
    public var coverURL: URL?
    public var coverPreviewURL: URL?
    public var shareURL: URL?
    public var customCoverPath: String?
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: WorkID = WorkID(),
        sourceID: SourceID,
        remoteID: String? = nil,
        title: String,
        readingMode: String? = nil,
        alternativeTitles: [String] = [],
        authors: [String] = [],
        summary: String = "",
        latestChapterTitle: String? = nil,
        tags: [String] = [],
        searchFacets: [WorkSearchFacet] = [],
        languageCode: String? = nil,
        kind: ContentKind,
        status: WorkStatus = .unknown,
        coverURL: URL? = nil,
        coverPreviewURL: URL? = nil,
        shareURL: URL? = nil,
        customCoverPath: String? = nil,
        createdAt: Date = .now,
        modifiedAt: Date = .now
    ) {
        self.id = id
        self.sourceID = sourceID
        self.remoteID = remoteID
        self.title = title
        self.readingMode = readingMode
        self.alternativeTitles = alternativeTitles
        self.authors = authors
        self.summary = summary
        self.latestChapterTitle = latestChapterTitle
        self.tags = tags
        self.searchFacets = searchFacets
        self.languageCode = languageCode
        self.kind = kind
        self.status = status
        self.coverURL = coverURL
        self.coverPreviewURL = coverPreviewURL
        self.shareURL = shareURL
        self.customCoverPath = customCoverPath
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceID
        case remoteID
        case title
        case readingMode
        case alternativeTitles
        case authors
        case summary
        case latestChapterTitle
        case tags
        case searchFacets
        case languageCode
        case kind
        case status
        case coverURL
        case coverPreviewURL
        case shareURL
        case customCoverPath
        case createdAt
        case modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(WorkID.self, forKey: .id)
        sourceID = try container.decode(SourceID.self, forKey: .sourceID)
        remoteID = try container.decodeIfPresent(String.self, forKey: .remoteID)
        title = try container.decode(String.self, forKey: .title)
        readingMode = try container.decodeIfPresent(String.self, forKey: .readingMode)
        alternativeTitles = try container.decodeIfPresent([String].self, forKey: .alternativeTitles) ?? []
        authors = try container.decodeIfPresent([String].self, forKey: .authors) ?? []
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        latestChapterTitle = try container.decodeIfPresent(String.self, forKey: .latestChapterTitle)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        searchFacets = try container.decodeIfPresent([WorkSearchFacet].self, forKey: .searchFacets) ?? []
        languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode)
        kind = try container.decode(ContentKind.self, forKey: .kind)
        status = try container.decodeIfPresent(WorkStatus.self, forKey: .status) ?? .unknown
        coverURL = try container.decodeIfPresent(URL.self, forKey: .coverURL)
        coverPreviewURL = try container.decodeIfPresent(URL.self, forKey: .coverPreviewURL)
        shareURL = try container.decodeIfPresent(URL.self, forKey: .shareURL)
        customCoverPath = try container.decodeIfPresent(String.self, forKey: .customCoverPath)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
    }
}

public struct Installment: Codable, Hashable, Sendable, Identifiable {
    public var id: InstallmentID
    public var workID: WorkID
    public var remoteID: String?
    public var title: String
    public var scanlators: [String]?
    public var volume: Double?
    public var number: Double?
    public var publishedAt: Date?
    public var languageCode: String?
    public var format: PublicationFormat
    public var acquisitionURL: URL?
    public var pageCount: Int?

    public init(
        id: InstallmentID = InstallmentID(),
        workID: WorkID,
        remoteID: String? = nil,
        title: String,
        scanlators: [String]? = nil,
        volume: Double? = nil,
        number: Double? = nil,
        publishedAt: Date? = nil,
        languageCode: String? = nil,
        format: PublicationFormat,
        acquisitionURL: URL? = nil,
        pageCount: Int? = nil
    ) {
        self.id = id
        self.workID = workID
        self.remoteID = remoteID
        self.title = title
        self.scanlators = scanlators
        self.volume = volume
        self.number = number
        self.publishedAt = publishedAt
        self.languageCode = languageCode
        self.format = format
        self.acquisitionURL = acquisitionURL
        self.pageCount = pageCount
    }
}

public enum ReadingLocator: Codable, Hashable, Sendable {
    case image(page: Int, total: Int?, offset: Double)
    case publication(readiumJSON: Data)

    public var progression: Double? {
        switch self {
        case let .image(page, total, offset):
            guard let total, total > 0 else { return nil }
            return min(1, max(0, (Double(page) + offset) / Double(total)))
        case .publication:
            return nil
        }
    }
}

public struct ReadingProgress: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var workID: WorkID
    public var installmentID: InstallmentID
    public var locator: ReadingLocator
    public var currentProgression: Double
    public var highestProgression: Double
    public var resetAt: Date?
    public var modifiedAt: Date
    public var deviceID: String

    public init(
        id: UUID = UUID(),
        workID: WorkID,
        installmentID: InstallmentID,
        locator: ReadingLocator,
        currentProgression: Double,
        highestProgression: Double,
        modifiedAt: Date = .now,
        deviceID: String,
        resetAt: Date? = nil
    ) {
        self.id = id
        self.workID = workID
        self.installmentID = installmentID
        self.locator = locator
        self.currentProgression = min(1, max(0, currentProgression))
        self.highestProgression = min(1, max(0, highestProgression))
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
        self.resetAt = resetAt
    }

    /// An explicit unread reset has no position to restore in any reader format.
    public var resumeLocator: ReadingLocator? {
        resetAt != nil && currentProgression == 0 && highestProgression == 0 ? nil : locator
    }

    public func merging(_ other: Self) -> Self {
        precondition(id == other.id || (workID == other.workID && installmentID == other.installmentID))
        let latestReset = [resetAt, other.resetAt].compactMap { $0 }.max()
        if let latestReset {
            if modifiedAt < latestReset {
                var winner = other
                winner.resetAt = latestReset
                return winner
            }
            if other.modifiedAt < latestReset {
                var winner = self
                winner.resetAt = latestReset
                return winner
            }
        }
        var winner: Self
        if modifiedAt == other.modifiedAt {
            winner = deviceID >= other.deviceID ? self : other
        } else {
            winner = modifiedAt > other.modifiedAt ? self : other
        }
        winner.highestProgression = max(highestProgression, other.highestProgression)
        winner.resetAt = latestReset
        return winner
    }
}

/// Identity includes the library-owned parent, including source-migrated works.
public enum ExtensionChapterIdentity {
    public static func id(sourceID: SourceID, workID: WorkID, remoteID: String) -> InstallmentID {
        let data = try! JSONEncoder().encode(["extension-chapter-v2", sourceID.rawValue, workID.description, remoteID])
        return InstallmentID(rawValue: uuid(data))
    }
    public static func legacyID(sourceID: SourceID, remoteID: String) -> InstallmentID {
        InstallmentID(rawValue: uuid(Data("installment|\(sourceID.rawValue)|\(remoteID)".utf8)))
    }
    private static func uuid(_ data: Data) -> UUID {
        let bytes = Array(SHA256.hash(data: data).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}
