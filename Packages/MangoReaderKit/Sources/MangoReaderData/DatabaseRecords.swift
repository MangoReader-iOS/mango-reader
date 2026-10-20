import Foundation
import GRDB
import MangoReaderDomain

public enum MangoReaderDataError: Error, Equatable, Sendable, LocalizedError {
    case inconsistentIdentifiers
    case emptyBulkMetadataSelection
    case emptySourceMigrationBatch
    case sourceMigrationBatchTooLarge(maximum: Int)
    case duplicateSourceMigrationWork
    case missingSourceMigrationWork
    case staleSourceMigrationPreview
    case invalidSourceMigration
    case invalidImportedOriginalReference
    case invalidSyncedAppSettings
    case missingImportedOriginalRelationship
    case unsafeManagedFileURL
    case invalidRecord(table: String, id: String)
    case unsupportedBackupVersion(Int)
    case corruptBackup(String)
    case stagedRestoreMissing
    case databaseRestoreFailed(String)

    public var errorDescription: String? {
        switch self {
        case .inconsistentIdentifiers:
            "The related Mango Reader records use inconsistent identifiers."
        case .emptyBulkMetadataSelection:
            "Choose at least one title to edit."
        case .emptySourceMigrationBatch:
            "Choose at least one title to migrate."
        case let .sourceMigrationBatchTooLarge(maximum):
            "Migrate no more than \(maximum) titles at once."
        case .duplicateSourceMigrationWork:
            "The source migration contains a duplicate title."
        case .missingSourceMigrationWork:
            "A title in the source migration is no longer in the library."
        case .staleSourceMigrationPreview:
            "A title changed after the source migration was reviewed. Preview the migration again."
        case .invalidSourceMigration:
            "The source migration contains invalid title or installment data."
        case .invalidImportedOriginalReference:
            "The imported-original cloud reference is invalid."
        case .invalidSyncedAppSettings:
            "The synchronized app settings record is invalid."
        case .missingImportedOriginalRelationship:
            "The imported-original reference does not match a local library installment."
        case .unsafeManagedFileURL:
            "The imported-original file URL is outside Mango Reader's managed file layout."
        case let .invalidRecord(table, id):
            "The \(table) record \(id) contains invalid data."
        case let .unsupportedBackupVersion(version):
            "Backup format version \(version) is not supported."
        case let .corruptBackup(reason):
            "The backup is invalid: \(reason)"
        case .stagedRestoreMissing:
            "The staged backup restore is no longer available."
        case let .databaseRestoreFailed(reason):
            "The database restore failed: \(reason)"
        }
    }
}

enum DataCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

