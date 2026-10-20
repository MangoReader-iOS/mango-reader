import CryptoKit
import Foundation
import MangoReaderDomain

public enum RepositoryEntryType: String, Codable, CaseIterable, Sendable {
    case connectorPreset
    case mangoReaderExtension = "extension"
}

public enum ExtensionKind: String, Codable, CaseIterable, Sendable {
    case content
    case tracker
}

public enum ExtensionAvailability: String, CaseIterable, Sendable, Codable {
    case available
    case serviceUnavailable
    case retired

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        if value == "approvalRequired" {
            self = .available
        } else if let availability = Self(rawValue: value) {
            self = availability
        } else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unsupported extension availability \(value)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ExtensionPermission: String, Codable, CaseIterable, Sendable {
    case network
    case cookies
    case state
    case secureState
    case rateLimiting
    case redactedLogging
    case challengeHandoff
    case authenticationHandoff
    case managedCollections
    case trackerUpdates
    case webExecution
}

public struct ExtensionPermissionSet: Codable, Hashable, Sendable {
    public var values: Set<ExtensionPermission>

    public init(_ values: Set<ExtensionPermission> = []) {
        self.values = values
    }

    public func isSuperset(of other: Self) -> Bool {
        values.isSuperset(of: other.values)
    }
}

public enum ExtensionAuthenticationMode: String, Codable, CaseIterable, Sendable {
    case none
    case basic
    case bearer
    case apiKey
    case oauth2Implicit
    case oauth2PKCE
    case visibleWebSession
}

public enum RepositoryMaturityRating: String, Codable, CaseIterable, Sendable {
    case safe = "SAFE"
    case mature = "MATURE"
    case adult = "ADULT"
}

public enum RepositoryCapability: String, Codable, CaseIterable, Sendable {
    case browse
    case discover
    case search
    case filters
    case details
    case installments
    case acquisition
    case imageSequence
    case updates
    case managedCollections
    case settings
    case authentication
    case interceptors
    case cookies
    case challengeHandoff
    case trackerSearch
    case progress
    case trackerCollections

    public var sourceCapability: SourceCapability? {
        switch self {
        case .browse: .browse
        case .discover: .discover
        case .search, .trackerSearch: .search
        case .filters: .filters
        case .authentication: .authentication
        case .acquisition: .acquisition
        case .imageSequence: .imageSequence
        case .updates: .updates
        case .managedCollections: .managedCollections
        case .details, .installments, .settings, .interceptors, .cookies,
             .challengeHandoff, .progress, .trackerCollections: nil
        }
    }
}

public struct RepositoryPublisher: Codable, Hashable, Sendable {
    public var name: String

    public init(name: String, publicKey: String? = nil) {
        self.name = name
        _ = publicKey // Legacy manifests may include this field; Codable ignores it.
    }
}

public struct SourceRepositoryIdentity: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var homepage: String
    public var privacyURL: String
    public var publisher: RepositoryPublisher

    public init(
        id: String,
        name: String,
        description: String,
        homepage: String,
        privacyURL: String,
        publisher: RepositoryPublisher
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.homepage = homepage
        self.privacyURL = privacyURL
        self.publisher = publisher
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, homepage, privacyURL, publisher
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        homepage = try values.decodeIfPresent(String.self, forKey: .homepage) ?? ""
        privacyURL = try values.decodeIfPresent(String.self, forKey: .privacyURL) ?? ""
        publisher = try values.decode(RepositoryPublisher.self, forKey: .publisher)
    }
}

public struct ConnectorPresetPayload: Codable, Hashable, Sendable {
    public var kind: SourceKind
    public var baseURL: String
    public var options: [String: String]

    public init(kind: SourceKind, baseURL: String, options: [String: String] = [:]) {
        self.kind = kind
        self.baseURL = baseURL
        self.options = options
    }
}

public enum ExtensionExecutionFormat: String, Codable, Hashable, Sendable {
    case wasm
    case javascript
    case unsupported

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unsupported
    }
}

public struct MangoReaderExtensionPayload: Codable, Hashable, Sendable {
    public static let supportedAPIVersion = "3.0"
    // Legacy metadata remains readable for explicit migration and backups.
    public static let supportedAPIVersions: Set<String> = ["1.0", "1.1", "1.2", "2.0", "3.0"]

