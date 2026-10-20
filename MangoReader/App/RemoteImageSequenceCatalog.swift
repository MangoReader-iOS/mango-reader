import Foundation
import ImageIO
import MangoReaderData
import MangoReaderDomain
import MangoReaderExtensions
import MangoReaderReaders
import MangoReaderSources
import MangoReaderSync
import Observation
import OSLog
import SwiftUI
import WebKit

struct PreparedDownload: Sendable {
    var remoteURL: URL
    var installment: Installment
    var configuration: SourceEndpointConfiguration?
    var verificationReference: DownloadVerificationReference?
}

nonisolated struct RecoveringRemoteImagePageLoader: RemoteImagePageLoading {
    let load: @Sendable (RemoteImagePageDescriptor) async throws -> RemoteImagePageContent
    var prioritizedLoad: (@Sendable (RemoteImagePageDescriptor, RemoteImageRequestPriority) async throws -> RemoteImagePageContent)?
    var updatePriority: (@Sendable (RemoteImagePageDescriptor, RemoteImageRequestPriority) async -> Void)?
    var incrementalLoad: (@Sendable (RemoteImagePageDescriptor, RemoteImageRequestPriority, @escaping RemoteImagePageProgress) async throws -> RemoteImagePageContent)?

    var progressLoad: (@Sendable (RemoteImagePageDescriptor, RemoteImageRequestPriority, @escaping RemoteImagePageProgress,
        @escaping RemoteImageDownloadProgressHandler) async throws -> RemoteImagePageContent)?

    func imagePageContent(for page: RemoteImagePageDescriptor) async throws -> RemoteImagePageContent {
        try await load(page)
    }

    func imagePageContent(for page: RemoteImagePageDescriptor, priority: RemoteImageRequestPriority) async throws -> RemoteImagePageContent {
        if let prioritizedLoad { return try await prioritizedLoad(page, priority) }
        return try await load(page)
    }

    func setImagePagePriority(for page: RemoteImagePageDescriptor, priority: RemoteImageRequestPriority) async {
        await updatePriority?(page, priority)
    }

    func streamImagePageContent(for page: RemoteImagePageDescriptor, priority: RemoteImageRequestPriority,
        onPartial: @escaping RemoteImagePageProgress,
        onProgress: @escaping RemoteImageDownloadProgressHandler) async throws -> RemoteImagePageContent {
        if let progressLoad { return try await progressLoad(page, priority, onPartial, onProgress) }
        return try await streamImagePageContent(for: page, priority: priority, onPartial: onPartial)
    }

    func streamImagePageContent(for page: RemoteImagePageDescriptor, priority: RemoteImageRequestPriority,
        onPartial: @escaping RemoteImagePageProgress) async throws -> RemoteImagePageContent {
        if let incrementalLoad { return try await incrementalLoad(page, priority, onPartial) }
        return try await imagePageContent(for: page, priority: priority)
    }
}

/// Resolves a source-provided, paginated image sequence without persisting its
/// descriptors or exposing source credentials to the reader UI.
struct RemoteImageSequenceCatalog: Sendable {
    let pageSize: Int
    let maximumPageCount: Int

    init(pageSize: Int = 200, maximumPageCount: Int = 50_000) {
        self.pageSize = min(200, max(1, pageSize))
        self.maximumPageCount = min(1_000_000, max(1, maximumPageCount))
    }

    @concurrent
    func publication(
        for work: Work,
        installment: Installment,
        source: any ContentSource,
        loader: (any RemoteImagePageLoading)? = nil,
        cacheScope: String? = nil
    ) async throws -> RemoteImagePublication {
        let log = OSLog(subsystem: "com.k800k.manko", category: "ExtensionPerformance")
        let signpost = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "Chapter Preparation", signpostID: signpost)
        defer { os_signpost(.end, log: log, name: "Chapter Preparation", signpostID: signpost) }
        guard installment.format == .remoteImageSequence else {
            throw ReaderError.unsupportedFormat(installment.format)
        }
        guard installment.workID == work.id else {
            throw SourceError.notFound
        }

        let sourceDescriptor = await source.descriptor
        guard sourceDescriptor.isEnabled,
              sourceDescriptor.id == work.sourceID,
              sourceDescriptor.capabilities.contains(.imageSequence)
        else {
            throw SourceError.unsupportedResponse
        }

        var requestedPages: Set<Int> = []
        var descriptorIDs: Set<String> = []
        var descriptorIndices: Set<Int> = []
        var descriptors: [RemoteImagePageDescriptor] = []
        var declaredTotalCount: Int?
        var pageNumber = 1
        let maximumRequestCount = max(1, (maximumPageCount + pageSize - 1) / pageSize + 1)

        while true {
            try Task.checkCancellation()
            guard requestedPages.count < maximumRequestCount,
                  requestedPages.insert(pageNumber).inserted
            else {
                throw SourceError.unsupportedResponse
            }

            let response = try await source.imagePages(
                for: installment,
                query: RemoteImagePageQuery(page: pageNumber, pageSize: pageSize)
            )
            if let totalCount = response.totalCount {
                guard totalCount >= 0, totalCount <= maximumPageCount else {
                    throw SourceError.resourceLimitExceeded("the installment contains too many pages")
                }
                if let declaredTotalCount, declaredTotalCount != totalCount {
                    throw SourceError.unsupportedResponse
                }
                declaredTotalCount = totalCount
            }

            for descriptor in response.items {
                guard descriptor.sourceID == sourceDescriptor.id,
                      descriptor.installmentID == installment.id,
                      descriptor.index < maximumPageCount,
                      descriptorIDs.insert(descriptor.id).inserted,
                      descriptorIndices.insert(descriptor.index).inserted,
                      Self.hasNoEmbeddedURLCredentials(descriptor.resourceURL)
                else {
                    throw SourceError.unsupportedResponse
                }
                descriptors.append(descriptor)
                guard descriptors.count <= maximumPageCount else {
                    throw SourceError.resourceLimitExceeded("the installment contains too many pages")
                }
            }

            guard let nextPage = response.nextPage else { break }
            guard nextPage > pageNumber, nextPage <= 1_000_000 else {
                throw SourceError.unsupportedResponse
            }
            pageNumber = nextPage
        }

        guard !descriptors.isEmpty else {
            throw ReaderError.noReadableImages
        }
        descriptors.sort { lhs, rhs in
            lhs.index == rhs.index ? lhs.id < rhs.id : lhs.index < rhs.index
        }
        guard descriptors.enumerated().allSatisfy({ $0.offset == $0.element.index }) else {
            throw SourceError.unsupportedResponse
        }
        if let declaredTotalCount, declaredTotalCount != descriptors.count {
            throw SourceError.unsupportedResponse
        }

        return RemoteImagePublication(sourcePages: descriptors, loader: loader ?? source, cacheScope: cacheScope)
    }

    nonisolated private static func hasNoEmbeddedURLCredentials(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.user == nil && components.password == nil
    }
}