struct WorkRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "works"

    var id: String
    var sourceID: String
    var remoteID: String?
    var title: String
    var readingMode: String?
    var alternativeTitles: Data
    var authors: Data
    var summary: String
    var tags: Data
    var searchFacets: Data
    var normalizedTitle: String
    var normalizedAlternativeTitles: String
    var normalizedAuthors: String
    var normalizedSummary: String
    var normalizedTags: String
    var languageCode: String?
    var kind: String
    var status: String
    var coverURL: String?
    var shareURL: String?
    var customCoverPath: String?
    var createdAt: Double
    var modifiedAt: Double

    init(_ work: Work) throws {
        id = work.id.rawValue.uuidString
        sourceID = work.sourceID.rawValue
        remoteID = work.remoteID
        title = work.title
        readingMode = work.readingMode
        alternativeTitles = try DataCoding.encode(work.alternativeTitles)
        authors = try DataCoding.encode(work.authors)
        summary = work.summary
        tags = try DataCoding.encode(work.tags)
        searchFacets = try DataCoding.encode(work.searchFacets)
        normalizedTitle = work.title.mangoReaderSearchNormalized
        normalizedAlternativeTitles = work.alternativeTitles
            .map(\.mangoReaderSearchNormalized)
            .joined(separator: " ")
        normalizedAuthors = work.authors
            .map(\.mangoReaderSearchNormalized)
            .joined(separator: " ")
        normalizedSummary = work.summary.mangoReaderSearchNormalized
        normalizedTags = work.tags
            .map(\.mangoReaderSearchNormalized)
            .joined(separator: " ")
        languageCode = work.languageCode
        kind = work.kind.rawValue
        status = work.status.rawValue
        coverURL = work.coverURL?.absoluteString
        shareURL = work.shareURL?.absoluteString
        customCoverPath = work.customCoverPath
        createdAt = work.createdAt.timeIntervalSince1970
        modifiedAt = work.modifiedAt.timeIntervalSince1970
    }

    func domainValue() throws -> Work {
        guard
            let uuid = UUID(uuidString: id),
            let contentKind = ContentKind(rawValue: kind),
            let workStatus = WorkStatus(rawValue: status)
        else {
            throw MangoReaderDataError.invalidRecord(table: Self.databaseTableName, id: id)
        }

        return try Work(
            id: WorkID(rawValue: uuid),
            sourceID: SourceID(rawValue: sourceID),
            remoteID: remoteID,
            title: title,
            readingMode: readingMode,
            alternativeTitles: DataCoding.decode([String].self, from: alternativeTitles),
            authors: DataCoding.decode([String].self, from: authors),
            summary: summary,
            tags: DataCoding.decode([String].self, from: tags),
            searchFacets: DataCoding.decode([WorkSearchFacet].self, from: searchFacets),
            languageCode: languageCode,
            kind: contentKind,
            status: workStatus,
            coverURL: coverURL.flatMap(URL.init(string:)),
            shareURL: shareURL.flatMap(URL.init(string:)),
            customCoverPath: customCoverPath,
            createdAt: Date(timeIntervalSince1970: createdAt),
            modifiedAt: Date(timeIntervalSince1970: modifiedAt)
        )
    }
}

struct InstallmentRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "installments"

    var id: String
    var workID: String
    var remoteID: String?
    var title: String
    var scanlators: Data?
    var volume: Double?
    var number: Double?
    var publishedAt: Double?
    var languageCode: String?
    var format: String
    var acquisitionURL: String?
    var pageCount: Int?

    init(_ installment: Installment) {
        id = installment.id.rawValue.uuidString
        workID = installment.workID.rawValue.uuidString
        remoteID = installment.remoteID
        title = installment.title
        scanlators = installment.scanlators.flatMap { try? DataCoding.encode($0) }
        volume = installment.volume
        number = installment.number
        publishedAt = installment.publishedAt?.timeIntervalSince1970
        languageCode = installment.languageCode
        format = installment.format.rawValue
        acquisitionURL = installment.acquisitionURL?.absoluteString
        pageCount = installment.pageCount
    }

    func domainValue() throws -> Installment {
        guard
            let uuid = UUID(uuidString: id),
            let workUUID = UUID(uuidString: workID),
            let publicationFormat = PublicationFormat(rawValue: format)
        else {
            throw MangoReaderDataError.invalidRecord(table: Self.databaseTableName, id: id)
        }

        return Installment(
            id: InstallmentID(rawValue: uuid),
            workID: WorkID(rawValue: workUUID),
            remoteID: remoteID,
            title: title,
            scanlators: scanlators.flatMap { try? DataCoding.decode([String].self, from: $0) },
            volume: volume,
            number: number,
            publishedAt: publishedAt.map(Date.init(timeIntervalSince1970:)),
            languageCode: languageCode,
            format: publicationFormat,
            acquisitionURL: acquisitionURL.flatMap(URL.init(string:)),
            pageCount: pageCount
        )
    }
}

struct ImportedOriginalReferenceRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "importedOriginalReferences"

    var installmentID: String
    var workID: String
    var sourceID: String
    var format: String
    var sha256Hex: String
    var byteCount: Int64
    var modifiedAt: Double
    var deviceID: String

    init(_ reference: ImportedOriginalReference) {
        installmentID = reference.installmentID.rawValue.uuidString
        workID = reference.workID.rawValue.uuidString
        sourceID = reference.sourceID.rawValue
        format = reference.format.rawValue
        sha256Hex = reference.sha256Hex
        byteCount = reference.byteCount
        modifiedAt = reference.modifiedAt.timeIntervalSince1970
        deviceID = reference.deviceID
    }

    func domainValue() throws -> ImportedOriginalReference {
        guard
            let installmentUUID = UUID(uuidString: installmentID),
            let workUUID = UUID(uuidString: workID),
            let publicationFormat = PublicationFormat(rawValue: format)
        else {
            throw MangoReaderDataError.invalidRecord(table: Self.databaseTableName, id: installmentID)
        }
        let reference = ImportedOriginalReference(
            workID: WorkID(rawValue: workUUID),
            installmentID: InstallmentID(rawValue: installmentUUID),
            sourceID: SourceID(rawValue: sourceID),
            format: publicationFormat,
            sha256Hex: sha256Hex,
            byteCount: byteCount,
            modifiedAt: Date(timeIntervalSince1970: modifiedAt),
            deviceID: deviceID
        )
        guard reference.isValidForCloudSync else {
            throw MangoReaderDataError.invalidRecord(table: Self.databaseTableName, id: installmentID)
        }
        return reference
    }
}

struct SyncedAppSettingsRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "syncedAppSettings"

    var id: String
    var version: Int
    var payload: Data
    var modifiedAt: Double
    var deviceID: String

    init(_ settings: SyncedAppSettings) throws {
        guard settings.isValidForCloudSync else {
            throw MangoReaderDataError.invalidSyncedAppSettings
        }
        id = SyncedAppSettings.singletonID
        version = settings.version
        payload = try DataCoding.encode(settings)
        modifiedAt = settings.modifiedAt.timeIntervalSince1970
        deviceID = settings.deviceID
    }

    func domainValue() throws -> SyncedAppSettings {
        guard
            id == SyncedAppSettings.singletonID,
            version == SyncedAppSettings.currentVersion,
            !payload.isEmpty,
            payload.count <= 65_536
        else {
            throw MangoReaderDataError.invalidRecord(table: Self.databaseTableName, id: id)
        }
        let settings = try DataCoding.decode(SyncedAppSettings.self, from: payload)
        guard
            settings.isValidForCloudSync,
            settings.version == version,
            settings.deviceID == deviceID,
            abs(settings.modifiedAt.timeIntervalSince1970 - modifiedAt) < 0.000_001
        else {
            throw MangoReaderDataError.invalidRecord(table: Self.databaseTableName, id: id)
        }
        return settings
    }
}

struct LibraryEntryRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "libraryEntries"

    var id: String
    var workID: String
    var addedAt: Double
    var lastOpenedAt: Double?
    var isPinned: Bool
    var isHidden: Bool
    var unreadCount: Int
    var downloadedCount: Int
    var cloudFilePolicy: String

    init(_ entry: LibraryEntry) {
        id = entry.id.uuidString
        workID = entry.workID.rawValue.uuidString
        addedAt = entry.addedAt.timeIntervalSince1970
        lastOpenedAt = entry.lastOpenedAt?.timeIntervalSince1970
        isPinned = entry.isPinned
        isHidden = entry.isHidden
        unreadCount = entry.unreadCount
        downloadedCount = entry.downloadedCount
        cloudFilePolicy = entry.cloudFilePolicy.rawValue
    }

    func domainValue() throws -> LibraryEntry {
        guard
            let uuid = UUID(uuidString: id),
            let workUUID = UUID(uuidString: workID),
            let filePolicy = CloudFilePolicy(rawValue: cloudFilePolicy)
        else {
            throw MangoReaderDataError.invalidRecord(table: Self.databaseTableName, id: id)
        }

        return LibraryEntry(
            id: uuid,
            workID: WorkID(rawValue: workUUID),
            addedAt: Date(timeIntervalSince1970: addedAt),
            lastOpenedAt: lastOpenedAt.map(Date.init(timeIntervalSince1970:)),
            isPinned: isPinned,
            isHidden: isHidden,
            unreadCount: unreadCount,
            downloadedCount: downloadedCount,
            cloudFilePolicy: filePolicy
        )
    }
}