    public var apiVersion: String
    public var connectorKind: SourceKind?
    public var runtime: ExtensionExecutionFormat
    public var moduleURL: String?
    public var scriptURL: String
    public var sha256: String
    public var size: Int
    public var allowedHTTPSHosts: [String]
    public var accountPolicy: ExtensionAccountPolicy?
    public var authenticationModes: Set<ExtensionAuthenticationMode>

    public init(
        apiVersion: String = "1.0",
        scriptURL: String,
        sha256: String = "",
        size: Int,
        allowedHTTPSHosts: [String] = [],
        authenticationModes: Set<ExtensionAuthenticationMode> = [.none],
        connectorKind: SourceKind? = nil,
        accountPolicy: ExtensionAccountPolicy? = nil
    ) {
        self.apiVersion = apiVersion
        self.connectorKind = connectorKind
        self.accountPolicy = accountPolicy
        self.runtime = .javascript
        self.moduleURL = nil
        self.scriptURL = scriptURL
        self.sha256 = sha256
        self.size = size
        self.allowedHTTPSHosts = allowedHTTPSHosts
        self.authenticationModes = authenticationModes
    }

    public init(
        apiVersion: String = Self.supportedAPIVersion,
        moduleURL: String,
        sha256: String,
        size: Int,
        allowedHTTPSHosts: [String] = [],
        authenticationModes: Set<ExtensionAuthenticationMode> = [.none],
        connectorKind: SourceKind? = nil,
        accountPolicy: ExtensionAccountPolicy? = nil
    ) {
        self.init(apiVersion: apiVersion, scriptURL: moduleURL, sha256: sha256, size: size,
                  allowedHTTPSHosts: allowedHTTPSHosts, authenticationModes: authenticationModes, connectorKind: connectorKind, accountPolicy: accountPolicy)
        runtime = .wasm
        self.moduleURL = moduleURL
    }

    public var isExecutable: Bool { runtime == .wasm && apiVersion == "3.0" && moduleURL != nil }
    public var artifactURL: String { moduleURL ?? scriptURL }

    private enum CodingKeys: String, CodingKey {
        case apiVersion, runtime, moduleURL, scriptURL, sha256, size
        case allowedHTTPSHosts, authenticationModes, connectorKind, accountPolicy
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        apiVersion = try values.decodeIfPresent(String.self, forKey: .apiVersion) ?? "1.0"
        connectorKind = try values.decodeIfPresent(SourceKind.self, forKey: .connectorKind)
        runtime = try values.decodeIfPresent(ExtensionExecutionFormat.self, forKey: .runtime) ?? .javascript
        moduleURL = try values.decodeIfPresent(String.self, forKey: .moduleURL)
        scriptURL = try values.decodeIfPresent(String.self, forKey: .scriptURL) ?? moduleURL ?? ""
        sha256 = try values.decode(String.self, forKey: .sha256)
        size = try values.decode(Int.self, forKey: .size)
        allowedHTTPSHosts = try values.decodeIfPresent([String].self, forKey: .allowedHTTPSHosts) ?? []
        accountPolicy = try values.decodeIfPresent(ExtensionAccountPolicy.self, forKey: .accountPolicy)
        authenticationModes = try values.decodeIfPresent(
            Set<ExtensionAuthenticationMode>.self,
            forKey: .authenticationModes
        ) ?? [.none]
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(apiVersion, forKey: .apiVersion)
        try values.encodeIfPresent(connectorKind, forKey: .connectorKind)
        try values.encode(runtime, forKey: .runtime)
        if runtime == .wasm { try values.encodeIfPresent(moduleURL, forKey: .moduleURL) }
        else { try values.encode(scriptURL, forKey: .scriptURL) }
        try values.encode(sha256, forKey: .sha256)
        try values.encode(size, forKey: .size)
        try values.encode(allowedHTTPSHosts, forKey: .allowedHTTPSHosts)
        try values.encodeIfPresent(accountPolicy, forKey: .accountPolicy)
        try values.encode(authenticationModes, forKey: .authenticationModes)
    }
}

