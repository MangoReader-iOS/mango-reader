import CryptoKit
import Foundation
import Security

public enum ExtensionStorageError: Error, Equatable, Sendable, LocalizedError {
    case invalidIdentifier
    case hashMismatch
    case sizeMismatch
    case scriptTooLarge
    case invalidScript
    case missingScript
    case encoding(String)
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "The extension storage identifier is invalid."
        case .hashMismatch: "The downloaded module does not match the catalog SHA-256 hash."
        case .sizeMismatch: "The downloaded module does not match the catalog byte count."
        case .scriptTooLarge: "The extension module exceeds 10 MiB."
        case .invalidScript: "The extension is not a WebAssembly module."
        case .missingScript: "The extension module is not installed on this device."
        case let .encoding(message): "Extension state could not be encoded: \(message)"
        case let .keychain(status): "Extension secure state Keychain operation failed (\(status))."
        }
    }
}

/// Identifies one live writer generation for an extension storage namespace.
/// Storage actors validate this value in the same actor turn as each mutation,
/// so revocation cannot race a delayed runtime or OAuth write.
struct ExtensionStorageWriteAuthorization: Hashable, Sendable {
    let namespace: String
    let generation: UInt64
    fileprivate let id: UUID

    init(namespace: String, generation: UInt64 = 1) {
        self.namespace = namespace
        self.generation = generation
        id = UUID()
    }
}

enum ExtensionStorageWriteAuthorizationError: Error, Equatable, Sendable {
    case stale
}