struct CategoryRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "categories"

    var id: String
    var name: String
    var sortIndex: Int
    var createdAt: Double
    var modifiedAt: Double

    init(_ category: MangoReaderDomain.Category) {
        id = category.id.uuidString
        name = category.name
        sortIndex = category.sortIndex
        createdAt = category.createdAt.timeIntervalSince1970
        modifiedAt = category.modifiedAt.timeIntervalSince1970
    }

    func domainValue() throws -> MangoReaderDomain.Category {
        guard let uuid = UUID(uuidString: id) else {
            throw MangoReaderDataError.invalidRecord(table: Self.databaseTableName, id: id)
        }
        return MangoReaderDomain.Category(
            id: uuid,
            name: name,
            sortIndex: sortIndex,
            createdAt: Date(timeIntervalSince1970: createdAt),
            modifiedAt: Date(timeIntervalSince1970: modifiedAt)
        )
    }
}

struct CategoryMembershipRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "categoryMemberships"

    var categoryID: String
    var workID: String
}

struct ReadingProgressRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "readingProgress"

    var id: String
    var workID: String
    var installmentID: String
    var locator: Data
    var currentProgression: Double
    var highestProgression: Double
    var resetAt: Double?
    var modifiedAt: Double
    var deviceID: String

    init(_ progress: ReadingProgress) throws {
        id = progress.id.uuidString
        workID = progress.workID.rawValue.uuidString
        installmentID = progress.installmentID.rawValue.uuidString
        locator = try DataCoding.encode(progress.locator)
        currentProgression = progress.currentProgression
        highestProgression = progress.highestProgression
        resetAt = progress.resetAt?.timeIntervalSince1970
        modifiedAt = progress.modifiedAt.timeIntervalSince1970
        deviceID = progress.deviceID
    }

    func domainValue() throws -> ReadingProgress {
        guard
            let uuid = UUID(uuidString: id),
            let workUUID = UUID(uuidString: workID),
            let installmentUUID = UUID(uuidString: installmentID)
        else {
            throw MangoReaderDataError.invalidRecord(table: Self.databaseTableName, id: id)
        }
        return try ReadingProgress(
            id: uuid,
            workID: WorkID(rawValue: workUUID),
            installmentID: InstallmentID(rawValue: installmentUUID),
            locator: DataCoding.decode(ReadingLocator.self, from: locator),
            currentProgression: currentProgression,
            highestProgression: highestProgression,
            modifiedAt: Date(timeIntervalSince1970: modifiedAt),
            deviceID: deviceID,
            resetAt: resetAt.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

struct ReadingSessionRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "readingSessions"

    var id: String
    var workID: String
    var installmentID: String
    var startedAt: Double
    var endedAt: Double?
    var secondsRead: Double
    var startProgression: Double
    var endProgression: Double
    var readingUnitCount: Int?

    init(_ session: ReadingSession) {
        id = session.id.uuidString
        workID = session.workID.rawValue.uuidString
        installmentID = session.installmentID.rawValue.uuidString
        startedAt = session.startedAt.timeIntervalSince1970
        endedAt = session.endedAt?.timeIntervalSince1970
        secondsRead = session.secondsRead
        startProgression = session.startProgression
        endProgression = session.endProgression
        readingUnitCount = session.readingUnitCount
    }

    func domainValue() throws -> ReadingSession {
        guard
            let uuid = UUID(uuidString: id),
            let workUUID = UUID(uuidString: workID),
            let installmentUUID = UUID(uuidString: installmentID)
        else {
            throw MangoReaderDataError.invalidRecord(table: Self.databaseTableName, id: id)
        }
        return ReadingSession(
            id: uuid,
            workID: WorkID(rawValue: workUUID),
            installmentID: InstallmentID(rawValue: installmentUUID),
            startedAt: Date(timeIntervalSince1970: startedAt),
            endedAt: endedAt.map(Date.init(timeIntervalSince1970:)),
            secondsRead: secondsRead,
            startProgression: startProgression,
            endProgression: endProgression,
            readingUnitCount: readingUnitCount
        )
    }
}

struct UserTitleStateRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "userTitleStates"

    var workID: String
    var rating: Int?
    var status: String?
    var startDate: Data?
    var finishDate: Data?
    var modifiedAt: Double
    var deviceID: String

    init(_ state: UserTitleState) throws {
        workID = state.workID.rawValue.uuidString
        rating = state.rating?.rawValue
        status = state.status?.rawValue
        startDate = try state.startDate.map(DataCoding.encode)
        finishDate = try state.finishDate.map(DataCoding.encode)
        modifiedAt = state.modifiedAt.timeIntervalSince1970
        deviceID = state.deviceID
    }

    func domainValue() throws -> UserTitleState {
        guard let workUUID = UUID(uuidString: workID),
              !deviceID.isEmpty,
              deviceID.count <= 128
        else {
            throw MangoReaderDataError.invalidRecord(table: Self.databaseTableName, id: workID)
        }
        let domainRating: TenPointRating?
        if let rating {
            guard let value = TenPointRating(rawValue: rating) else {
                throw MangoReaderDataError.invalidRecord(table: Self.databaseTableName, id: workID)
            }
            domainRating = value
        } else {
            domainRating = nil
        }
        let domainStatus: TrackerReadingStatus?
        if let status {
            guard let value = TrackerReadingStatus(rawValue: status) else {
                throw MangoReaderDataError.invalidRecord(table: Self.databaseTableName, id: workID)
            }
            domainStatus = value
        } else {
            domainStatus = nil
        }
        return UserTitleState(
            workID: WorkID(rawValue: workUUID),
            rating: domainRating,
            status: domainStatus,
            startDate: try startDate.map { try DataCoding.decode(TrackerDate.self, from: $0) },
            finishDate: try finishDate.map { try DataCoding.decode(TrackerDate.self, from: $0) },
            modifiedAt: Date(timeIntervalSince1970: modifiedAt),
            deviceID: deviceID
        )
    }
}