public struct SourceRepositoryEntryV2: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var version: String
    public var icon: String
    public var languages: [String]
    public var maturityRating: RepositoryMaturityRating
    public var capabilities: Set<RepositoryCapability>
    public var developers: [RepositoryPublisher]
    public var universalLink: String?
    public var rightsDeclaration: String
    public var rightsURL: String
    public var reportURL: String
    public var sourceURL: String?
    public var sourceRevision: String?
    public var entryType: RepositoryEntryType
    public var kind: ExtensionKind?
    public var availability: ExtensionAvailability
    public var permissions: ExtensionPermissionSet
    public var connectorPreset: ConnectorPresetPayload?
    public var mangoReaderExtension: MangoReaderExtensionPayload?

    public init(
        id: String,
        name: String,
        description: String,
        version: String,
        icon: String,
        languages: [String],
        maturityRating: RepositoryMaturityRating,
        capabilities: Set<RepositoryCapability>,
        developers: [RepositoryPublisher],
        universalLink: String? = nil,
        rightsDeclaration: String,
        rightsURL: String,
        reportURL: String,
        sourceURL: String? = nil,
        sourceRevision: String? = nil,
        entryType: RepositoryEntryType,
        kind: ExtensionKind? = nil,
        availability: ExtensionAvailability = .available,
        permissions: ExtensionPermissionSet = .init(),
        connectorPreset: ConnectorPresetPayload? = nil,
        mangoReaderExtension: MangoReaderExtensionPayload? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.icon = icon
        self.languages = languages
        self.maturityRating = maturityRating
        self.capabilities = capabilities
        self.developers = developers
        self.universalLink = universalLink
        self.rightsDeclaration = rightsDeclaration
        self.rightsURL = rightsURL
        self.reportURL = reportURL
        self.sourceURL = sourceURL
        self.sourceRevision = sourceRevision
        self.entryType = entryType
        self.kind = kind
        self.availability = availability
        self.permissions = permissions
        self.connectorPreset = connectorPreset
        self.mangoReaderExtension = mangoReaderExtension
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case version
        case icon
        case languages
        case maturityRating = "contentRating"
        case capabilities
        case developers
        case universalLink
        case rightsDeclaration
        case rightsURL
        case reportURL
        case sourceURL
        case sourceRevision
        case entryType
        case kind
        case availability
        case permissions
        case connectorPreset
        case mangoReaderExtension = "extension"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        version = try values.decode(String.self, forKey: .version)
        icon = try values.decodeIfPresent(String.self, forKey: .icon) ?? ""
        languages = try values.decodeIfPresent([String].self, forKey: .languages) ?? []
        maturityRating = try values.decodeIfPresent(
            RepositoryMaturityRating.self,
            forKey: .maturityRating
        ) ?? .safe
        capabilities = try values.decodeIfPresent(Set<RepositoryCapability>.self, forKey: .capabilities) ?? []
        developers = try values.decodeIfPresent([RepositoryPublisher].self, forKey: .developers) ?? []
        universalLink = try values.decodeIfPresent(String.self, forKey: .universalLink)
        rightsDeclaration = try values.decodeIfPresent(String.self, forKey: .rightsDeclaration) ?? ""
        rightsURL = try values.decodeIfPresent(String.self, forKey: .rightsURL) ?? ""
        reportURL = try values.decodeIfPresent(String.self, forKey: .reportURL) ?? ""
        sourceURL = try values.decodeIfPresent(String.self, forKey: .sourceURL)
        sourceRevision = try values.decodeIfPresent(String.self, forKey: .sourceRevision)
        entryType = try values.decode(RepositoryEntryType.self, forKey: .entryType)
        kind = try values.decodeIfPresent(ExtensionKind.self, forKey: .kind)
        availability = try values.decodeIfPresent(ExtensionAvailability.self, forKey: .availability) ?? .available
        permissions = try values.decodeIfPresent(ExtensionPermissionSet.self, forKey: .permissions) ?? .init()
        connectorPreset = try values.decodeIfPresent(ConnectorPresetPayload.self, forKey: .connectorPreset)
        mangoReaderExtension = try values.decodeIfPresent(
            MangoReaderExtensionPayload.self,
            forKey: .mangoReaderExtension
        )
    }
}

public typealias SourceRepositoryEntry = SourceRepositoryEntryV2

