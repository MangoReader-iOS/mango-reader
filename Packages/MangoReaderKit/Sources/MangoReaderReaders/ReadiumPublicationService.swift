import Foundation
import MangoReaderDomain
import ReadiumShared
import ReadiumStreamer
import OSLog
import UIKit

public struct PersistedReadiumLocator: Codable, Hashable, Sendable {
    public let jsonData: Data

    public init(jsonData: Data) throws {
        let locator: Locator
        do {
            locator = try Locator(jsonData: jsonData)
        } catch {
            throw ReaderError.invalidLocator
        }
        do {
            self.jsonData = try locator.jsonData()
        } catch {
            throw ReaderError.invalidLocator
        }
    }

    public init(locator: Locator) throws {
        do {
            jsonData = try locator.jsonData()
        } catch {
            throw ReaderError.invalidLocator
        }
    }

    public init(readingLocator: ReadingLocator) throws {
        guard case let .publication(readiumJSON) = readingLocator else {
            throw ReaderError.invalidLocator
        }
        try self.init(jsonData: readiumJSON)
    }

    public var readingLocator: ReadingLocator {
        .publication(readiumJSON: jsonData)
    }

    public var totalProgression: Double? {
        (try? makeLocator())?.locations.totalProgression
    }

    public func makeLocator() throws -> Locator {
        do {
            return try Locator(jsonData: jsonData)
        } catch {
            throw ReaderError.invalidLocator
        }
    }
}

public struct ReadiumLocatorCodec: Sendable {
    public init() {}

    public func encode(_ locator: Locator) throws -> Data {
        try PersistedReadiumLocator(locator: locator).jsonData
    }

    public func decode(_ data: Data) throws -> Locator {
        try PersistedReadiumLocator(jsonData: data).makeLocator()
    }

    public func encodeAsReadingLocator(_ locator: Locator) throws -> ReadingLocator {
        try PersistedReadiumLocator(locator: locator).readingLocator
    }

    public func decode(_ readingLocator: ReadingLocator) throws -> Locator {
        try PersistedReadiumLocator(readingLocator: readingLocator).makeLocator()
    }
}

public struct ReadiumPublicationSnapshot: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let sourceURL: URL
    public let format: PublicationFormat
    public let title: String?
    public let identifier: String?
    public let languageCodes: [String]
    public let readingOrderCount: Int
    public let numberOfPages: Int?
    public let detectedMediaType: String?
    public let manifestJSON: String?

    public init(
        id: UUID,
        sourceURL: URL,
        format: PublicationFormat,
        title: String?,
        identifier: String?,
        languageCodes: [String],
        readingOrderCount: Int,
        numberOfPages: Int?,
        detectedMediaType: String?,
        manifestJSON: String?
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.format = format
        self.title = title
        self.identifier = identifier
        self.languageCodes = languageCodes
        self.readingOrderCount = readingOrderCount
        self.numberOfPages = numberOfPages
        self.detectedMediaType = detectedMediaType
        self.manifestJSON = manifestJSON
    }
}

public final class ReadiumPublicationDocument {
    public let snapshot: ReadiumPublicationSnapshot
    public let publication: Publication
    public let sectionMap: GeneratedPublicationSections?

    init(snapshot: ReadiumPublicationSnapshot, publication: Publication, sectionMap: GeneratedPublicationSections? = nil) {
        self.snapshot = snapshot
        self.publication = publication
        self.sectionMap = sectionMap
    }

    public func resolvedLocator(_ persisted: PersistedReadiumLocator, requiresTextMatch: Bool = false, selectedText: String? = nil) throws -> PersistedReadiumLocator {
        guard let sectionMap else { return persisted }
        return try PersistedReadiumLocator(jsonData: sectionMap.remap(persisted.jsonData, selectedText: selectedText, requiresTextMatch: requiresTextMatch))
    }

    public var isSearchable: Bool {
        publication.isSearchable
    }

    public func normalizedLocator(from persisted: PersistedReadiumLocator) throws -> PersistedReadiumLocator {
        let locator = try persisted.makeLocator()
        return try PersistedReadiumLocator(locator: publication.normalizeLocator(locator))
    }

    public func search(
        _ query: String,
        preferences: PublicationSearchPreferences = PublicationSearchPreferences()
    ) async throws -> [PersistedReadiumLocator] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return []
        }

        let options = SearchOptions(
            caseSensitive: preferences.isCaseSensitive,
            diacriticSensitive: preferences.isDiacriticSensitive,
            wholeWord: preferences.matchesWholeWords
        )
        let iterator: any SearchIterator
        switch await publication.search(query: trimmedQuery, options: options) {
        case let .success(value):
            iterator = value
        case let .failure(error):
            throw ReaderError.readiumOpenFailed(Self.searchErrorDescription(error))
        }

        var results: [PersistedReadiumLocator] = []
        while results.count < preferences.maximumResults {
            let collection: LocatorCollection?
            switch await iterator.next() {
            case let .success(value):
                collection = value
            case let .failure(error):
                throw ReaderError.readiumOpenFailed(Self.searchErrorDescription(error))
            }
            guard let collection else {
                break
            }
            for locator in collection.locators {
                results.append(try PersistedReadiumLocator(locator: locator))
                if results.count == preferences.maximumResults {
                    break
                }
            }
        }
        return results
    }

    private static func searchErrorDescription(_ error: SearchError) -> String {
        switch error {
        case .publicationNotSearchable:
            "this publication is not searchable"
        case .badQuery:
            "the search query is not supported"
        case .reading:
            "the publication content could not be read"
        }
    }
}

