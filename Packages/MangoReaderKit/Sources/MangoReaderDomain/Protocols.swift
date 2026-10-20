import Foundation

public enum RemoteImageRequestPriority: Int, Comparable, Sendable {
    case cover = 0
    case prefetch = 1
    case visible = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Declared in the actor-neutral domain module so app targets with default
/// MainActor isolation use exactly the same callback type in their witnesses.
public typealias RemoteImagePageProgress = @Sendable (RemoteImagePageContent) async -> Void

/// Download byte counts are separate from partial image data and decode progress.
public struct RemoteImageDownloadProgress: Hashable, Sendable {
    public let receivedBytes: Int64
    public let expectedBytes: Int64?

    public init(receivedBytes: Int64, expectedBytes: Int64?) {
        self.receivedBytes = max(0, receivedBytes)
        self.expectedBytes = expectedBytes.flatMap { $0 > 0 ? $0 : nil }
    }

    public var fractionCompleted: Double? {
        guard let expectedBytes, receivedBytes <= expectedBytes else { return nil }
        return Double(receivedBytes) / Double(expectedBytes)
    }
}

public typealias RemoteImageDownloadProgressHandler = @Sendable (RemoteImageDownloadProgress) async -> Void

public protocol RemoteImagePageLoading: Sendable {
    func imagePageContent(for page: RemoteImagePageDescriptor) async throws -> RemoteImagePageContent
    func imagePageContent(for page: RemoteImagePageDescriptor, priority: RemoteImageRequestPriority) async throws -> RemoteImagePageContent
    func setImagePagePriority(for page: RemoteImagePageDescriptor, priority: RemoteImageRequestPriority) async
    func streamImagePageContent(for page: RemoteImagePageDescriptor, priority: RemoteImageRequestPriority,
        onPartial: @escaping RemoteImagePageProgress) async throws -> RemoteImagePageContent
    func streamImagePageContent(for page: RemoteImagePageDescriptor, priority: RemoteImageRequestPriority,
        onPartial: @escaping RemoteImagePageProgress,
        onProgress: @escaping RemoteImageDownloadProgressHandler) async throws -> RemoteImagePageContent
}

public extension RemoteImagePageLoading {
    func streamImagePageContent(for page: RemoteImagePageDescriptor, priority: RemoteImageRequestPriority,
        onPartial: @escaping RemoteImagePageProgress,
        onProgress: @escaping RemoteImageDownloadProgressHandler) async throws -> RemoteImagePageContent {
        try await streamImagePageContent(for: page, priority: priority, onPartial: onPartial)
    }

    func streamImagePageContent(for page: RemoteImagePageDescriptor, priority: RemoteImageRequestPriority,
        onPartial: @escaping RemoteImagePageProgress) async throws -> RemoteImagePageContent {
        try await imagePageContent(for: page, priority: priority)
    }
    func imagePageContent(for page: RemoteImagePageDescriptor, priority: RemoteImageRequestPriority) async throws -> RemoteImagePageContent {
        try await imagePageContent(for: page)
    }
    func setImagePagePriority(for page: RemoteImagePageDescriptor, priority: RemoteImageRequestPriority) async {}
}

public protocol ContentSource: RemoteImagePageLoading, Sendable {
    var descriptor: SourceDescriptor { get async }
    func browse(_ query: SourceQuery) async throws -> SourcePage<Work>
    func search(_ query: SourceQuery) async throws -> SourcePage<Work>
    func details(for remoteID: String) async throws -> Work
    func installments(for work: Work, page: Int) async throws -> SourcePage<Installment>
    func acquisitionURL(for installment: Installment) async throws -> URL
    func imagePages(
        for installment: Installment,
        query: RemoteImagePageQuery
    ) async throws -> SourcePage<RemoteImagePageDescriptor>
}

public extension ContentSource {
    func imagePages(
        for _: Installment,
        query _: RemoteImagePageQuery
    ) async throws -> SourcePage<RemoteImagePageDescriptor> {
        throw SourceError.unsupportedResponse
    }

    func imagePageContent(for _: RemoteImagePageDescriptor) async throws -> RemoteImagePageContent {
        throw SourceError.unsupportedResponse
    }
}

public struct ReaderSessionDescriptor: Codable, Hashable, Sendable {
    public var work: Work
    public var installment: Installment
    public var fileURL: URL?
    public var initialLocator: ReadingLocator?
    public var incognito: Bool

    public init(work: Work, installment: Installment, fileURL: URL? = nil, initialLocator: ReadingLocator? = nil, incognito: Bool = false) {
        self.work = work
        self.installment = installment
        self.fileURL = fileURL
        self.initialLocator = initialLocator
        self.incognito = incognito
    }
}

public protocol ReaderEngine: Sendable {
    var supportedFormats: Set<PublicationFormat> { get }
    func validate(_ session: ReaderSessionDescriptor) async throws
}

public enum PublicationProtection: String, Codable, Sendable {
    case none
    case readiumLCP
    case adobeDRM
    case passwordProtectedPDF
    case unknown
}

public protocol PublicationProtectionAdapter: Sendable {
    var protection: PublicationProtection { get }
    func canOpen(url: URL) async -> Bool
}

public struct TrackerMatch: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var coverURL: URL?
    public var mediaKind: ContentKind

    public init(id: String, title: String, coverURL: URL? = nil, mediaKind: ContentKind) {
        self.id = id
        self.title = title
        self.coverURL = coverURL
        self.mediaKind = mediaKind
    }
}