public struct SourceRepositoryManifestV2: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var repository: SourceRepositoryIdentity
    public var sources: [SourceRepositoryEntryV2]

    public init(
        schemaVersion: Int = 3,
        repository: SourceRepositoryIdentity,
        sources: [SourceRepositoryEntryV2]
    ) {
        self.schemaVersion = schemaVersion
        self.repository = repository
        self.sources = sources
    }
}

public struct RepositoryRecord: Codable, Hashable, Sendable, Identifiable {
    public var manifest: SourceRepositoryManifestV2
    public var repositoryURL: URL
    public var manifestURL: URL
    public var isBlocked: Bool
    public var addedAt: Date
    public var checkedAt: Date
    public var knownSourceIDs: Set<String>
    public var newSourceIDs: Set<String>

    public var id: String { manifest.repository.id }

    public func hasSameCatalog(as other: RepositoryRecord) -> Bool {
        repositoryURL == other.repositoryURL && manifestURL == other.manifestURL && manifest == other.manifest
    }

    public init(
        manifest: SourceRepositoryManifestV2,
        repositoryURL: URL,
        manifestURL: URL,
        isBlocked: Bool = false,
        addedAt: Date = .now,
        checkedAt: Date = .now,
        knownSourceIDs: Set<String>? = nil,
        newSourceIDs: Set<String> = []
    ) {
        self.manifest = manifest
        self.repositoryURL = repositoryURL
        self.manifestURL = manifestURL
        self.isBlocked = isBlocked
        self.addedAt = addedAt
        self.checkedAt = checkedAt
        self.knownSourceIDs = knownSourceIDs ?? Set(manifest.sources.map(\.id))
        self.newSourceIDs = newSourceIDs
    }

    public func isNewSource(_ sourceID: String) -> Bool {
        newSourceIDs.contains(sourceID)
    }

    private enum CodingKeys: String, CodingKey {
        case manifest, repositoryURL, manifestURL, isBlocked, addedAt, checkedAt
        case knownSourceIDs, newSourceIDs
        case trustState // Legacy repository-state field; only `blocked` is migrated.
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        manifest = try values.decode(SourceRepositoryManifestV2.self, forKey: .manifest)
        repositoryURL = try values.decode(URL.self, forKey: .repositoryURL)
        manifestURL = try values.decode(URL.self, forKey: .manifestURL)
        isBlocked = try values.decodeIfPresent(Bool.self, forKey: .isBlocked)
            ?? (try values.decodeIfPresent(String.self, forKey: .trustState) == "blocked")
        addedAt = try values.decode(Date.self, forKey: .addedAt)
        checkedAt = try values.decode(Date.self, forKey: .checkedAt)
        knownSourceIDs = try values.decodeIfPresent(Set<String>.self, forKey: .knownSourceIDs)
            ?? Set(manifest.sources.map(\.id))
        newSourceIDs = try values.decodeIfPresent(Set<String>.self, forKey: .newSourceIDs) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(manifest, forKey: .manifest)
        try values.encode(repositoryURL, forKey: .repositoryURL)
        try values.encode(manifestURL, forKey: .manifestURL)
        try values.encode(isBlocked, forKey: .isBlocked)
        try values.encode(addedAt, forKey: .addedAt)
        try values.encode(checkedAt, forKey: .checkedAt)
        try values.encode(knownSourceIDs, forKey: .knownSourceIDs)
        try values.encode(newSourceIDs, forKey: .newSourceIDs)
    }
}

public struct RepositoryRefreshDelta: Codable, Hashable, Sendable {
    public var repositoryID: String
    public var newSourceIDs: Set<String>
    public var removedSourceIDs: Set<String>
    public var updateSourceIDs: Set<String>

    public init(
        repositoryID: String,
        newSourceIDs: Set<String> = [],
        removedSourceIDs: Set<String> = [],
        updateSourceIDs: Set<String> = []
    ) {
        self.repositoryID = repositoryID
        self.newSourceIDs = newSourceIDs
        self.removedSourceIDs = removedSourceIDs
        self.updateSourceIDs = updateSourceIDs
    }
}

public struct RepositoryRefreshFailure: Codable, Hashable, Sendable, Identifiable {
    public var repositoryID: String
    public var message: String

    public var id: String { repositoryID }

    public init(repositoryID: String, message: String) {
        self.repositoryID = repositoryID
        self.message = message
    }
}