struct TrackerLinkRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "trackerLinks"

    var workID: String
    var trackerID: String
    var remoteWorkID: String
    var remoteTitle: String
    var lastSynced: Data
    var lastPulledAt: Double?
    var conflicts: Data
    var lastRemote: Data?
    var supportsDateUpdates: Bool?
    var generation: String?

    init(_ link: TrackerLink) throws {
        workID = link.workID.rawValue.uuidString
        trackerID = link.trackerID.rawValue
        remoteWorkID = link.remoteWorkID
        remoteTitle = link.remoteTitle
        lastSynced = try DataCoding.encode(link.lastSynced)
        lastPulledAt = link.lastPulledAt?.timeIntervalSince1970
        conflicts = try DataCoding.encode(link.conflicts)
        lastRemote = try link.lastRemote.map(DataCoding.encode)
        supportsDateUpdates = link.supportsDateUpdates
        generation = link.generation?.uuidString
    }

    func domainValue() throws -> TrackerLink {
        guard let uuid = UUID(uuidString: workID),
              !trackerID.isEmpty,
              !remoteWorkID.isEmpty,
              !remoteTitle.isEmpty
        else {
            throw MangoReaderDataError.invalidRecord(
                table: Self.databaseTableName,
                id: "\(workID):\(trackerID)"
            )
        }
        return try TrackerLink(
            workID: WorkID(rawValue: uuid),
            trackerID: TrackerID(rawValue: trackerID),
            remoteWorkID: remoteWorkID,
            remoteTitle: remoteTitle,
            lastSynced: DataCoding.decode(TrackerSyncSnapshot.self, from: lastSynced),
            lastPulledAt: lastPulledAt.map(Date.init(timeIntervalSince1970:)),
            conflicts: DataCoding.decode([TrackerFieldConflict].self, from: conflicts),
            lastRemote: try lastRemote.map { try DataCoding.decode(TrackerProgress.self, from: $0) },
            supportsDateUpdates: supportsDateUpdates,
            generation: generation.flatMap(UUID.init(uuidString:))
        )
    }
}