public struct TrackerProgress: Codable, Hashable, Sendable {
    public var trackerID: TrackerID
    public var remoteWorkID: String
    public var chapter: Double?
    public var volume: Double?
    public var status: TrackerReadingStatus?
    public var score: Double?
    public var modifiedAt: Date
    public var startDate: TrackerDate?
    public var finishDate: TrackerDate?
    public var totalChapters: Int?
    public var totalVolumes: Int?
    public var dateUpdates: TrackerDateUpdates?
    public var fieldsToUpdate: Set<TrackerSyncField>?

    public init(trackerID: TrackerID, remoteWorkID: String, chapter: Double? = nil, volume: Double? = nil, status: TrackerReadingStatus? = nil, score: Double? = nil, modifiedAt: Date = .now, startDate: TrackerDate? = nil, finishDate: TrackerDate? = nil, totalChapters: Int? = nil, totalVolumes: Int? = nil, dateUpdates: TrackerDateUpdates? = nil, fieldsToUpdate: Set<TrackerSyncField>? = nil) {
        self.trackerID = trackerID
        self.remoteWorkID = remoteWorkID
        self.chapter = chapter
        self.volume = volume
        self.status = status
        self.score = score
        self.modifiedAt = modifiedAt
        self.startDate = startDate
        self.finishDate = finishDate
        self.totalChapters = totalChapters
        self.totalVolumes = totalVolumes
        self.dateUpdates = dateUpdates
        self.fieldsToUpdate = fieldsToUpdate
    }

    private enum CodingKeys: String, CodingKey {
        case trackerID, remoteWorkID, chapter, volume, status, score, modifiedAt
        case startDate, finishDate, totalChapters, totalVolumes, dateUpdates, fieldsToUpdate
    }

    /// Legacy payloads omitted nil values; only an explicit field mask requests clears.
    public var updateFields: Set<TrackerSyncField> {
        if let fieldsToUpdate { return fieldsToUpdate }
        var fields = dateUpdates?.fields ?? []
        if chapter != nil { fields.insert(.chapter) }
        if volume != nil { fields.insert(.volume) }
        if status != nil { fields.insert(.status) }
        if score != nil { fields.insert(.rating) }
        return fields
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(trackerID, forKey: .trackerID)
        try container.encode(remoteWorkID, forKey: .remoteWorkID)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        if fieldsToUpdate?.contains(.chapter) != false { try container.encodeIfPresent(chapter, forKey: .chapter) }
        if fieldsToUpdate?.contains(.volume) != false { try container.encodeIfPresent(volume, forKey: .volume) }
        if fieldsToUpdate?.contains(.status) != false { try container.encodeIfPresent(status, forKey: .status) }
        if fieldsToUpdate?.contains(.rating) == true {
            try container.encode(score, forKey: .score)
        } else if fieldsToUpdate == nil {
            try container.encodeIfPresent(score, forKey: .score)
        }
        try container.encodeIfPresent(startDate, forKey: .startDate)
        try container.encodeIfPresent(finishDate, forKey: .finishDate)
        try container.encodeIfPresent(totalChapters, forKey: .totalChapters)
        try container.encodeIfPresent(totalVolumes, forKey: .totalVolumes)
        try container.encodeIfPresent(dateUpdates, forKey: .dateUpdates)
        try container.encodeIfPresent(fieldsToUpdate, forKey: .fieldsToUpdate)
    }
}

public protocol TrackerProvider: Sendable {
    var id: TrackerID { get }
    var displayName: String { get }
    func search(title: String, kind: ContentKind) async throws -> [TrackerMatch]
    func progress(remoteWorkID: String) async throws -> TrackerProgress?
    func progressBatch(remoteWorkIDs: [String]) async throws -> [String: TrackerProgress]
    func update(_ progress: TrackerProgress) async throws
    func trackingCapabilities() async throws -> TrackerCapabilities
}

public extension TrackerProvider {
    func trackingCapabilities() async throws -> TrackerCapabilities { .init() }
    /// Extension API 1.0/1.1 providers inherit this bounded fallback. API 1.2
    /// providers can replace it with one native batch snapshot operation.
    func progressBatch(remoteWorkIDs: [String]) async throws -> [String: TrackerProgress] {
        var result: [String: TrackerProgress] = [:]
        for remoteWorkID in remoteWorkIDs.prefix(50) {
            try Task.checkCancellation()
            if let progress = try await progress(remoteWorkID: remoteWorkID) {
                result[remoteWorkID] = progress
            }
        }
        return result
    }
}

public protocol LibraryRepository: Sendable {
    func library(sort: LibrarySort) async throws -> [Work]
    func work(id: WorkID) async throws -> Work?
    func save(work: Work, entry: LibraryEntry) async throws
    func remove(workID: WorkID, deviceID: String) async throws
    func search(_ query: String, limit: Int) async throws -> [Work]
    func progress(workID: WorkID) async throws -> ReadingProgress?
    func save(progress: ReadingProgress) async throws
    func sessions(limit: Int) async throws -> [ReadingSession]
}

public protocol SyncChangeStore: Sendable {
    func pendingRecordIDs(limit: Int) async throws -> [String]
    func markUploaded(recordIDs: [String]) async throws
    func applyRemoteChanges(_ changes: [Data]) async throws
}
