import Foundation
import MangoReaderDomain
import MangoReaderExtensions
import MangoReaderSources
import OSLog
import MangoReaderReaders

extension SourcesModel {
    func progressivePublication(work: Work, installment: Installment, descriptor: SourceDescriptor) -> ProgressivePublicationSession {
        let workID = work.remoteID ?? "", bookID = installment.remoteID ?? ""
        let scope = contentCacheScope(work.sourceID), isPrivate = !usesPersistentContentCache
        let key = sourceCacheKey(work.sourceID, operation: "progressivePublication-v1", query: [workID, bookID])
        let cache = contentCache
        let legacyURL = installment.acquisitionURL.flatMap { $0.isFileURL && $0.pathComponents.contains("MankoExtensionPublications") ? $0 : nil }
        let namespace = installedRepositorySources.first(where: { $0.descriptor.id == work.sourceID })?.id ?? work.sourceID.rawValue
        return ProgressivePublicationSession(workID: workID, volumeID: bookID, isPrivate: isPrivate, legacyLoader: {
            guard !isPrivate else { return nil }
            if let legacyURL { return try await MangoReaderExtensionEPUBBuilder.sectionMetadata(at: legacyURL) }
            return try await MangoReaderExtensionEPUBBuilder().cachedSectionMetadata(workID: workID, volumeID: bookID, sourceNamespace: namespace)
        }) { [weak self] deliver in
            guard let self else { throw CancellationError() }
            let token = await cache.writeToken()
            let cached: ProgressivePublicationSnapshot?
            if !isPrivate, let entry = await cache.entry(for: key),
               let snapshot = try? entry.decode(ProgressivePublicationSnapshot.self), snapshot.validates(workID: workID, volumeID: bookID) {
                cached = snapshot
            } else { cached = nil }
            if let snapshot = cached {
                guard await self.contentCacheScope(work.sourceID) == scope,
                      await self.usesPersistentContentCache else { throw CancellationError() }
                try await deliver(snapshot.blocks, snapshot.complete)
                if snapshot.complete { return }
            }
            let cachedCount = cached?.blocks.count ?? 0
            let collected = try await SourceCachePolicy.$scope.withValue(scope) {
              try await SourceCachePolicy.$isPrivate.withValue(isPrivate) {
                try await self.performSourceOperation(mode: .foreground) {
                    // Verification may retry the request; each attempt owns a fresh parser.
                    let parser = LNoriProgressiveParser(workID: workID, volumeID: bookID)
                    let collector = ProgressivePublicationCollector(workID: workID, volumeID: bookID)
                    let source = try await self.makeRemoteSource(for: descriptor)
                    guard let source = source as? MangoReaderExtensionSourceAdapter else { throw SourceError.unsupportedResponse }
                    try await source.streamPublication(work: work, installment: installment) { head, bytes in
                        guard head.header("Content-Type")?.lowercased().contains("text/html") == true else { throw SourceError.unsupportedResponse }
                        guard await self.contentCacheScope(work.sourceID) == scope,
                              await self.usesPersistentContentCache == !isPrivate else { throw CancellationError() }
                        let blocks = try await parser.append(bytes)
                        guard !blocks.isEmpty else { return }
                        try await deliver(blocks, false)
                        let (snapshot, checkpoint) = await collector.append(blocks)
                        if !isPrivate, await self.contentCacheScope(work.sourceID) == scope,
                           await self.usesPersistentContentCache, checkpoint, snapshot.blocks.count >= cachedCount {
                            await cache.store(try JSONEncoder().encode(snapshot), for: key, token: token)
                        }
                    }
                    try await parser.finish()
                    return await collector.snapshot().blocks
                }
              }
            }
            try await deliver(collected, true)
            if !isPrivate, await self.contentCacheScope(work.sourceID) == scope, await self.usesPersistentContentCache {
                await cache.store(try JSONEncoder().encode(ProgressivePublicationSnapshot(workID: workID, volumeID: bookID, blocks: collected, complete: true)), for: key, token: token)
            }
        }
    }