public struct RepositoryRefreshSummary: Codable, Hashable, Sendable {
    public var deltas: [RepositoryRefreshDelta]
    public var failures: [RepositoryRefreshFailure]

    public var checkedCount: Int { deltas.count + failures.count }
    public var newCount: Int { deltas.reduce(0) { $0 + $1.newSourceIDs.count } }
    public var updateCount: Int { deltas.reduce(0) { $0 + $1.updateSourceIDs.count } }
    public var failedCount: Int { failures.count }
    public var failedRepositoryIDs: Set<String> { Set(failures.map(\.repositoryID)) }

    public init(
        deltas: [RepositoryRefreshDelta] = [],
        failures: [RepositoryRefreshFailure] = []
    ) {
        self.deltas = deltas
        self.failures = failures
    }
}

public enum RepositoryCleanupScope: String, Codable, Hashable, Sendable {
    case source
    case repository
}

public struct PendingRepositoryCleanup: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var scope: RepositoryCleanupScope
    public var repositoryID: String
    public var sourceID: String?
    public var installedSources: [InstalledRepositorySource]
    public var createdAt: Date
    public var attemptCount: Int

    public init(
        id: String,
        scope: RepositoryCleanupScope,
        repositoryID: String,
        sourceID: String?,
        installedSources: [InstalledRepositorySource],
        createdAt: Date = .now,
        attemptCount: Int = 0
    ) {
        self.id = id
        self.scope = scope
        self.repositoryID = repositoryID
        self.sourceID = sourceID
        self.installedSources = installedSources
        self.createdAt = createdAt
        self.attemptCount = attemptCount
    }
}

public enum RepositoryVersion {
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) == .orderedDescending
    }

    public static func hasUpdate(
        entry: SourceRepositoryEntry,
        installed: InstalledRepositorySource?
    ) -> Bool {
        guard let installed else { return false }
        if !installed.isRuntimeCompatible, entry.mangoReaderExtension?.isExecutable == true {
            return compare(entry.version, installed.version) != .orderedAscending
        }
        return isNewer(entry.version, than: installed.version)
    }

    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let lhs = SemanticVersion(lhs), let rhs = SemanticVersion(rhs) {
            return lhs.compare(to: rhs)
        }
        return lhs.compare(rhs, options: [.numeric, .caseInsensitive])
    }

    private struct SemanticVersion {
        var core: [Int]
        var prerelease: [String]?

        init?(_ value: String) {
            let buildParts = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
            guard Self.validIdentifiers(buildParts.dropFirst().first, permitsNumericLeadingZero: true) else {
                return nil
            }
            let parts = buildParts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let rawCore = parts[0].split(separator: ".", omittingEmptySubsequences: false)
            guard rawCore.count == 3,
                  rawCore.allSatisfy(Self.validCoreIdentifier),
                  rawCore.compactMap({ Int($0) }).count == rawCore.count
            else { return nil }
            core = rawCore.compactMap { Int($0) }
            if parts.count == 2 {
                let identifiers = parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                guard Self.validIdentifiers(parts[1], permitsNumericLeadingZero: false) else { return nil }
                prerelease = identifiers
            } else {
                prerelease = nil
            }
        }

        private static func validCoreIdentifier(_ value: Substring) -> Bool {
            !value.isEmpty
                && value.allSatisfy { $0.isASCII && $0.isNumber }
                && (value == "0" || value.first != "0")
        }

        private static func validIdentifiers(
            _ value: Substring?,
            permitsNumericLeadingZero: Bool
        ) -> Bool {
            guard let value else { return true }
            let identifiers = value.split(separator: ".", omittingEmptySubsequences: false)
            return !identifiers.isEmpty && identifiers.allSatisfy { identifier in
                guard !identifier.isEmpty,
                      identifier.allSatisfy({
                          $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
                      })
                else { return false }
                let isNumeric = identifier.allSatisfy(\.isNumber)
                return permitsNumericLeadingZero || !isNumeric || identifier == "0" || identifier.first != "0"
            }
        }

        func compare(to other: Self) -> ComparisonResult {
            let count = max(core.count, other.core.count)
            for index in 0 ..< count {
                let lhs = index < core.count ? core[index] : 0
                let rhs = index < other.core.count ? other.core[index] : 0
                if lhs != rhs { return lhs < rhs ? .orderedAscending : .orderedDescending }
            }
            switch (prerelease, other.prerelease) {
            case (nil, nil): return .orderedSame
            case (nil, _): return .orderedDescending
            case (_, nil): return .orderedAscending
            case let (lhs?, rhs?):
                for index in 0 ..< max(lhs.count, rhs.count) {
                    guard index < lhs.count else { return .orderedAscending }
                    guard index < rhs.count else { return .orderedDescending }
                    if lhs[index] == rhs[index] { continue }
                    let lhsNumber = Int(lhs[index])
                    let rhsNumber = Int(rhs[index])
                    switch (lhsNumber, rhsNumber) {
                    case let (left?, right?): return left < right ? .orderedAscending : .orderedDescending
                    case (_?, nil): return .orderedAscending
                    case (nil, _?): return .orderedDescending
                    case (nil, nil):
                        return lhs[index].compare(rhs[index], options: .literal)
                    }
                }
                return .orderedSame
            }
        }
    }
}