struct BookmarkRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "bookmarks"

    var id: String
    var workID: String
    var installmentID: String
    var locator: Data
    var title: String
    var createdAt: Double
    var modifiedAt: Double

    init(_ bookmark: Bookmark) throws {
        id = bookmark.id.uuidString
        workID = bookmark.workID.rawValue.uuidString
        installmentID = bookmark.installmentID.rawValue.uuidString
        locator = try DataCoding.encode(bookmark.locator)
        title = bookmark.title
        createdAt = bookmark.createdAt.timeIntervalSince1970
        modifiedAt = bookmark.modifiedAt.timeIntervalSince1970
    }

    func domainValue() throws -> Bookmark {
        guard
            let uuid = UUID(uuidString: id),
            let workUUID = UUID(uuidString: workID),
            let installmentUUID = UUID(uuidString: installmentID)
        else {
            throw MangoReaderDataError.invalidRecord(table: Self.databaseTableName, id: id)
        }
        return try Bookmark(
            id: uuid,
            workID: WorkID(rawValue: workUUID),
            installmentID: InstallmentID(rawValue: installmentUUID),
            locator: DataCoding.decode(ReadingLocator.self, from: locator),
            title: title,
            createdAt: Date(timeIntervalSince1970: createdAt),
            modifiedAt: Date(timeIntervalSince1970: modifiedAt)
        )
    }
}

struct AnnotationRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "annotations"

    var id: String
    var workID: String
    var installmentID: String
    var locator: Data
    var selectedText: String?
    var note: String
    var highlightColor: String
    var createdAt: Double
    var modifiedAt: Double

    init(_ annotation: Annotation) throws {
        id = annotation.id.uuidString
        workID = annotation.workID.rawValue.uuidString
        installmentID = annotation.installmentID.rawValue.uuidString
        locator = try DataCoding.encode(annotation.locator)
        selectedText = annotation.selectedText
        note = annotation.note
        highlightColor = annotation.highlightColor.rawValue
        createdAt = annotation.createdAt.timeIntervalSince1970
        modifiedAt = annotation.modifiedAt.timeIntervalSince1970
    }

    func domainValue() throws -> Annotation {
        guard
            let uuid = UUID(uuidString: id),
            let workUUID = UUID(uuidString: workID),
            let installmentUUID = UUID(uuidString: installmentID),
            let highlightColor = ReaderHighlightColor(rawValue: highlightColor)
        else {
            throw MangoReaderDataError.invalidRecord(table: Self.databaseTableName, id: id)
        }
        return try Annotation(
            id: uuid,
            workID: WorkID(rawValue: workUUID),
            installmentID: InstallmentID(rawValue: installmentUUID),
            locator: DataCoding.decode(ReadingLocator.self, from: locator),
            selectedText: selectedText,
            note: note,
            highlightColor: highlightColor,
            createdAt: Date(timeIntervalSince1970: createdAt),
            modifiedAt: Date(timeIntervalSince1970: modifiedAt)
        )
    }
}

