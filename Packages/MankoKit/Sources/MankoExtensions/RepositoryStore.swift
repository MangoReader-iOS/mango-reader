import Foundation
import MankoDomain

public enum RepositoryStoreError: Error, Equatable, Sendable, LocalizedError {
    case duplicateRepository(String)
    case repositoryNotFound(String)
    case sourceNotFound(String)
    case cleanupPending(String)
    case corrupted

    public var errorDescription: String? {
        switch self {
        case let .duplicateRepository(id): "Repository “\(id)” is already installed."
        case let .repositoryNotFound(id): "Repository “\(id)” was not found."
        case let .sourceNotFound(id): "Source “\(id)” was not found."
        case let .cleanupPending(id): "Source “\(id)” is still being removed. Try again after cleanup finishes."
        case .corrupted: "The local source repository index is damaged."
        }
    }
}

public actor SourceRepositoryStore {
    fileprivate struct State: Codable, Sendable {
        var version = 2
        var repositories: [RepositoryRecord] = []
        var installedSources: [InstalledRepositorySource] = []
        var pendingCleanups: [PendingRepositoryCleanup] = []

        private enum CodingKeys: String, CodingKey {
            case version, repositories, installedSources, pendingCleanups
        }

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 2
            repositories = try values.decodeIfPresent([RepositoryRecord].self, forKey: .repositories) ?? []
            installedSources = try values.decodeIfPresent(
                [InstalledRepositorySource].self,
                forKey: .installedSources
            ) ?? []
            pendingCleanups = try values.decodeIfPresent(
                [PendingRepositoryCleanup].self,
                forKey: .pendingCleanups
            ) ?? []
        }
    }

    private let fileURL: URL
    private var state: State

    private let isPrivate: Bool

    public init(directory: URL, isPrivate: Bool = false) throws {
        self.isPrivate = isPrivate
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.applyProtection(isPrivate: isPrivate, to: directory)
        fileURL = directory.appending(path: "repositories.json", directoryHint: .notDirectory)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let data = try Data(contentsOf: fileURL)
                state = try decoder.decode(State.self, from: data)
                guard state.version == 2 else {
                    #if DEBUG
                    print("Manko repository diagnostic: unsupported index version \(state.version)")
                    #endif
                    throw RepositoryStoreError.corrupted
                }
            } catch {
                #if DEBUG
                let context: DecodingError.Context?
                let kind: String
                switch error {
                case let DecodingError.keyNotFound(key, value):
                    context = value; kind = "missing field \(key.stringValue)"
                case let DecodingError.typeMismatch(_, value):
                    context = value; kind = "type mismatch"
                case let DecodingError.valueNotFound(_, value):
                    context = value; kind = "missing value"
                case let DecodingError.dataCorrupted(value):
                    context = value; kind = "invalid encoding"
                default:
                    context = nil; kind = "\((error as NSError).domain) code \((error as NSError).code)"
                }
                let path = context?.codingPath.map { $0.intValue == nil ? $0.stringValue : "[item]" }.joined(separator: ".") ?? ""
                print("Manko repository diagnostic: \(kind); field=\(path)")
                #endif
                throw RepositoryStoreError.corrupted
            }
        } else {
            state = State()
        }
    }

    private func validateContinuity(previous: RepositoryRecord, incoming: RepositoryRecord) throws {
        guard previous.repositoryURL == incoming.repositoryURL else { throw ExtensionSecurityError.repositoryAddressChanged }
        for entry in incoming.manifest.sources {
            if let oldEntry = previous.manifest.sources.first(where: { $0.id == entry.id }),
               entry.version == oldEntry.version,
               entry.mankoExtension?.sha256 != oldEntry.mankoExtension?.sha256 { throw ExtensionSecurityError.artifactChanged }
        }
    }

    public func repositories() -> [RepositoryRecord] {
        state.repositories.sorted { $0.manifest.repository.name.localizedStandardCompare($1.manifest.repository.name) == .orderedAscending }
    }

    public func installedSources() -> [InstalledRepositorySource] {
        state.installedSources
    }

    public func pendingCleanups() -> [PendingRepositoryCleanup] {
        state.pendingCleanups.sorted { $0.createdAt < $1.createdAt }
    }

    public func repository(id: String) -> RepositoryRecord? {
        state.repositories.first { $0.id == id }
    }

    public func repository(url: URL) -> RepositoryRecord? {
        state.repositories.first { $0.repositoryURL == url }
    }

    public func upsert(_ record: RepositoryRecord) throws {
        try Task.checkCancellation()
        let previousState = state
        if let index = state.repositories.firstIndex(where: { $0.id == record.id }) {
            let previous = state.repositories[index]
            try validateContinuity(previous: previous, incoming: record)
            state.repositories[index] = refreshedRecord(previous: previous, incoming: record).record
        } else {
            state.repositories.append(record)
        }
        do {
            try persist()
        } catch {
            state = previousState
            throw error
        }
    }

    @discardableResult
    public func refresh(_ record: RepositoryRecord) throws -> RepositoryRefreshDelta {
        guard let index = state.repositories.firstIndex(where: { $0.id == record.id }) else {
            throw RepositoryStoreError.repositoryNotFound(record.id)
        }
        try validateContinuity(previous: state.repositories[index], incoming: record)
        let previousState = state
        let result = refreshedRecord(previous: state.repositories[index], incoming: record)
        state.repositories[index] = result.record
        do {
            try persist()
        } catch {
            state = previousState
            throw error
        }
        return result.delta
    }

    public func removeRepository(id: String) throws -> [InstalledRepositorySource] {
        try scheduleRepositoryRemoval(id: id).installedSources
    }

    @discardableResult
    public func scheduleRepositoryRemoval(id: String) throws -> PendingRepositoryCleanup {
        let cleanupID = "repository::\(id)"
        if let existing = state.pendingCleanups.first(where: { $0.id == cleanupID }) {
            return existing
        }
        guard state.repositories.contains(where: { $0.id == id }) else {
            throw RepositoryStoreError.repositoryNotFound(id)
        }
        let previousState = state
        let removedSources = state.installedSources.filter { $0.repositoryID == id }
        let cleanup = PendingRepositoryCleanup(
            id: cleanupID,
            scope: .repository,
            repositoryID: id,
            sourceID: nil,
            installedSources: removedSources
        )
        state.repositories.removeAll { $0.id == id }
        state.installedSources.removeAll { $0.repositoryID == id }
        state.pendingCleanups.append(cleanup)
        do {
            try persist()
        } catch {
            state = previousState
            throw error
        }
        return cleanup
    }

    public func install(_ source: InstalledRepositorySource, reviewedRepository: RepositoryRecord? = nil) throws {
        // Metadata-only legacy/restored entries remain readable but cannot execute.
        // Every executable installation is revalidated atomically with persistence.
        if let grant = source.accessGrant {
            guard let record = repository(id: source.repositoryID),
                  let entry = record.manifest.sources.first(where: { $0.id == source.sourceID }),
                  grant.matches(entry, record: record),
                  reviewedRepository.map({ record.hasSameCatalog(as: $0) }) ?? true
            else { throw ExtensionSecurityError.approvalRequired }
        }
        try assertInstallationAllowed(
            repositoryID: source.repositoryID,
            sourceID: source.sourceID
        )
        let previousState = state
        if let index = state.installedSources.firstIndex(where: { $0.id == source.id }) {
            state.installedSources[index] = source
        } else {
            state.installedSources.append(source)
        }
        if let repositoryIndex = state.repositories.firstIndex(where: { $0.id == source.repositoryID }) {
            state.repositories[repositoryIndex].knownSourceIDs.insert(source.sourceID)
            state.repositories[repositoryIndex].newSourceIDs.remove(source.sourceID)
        }
        do {
            try persist()
        } catch {
            state = previousState
            throw error
        }
    }

    /// Checks the repository-removal tombstone and repository membership in one
    /// actor turn. Repository-scope cleanup blocks every source, including a
    /// source that was not installed when removal was scheduled.
    public func assertInstallationAllowed(repositoryID: String, sourceID: String) throws {
        let installedSourceID = "\(repositoryID)::\(sourceID)"
        guard !state.pendingCleanups.contains(where: { cleanup in
            (cleanup.scope == .repository && cleanup.repositoryID == repositoryID)
                || cleanup.installedSources.contains(where: { $0.id == installedSourceID })
        }) else {
            throw RepositoryStoreError.cleanupPending(installedSourceID)
        }
        guard state.repositories.contains(where: { $0.id == repositoryID }) else {
            throw RepositoryStoreError.repositoryNotFound(repositoryID)
        }
    }

    public func removeInstalledSource(id: String) throws -> InstalledRepositorySource {
        guard let removed = try scheduleSourceRemoval(id: id).installedSources.first(where: { $0.id == id }) else {
            throw RepositoryStoreError.sourceNotFound(id)
        }
        return removed
    }

    @discardableResult
    public func scheduleSourceRemoval(id: String) throws -> PendingRepositoryCleanup {
        if let existing = state.pendingCleanups.first(where: {
            $0.installedSources.contains(where: { $0.id == id })
        }) {
            return existing
        }
        guard let index = state.installedSources.firstIndex(where: { $0.id == id }) else {
            throw RepositoryStoreError.sourceNotFound(id)
        }
        let previousState = state
        let removed = state.installedSources.remove(at: index)
        let cleanup = PendingRepositoryCleanup(
            id: "source::\(removed.repositoryID)::\(removed.sourceID)",
            scope: .source,
            repositoryID: removed.repositoryID,
            sourceID: removed.sourceID,
            installedSources: [removed]
        )
        if let repositoryIndex = state.repositories.firstIndex(where: { $0.id == removed.repositoryID }) {
            state.repositories[repositoryIndex].knownSourceIDs.remove(removed.sourceID)
            state.repositories[repositoryIndex].newSourceIDs.remove(removed.sourceID)
        }
        state.pendingCleanups.append(cleanup)
        do {
            try persist()
        } catch {
            state = previousState
            throw error
        }
        return cleanup
    }

    public func recordCleanupFailure(id: String) throws {
        guard let index = state.pendingCleanups.firstIndex(where: { $0.id == id }) else { return }
        let previousState = state
        state.pendingCleanups[index].attemptCount += 1
        do {
            try persist()
        } catch {
            state = previousState
            throw error
        }
    }

    public func completeCleanup(id: String) throws {
        guard state.pendingCleanups.contains(where: { $0.id == id }) else { return }
        let previousState = state
        state.pendingCleanups.removeAll { $0.id == id }
        do {
            try persist()
        } catch {
            state = previousState
            throw error
        }
    }

    @discardableResult
    public func setInstalledSourceEnabled(id: String, isEnabled: Bool) throws -> InstalledRepositorySource {
        guard let index = state.installedSources.firstIndex(where: { $0.id == id }) else {
            throw RepositoryStoreError.sourceNotFound(id)
        }
        guard !isEnabled || state.installedSources[index].isRuntimeCompatible else {
            throw RepositoryVerificationError.unsupportedAPI(state.installedSources[index].apiVersion)
        }
        let previousState = state
        state.installedSources[index].isEnabled = isEnabled
        state.installedSources[index].descriptor.isEnabled = isEnabled
        do {
            try persist()
        } catch {
            state = previousState
            throw error
        }
        return state.installedSources[index]
    }

    public func blockRepository(id: String, message: String) throws -> [InstalledRepositorySource] {
        guard let repositoryIndex = state.repositories.firstIndex(where: { $0.id == id }) else {
            throw RepositoryStoreError.repositoryNotFound(id)
        }
        let previousState = state
        state.repositories[repositoryIndex].isBlocked = true
        _ = message
        var affected: [InstalledRepositorySource] = []
        for index in state.installedSources.indices where state.installedSources[index].repositoryID == id {
            state.installedSources[index].isEnabled = false
            state.installedSources[index].descriptor.isEnabled = false
            affected.append(state.installedSources[index])
        }
        do {
            try persist()
        } catch {
            state = previousState
            throw error
        }
        return affected
    }

    public func restoreReferences(
        repositories: [RepositoryRecord],
        installedSources: [InstalledRepositorySource],
        preservingExistingInstallations: Bool = false
    ) throws {
        let previousState = state
        let pendingRepositoryIDs = Set(
            state.pendingCleanups
                .filter { $0.scope == .repository }
                .map(\.repositoryID)
        )
        let pendingSourceIDs = Set(
            state.pendingCleanups
                .flatMap(\.installedSources)
                .map(\.id)
        )
        state.repositories = repositories.filter { !pendingRepositoryIDs.contains($0.id) }
        for cleanup in state.pendingCleanups where cleanup.scope == .source {
            guard let sourceID = cleanup.sourceID,
                  let repositoryIndex = state.repositories.firstIndex(where: { $0.id == cleanup.repositoryID })
            else { continue }
            state.repositories[repositoryIndex].knownSourceIDs.remove(sourceID)
            state.repositories[repositoryIndex].newSourceIDs.remove(sourceID)
        }
        // Restored executable sources remain disabled until their packages are
        // downloaded and initialized again. Package bytes never enter backups.
        state.installedSources = installedSources.compactMap { source in
            guard !pendingRepositoryIDs.contains(source.repositoryID),
                  !pendingSourceIDs.contains(source.id)
            else { return nil }
            if preservingExistingInstallations,
               let existing = previousState.installedSources.first(where: { $0.id == source.id }),
               existing.scriptSHA256 == source.scriptSHA256,
               let previousRepository = previousState.repositories.first(where: { $0.id == source.repositoryID }),
               let incomingRepository = repositories.first(where: { $0.id == source.repositoryID }),
               previousRepository.hasSameCatalog(as: incomingRepository) {
                return existing
            }
            var source = source
            if source.entryType == .mankoExtension {
                source.accessGrant = nil
                source.isEnabled = false
                source.descriptor.isEnabled = false
            }
            return source
        }
        do {
            try persist()
        } catch {
            state = previousState
            throw error
        }
    }

    private func refreshedRecord(
        previous: RepositoryRecord,
        incoming: RepositoryRecord
    ) -> (record: RepositoryRecord, delta: RepositoryRefreshDelta) {
        let previousIDs = Set(previous.manifest.sources.map(\.id))
        let incomingIDs = Set(incoming.manifest.sources.map(\.id))
        let newIDs = incomingIDs.subtracting(previous.knownSourceIDs)
        let installedBySourceID = Dictionary(
            uniqueKeysWithValues: state.installedSources
                .filter { $0.repositoryID == previous.id }
                .map { ($0.sourceID, $0) }
        )
        let updateIDs = Set(incoming.manifest.sources.compactMap { entry in
            RepositoryVersion.hasUpdate(entry: entry, installed: installedBySourceID[entry.id])
                ? entry.id
                : nil
        })
        var updated = incoming
        updated.addedAt = previous.addedAt
        updated.isBlocked = previous.isBlocked
        updated.knownSourceIDs = previous.knownSourceIDs.union(incomingIDs)
        updated.newSourceIDs = newIDs
        return (
            updated,
            RepositoryRefreshDelta(
                repositoryID: previous.id,
                newSourceIDs: newIDs,
                removedSourceIDs: previousIDs.subtracting(incomingIDs),
                updateSourceIDs: updateIDs
            )
        )
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: [.atomic, isPrivate ? .completeFileProtection : .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func applyProtection(isPrivate: Bool, to url: URL) throws {
        #if os(iOS) || os(tvOS) || os(watchOS)
        try FileManager.default.setAttributes(
            [.protectionKey: isPrivate ? FileProtectionType.complete : .completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #else
        _ = url
        #endif
    }
}