    /// Novel bodies are cached before packaging. Reopening a volume therefore
    /// doesn't depend on rehydrating extension metadata or making HTTP requests.
    func cachedPublicationContent(work: Work, installment: Installment, descriptor: SourceDescriptor,
        legacyContent: MangoReaderPublicationContent? = nil) async throws -> MangoReaderPublicationContent {
        let key = sourceCacheKey(work.sourceID, operation: "publicationContent", query: [
            work.id.description, work.remoteID ?? work.id.description,
            installment.id.description, installment.remoteID ?? installment.id.description,
        ])
        guard installment.workID == work.id else { throw SourceError.unsupportedResponse }
        if let remoteWork = work.remoteID, let remoteBook = installment.remoteID, usesPersistentContentCache {
            let progressiveKey = sourceCacheKey(work.sourceID, operation: "progressivePublication-v1", query: [remoteWork, remoteBook])
            if let entry = await contentCache.entry(for: progressiveKey),
               let snapshot = try? entry.decode(ProgressivePublicationSnapshot.self), snapshot.complete,
               snapshot.validates(workID: remoteWork, volumeID: remoteBook) {
                return MangoReaderPublicationContent(id: remoteBook, workId: remoteWork, mimeType: "application/xhtml+xml",
                    text: snapshot.blocks.map(\.html).joined())
            }
        }
        let scope = contentCacheScope(work.sourceID)
        let isPrivate = !usesPersistentContentCache
        let cache = contentCache
        let load: @Sendable (CloudflareRecoveryMode) async throws -> Data = { [weak self] mode in
            guard let self else { throw CancellationError() }
            let content: MangoReaderPublicationContent = try await SourceCachePolicy.$scope.withValue(scope) {
              try await SourceCachePolicy.$isPrivate.withValue(isPrivate) {
               try await self.performSourceOperation(mode: mode) {
                let source = try await self.makeRemoteSource(for: descriptor)
                guard let source = source as? MangoReaderExtensionSourceAdapter else { throw SourceError.unsupportedResponse }
                _ = try await source.rehydrate(work: work, installment: installment)
                return try await source.publicationContent(for: installment)
               }
              }
            }
            guard content.workId == work.remoteID else { throw SourceError.unsupportedResponse }
            return try JSONEncoder().encode(content)
        }
        guard usesPersistentContentCache else {
            return try JSONDecoder().decode(MangoReaderPublicationContent.self, from: await load(.foreground))
        }
        if let entry = await cache.entry(for: key), let content = try? entry.decode(MangoReaderPublicationContent.self), content.workId == work.remoteID {
            try Task.checkCancellation()
            guard scope == contentCacheScope(work.sourceID), usesPersistentContentCache else { throw CancellationError() }
            if !entry.isFresh() {
                // The current publication stays immutable even if this refresh
                // finds an edited volume. Verification never interrupts reading.
                Task { _ = try? await cache.refresh(key) { try await load(.background) } }
            }
            return content
        }
        if let legacyContent, legacyContent.workId == work.remoteID {
            let token = await cache.writeToken()
            let data = try JSONEncoder().encode(legacyContent)
            await cache.store(data, for: key, token: token)
            try Task.checkCancellation()
            guard scope == contentCacheScope(work.sourceID), usesPersistentContentCache else { throw CancellationError() }
            return legacyContent
        }
        let log = OSLog(subsystem: "com.k800k.manko", category: "ReaderOpening")
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "PublicationFetch", signpostID: id)
        defer { os_signpost(.end, log: log, name: "PublicationFetch", signpostID: id) }
        let entry = try await cache.refresh(key) { try await load(.foreground) }
        try Task.checkCancellation()
        guard scope == contentCacheScope(work.sourceID), usesPersistentContentCache else { throw CancellationError() }
        return try entry.decode(MangoReaderPublicationContent.self)
    }

    /// A refreshed first page may change cursor ordering. Revalidate only the
    /// pages already visited, and let the view replace them atomically.
    func refreshedPageWindow(first: SourcePage<Work>, loadedPages: Int,
        load: @MainActor (Int, SourceCursor?) async throws -> SourcePage<Work>
    ) async throws -> (result: SourcePage<Work>, pages: Set<Int>) {
        var result = first, pages: Set<Int> = [1], lastPage = 1
        var initialIDs: Set<WorkID> = []
        result.items = result.items.filter { initialIDs.insert($0.id).inserted }
        while pages.count < loadedPages, let next = result.nextPage {
            try Task.checkCancellation()
            guard next > lastPage else { throw SourceError.unsupportedResponse }
            let page = try await load(next, result.nextCursor)
            try Task.checkCancellation()
            if let total = first.totalCount, let updatedTotal = page.totalCount, total != updatedTotal {
                throw SourceError.unsupportedResponse
            }
            var seen = Set(result.items.map(\.id))
            result.items += page.items.filter { seen.insert($0.id).inserted }
            result.nextPage = page.nextPage; result.nextCursor = page.nextCursor
            lastPage = next; pages.insert(next)
        }
        return (result, pages)
    }

    var usesPersistentContentCache: Bool { !isPrivate && !defaults.bool(forKey: "incognitoMode") }

    func contentCacheScope(_ id: SourceID) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let descriptor = sources.first { $0.id == id }
        var canonicalDescriptor = descriptor
        canonicalDescriptor?.languageCodes.sort()
        var configurationData = (try? encoder.encode(canonicalDescriptor)) ?? Data()
        if var object = (try? JSONSerialization.jsonObject(with: configurationData)) as? [String: Any],
           let capabilities = object["capabilities"] as? [String] {
            object["capabilities"] = capabilities.sorted()
            configurationData = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? configurationData
        }
        let configuration = String(data: configurationData, encoding: .utf8) ?? ""
        let options = (try? encoder.encode(sourceOptions[id.rawValue] ?? [:])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let version = installedRepositorySources.first { $0.descriptor.id == id }?.version ?? ""
        return ContentCache.key([isPrivate ? "private-v2" : "v2", id.rawValue, configuration, options, version,
            sourceCredentialAccounts[id.rawValue] ?? "anonymous",
            defaults.string(forKey: "contentCacheEpoch.\(id.rawValue)") ?? "initial"])
    }

    func sourceCacheKey<Query: Encodable>(_ id: SourceID, operation: String, query: Query) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = (try? encoder.encode(query)) ?? Data()
        if var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for field in ["languageCodes", "kinds", "capabilities"] {
                if let values = object[field] as? [String] { object[field] = values.sorted() }
            }
            data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? data
        }
        return ContentCache.key([contentCacheScope(id), operation, data.base64EncodedString()])
    }

    func sourcePageCacheKey(_ id: SourceID, operation: String, query: SourceQuery) async -> String {
        let key = sourceCacheKey(id, operation: operation, query: query)
        guard query.page > 1 else { return key }
        var first = query; first.page = 1; first.cursor = nil
        let firstKey = sourceCacheKey(id, operation: operation, query: first)
        guard let snapshot = await contentCache.entry(for: firstKey),
              let page = try? snapshot.decode(SourcePage<Work>.self) else { return key }
        // A changed first page starts a new pagination snapshot; old later
        // pages cannot be spliced into its refreshed ordering.
        let identity = SourcePage(items: page.items.map(\.id), nextPage: page.nextPage,
            totalCount: page.totalCount, nextCursor: page.nextCursor)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(identity)) ?? snapshot.data
        return ContentCache.key([key, ContentCache.key([data.base64EncodedString()])])
    }

    /// Cached delivery happens before the refresh is awaited, so the caller
    /// retains its normal error/retry handling without clearing its content.
    func cachedSourceValue<Value: Codable & Sendable>(
        sourceID: SourceID, key: String, force: Bool = false,
        recoveryMode: CloudflareRecoveryMode? = nil,
        onCached: (@MainActor (Value) -> Void)? = nil,
        loader: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        #if DEBUG
        if sourceID == CacheVerificationSource.descriptor.id { AppFixtures.cacheVerificationKeys.insert(key) }
        #endif
        guard usesPersistentContentCache else {
            return try await SourceCachePolicy.$isPrivate.withValue(true) {
                try await SourceCachePolicy.$reload.withValue(force) {
                    try await performSourceOperation(mode: recoveryMode ?? .foreground, loader)
                }
            }
        }
        let scope = contentCacheScope(sourceID)
        var hasCached = false
        if let cached = await contentCache.entry(for: key),
           case let .success(value) = Result<Value, Error>(catching: { try cached.decode(Value.self) }) {
            try Task.checkCancellation()
            guard scope == contentCacheScope(sourceID), usesPersistentContentCache else { throw CancellationError() }
            onCached?(value)
            // A stale page can still teach canonical values before its refresh
            // finishes, including when that refresh fails offline.
            if let page = value as? SourcePage<Work> {
                await learnSourceFacets(page.items, for: sourceID)
            } else if let suggestions = value as? [SourceSearchSuggestion] {
                await learnSourceSuggestions(suggestions, for: sourceID)
            }
            try Task.checkCancellation()
            guard scope == contentCacheScope(sourceID), usesPersistentContentCache else { throw CancellationError() }
            hasCached = true
            if !force, cached.isFresh() { return value }
        }
        let mode: CloudflareRecoveryMode = recoveryMode
            ?? (isPerformingQuietRefresh || (hasCached && !force) ? .background : .foreground)
        let freshness = SourceCacheFreshness()
        let entry = try await contentCache.refresh(key, replacing: force, freshness: { await freshness.lifetime() }) { [weak self] in
            guard let self else { throw CancellationError() }
            let result = try await SourceCachePolicy.$freshness.withValue(freshness) {
                try await SourceCachePolicy.$scope.withValue(scope) {
                    try await SourceCachePolicy.$reload.withValue(force) {
                        try await self.performSourceOperation(mode: mode, loader)
                    }
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(result)
        }
        try Task.checkCancellation()
        guard scope == contentCacheScope(sourceID), usesPersistentContentCache else { throw CancellationError() }
        return try entry.decode(Value.self)
    }
}

private actor ProgressivePublicationCollector {
    let workID: String, volumeID: String
    var blocks: [ProgressivePublicationBlock] = []
    var checkpointCount = 0
    init(workID: String, volumeID: String) { self.workID = workID; self.volumeID = volumeID }
    func append(_ incoming: [ProgressivePublicationBlock]) -> (ProgressivePublicationSnapshot, Bool) {
        blocks += incoming
        let checkpoint = checkpointCount == 0 || blocks.count - checkpointCount >= 64 || incoming.contains { $0.heading != nil }
        if checkpoint { checkpointCount = blocks.count }
        return (snapshot(), checkpoint)
    }
    func snapshot() -> ProgressivePublicationSnapshot { .init(workID: workID, volumeID: volumeID, blocks: blocks, complete: false) }
}