/// Builds the durable state namespace for an installed extension. Existing
/// short identifiers keep their historical value. Longer identifier pairs use
/// a readable prefix plus the full SHA-256 digest so truncation cannot make
/// distinct long pairs collide at the 128-byte storage boundary.
public enum ExtensionRuntimeNamespace {
    private static let maximumBytes = 128
    private static let digestBytes = 64

    public static func primary(repositoryID: String, sourceID: String) -> String {
        bounded(
            "\(repositoryID).\(sourceID)",
            digestSeed: "primary\0\(repositoryID)\0\(sourceID)"
        )
    }

    public static func staged(repositoryID: String, sourceID: String) -> String {
        bounded(
            "\(repositoryID).\(sourceID)-staged",
            digestSeed: "staged\0\(repositoryID)\0\(sourceID)"
        )
    }

    /// The namespace emitted by earlier builds. This is used only to copy old
    /// state forward; long legacy namespaces are never deleted because more
    /// than one source may have been truncated to the same value.
    public static func legacyPrimary(repositoryID: String, sourceID: String) -> String {
        let raw = "\(repositoryID).\(sourceID)"
        let legacy = raw.count <= maximumBytes ? raw : String(raw.prefix(maximumBytes))
        // Older builds measured characters, while durable storage measured
        // UTF-8 bytes. An oversized Unicode result could never have been
        // persisted, so there is no legacy namespace to copy in that case.
        return RepositoryURLPolicy.isSafeIdentifier(legacy)
            ? legacy
            : primary(repositoryID: repositoryID, sourceID: sourceID)
    }

    private static func bounded(_ raw: String, digestSeed: String) -> String {
        guard raw.utf8.count > maximumBytes else { return raw }
        let digest = SHA256.hash(data: Data(digestSeed.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let prefixBytes = maximumBytes - digestBytes - 1
        return "\(utf8Prefix(raw, maximumBytes: prefixBytes))-\(digest)"
    }

    private static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var count = 0
        for scalar in value.unicodeScalars {
            guard count + scalar.utf8.count <= maximumBytes else { break }
            scalars.append(scalar)
            count += scalar.utf8.count
        }
        return String(scalars)
    }
}

public struct InstalledMangoReaderExtension: Codable, Hashable, Sendable, Identifiable {
    public var repositoryID: String
    public var sourceID: String
    public var descriptor: SourceDescriptor
    public var entryType: RepositoryEntryType
    public var kind: ExtensionKind?
    public var availability: ExtensionAvailability
    public var version: String
    public var apiVersion: String
    public var connectorKind: SourceKind?
    public var runtime: ExtensionExecutionFormat
    public var scriptSHA256: String?
    public var capabilities: Set<RepositoryCapability>
    public var allowedHTTPSHosts: [String]
    public var accountPolicy: ExtensionAccountPolicy?
    public var authenticationModes: Set<ExtensionAuthenticationMode>
    public var permissions: ExtensionPermissionSet
    public var installedAt: Date
    public var isEnabled: Bool