public actor ReadiumPublicationService {
    // Readium 3.10's immutable service facades predate Swift 6 Sendable
    // annotations. Their async APIs are designed for concurrent retrieval, so
    // keep the unchecked boundary narrow instead of making publications or the
    // UI model globally unchecked-Sendable.
    nonisolated(unsafe) private let assetRetriever: AssetRetriever
    nonisolated(unsafe) private let publicationOpener: PublicationOpener
    private let validator: any LocalPublicationValidating

    public init(validator: any LocalPublicationValidating = DefaultLocalPublicationValidator()) {
        let httpClient = DefaultHTTPClient(ephemeral: true)
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        self.assetRetriever = assetRetriever
        publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            ),
            contentProtections: []
        )
        self.validator = validator
    }

    public func open(
        url: URL,
        format: PublicationFormat
    ) async throws -> sending ReadiumPublicationDocument {
        let log = OSLog(subsystem: "com.k800k.manko", category: "ReaderOpening")
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "PublicationOpen", signpostID: id)
        defer { os_signpost(.end, log: log, name: "PublicationOpen", signpostID: id) }
        guard [.epub, .pdf].contains(format) else {
            throw ReaderError.unsupportedFormat(format)
        }
        _ = try await validator.validate(url, expectedFormat: format)
        guard let fileURL = FileURL(url: url) else {
            throw ReaderError.invalidFileURL
        }

        let asset: Asset
        switch await assetRetriever.retrieve(url: fileURL) {
        case let .success(value):
            asset = value
        case let .failure(error):
            throw ReaderError.readiumOpenFailed(Self.assetErrorDescription(error))
        }

        let publication: Publication
        switch await publicationOpener.open(asset: asset, allowUserInteraction: false) {
        case let .success(value):
            publication = value
        case let .failure(error):
            throw ReaderError.readiumOpenFailed(Self.openErrorDescription(error))
        }

        let expectedProfile: Publication.Profile = format == .epub ? .epub : .pdf
        guard publication.conforms(to: expectedProfile) else {
            throw ReaderError.formatMismatch(expected: format, detected: nil)
        }

        let snapshot = ReadiumPublicationSnapshot(
            id: UUID(),
            sourceURL: url,
            format: format,
            title: publication.metadata.title,
            identifier: publication.metadata.identifier,
            languageCodes: publication.metadata.languages,
            readingOrderCount: publication.readingOrder.count,
            numberOfPages: publication.metadata.numberOfPages,
            detectedMediaType: asset.format.mediaType?.string,
            manifestJSON: publication.jsonManifest
        )
        var sectionMap: GeneratedPublicationSections?
        if format == .epub, publication.metadata.identifier?.hasPrefix("urn:manko:extension:") == true,
           let href = AnyURL(string: GeneratedPublicationSections.resourcePath),
           let resource = publication.get(href) {
            let data = try await resource.read().get()
            sectionMap = try JSONDecoder().decode(GeneratedPublicationSections.self, from: data)
        }
        return ReadiumPublicationDocument(snapshot: snapshot, publication: publication, sectionMap: sectionMap)
    }

    /// Returns a bounded bitmap cover without allowing Readium's non-Sendable
    /// publication or image types to escape this actor.
    public func coverData(
        url: URL,
        format: PublicationFormat,
        maximumDimension: Int = 1_600
    ) async throws -> Data? {
        let document = try await open(url: url, format: format)
        let dimension = CGFloat(max(1, maximumDimension))
        switch await document.publication.coverFitting(
            maxSize: CGSize(width: dimension, height: dimension)
        ) {
        case let .success(image):
            return image?.jpegData(compressionQuality: 0.9)
        case .failure:
            return nil
        }
    }

    private static func assetErrorDescription(_ error: AssetRetrieveURLError) -> String {
        switch error {
        case .schemeNotSupported:
            "the file URL scheme is unsupported"
        case .formatNotSupported:
            "the publication format was not recognized"
        case .reading:
            "the publication file could not be read"
        }
    }

    private static func openErrorDescription(_ error: PublicationOpenError) -> String {
        switch error {
        case .formatNotSupported:
            "the publication format is unsupported"
        case .reading:
            "the publication content could not be read"
        }
    }
}