struct DownloadJobRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "downloads"

    var id: String
    var workID: String
    var installmentID: String
    var state: String
    var priority: Int
    var completedBytes: Int64
    var totalBytes: Int64?
    var localRelativePath: String?
    var lastError: String?
    var createdAt: Double
    var modifiedAt: Double

    init(_ job: DownloadJob) {
        id = job.id.uuidString
        workID = job.workID.rawValue.uuidString
        installmentID = job.installmentID.rawValue.uuidString
        state = job.state.rawValue
        priority = job.priority
        completedBytes = job.completedBytes
        totalBytes = job.totalBytes
        localRelativePath = job.localRelativePath
        lastError = job.lastError
        createdAt = job.createdAt.timeIntervalSince1970
        modifiedAt = job.modifiedAt.timeIntervalSince1970
    }

    func domainValue() throws -> DownloadJob {
        guard
            let uuid = UUID(uuidString: id),
            let workUUID = UUID(uuidString: workID),
            let installmentUUID = UUID(uuidString: installmentID),
            let downloadState = DownloadState(rawValue: state)
        else {
            throw MangoReaderDataError.invalidRecord(table: Self.databaseTableName, id: id)
        }
        return DownloadJob(
            id: uuid,
            workID: WorkID(rawValue: workUUID),
            installmentID: InstallmentID(rawValue: installmentUUID),
            state: downloadState,
            priority: priority,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            localRelativePath: localRelativePath,
            lastError: lastError,
            createdAt: Date(timeIntervalSince1970: createdAt),
            modifiedAt: Date(timeIntervalSince1970: modifiedAt)
        )
    }
}

struct SavedFilterRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "savedFilters"

    var id: String
    var name: String
    var query: String
    var kinds: Data
    var categoryIDs: Data
    var sort: String
    var isSmart: Bool

    init(_ filter: SavedFilter) throws {
        id = filter.id.uuidString
        name = filter.name
        query = filter.query
        kinds = try DataCoding.encode(filter.kinds.map(\.rawValue).sorted())
        categoryIDs = try DataCoding.encode(filter.categoryIDs.map(\.uuidString).sorted())
        sort = filter.sort.rawValue
        isSmart = filter.isSmart
    }

    func domainValue() throws -> SavedFilter {
        guard
            let uuid = UUID(uuidString: id),
            let librarySort = LibrarySort(rawValue: sort)
        else {
            throw MangoReaderDataError.invalidRecord(table: Self.databaseTableName, id: id)
        }
        let kindValues = try DataCoding.decode([String].self, from: kinds)
        let categoryValues = try DataCoding.decode([String].self, from: categoryIDs)
        guard
            kindValues.allSatisfy({ ContentKind(rawValue: $0) != nil }),
            categoryValues.allSatisfy({ UUID(uuidString: $0) != nil })
        else {
            throw MangoReaderDataError.invalidRecord(table: Self.databaseTableName, id: id)
        }
        return SavedFilter(
            id: uuid,
            name: name,
            query: query,
            kinds: Set(kindValues.compactMap(ContentKind.init(rawValue:))),
            categoryIDs: Set(categoryValues.compactMap(UUID.init(uuidString:))),
            sort: librarySort,
            isSmart: isSmart
        )
    }
}

struct TombstoneRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "tombstones"

    var id: String
    var entityType: String
    var entityID: String
    var deletedAt: Double
    var deviceID: String

    init(_ tombstone: Tombstone) {
        id = tombstone.id.uuidString
        entityType = tombstone.entityType
        entityID = tombstone.entityID
        deletedAt = tombstone.deletedAt.timeIntervalSince1970
        deviceID = tombstone.deviceID
    }

    func domainValue() throws -> Tombstone {
        guard let uuid = UUID(uuidString: id) else {
            throw MangoReaderDataError.invalidRecord(table: Self.databaseTableName, id: id)
        }
        return Tombstone(
            id: uuid,
            entityType: entityType,
            entityID: entityID,
            deletedAt: Date(timeIntervalSince1970: deletedAt),
            deviceID: deviceID
        )
    }
}