    public var accessGrant: ExtensionAccessGrant?
    public var id: String { "\(repositoryID)::\(sourceID)" }
    public var isRuntimeCompatible: Bool {
        if entryType != .mangoReaderExtension { return true }
        guard apiVersion == "3.0", runtime == .wasm, let accessGrant,
              accessGrant.repositoryURL != nil,
              accessGrant.repositoryID == repositoryID, accessGrant.sourceID == sourceID,
              accessGrant.artifactHash == scriptSHA256?.lowercased() else { return false }
        let entry = SourceRepositoryEntry(id: sourceID, name: descriptor.name, description: "", version: version,
            icon: "", languages: [], maturityRating: .safe, capabilities: capabilities, developers: [],
            rightsDeclaration: "", rightsURL: "", reportURL: "", entryType: .mangoReaderExtension, kind: kind,
            permissions: permissions, mangoReaderExtension: .init(moduleURL: "main.wasm", sha256: scriptSHA256!, size: 1,
                allowedHTTPSHosts: allowedHTTPSHosts, authenticationModes: authenticationModes,
                connectorKind: connectorKind, accountPolicy: accountPolicy))
        return accessGrant.policyDigest == (try? ExtensionAccessGrant.digest(entry))
    }

    public init(
        repositoryID: String,
        sourceID: String,
        descriptor: SourceDescriptor,
        entryType: RepositoryEntryType,
        kind: ExtensionKind? = nil,
        availability: ExtensionAvailability = .available,
        version: String,
        apiVersion: String = MangoReaderExtensionPayload.supportedAPIVersion,
        scriptSHA256: String?,
        capabilities: Set<RepositoryCapability>,
        allowedHTTPSHosts: [String],
        authenticationModes: Set<ExtensionAuthenticationMode> = [.none],
        permissions: ExtensionPermissionSet = .init(),
        installedAt: Date = .now,
        isEnabled: Bool = true,
        runtime: ExtensionExecutionFormat? = nil,
        connectorKind: SourceKind? = nil
    ) {
        self.repositoryID = repositoryID
        self.sourceID = sourceID
        self.descriptor = descriptor
        self.entryType = entryType
        self.kind = kind
        self.availability = availability
        self.version = version
        self.apiVersion = apiVersion
        self.connectorKind = connectorKind
        self.runtime = runtime ?? (apiVersion == "3.0" ? .wasm : .javascript)
        self.scriptSHA256 = scriptSHA256
        self.capabilities = capabilities
        self.allowedHTTPSHosts = allowedHTTPSHosts
        self.authenticationModes = authenticationModes
        self.permissions = permissions
        self.installedAt = installedAt
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case repositoryID, sourceID, descriptor, entryType, kind, availability, version, apiVersion
        case scriptSHA256, capabilities, approvedCapabilities, allowedHTTPSHosts
        case authenticationModes, permissions, installedAt, isEnabled, runtime, connectorKind, accountPolicy, accessGrant
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accessGrant = try values.decodeIfPresent(ExtensionAccessGrant.self, forKey: .accessGrant)
        repositoryID = try values.decode(String.self, forKey: .repositoryID)
        sourceID = try values.decode(String.self, forKey: .sourceID)
        descriptor = try values.decode(SourceDescriptor.self, forKey: .descriptor)
        entryType = try values.decode(RepositoryEntryType.self, forKey: .entryType)
        kind = try values.decodeIfPresent(ExtensionKind.self, forKey: .kind)
        availability = try values.decodeIfPresent(ExtensionAvailability.self, forKey: .availability) ?? .available
        version = try values.decode(String.self, forKey: .version)
        apiVersion = try values.decodeIfPresent(String.self, forKey: .apiVersion) ?? "1.0"
        connectorKind = try values.decodeIfPresent(SourceKind.self, forKey: .connectorKind)
        runtime = try values.decodeIfPresent(ExtensionExecutionFormat.self, forKey: .runtime) ?? (apiVersion == "3.0" ? .wasm : .javascript)
        scriptSHA256 = try values.decodeIfPresent(String.self, forKey: .scriptSHA256)
        capabilities = try values.decodeIfPresent(Set<RepositoryCapability>.self, forKey: .capabilities)
            ?? values.decodeIfPresent(Set<RepositoryCapability>.self, forKey: .approvedCapabilities)
            ?? []
        allowedHTTPSHosts = try values.decodeIfPresent([String].self, forKey: .allowedHTTPSHosts) ?? []
        accountPolicy = try values.decodeIfPresent(ExtensionAccountPolicy.self, forKey: .accountPolicy)
        authenticationModes = try values.decodeIfPresent(Set<ExtensionAuthenticationMode>.self, forKey: .authenticationModes) ?? [.none]
        permissions = try values.decodeIfPresent(ExtensionPermissionSet.self, forKey: .permissions) ?? .init()
        installedAt = try values.decode(Date.self, forKey: .installedAt)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? descriptor.isEnabled
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(accessGrant, forKey: .accessGrant)
        try values.encode(repositoryID, forKey: .repositoryID)
        try values.encode(sourceID, forKey: .sourceID)
        try values.encode(descriptor, forKey: .descriptor)
        try values.encode(entryType, forKey: .entryType)
        try values.encodeIfPresent(kind, forKey: .kind)
        try values.encode(availability, forKey: .availability)
        try values.encode(version, forKey: .version)
        try values.encode(apiVersion, forKey: .apiVersion)
        try values.encodeIfPresent(connectorKind, forKey: .connectorKind)
        try values.encode(runtime, forKey: .runtime)
        try values.encodeIfPresent(scriptSHA256, forKey: .scriptSHA256)
        try values.encode(capabilities, forKey: .capabilities)
        try values.encode(allowedHTTPSHosts, forKey: .allowedHTTPSHosts)
        try values.encodeIfPresent(accountPolicy, forKey: .accountPolicy)
        try values.encode(authenticationModes, forKey: .authenticationModes)
        try values.encode(permissions, forKey: .permissions)
        try values.encode(installedAt, forKey: .installedAt)
        try values.encode(isEnabled, forKey: .isEnabled)
    }
}

public typealias InstalledRepositorySource = InstalledMangoReaderExtension

public enum ExtensionInstallDisclosurePolicy {
    public static func requiresConfirmation(
        entry: SourceRepositoryEntry,
        installed: InstalledRepositorySource?
    ) -> Bool {
        guard let installed else { return true }
        return !installed.isRuntimeCompatible || expandsAccess(entry: entry, installed: installed)
    }