public actor ExtensionPackageStore {
    public struct StagedPackage: Hashable, Sendable {
        public var repositoryID: String
        public var sourceID: String
        public var version: String
        public var sha256: String
        public var url: URL
    }

    public struct ActivationReceipt: Hashable, Sendable {
        public var scriptURL: URL
        fileprivate var sourceDirectory: URL
        fileprivate var activatedVersion: String
        fileprivate var previousMarker: Data?
        fileprivate var previousPackage: URL?
    }

    private struct ActiveVersion: Codable, Sendable {
        var version: String
    }

    private let isPrivate: Bool
    private let rootDirectory: URL

    public init(rootDirectory: URL, isPrivate: Bool = false) throws {
        self.isPrivate = isPrivate
        self.rootDirectory = rootDirectory
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try protectAndExclude(rootDirectory)
    }

    public func stage(
        script data: Data,
        repositoryID: String,
        sourceID: String,
        version: String,
        expectedSHA256: String,
        expectedSize: Int
    ) async throws -> StagedPackage {
        guard data.count <= SourceRepositoryLimits.scriptBytes else {
            throw ExtensionStorageError.scriptTooLarge
        }
        guard data.count == expectedSize else { throw ExtensionStorageError.sizeMismatch }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA256.lowercased() else { throw ExtensionStorageError.hashMismatch }
        guard data.starts(with: [0, 97, 115, 109, 1, 0, 0, 0]) else { throw ExtensionStorageError.invalidScript }
        try validate(repositoryID)
        try validate(sourceID)
        try validate(version)

        let stagingDirectory = rootDirectory
            .appending(path: ".staging", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let mainURL = stagingDirectory.appending(path: "main.wasm", directoryHint: .notDirectory)
        try data.write(to: mainURL, options: [.atomic, isPrivate ? .completeFileProtection : .completeFileProtectionUntilFirstUserAuthentication])
        try protectAndExclude(stagingDirectory)
        return StagedPackage(
            repositoryID: repositoryID,
            sourceID: sourceID,
            version: version,
            sha256: expectedSHA256,
            url: mainURL
        )
    }

    /// Activates a staged package without deleting the previous version. The
    /// caller must initialize the staged runtime successfully before invoking this.
    public func activate(_ staged: StagedPackage) throws -> ActivationReceipt {
        let sourceDirectory = try directory(repositoryID: staged.repositoryID, sourceID: staged.sourceID)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let markerURL = sourceDirectory.appending(path: "active.json", directoryHint: .notDirectory)
        let previousMarker = try? Data(contentsOf: markerURL)
        let versionDirectory = sourceDirectory.appending(path: staged.version, directoryHint: .isDirectory)
        let previousPackage = FileManager.default.fileExists(atPath: versionDirectory.path)
            ? sourceDirectory.appending(path: ".rollback-\(UUID().uuidString)", directoryHint: .isDirectory) : nil
        if let previousPackage {
            try FileManager.default.moveItem(at: versionDirectory, to: previousPackage)
        }
        do {
            try FileManager.default.moveItem(at: staged.url.deletingLastPathComponent(), to: versionDirectory)

        let marker = ActiveVersion(version: staged.version)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(marker).write(
            to: markerURL,
            options: [.atomic, isPrivate ? .completeFileProtection : .completeFileProtectionUntilFirstUserAuthentication]
        )
        try protectAndExclude(sourceDirectory)
        } catch {
            try? FileManager.default.removeItem(at: versionDirectory)
            if let previousPackage { try? FileManager.default.moveItem(at: previousPackage, to: versionDirectory) }
            if let previousMarker { try? previousMarker.write(to: markerURL, options: .atomic) }
            else { try? FileManager.default.removeItem(at: markerURL) }
            throw error
        }
        return ActivationReceipt(
            scriptURL: versionDirectory.appending(path: "main.wasm", directoryHint: .notDirectory),
            sourceDirectory: sourceDirectory,
            activatedVersion: staged.version,
            previousMarker: previousMarker,
            previousPackage: previousPackage
        )
    }

    /// Restores the previous active marker after a later persistence failure.
    /// Versioned package bytes are intentionally retained for diagnostics and
    /// a future retry, while the previously active version remains selected.
    public func rollback(_ receipt: ActivationReceipt) throws {
        if let previousPackage = receipt.previousPackage {
            let activated = receipt.sourceDirectory.appending(path: receipt.activatedVersion, directoryHint: .isDirectory)
            try FileManager.default.removeItem(at: activated)
            try FileManager.default.moveItem(at: previousPackage, to: activated)
        }
        let markerURL = receipt.sourceDirectory.appending(path: "active.json", directoryHint: .notDirectory)
        if let previousMarker = receipt.previousMarker {
            try previousMarker.write(
                to: markerURL,
                options: [.atomic, isPrivate ? .completeFileProtection : .completeFileProtectionUntilFirstUserAuthentication]
            )
        } else {
            try? FileManager.default.removeItem(at: markerURL)
        }
    }

    public func commit(_ receipt: ActivationReceipt) throws {
        if let previousPackage = receipt.previousPackage { try FileManager.default.removeItem(at: previousPackage) }
    }

    public func activeScriptURL(repositoryID: String, sourceID: String) throws -> URL {
        let sourceDirectory = try directory(repositoryID: repositoryID, sourceID: sourceID)
        let markerURL = sourceDirectory.appending(path: "active.json", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: markerURL),
              let active = try? JSONDecoder().decode(ActiveVersion.self, from: data)
        else {
            throw ExtensionStorageError.missingScript
        }
        try validate(active.version)
        let scriptURL = sourceDirectory
            .appending(path: active.version, directoryHint: .isDirectory)
            .appending(path: "main.wasm", directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw ExtensionStorageError.missingScript
        }
        return scriptURL
    }

    func activeScriptIsValid(
        repositoryID: String,
        sourceID: String,
        version: String,
        expectedSHA256: String
    ) throws -> Bool {
        let sourceDirectory = try directory(repositoryID: repositoryID, sourceID: sourceID)
        let markerURL = sourceDirectory.appending(path: "active.json", directoryHint: .notDirectory)
        guard let markerData = try? Data(contentsOf: markerURL),
              let active = try? JSONDecoder().decode(ActiveVersion.self, from: markerData),
              active.version == version
        else { return false }
        try validate(active.version)

        let scriptURL = sourceDirectory
            .appending(path: active.version, directoryHint: .isDirectory)
            .appending(path: "main.wasm", directoryHint: .notDirectory)
        guard let script = try? Data(contentsOf: scriptURL),
              script.count <= SourceRepositoryLimits.scriptBytes,
              script.starts(with: [0, 97, 115, 109, 1, 0, 0, 0])
        else { return false }

        let digest = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
        return digest == expectedSHA256.lowercased()
    }

    public func discard(_ staged: StagedPackage) {
        try? FileManager.default.removeItem(at: staged.url.deletingLastPathComponent())
    }

    /// Only called after package activation and installation persistence succeed.
    public func removeLegacyPackages(repositoryID: String, sourceID: String) throws {
        let sourceDirectory = try directory(repositoryID: repositoryID, sourceID: sourceID)
        let versions = try FileManager.default.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
        for version in versions where version.lastPathComponent != "active.json" {
            let legacy = version.appending(path: "main.js")
            guard FileManager.default.fileExists(atPath: legacy.path) else { continue }
            try FileManager.default.removeItem(at: legacy)
            if (try FileManager.default.contentsOfDirectory(atPath: version.path)).isEmpty {
                try FileManager.default.removeItem(at: version)
            }
        }
    }

    public func remove(repositoryID: String, sourceID: String) throws {
        let sourceDirectory = try directory(repositoryID: repositoryID, sourceID: sourceID)
        guard FileManager.default.fileExists(atPath: sourceDirectory.path) else { return }
        try FileManager.default.removeItem(at: sourceDirectory)
    }

    private func directory(repositoryID: String, sourceID: String) throws -> URL {
        try validate(repositoryID)
        try validate(sourceID)
        return rootDirectory
            .appending(path: repositoryID, directoryHint: .isDirectory)
            .appending(path: sourceID, directoryHint: .isDirectory)
    }

    private func validate(_ identifier: String) throws {
        guard RepositoryURLPolicy.isSafeIdentifier(identifier) else {
            throw ExtensionStorageError.invalidIdentifier
        }
    }

    private nonisolated func protectAndExclude(_ url: URL) throws {
        #if os(iOS) || os(tvOS) || os(watchOS)
        try FileManager.default.setAttributes(
            [.protectionKey: isPrivate ? FileProtectionType.complete : .completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}

public actor ExtensionStateStore {
    private struct State: Codable, Sendable {
        var values: [String: Data] = [:]
    }

    private let isPrivate: Bool
    private let rootDirectory: URL
    private var activeWriteAuthorizations: [String: ExtensionStorageWriteAuthorization] = [:]
    private var revokedWriteGenerations: [String: UInt64] = [:]

    public init(rootDirectory: URL, isPrivate: Bool = false) throws {
        self.isPrivate = isPrivate
        self.rootDirectory = rootDirectory
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try Self.protectAndExclude(rootDirectory, isPrivate: isPrivate)
    }

    public func values(namespace: String) throws -> [String: Data] {
        try load(namespace: namespace).values
    }

    @discardableResult
    func activateWriteAuthorization(_ authorization: ExtensionStorageWriteAuthorization) -> Bool {
        let namespace = authorization.namespace
        guard authorization.generation > revokedWriteGenerations[namespace, default: 0],
              activeWriteAuthorizations[namespace].map({ $0.generation <= authorization.generation }) ?? true
        else { return false }
        activeWriteAuthorizations[namespace] = authorization
        return true
    }

    func revokeWriteAuthorization(
        namespace: String,
        through generation: UInt64
    ) {
        revokedWriteGenerations[namespace] = max(
            revokedWriteGenerations[namespace, default: 0],
            generation
        )
        if let active = activeWriteAuthorizations[namespace], active.generation <= generation {
            activeWriteAuthorizations[namespace] = nil
        }
    }

    public func set(_ value: Data?, key: String, namespace: String) throws {
        var state = try load(namespace: namespace)
        state.values[key] = value
        try persist(state, namespace: namespace)
    }

    func set(
        _ value: Data?,
        key: String,
        namespace: String,
        authorization: ExtensionStorageWriteAuthorization
    ) throws {
        try validate(authorization)
        if let value {
            let other = try values(namespace: namespace).filter { $0.key != key }
            guard other.count < 256, value.count <= 1_024 * 1_024,
                  other.values.reduce(0, { $0 + $1.count }) + value.count <= 4 * 1_024 * 1_024
            else { throw MangoReaderExtensionRuntimeError.responseTooLarge }
        }
        try set(value, key: key, namespace: namespace)
    }

    public func reset(namespace: String) throws {
        let url = try fileURL(namespace: namespace)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func reset(
        namespace: String,
        authorization: ExtensionStorageWriteAuthorization
    ) throws {
        try validate(authorization)
        try reset(namespace: namespace)
    }

    /// Revokes this generation and removes its namespace only when a newer
    /// writer has not already been activated for a reinstall.
    func revokeAndReset(_ authorization: ExtensionStorageWriteAuthorization) throws {
        let namespace = authorization.namespace
        revokeWriteAuthorization(namespace: namespace, through: authorization.generation)
        guard (activeWriteAuthorizations[namespace]?.generation ?? 0) <= authorization.generation else { return }
        try reset(namespace: namespace)
    }

    private func validate(_ authorization: ExtensionStorageWriteAuthorization) throws {
        guard activeWriteAuthorizations[authorization.namespace] == authorization,
              authorization.generation > revokedWriteGenerations[authorization.namespace, default: 0]
        else { throw ExtensionStorageWriteAuthorizationError.stale }
    }

    private func load(namespace: String) throws -> State {
        let url = try fileURL(namespace: namespace)
        guard FileManager.default.fileExists(atPath: url.path) else { return State() }
        do {
            return try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
        } catch {
            throw ExtensionStorageError.encoding(error.localizedDescription)
        }
    }

    private func persist(_ state: State, namespace: String) throws {
        let url = try fileURL(namespace: namespace)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(
                to: url,
                options: [.atomic, isPrivate ? .completeFileProtection : .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            throw ExtensionStorageError.encoding(error.localizedDescription)
        }
    }

    private func fileURL(namespace: String) throws -> URL {
        guard RepositoryURLPolicy.isSafeIdentifier(namespace) else {
            throw ExtensionStorageError.invalidIdentifier
        }
        return rootDirectory.appending(path: "\(namespace).json", directoryHint: .notDirectory)
    }

    private static func protectAndExclude(_ url: URL, isPrivate: Bool = false) throws {
        #if os(iOS) || os(tvOS) || os(watchOS)
        try FileManager.default.setAttributes(
            [.protectionKey: isPrivate ? FileProtectionType.complete : .completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}

public actor ExtensionSecureStateStore {
    private struct LegacyAccountClaim: Hashable {
        var namespace: String
        var key: String
    }

    private struct LegacyIndexRecord {
        var namespace: String
        var keys: Set<String>?
    }

    private let isPrivate: Bool
    private let service: String
    private var activeWriteAuthorizations: [String: ExtensionStorageWriteAuthorization] = [:]
    private var revokedWriteGenerations: [String: UInt64] = [:]

    public init(service: String = "com.k800k.manko.extensions", isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        self.service = service
    }

    public func value(namespace: String, key: String) throws -> Data? {
        let account = try account(namespace: namespace, key: key)
        if let data = try keychainValue(account: account) {
            guard key != "__keys" || validatedIndexKeys(from: data, namespace: namespace) != nil else {
                return nil
            }
            return data
        }

        // Keep a nonsecret removal tombstone outside the namespace's account
        // prefix. An ambiguous, unindexed legacy item cannot be erased safely,
        // but it must never be imported into a later reinstall.
        if try keychainValue(account: legacySuppressionAccount(namespace: namespace)) != nil {
            return nil
        }

        let legacyAccount = try legacyAccount(namespace: namespace, key: key)
        guard let data = try keychainValue(account: legacyAccount) else { return nil }
        // Version-one accounts used `.` between two components which could
        // themselves contain dots. Every decodable namespace index is treated
        // as an ownership claim; migrate only when this exact namespace/key is
        // the sole claimant for the physical Keychain account.
        guard try uniquelyOwnsLegacyAccount(namespace: namespace, key: key) else {
            return nil
        }
        if key == "__keys",
           validatedIndexKeys(from: data, namespace: namespace) == nil {
            return nil
        }
        try setKeychainValue(data, account: account)
        return data
    }

    private func keychainValue(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ExtensionStorageError.keychain(status)
        }
        return data
    }

    public func values(namespace: String) throws -> [String: Data] {
        guard let indexData = try value(namespace: namespace, key: "__keys"),
              let keys = validatedIndexKeys(from: indexData, namespace: namespace)
        else { return [:] }
        var result: [String: Data] = [:]
        for key in keys {
            result[key] = try value(namespace: namespace, key: key)
        }
        return result
    }

    @discardableResult
    func activateWriteAuthorization(_ authorization: ExtensionStorageWriteAuthorization) -> Bool {
        let namespace = authorization.namespace
        guard authorization.generation > revokedWriteGenerations[namespace, default: 0],
              activeWriteAuthorizations[namespace].map({ $0.generation <= authorization.generation }) ?? true
        else { return false }
        activeWriteAuthorizations[namespace] = authorization
        return true
    }

    func revokeWriteAuthorization(
        namespace: String,
        through generation: UInt64
    ) {
        revokedWriteGenerations[namespace] = max(
            revokedWriteGenerations[namespace, default: 0],
            generation
        )
        if let active = activeWriteAuthorizations[namespace], active.generation <= generation {
            activeWriteAuthorizations[namespace] = nil
        }
    }

    public func set(_ value: Data?, namespace: String, key: String) throws {
        let account = try account(namespace: namespace, key: key)
        try setKeychainValue(value, account: account)

        // A legacy item can be removed only when all legacy indexes agree that
        // this namespace/key is its sole owner.
        guard value == nil else { return }
        // Namespace indexes are ambiguity evidence for every value they name.
        // Only removeNamespace evaluates the whole index before deleting it.
        guard key != "__keys" else { return }
        if try uniquelyOwnsLegacyAccount(namespace: namespace, key: key) {
            try setKeychainValue(
                nil,
                account: try legacyAccount(namespace: namespace, key: key)
            )
        }
    }

    private func setKeychainValue(_ value: Data?, account: String) throws {
        let query = baseQuery(account: account)
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ExtensionStorageError.keychain(status)
            }
            return
        }
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: (isPrivate ? kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly),
            kSecValueData as String: value,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            attributes.forEach { add[$0.key] = $0.value }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ExtensionStorageError.keychain(status) }
    }

    public func removeNamespace(_ namespace: String) throws {
        guard RepositoryURLPolicy.isSafeIdentifier(namespace) else {
            throw ExtensionStorageError.invalidIdentifier
        }
        // Suppress every legacy fallback before deletion begins. If cleanup is
        // interrupted, a reinstall may create fresh v2 values but can never
        // resurrect delimiter-ambiguous state from the removed installation.
        try setKeychainValue(
            Data([1]),
            account: try legacySuppressionAccount(namespace: namespace)
        )
        // New accounts encode the namespace as one unambiguous segment, so all
        // of them (including unindexed writes) can be enumerated safely.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        #if os(macOS) || targetEnvironment(macCatalyst)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ExtensionStorageError.keychain(status)
        }
        if status == errSecSuccess {
            let attributes: [[String: Any]]
            if let matches = result as? [[String: Any]] {
                attributes = matches
            } else if let match = result as? [String: Any] {
                attributes = [match]
            } else {
                throw ExtensionStorageError.keychain(errSecDecode)
            }
            let accountPrefix = try accountPrefix(namespace: namespace)
            for account in attributes.compactMap({ $0[kSecAttrAccount as String] as? String })
            where account.hasPrefix(accountPrefix) {
                try deleteAccount(account)
            }
        }

        // Legacy accounts have an ambiguous delimiter and cannot be safely
        // prefix-enumerated. Delete only uniquely attributed values. If any
        // extant value is claimed by another namespace too, retain this
        // namespace's nonsecret index so the ambiguity cannot disappear and
        // later let that sibling import our historical secret.
        let legacyIndexAccount = try legacyAccount(namespace: namespace, key: "__keys")
        guard let legacyIndexData = try keychainValue(account: legacyIndexAccount),
              try uniquelyOwnsLegacyAccount(namespace: namespace, key: "__keys"),
              let legacyKeys = validatedIndexKeys(from: legacyIndexData, namespace: namespace)
        else { return }

        var mustRetainLegacyIndex = false
        for key in legacyKeys {
            let account = try legacyAccount(namespace: namespace, key: key)
            guard try keychainValue(account: account) != nil else { continue }
            if try uniquelyOwnsLegacyAccount(namespace: namespace, key: key) {
                try deleteAccount(account)
            } else {
                mustRetainLegacyIndex = true
            }
        }
        if !mustRetainLegacyIndex {
            try deleteAccount(legacyIndexAccount)
        }
    }

    public func setIndexed(_ value: Data?, namespace: String, key: String) throws {
        try validateAccountComponents(namespace: namespace, key: key)
        guard key != "__keys" else { throw ExtensionStorageError.invalidIdentifier }
        var keys: Set<String> = []
        let indexData = try self.value(namespace: namespace, key: "__keys")
        if let indexData,
           let decoded = validatedIndexKeys(from: indexData, namespace: namespace) {
            keys = decoded
        }
        if let value {
            // Record new keys before creating their secret-bearing item. A
            // stale index entry is harmless; an unindexed secret is not.
            if keys.insert(key).inserted {
                try set(try JSONEncoder().encode(keys), namespace: namespace, key: "__keys")
            }
            try set(value, namespace: namespace, key: key)
        } else {
            try set(nil, namespace: namespace, key: key)
            if keys.remove(key) != nil || indexData != nil {
                try set(try JSONEncoder().encode(keys), namespace: namespace, key: "__keys")
            }
        }
    }

    func setIndexed(
        _ value: Data?,
        namespace: String,
        key: String,
        authorization: ExtensionStorageWriteAuthorization
    ) throws {
        try validate(authorization)
        if let value {
            let other = try values(namespace: namespace).filter { $0.key != key }
            guard other.count < 256, value.count <= 1_024 * 1_024,
                  other.values.reduce(0, { $0 + $1.count }) + value.count <= 4 * 1_024 * 1_024
            else { throw MangoReaderExtensionRuntimeError.responseTooLarge }
        }
        try setIndexed(value, namespace: namespace, key: key)
    }

    /// Revokes this generation and removes its namespace only when a newer
    /// writer has not already been activated for a reinstall.
    func revokeAndRemove(_ authorization: ExtensionStorageWriteAuthorization) throws {
        let namespace = authorization.namespace
        revokeWriteAuthorization(namespace: namespace, through: authorization.generation)
        guard (activeWriteAuthorizations[namespace]?.generation ?? 0) <= authorization.generation else { return }
        try removeNamespace(namespace)
    }

    /// Atomically merges cookies received by concurrent broker responses. Keeping
    /// the read, merge, and indexed write in one actor turn prevents one response
    /// from replacing cookies persisted by another response.
    func mergeCookies(
        _ received: [ExtensionHTTPStateCookie],
        for origin: URL? = nil,
        namespace: String,
        authorization: ExtensionStorageWriteAuthorization
    ) throws {
        try validate(authorization)
        let now = Date.now
        var cookies = try storedCookies(namespace: namespace).filter { !$0.isExpired(at: now) }
        for cookie in received {
            cookies.removeAll { $0.hasSameIdentity(as: cookie) }
            guard !cookie.isExpired(at: now),
                  origin.map({ cookie.isValidForOrigin($0, at: now) }) ?? true
            else { continue }
            cookies.append(cookie)
        }
        try storeCookies(Array(cookies.suffix(100)), namespace: namespace)
    }

    /// Persists the WebKit identity and its scoped cookies in one actor turn.
    /// A changed user agent (or origin) invalidates every prior Cloudflare
    /// clearance before cookies from the newly verified browser are merged.
    func completeBrowserSession(
        profile: ExtensionBrowserSessionProfile,
        importing received: [ExtensionHTTPStateCookie],
        verificationURL: URL? = nil,
        namespace: String,
        authorization: ExtensionStorageWriteAuthorization
    ) throws {
        try validate(authorization)
        guard profile.isValid() else {
            throw ExtensionBrowserSessionError.invalidHTTPSOrigin
        }
        let clearanceURL = verificationURL ?? profile.canonicalHTTPSOrigin
        guard ExtensionBrowserSessionProfile.canonicalHTTPSOrigin(for: clearanceURL)
            == profile.canonicalHTTPSOrigin
        else {
            throw ExtensionBrowserSessionError.invalidHTTPSOrigin
        }

        let now = Date.now
        let currentProfile = try value(
            namespace: namespace,
            key: ExtensionBrowserSessionProfile.secureStateKey
        ).flatMap { try? JSONDecoder().decode(ExtensionBrowserSessionProfile.self, from: $0) }
        var cookies = try storedCookies(namespace: namespace).filter { !$0.isExpired(at: now) }
        if currentProfile?.userAgent != profile.userAgent
            || currentProfile?.canonicalHTTPSOrigin != profile.canonicalHTTPSOrigin {
            cookies.removeAll {
                $0.name.caseInsensitiveCompare("cf_clearance") == .orderedSame
            }
        }

        for cookie in received {
            cookies.removeAll { $0.hasSameIdentity(as: cookie) }
            guard cookie.isValidForOrigin(profile.canonicalHTTPSOrigin, at: now) else { continue }
            cookies.append(cookie)
        }
        guard cookies.contains(where: {
            $0.name.caseInsensitiveCompare("cf_clearance") == .orderedSame
                && $0.isApplicable(to: clearanceURL, at: now)
        }) else {
            throw ExtensionBrowserSessionError.missingClearanceCookie
        }

        try storeCookies(Array(cookies.suffix(100)), namespace: namespace)
        try setIndexed(
            JSONEncoder().encode(profile),
            namespace: namespace,
            key: ExtensionBrowserSessionProfile.secureStateKey
        )
        try setIndexed(
            nil,
            namespace: namespace,
            key: CloudflareChallengeContext.pendingSecureStateKey
        )
    }

    private func storedCookies(namespace: String) throws -> [ExtensionHTTPStateCookie] {
        guard let data = try value(namespace: namespace, key: "cookie_store_cookies") else { return [] }
        return (try? JSONDecoder().decode([ExtensionHTTPStateCookie].self, from: data)) ?? []
    }

    private func storeCookies(
        _ cookies: [ExtensionHTTPStateCookie],
        namespace: String
    ) throws {
        let data = try JSONEncoder().encode(cookies)
        guard data.count <= 128 * 1_024 else {
            throw ExtensionStorageError.encoding("Cloudflare cookie state exceeds 128 KiB.")
        }
        try setIndexed(
            data,
            namespace: namespace,
            key: "cookie_store_cookies"
        )
    }

    private func validate(_ authorization: ExtensionStorageWriteAuthorization) throws {
        guard activeWriteAuthorizations[authorization.namespace] == authorization,
              authorization.generation > revokedWriteGenerations[authorization.namespace, default: 0]
        else { throw ExtensionStorageWriteAuthorizationError.stale }
    }

    private func account(namespace: String, key: String) throws -> String {
        try validateAccountComponents(namespace: namespace, key: key)
        return try accountPrefix(namespace: namespace) + Self.encodedAccountSegment(key)
    }

    private func accountPrefix(namespace: String) throws -> String {
        guard RepositoryURLPolicy.isSafeIdentifier(namespace) else {
            throw ExtensionStorageError.invalidIdentifier
        }
        // The legacy format always starts with `source.`. A hyphen here makes
        // the v2 namespace structurally disjoint from every possible v1
        // namespace/key combination.
        return "source-v2.\(Self.encodedAccountSegment(namespace))."
    }

    private func legacyAccount(namespace: String, key: String) throws -> String {
        try validateAccountComponents(namespace: namespace, key: key)
        return "source.\(namespace).\(key)"
    }

    private func legacySuppressionAccount(namespace: String) throws -> String {
        guard RepositoryURLPolicy.isSafeIdentifier(namespace) else {
            throw ExtensionStorageError.invalidIdentifier
        }
        return "source-v2-removed.\(Self.encodedAccountSegment(namespace))"
    }

    private func validateAccountComponents(namespace: String, key: String) throws {
        guard RepositoryURLPolicy.isSafeIdentifier(namespace),
              !key.isEmpty,
              key.utf8.count <= 256,
              key != "__keys" || RepositoryURLPolicy.isSafeIdentifier(namespace)
        else { throw ExtensionStorageError.invalidIdentifier }
    }

    private func validatedIndexKeys(from data: Data, namespace: String) -> Set<String>? {
        guard let keys = try? JSONDecoder().decode(Set<String>.self, from: data),
              keys.allSatisfy({ key in
                  key != "__keys" && (try? legacyAccount(namespace: namespace, key: key)) != nil
              })
        else { return nil }
        return keys
    }

    private func uniquelyOwnsLegacyAccount(namespace: String, key: String) throws -> Bool {
        // The v1 delimiter makes a dotted key indistinguishable from a child
        // namespace, and a namespace with more than one dot indistinguishable
        // from a parent namespace plus a dotted key. Production extension
        // namespaces contain one repository/source separator, so those shapes
        // remain structurally ambiguous even if a competing index was deleted
        // before upgrade.
        guard !key.contains("."), namespace.filter({ $0 == "." }).count <= 1 else {
            return false
        }
        let account = try legacyAccount(namespace: namespace, key: key)
        let claims = try legacyClaims(for: account)
        return claims.count == 1 && claims.contains(
            LegacyAccountClaim(namespace: namespace, key: key)
        )
    }

    private func legacyClaims(for account: String) throws -> Set<LegacyAccountClaim> {
        var claims: Set<LegacyAccountClaim> = []
        for index in try legacyIndexRecords() {
            if try legacyAccount(namespace: index.namespace, key: "__keys") == account {
                claims.insert(LegacyAccountClaim(namespace: index.namespace, key: "__keys"))
            }
            if let keys = index.keys {
                for key in keys
                where (try? legacyAccount(namespace: index.namespace, key: key)) == account {
                    claims.insert(LegacyAccountClaim(namespace: index.namespace, key: key))
                }
            } else {
                // A corrupt index is not evidence that its namespace owns
                // nothing. Treat every account structurally below that
                // namespace as a possible claim so another dotted namespace
                // cannot absorb or delete its secrets.
                let prefix = "source.\(index.namespace)."
                if account.hasPrefix(prefix) {
                    let key = String(account.dropFirst(prefix.count))
                    if (try? legacyAccount(namespace: index.namespace, key: key)) == account {
                        claims.insert(LegacyAccountClaim(namespace: index.namespace, key: key))
                    }
                }
            }
        }
        return claims
    }

    private func legacyIndexRecords() throws -> [LegacyIndexRecord] {
        let accountPrefix = "source."
        let indexSuffix = ".__keys"
        return try keychainItems().compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix(accountPrefix),
                  account.hasSuffix(indexSuffix)
            else { return nil }

            let namespaceStart = account.index(account.startIndex, offsetBy: accountPrefix.count)
            let namespaceEnd = account.index(account.endIndex, offsetBy: -indexSuffix.count)
            guard namespaceStart < namespaceEnd else { return nil }
            let namespace = String(account[namespaceStart..<namespaceEnd])
            guard RepositoryURLPolicy.isSafeIdentifier(namespace) else { return nil }
            let keys = (item[kSecValueData as String] as? Data).flatMap {
                validatedIndexKeys(from: $0, namespace: namespace)
            }
            return LegacyIndexRecord(namespace: namespace, keys: keys)
        }
    }

    private func keychainItems() throws -> [[String: Any]] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        #if os(macOS) || targetEnvironment(macCatalyst)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw ExtensionStorageError.keychain(status)
        }
        if let matches = result as? [[String: Any]] { return matches }
        if let match = result as? [String: Any] { return [match] }
        throw ExtensionStorageError.keychain(errSecDecode)
    }

    private func deleteAccount(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ExtensionStorageError.keychain(status)
        }
    }

    private static func encodedAccountSegment(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        #if os(macOS) || targetEnvironment(macCatalyst)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
}