    public static func expandsAccess(
        entry: SourceRepositoryEntry,
        installed: InstalledRepositorySource
    ) -> Bool {
        installed.accessGrant?.policyDigest != (try? ExtensionAccessGrant.digest(entry))
    }
}

public struct RepositoryInstallResult: Codable, Hashable, Sendable, Identifiable {
    public var sourceID: String
    public var sourceName: String
    public var installed: Bool
    public var message: String

    public var id: String { sourceID }

    public init(sourceID: String, sourceName: String, installed: Bool, message: String) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.installed = installed
        self.message = message
    }
}

public struct RepositorySourceHealthIssue: Equatable, Sendable, Identifiable {
    public var installedSourceID: String
    public var sourceName: String
    public var message: String

    public var id: String { installedSourceID }

    public init(installedSourceID: String, sourceName: String, message: String) {
        self.installedSourceID = installedSourceID
        self.sourceName = sourceName
        self.message = message
    }
}

public struct RepositorySourceHealthReport: Equatable, Sendable {
    public var checkedCount: Int
    public var issues: [RepositorySourceHealthIssue]

    public init(checkedCount: Int = 0, issues: [RepositorySourceHealthIssue] = []) {
        self.checkedCount = checkedCount
        self.issues = issues
    }
}

public struct RepositorySourceRepairReport: Equatable, Sendable {
    public var checkedCount: Int
    public var repairedSourceIDs: Set<String>
    public var failures: [RepositorySourceHealthIssue]

    public var repairedCount: Int { repairedSourceIDs.count }

    public init(
        checkedCount: Int = 0,
        repairedSourceIDs: Set<String> = [],
        failures: [RepositorySourceHealthIssue] = []
    ) {
        self.checkedCount = checkedCount
        self.repairedSourceIDs = repairedSourceIDs
        self.failures = failures
    }
}

public enum SourceRepositoryLimits {
    public static let manifestBytes = 1 * 1_024 * 1_024
    public static let maximumEntries = 500
    public static let scriptBytes = 10 * 1_024 * 1_024
    public static let iconBytes = 2 * 1_024 * 1_024
    public static let selectedEntries = 100
    public static let deepLinkBytes = 8 * 1_024
}
