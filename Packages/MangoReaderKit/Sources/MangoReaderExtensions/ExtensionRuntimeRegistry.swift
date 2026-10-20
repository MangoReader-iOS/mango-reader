import CryptoKit
import Foundation
import MangoReaderDomain
import MangoReaderSources
import SwiftPublicSuffixList

public actor ExtensionRuntimeRegistry {
    private enum NamespaceMigrationState: String {
        case migrated
        case removed
    }

    private static let namespaceMigrationLedger = "extension-namespace-migrations"

    // Hitomi hydrates a complete 25-card page before returning search results.
    // Give it the same bounded deadline as discovery, including network waits.
    nonisolated static func catalogSearchTimeout(entryID: String) -> Duration {
        entryID == "HitomiLA" ? .seconds(60) : .seconds(15)
    }

    private let isPrivate: Bool
    private var isLocked = false
    private let packageStore: ExtensionPackageStore
    private let stateStore: ExtensionStateStore
    private let secureStateStore: ExtensionSecureStateStore
    private let trackerOAuthTokenManager: TrackerOAuthTokenManager
    private var catalogRequestGates: [String: ExtensionCatalogRequestGate] = [:]
    private var adapters: [String: MangoReaderExtensionSourceAdapter] = [:]
    private var connectorCreationGates: [String: MangoReaderRequestPermitPool] = [:]
    private var connectorInstallations: [String: InstalledRepositorySource] = [:]
    private var connectorAdapters: [String: MangoReaderConnectorSourceAdapter] = [:]
    private var connectorConnectionGenerations: [SourceID: UInt64] = [:]
    private var connectorGenerations: [String: UInt64] = [:]
    private var removedConnectorProviders: [String: Date] = [:]
    private static let connectorNamespaceLedger = "connector-namespaces"

    private struct ConnectorNamespaceRecord: Codable {
        var providerID: String
        var sourceID: SourceID
    }

    private var trackerAdapters: [String: MangoReaderExtensionTrackerAdapter] = [:]
    private var adapterNamespaces: [String: String] = [:]
    private var storageWriteAuthorizations: [String: ExtensionStorageWriteAuthorization] = [:]
    private var storageWriteGenerations: [String: UInt64] = [:]

    public init(
        packageStore: ExtensionPackageStore,
        stateStore: ExtensionStateStore,
        secureStateStore: ExtensionSecureStateStore,
        isPrivate: Bool = false
    ) {
        self.isPrivate = isPrivate
        self.packageStore = packageStore
        self.stateStore = stateStore
        self.secureStateStore = secureStateStore
        trackerOAuthTokenManager = TrackerOAuthTokenManager(secureStateStore: secureStateStore)
    }

    public func namespace(repositoryID: String, sourceID: String) -> String {
        primaryNamespace(repositoryID: repositoryID, sourceID: sourceID)
    }

    private func primaryNamespace(repositoryID: String, sourceID: String) -> String {
        ExtensionRuntimeNamespace.primary(repositoryID: isPrivate ? "private-" + repositoryID : repositoryID, sourceID: sourceID)
    }

    private func stagedNamespace(repositoryID: String, sourceID: String) -> String {
        ExtensionRuntimeNamespace.staged(repositoryID: isPrivate ? "private-" + repositoryID : repositoryID, sourceID: sourceID)
    }

    private func legacyNamespace(repositoryID: String, sourceID: String) -> String {
        ExtensionRuntimeNamespace.legacyPrimary(repositoryID: isPrivate ? "private-" + repositoryID : repositoryID, sourceID: sourceID)
    }

    private func scopedConnectorNamespace(providerID: String, sourceID: SourceID) -> String {
        Self.connectorNamespace(providerID: isPrivate ? "private-" + providerID : providerID, sourceID: sourceID)
    }

    /// Revoke durable writers before resetting runtimes so late callbacks cannot save state.
    public func lock() async {
        isLocked = true
        for namespace in Array(storageWriteGenerations.keys) { await revokeNamespace(namespace) }
        storageWriteAuthorizations.removeAll()
        for adapter in adapters.values { await adapter.resetRuntime() }
        for adapter in connectorAdapters.values { await adapter.resetRuntime() }
        adapters.removeAll()
        connectorAdapters.removeAll()
        trackerAdapters.removeAll()
    }

    public func source(for installed: InstalledRepositorySource, requestSpeed: ExtensionRequestSpeed = .standard) async throws -> MangoReaderExtensionSourceAdapter {
        guard !isLocked, installed.entryType == .mangoReaderExtension,
              installed.isRuntimeCompatible,
              installed.kind == .content,
              installed.connectorKind == nil,
              installed.availability == .available,
              installed.isEnabled
        else {
            throw MangoReaderExtensionRuntimeError.sourceUnavailable
        }
        let gate: ExtensionCatalogRequestGate
        if let existing = catalogRequestGates[installed.id] { gate = existing }
        else {
            gate = await ExtensionCatalogRequestGate(speed: requestSpeed, sourceID: installed.sourceID)
            catalogRequestGates[installed.id] = gate
        }
        await setRequestSpeed(requestSpeed, installedSourceID: installed.id)
        if let adapter = adapters[installed.id] { return adapter }
        let scriptURL = try await packageStore.activeScriptURL(
            repositoryID: installed.repositoryID,
            sourceID: installed.sourceID
        )
        let rawNamespace = primaryNamespace(
            repositoryID: installed.repositoryID,
            sourceID: installed.sourceID
        )
        let authorization = try await writeAuthorization(
            for: installed,
            namespace: rawNamespace
        )
        let namespace = try await preparedNamespace(for: installed, authorization: authorization)
        let configuration = MangoReaderExtensionRuntime.Configuration(
            namespace: namespace,
            entryID: installed.sourceID,
            apiVersion: installed.apiVersion,
            scriptURL: scriptURL,
            allowedHTTPSHosts: Set(installed.allowedHTTPSHosts),
            permissions: installed.permissions,
            searchOperationTimeout: Self.catalogSearchTimeout(entryID: installed.sourceID)
        )
        let stateStore = stateStore
        let secureStateStore = secureStateStore
        let adapter = MangoReaderExtensionSourceAdapter(installedSource: installed) {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.httpCookieStorage = nil
            sessionConfiguration.httpShouldSetCookies = false
            sessionConfiguration.httpCookieAcceptPolicy = .never
            sessionConfiguration.urlCredentialStorage = nil
            sessionConfiguration.urlCache = nil
            sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
            sessionConfiguration.timeoutIntervalForRequest = 30
            sessionConfiguration.timeoutIntervalForResource = 30
            let client = MangoReaderSources.HTTPClient(
                session: URLSession(configuration: sessionConfiguration),
                retryPolicy: .init(maximumAttempts: 2, initialBackoffSeconds: 0.5, maximumDelaySeconds: 4)
            )
            return MangoReaderExtensionRuntime(
                configuration: configuration,
                httpClient: client,
                stateStore: stateStore,
                secureStateStore: secureStateStore,
                storageWriteAuthorization: authorization,
                catalogRequestGate: gate
            )
        }
        guard !isLocked else { throw MangoReaderExtensionRuntimeError.sourceUnavailable }
        adapters[installed.id] = adapter
        adapterNamespaces[installed.id] = configuration.namespace
        return adapter
    }

    public func connector(
        for installed: InstalledRepositorySource,
        configuration: SourceEndpointConfiguration,
        credentialLoader: (any SourceCredentialLoading)? = nil
    ) async throws -> MangoReaderConnectorSourceAdapter {
        let key = "\(installed.id)::connection::\(configuration.id.rawValue)"
        let gate: MangoReaderRequestPermitPool
        if let existing = connectorCreationGates[key] { gate = existing }
        else { gate = MangoReaderRequestPermitPool(limit: 1); connectorCreationGates[key] = gate }
        try await gate.acquire()
        do {
            let source = try await makeConnector(for: installed, configuration: configuration, credentialLoader: credentialLoader)
            await gate.release()
            return source
        } catch {
            await gate.release()
            throw error
        }
    }

    private func makeConnector(
        for installed: InstalledRepositorySource,
        configuration: SourceEndpointConfiguration,
        credentialLoader: (any SourceCredentialLoading)?
    ) async throws -> MangoReaderConnectorSourceAdapter {
        guard !isLocked, installed.entryType == .mangoReaderExtension, installed.isRuntimeCompatible,
              installed.kind == .content, installed.connectorKind == configuration.kind,
              [.opds, .komga, .kavita, .suwayomi].contains(configuration.kind), installed.availability == .available,
              installed.isEnabled, removedConnectorProviders[installed.id] != installed.installedAt
        else { throw MangoReaderExtensionRuntimeError.sourceUnavailable }
        let key = "\(installed.id)::connection::\(configuration.id.rawValue)"
        if let adapter = connectorAdapters[key], adapter.configuration == configuration,
           connectorInstallations[key] == installed { return adapter }
        if let adapter = connectorAdapters.removeValue(forKey: key) { await adapter.resetRuntime() }
        if let authorization = storageWriteAuthorizations.removeValue(forKey: key) {
            await revokeWriteAuthorization(authorization)
        }
        let generation = connectorGenerations[installed.id, default: 0]
        let connectionGeneration = connectorConnectionGenerations[configuration.id, default: 0]
        let namespace = scopedConnectorNamespace(providerID: installed.id, sourceID: configuration.id)
        let scriptURL = try await packageStore.activeScriptURL(repositoryID: installed.repositoryID, sourceID: installed.sourceID)
        let authorization = try await makeWriteAuthorization(namespace: namespace)
        // One independently written ledger entry per connection avoids read/modify/write races.
        let record = ConnectorNamespaceRecord(providerID: installed.id, sourceID: configuration.id)
        try await stateStore.set(try JSONEncoder().encode(record), key: namespace, namespace: Self.connectorNamespaceLedger)
        guard connectorGenerations[installed.id, default: 0] == generation,
              connectorConnectionGenerations[configuration.id, default: 0] == connectionGeneration,
              removedConnectorProviders[installed.id] != installed.installedAt else {
            await revokeWriteAuthorization(authorization)
            try await stateStore.reset(namespace: namespace)
            try await secureStateStore.removeNamespace(namespace)
            try await stateStore.set(nil, key: namespace, namespace: Self.connectorNamespaceLedger)
            throw MangoReaderExtensionRuntimeError.sourceUnavailable
        }
        let runtimeConfiguration = MangoReaderExtensionRuntime.Configuration(namespace: namespace,
            entryID: installed.sourceID, apiVersion: installed.apiVersion, kind: .content,
            scriptURL: scriptURL, permissions: installed.permissions,
            connectorKind: installed.connectorKind, connection: configuration, credentialLoader: credentialLoader)
        let stateStore = stateStore
        let secureStateStore = secureStateStore
        let adapter = MangoReaderConnectorSourceAdapter(configuration: configuration, credentialLoader: credentialLoader) {
            let session = URLSessionConfiguration.ephemeral
            session.httpCookieStorage = nil
            session.httpShouldSetCookies = false
            session.urlCredentialStorage = nil
            session.urlCache = nil
            return MangoReaderExtensionRuntime(configuration: runtimeConfiguration,
                httpClient: HTTPClient(session: URLSession(configuration: session)),
                stateStore: stateStore, secureStateStore: secureStateStore,
                storageWriteAuthorization: authorization)
        }
        storageWriteAuthorizations[key] = authorization
        guard !isLocked else { throw MangoReaderExtensionRuntimeError.sourceUnavailable }
        connectorAdapters[key] = adapter
        connectorInstallations[key] = installed
        return adapter
    }

    static func connectorNamespace(providerID: String, sourceID: SourceID) -> String {
        "connector-" + SHA256.hash(data: Data("\(providerID)\0\(sourceID.rawValue)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    public func invalidateConnectorConnection(sourceID: SourceID) async {
        connectorConnectionGenerations[sourceID, default: 0] &+= 1
        let suffix = "::connection::" + sourceID.rawValue
        for key in connectorAdapters.keys.filter({ $0.hasSuffix(suffix) }) {
            let adapter = connectorAdapters.removeValue(forKey: key)
            connectorInstallations.removeValue(forKey: key)
            if let authorization = storageWriteAuthorizations.removeValue(forKey: key) {
                await revokeWriteAuthorization(authorization)
            }
            await adapter?.resetRuntime()
        }
    }

    public func removeConnectorConnection(sourceID: SourceID) async throws {
        await invalidateConnectorConnection(sourceID: sourceID)
        let entries = try await stateStore.values(namespace: Self.connectorNamespaceLedger)
        for (namespace, data) in entries {
            let record = try JSONDecoder().decode(ConnectorNamespaceRecord.self, from: data)
            guard record.sourceID == sourceID else { continue }
            await revokeNamespace(namespace)
            try await stateStore.reset(namespace: namespace)
            try await secureStateStore.removeNamespace(namespace)
            try await stateStore.set(nil, key: namespace, namespace: Self.connectorNamespaceLedger)
        }
    }

    public func setRequestSpeed(_ speed: ExtensionRequestSpeed, installedSourceID: String) async {
        guard let gate = catalogRequestGates[installedSourceID] else { return }
        await MainActor.run { gate.speed = speed }
    }

    #if DEBUG
    /// Prepared runtimes for isolated app verification; never included in release builds.
    @_spi(Testing) public func registerPreparedTracker(_ adapter: MangoReaderExtensionTrackerAdapter, installedID: String) {
        trackerAdapters[installedID] = adapter
    }
    #endif

    public func tracker(for installed: InstalledRepositorySource) async throws -> MangoReaderExtensionTrackerAdapter {
        guard !isPrivate else { throw MangoReaderExtensionRuntimeError.sourceUnavailable }
        guard !isLocked, installed.entryType == .mangoReaderExtension,
              installed.isRuntimeCompatible,
              installed.kind == .tracker,
              installed.availability == .available,
              installed.isEnabled
        else { throw MangoReaderExtensionRuntimeError.sourceUnavailable }
        if let adapter = trackerAdapters[installed.id] { return adapter }
        let scriptURL = try await packageStore.activeScriptURL(
            repositoryID: installed.repositoryID,
            sourceID: installed.sourceID
        )
        let rawNamespace = primaryNamespace(
            repositoryID: installed.repositoryID,
            sourceID: installed.sourceID
        )
        let authorization = try await writeAuthorization(
            for: installed,
            namespace: rawNamespace
        )
        let namespace = try await preparedNamespace(for: installed, authorization: authorization)
        let configuration = MangoReaderExtensionRuntime.Configuration(
            namespace: namespace,
            entryID: installed.sourceID,
            apiVersion: installed.apiVersion,
            scriptURL: scriptURL,
            allowedHTTPSHosts: Set(installed.allowedHTTPSHosts),
            permissions: installed.permissions,
            accountPolicy: installed.accountPolicy
        )
        let stateStore = stateStore
        let secureStateStore = secureStateStore
        let oauthTokenManager = trackerOAuthTokenManager
        let adapter = MangoReaderExtensionTrackerAdapter(
            installedExtension: installed,
            authenticationPreparation: { descriptor in
                guard descriptor == installed.accountPolicy?.authentication else { throw ExtensionSecurityError.invalidPolicy }
                return try await oauthTokenManager.refreshIfNeeded(
                    descriptor: descriptor,
                    namespace: namespace,
                    authorization: authorization
                )
            }
        ) {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.httpCookieStorage = nil
            sessionConfiguration.httpShouldSetCookies = false
            sessionConfiguration.httpCookieAcceptPolicy = .never
            sessionConfiguration.urlCredentialStorage = nil
            sessionConfiguration.urlCache = nil
            sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
            sessionConfiguration.timeoutIntervalForRequest = 30
            sessionConfiguration.timeoutIntervalForResource = 30
            let client = MangoReaderSources.HTTPClient(session: URLSession(configuration: sessionConfiguration))
            return MangoReaderExtensionRuntime(
                configuration: configuration,
                httpClient: client,
                stateStore: stateStore,
                secureStateStore: secureStateStore,
                storageWriteAuthorization: authorization
            )
        }
        guard !isLocked else { throw MangoReaderExtensionRuntimeError.sourceUnavailable }
        trackerAdapters[installed.id] = adapter
        adapterNamespaces[installed.id] = configuration.namespace
        return adapter
    }

    public func trackerAuthentication(for installed: InstalledRepositorySource) async throws -> TrackerAuthenticationDescriptor {
        try await tracker(for: installed).authentication()
    }

    public func trackerIsAuthenticated(_ installed: InstalledRepositorySource) async throws -> Bool {
        guard installed.isRuntimeCompatible else { return false }
        let namespace = primaryNamespace(
            repositoryID: installed.repositoryID,
            sourceID: installed.sourceID
        )
        let authorization = try await writeAuthorization(for: installed, namespace: namespace)
        _ = try await preparedNamespace(for: installed, authorization: authorization)
        return try await secureStateStore.value(namespace: namespace, key: "__native_oauth_access_token") != nil
    }

    public func storeTrackerOAuthCredentials(
        for installed: InstalledRepositorySource,
        accessToken: String,
        refreshToken: String?,
        tokenType: String?,
        expiresAt: Date?
    ) async throws {
        let namespace = primaryNamespace(
            repositoryID: installed.repositoryID,
            sourceID: installed.sourceID
        )
        let authorization = try await writeAuthorization(for: installed, namespace: namespace)
        _ = try await preparedNamespace(for: installed, authorization: authorization)
        guard installed.isRuntimeCompatible, installed.accountPolicy != nil else { throw ExtensionSecurityError.incompatible }
        try await setSecureString(accessToken, namespace: namespace, key: "__native_oauth_access_token", authorization: authorization)
        try await setSecureString(refreshToken, namespace: namespace, key: "__native_oauth_refresh_token", authorization: authorization)
        try await setSecureString(tokenType ?? "Bearer", namespace: namespace, key: "__native_oauth_token_type", authorization: authorization)
        try await setSecureString(expiresAt?.ISO8601Format(), namespace: namespace, key: "__native_oauth_expires_at", authorization: authorization)
        await invalidate(installedSourceID: installed.id)
    }

    public func signOutTracker(_ installed: InstalledRepositorySource) async throws {
        let namespace = primaryNamespace(
            repositoryID: installed.repositoryID,
            sourceID: installed.sourceID
        )
        let authorization = try await writeAuthorization(for: installed, namespace: namespace)
        _ = try await preparedNamespace(for: installed, authorization: authorization)
        try await trackerOAuthTokenManager.clearCredentials(
            namespace: namespace,
            authorization: authorization
        )
        await invalidate(installedSourceID: installed.id)
    }

    public func makeStagedRuntime(
        for installed: InstalledRepositorySource,
        scriptURL: URL
    ) async throws -> MangoReaderExtensionRuntime {
        let namespace = stagedNamespace(
            repositoryID: installed.repositoryID,
            sourceID: installed.sourceID
        )
        let authorization = try await makeWriteAuthorization(namespace: namespace)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieAcceptPolicy = .never
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 30
        let client = MangoReaderSources.HTTPClient(session: URLSession(configuration: sessionConfiguration))
        return await MangoReaderExtensionRuntime(
            configuration: .init(
                namespace: namespace,
                entryID: installed.sourceID,
                apiVersion: installed.apiVersion,
                kind: installed.kind,
                scriptURL: scriptURL,
                allowedHTTPSHosts: Set(installed.allowedHTTPSHosts),
                permissions: installed.permissions,
                searchOperationTimeout: Self.catalogSearchTimeout(entryID: installed.sourceID),
                connectorKind: installed.connectorKind,
                accountPolicy: installed.accountPolicy,
                offlineValidation: true
            ),
            httpClient: client,
            stateStore: stateStore,
            secureStateStore: secureStateStore,
            storageWriteAuthorization: authorization
        )
    }

    public func invalidate(installedSourceID: String) async {
        connectorGenerations[installedSourceID, default: 0] &+= 1
        let connectionKeys = connectorAdapters.keys.filter { $0.hasPrefix(installedSourceID + "::connection::") }
        for key in connectionKeys {
            connectorInstallations.removeValue(forKey: key)
            let adapter = connectorAdapters.removeValue(forKey: key)
            if let authorization = storageWriteAuthorizations.removeValue(forKey: key) {
                await revokeWriteAuthorization(authorization)
            }
            await adapter?.resetRuntime()
        }

        if let authorization = storageWriteAuthorizations.removeValue(forKey: installedSourceID) {
            await revokeWriteAuthorization(authorization)
        }
        adapterNamespaces.removeValue(forKey: installedSourceID)
        if let adapter = adapters.removeValue(forKey: installedSourceID) {
            await adapter.resetRuntime()
        }
        if let adapter = trackerAdapters.removeValue(forKey: installedSourceID) {
            await adapter.resetRuntime()
        }
    }

    private func writeAuthorization(
        for installed: InstalledRepositorySource,
        namespace: String
    ) async throws -> ExtensionStorageWriteAuthorization {
        guard !isLocked else { throw ExtensionStorageWriteAuthorizationError.stale }
        if let existing = storageWriteAuthorizations[installed.id] {
            guard await activateWriteAuthorization(existing) else {
                throw ExtensionStorageWriteAuthorizationError.stale
            }
            return existing
        }

        let authorization = nextWriteAuthorization(namespace: namespace)
        // Reserve the generation before suspension. Reentrant callers reuse the
        // same value, while removal can revoke exactly this reservation.
        storageWriteAuthorizations[installed.id] = authorization
        guard !isLocked, await activateWriteAuthorization(authorization),
              storageWriteAuthorizations[installed.id] == authorization
        else {
            if storageWriteAuthorizations[installed.id] == authorization {
                storageWriteAuthorizations[installed.id] = nil
            }
            await revokeWriteAuthorization(authorization)
            throw ExtensionStorageWriteAuthorizationError.stale
        }
        return authorization
    }

    private func makeWriteAuthorization(
        namespace: String
    ) async throws -> ExtensionStorageWriteAuthorization {
        guard !isLocked else { throw ExtensionStorageWriteAuthorizationError.stale }
        let authorization = nextWriteAuthorization(namespace: namespace)
        guard !isLocked, await activateWriteAuthorization(authorization) else {
            await revokeWriteAuthorization(authorization)
            throw ExtensionStorageWriteAuthorizationError.stale
        }
        return authorization
    }

    private func nextWriteAuthorization(namespace: String) -> ExtensionStorageWriteAuthorization {
        let generation = storageWriteGenerations[namespace, default: 0] &+ 1
        storageWriteGenerations[namespace] = generation
        return ExtensionStorageWriteAuthorization(namespace: namespace, generation: generation)
    }

    private func activateWriteAuthorization(
        _ authorization: ExtensionStorageWriteAuthorization
    ) async -> Bool {
        guard await stateStore.activateWriteAuthorization(authorization),
              await secureStateStore.activateWriteAuthorization(authorization),
              // Recheck both actors after suspension so an overlapping newer
              // generation cannot leave the two stores split.
              await stateStore.activateWriteAuthorization(authorization),
              await secureStateStore.activateWriteAuthorization(authorization)
        else { return false }
        return true
    }

    private func revokeWriteAuthorization(
        _ authorization: ExtensionStorageWriteAuthorization
    ) async {
        storageWriteGenerations[authorization.namespace] = max(
            storageWriteGenerations[authorization.namespace, default: 0],
            authorization.generation
        )
        await stateStore.revokeWriteAuthorization(
            namespace: authorization.namespace,
            through: authorization.generation
        )
        await secureStateStore.revokeWriteAuthorization(
            namespace: authorization.namespace,
            through: authorization.generation
        )
    }

    private func revokeNamespace(_ namespace: String) async {
        let generation = storageWriteGenerations[namespace, default: 0] &+ 1
        storageWriteGenerations[namespace] = generation
        await stateStore.revokeWriteAuthorization(namespace: namespace, through: generation)
        await secureStateStore.revokeWriteAuthorization(namespace: namespace, through: generation)
    }

    private func setSecureString(
        _ value: String?,
        namespace: String,
        key: String,
        authorization: ExtensionStorageWriteAuthorization
    ) async throws {
        let data = try value.map { try JSONEncoder().encode($0) }
        try await secureStateStore.setIndexed(
            data,
            namespace: namespace,
            key: key,
            authorization: authorization
        )
    }

    public func browserSessionSeed(
        for context: CloudflareChallengeContext
    ) async throws -> ExtensionBrowserSessionSeed {
        guard RepositoryURLPolicy.isSafeIdentifier(context.namespace) else {
            throw ExtensionStorageError.invalidIdentifier
        }
        let values = try await secureStateStore.values(namespace: context.namespace)
        let storedProfile = values[ExtensionBrowserSessionProfile.secureStateKey]
            .flatMap { try? JSONDecoder().decode(ExtensionBrowserSessionProfile.self, from: $0) }
            .flatMap { $0.isValid() ? $0 : nil }
        guard let targetURL = context.url ?? storedProfile?.canonicalHTTPSOrigin,
              let origin = ExtensionBrowserSessionProfile.canonicalHTTPSOrigin(for: targetURL),
              context.authorizesHandoffURL(targetURL)
        else {
            throw ExtensionBrowserSessionError.invalidHTTPSOrigin
        }

        let storedCookies = values["cookie_store_cookies"]
            .flatMap { try? JSONDecoder().decode([ExtensionHTTPStateCookie].self, from: $0) }
            ?? []
        return ExtensionBrowserSessionSeed(
            profile: storedProfile?.canonicalHTTPSOrigin == origin ? storedProfile : nil,
            cookies: Array(storedCookies.lazy.filter { $0.isApplicable(to: targetURL) }.prefix(100))
        )
    }

    /// Rebuilds the secret-bearing browser identity for an extension download
    /// at start time. The durable download queue stores only the namespace;
    /// this method returns a valid profile for the namespace. Request building
    /// applies it only at that exact origin, including after an allowed
    /// source-to-download-host redirect.
    public func downloadRedirectIdentity(
        namespace: String,
        requestURL: URL
    ) async throws -> HTTPRedirectIdentity? {
        guard RepositoryURLPolicy.isSafeIdentifier(namespace) else {
            throw ExtensionStorageError.invalidIdentifier
        }
        guard ExtensionBrowserSessionProfile.canonicalHTTPSOrigin(for: requestURL) != nil else {
            return nil
        }
        let values = try await secureStateStore.values(namespace: namespace)
        guard let profile = values[ExtensionBrowserSessionProfile.secureStateKey]
            .flatMap({ try? JSONDecoder().decode(ExtensionBrowserSessionProfile.self, from: $0) }),
            profile.isValid()
        else { return nil }

        let cookies = values["cookie_store_cookies"]
            .flatMap { try? JSONDecoder().decode([ExtensionHTTPStateCookie].self, from: $0) }
            ?? []
        return HTTPRedirectIdentity(
            origin: profile.canonicalHTTPSOrigin,
            userAgent: profile.userAgent,
            cookies: Array(cookies.lazy
                .filter { $0.isValidForOrigin(profile.canonicalHTTPSOrigin) }
                .prefix(100))
                .map {
                    HTTPRedirectCookie(
                        name: $0.name,
                        value: $0.value,
                        path: $0.path,
                        secure: $0.secure
                    )
                }
        )
    }

    public func recordPendingCloudflareVerification(
        _ context: CloudflareChallengeContext
    ) async throws {
        guard RepositoryURLPolicy.isSafeIdentifier(context.namespace),
              let url = context.url,
              let sanitizedURL = Self.sanitizedChallengeURL(url),
              context.authorizesHandoffURL(sanitizedURL)
        else {
            throw ExtensionBrowserSessionError.invalidHTTPSOrigin
        }
        var sanitized = context
        sanitized.url = sanitizedURL
        let affected = adapterNamespaces.compactMap { $0.value == context.namespace ? $0.key : nil }
        guard let authorization = affected.lazy.compactMap({ self.storageWriteAuthorizations[$0] }).first else {
            throw ExtensionStorageWriteAuthorizationError.stale
        }
        try await secureStateStore.setIndexed(
            JSONEncoder().encode(sanitized),
            namespace: context.namespace,
            key: CloudflareChallengeContext.pendingSecureStateKey,
            authorization: authorization
        )
    }

    private static func sanitizedChallengeURL(_ url: URL) -> URL? {
        guard let origin = ExtensionBrowserSessionProfile.canonicalHTTPSOrigin(for: url),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = "https"
        components.user = nil
        components.password = nil
        components.host = origin.host
        components.port = origin.port
        components.query = nil
        components.fragment = nil
        if components.path.isEmpty { components.path = "/" }
        guard let result = components.url,
              ExtensionBrowserSessionProfile.canonicalHTTPSOrigin(for: result) == origin
        else { return nil }
        return result
    }

    public func pendingCloudflareVerification(
        namespace: String
    ) async throws -> CloudflareChallengeContext? {
        guard RepositoryURLPolicy.isSafeIdentifier(namespace) else {
            throw ExtensionStorageError.invalidIdentifier
        }
        guard let data = try await secureStateStore.value(
            namespace: namespace,
            key: CloudflareChallengeContext.pendingSecureStateKey
        ) else { return nil }
        let context = try JSONDecoder().decode(CloudflareChallengeContext.self, from: data)
        guard let url = context.url, context.authorizesHandoffURL(url) else {
            throw ExtensionBrowserSessionError.invalidHTTPSOrigin
        }
        return context
    }

    @discardableResult
    public func completeCloudflareHandoff(
        namespace: String,
        origin: URL,
        verificationURL: URL? = nil,
        userAgent: String,
        cookies: [ExtensionHTTPStateCookie]
    ) async throws -> ExtensionBrowserSessionProfile {
        guard RepositoryURLPolicy.isSafeIdentifier(namespace) else {
            throw ExtensionStorageError.invalidIdentifier
        }
        guard let canonicalOrigin = ExtensionBrowserSessionProfile.canonicalHTTPSOrigin(for: origin) else {
            throw ExtensionBrowserSessionError.invalidHTTPSOrigin
        }
        guard ExtensionBrowserSessionProfile.hasValidUserAgent(userAgent) else {
            throw ExtensionBrowserSessionError.invalidUserAgent
        }
        let clearanceURL = verificationURL ?? canonicalOrigin
        guard ExtensionBrowserSessionProfile.canonicalHTTPSOrigin(for: clearanceURL) == canonicalOrigin else {
            throw ExtensionBrowserSessionError.invalidHTTPSOrigin
        }

        let imported = Array(cookies.lazy
            .filter { $0.isValidForOrigin(canonicalOrigin) }
            .prefix(100))
        guard imported.contains(where: {
            $0.name.caseInsensitiveCompare("cf_clearance") == .orderedSame
                && $0.isApplicable(to: clearanceURL)
        }) else {
            throw ExtensionBrowserSessionError.missingClearanceCookie
        }

        let profile = ExtensionBrowserSessionProfile(
            canonicalHTTPSOrigin: canonicalOrigin,
            userAgent: userAgent,
            updatedAt: .now
        )
        let affected = adapterNamespaces.compactMap { $0.value == namespace ? $0.key : nil }
        guard let authorization = affected.lazy.compactMap({ self.storageWriteAuthorizations[$0] }).first else {
            throw ExtensionStorageWriteAuthorizationError.stale
        }
        try await secureStateStore.completeBrowserSession(
            profile: profile,
            importing: imported,
            verificationURL: clearanceURL,
            namespace: namespace,
            authorization: authorization
        )
        for sourceID in affected {
            await invalidate(installedSourceID: sourceID)
        }
        return profile
    }

    public func remove(_ installed: InstalledRepositorySource) async throws {
        removedConnectorProviders[installed.id] = installed.installedAt
        await invalidate(installedSourceID: installed.id)
        catalogRequestGates.removeValue(forKey: installed.id)
        for (namespace, data) in try await stateStore.values(namespace: Self.connectorNamespaceLedger) {
            let record = try JSONDecoder().decode(ConnectorNamespaceRecord.self, from: data)
            guard record.providerID == installed.id else { continue }
            await revokeNamespace(namespace)
            try await stateStore.reset(namespace: namespace)
            try await secureStateStore.removeNamespace(namespace)
            try await stateStore.set(nil, key: namespace, namespace: Self.connectorNamespaceLedger)
        }
        let namespace = primaryNamespace(
            repositoryID: installed.repositoryID,
            sourceID: installed.sourceID
        )
        await revokeNamespace(namespace)
        let stagedNamespace = stagedNamespace(
            repositoryID: installed.repositoryID,
            sourceID: installed.sourceID
        )
        await revokeNamespace(stagedNamespace)
        try await preventLegacyStateResurrection(for: installed, namespace: namespace)
        try await packageStore.remove(repositoryID: installed.repositoryID, sourceID: installed.sourceID)
        try await stateStore.reset(namespace: namespace)
        try await secureStateStore.removeNamespace(namespace)
        try await stateStore.reset(namespace: stagedNamespace)
        try await secureStateStore.removeNamespace(stagedNamespace)
    }

    /// Finishes cleanup that is safe only after an entire repository has been
    /// detached. Individual long-ID removals retain the ambiguous namespace so
    /// another source that shared the old truncated value is not damaged. A
    /// repository cleanup may delete each deduplicated legacy namespace once no
    /// still-installed extension refers to it, then discard the migration
    /// tombstones because no legacy data remains to resurrect.
    public func finalizeRepositoryRemoval(
        removed: [InstalledRepositorySource],
        preserving retained: [InstalledRepositorySource]
    ) async throws {
        let retainedNamespaces = Set(retained.flatMap { installed in
            [
                primaryNamespace(
                    repositoryID: installed.repositoryID,
                    sourceID: installed.sourceID
                ),
                legacyNamespace(
                    repositoryID: installed.repositoryID,
                    sourceID: installed.sourceID
                ),
            ]
        })
        let longNamespaces = removed.compactMap { installed -> (legacy: String, canonical: String)? in
            let canonical = primaryNamespace(
                repositoryID: installed.repositoryID,
                sourceID: installed.sourceID
            )
            let legacy = legacyNamespace(
                repositoryID: installed.repositoryID,
                sourceID: installed.sourceID
            )
            guard canonical != legacy, !retainedNamespaces.contains(legacy) else { return nil }
            return (legacy, canonical)
        }
        let safeLegacyNamespaces = Set(longNamespaces.map { $0.legacy })
        for legacy in safeLegacyNamespaces {
            try await stateStore.reset(namespace: legacy)
            try await secureStateStore.removeNamespace(legacy)
            for canonical in Set(longNamespaces.lazy.filter { $0.legacy == legacy }.map { $0.canonical }) {
                try await stateStore.set(
                    nil,
                    key: canonical,
                    namespace: Self.namespaceMigrationLedger
                )
            }
        }
    }

    private func preparedNamespace(
        for installed: InstalledRepositorySource,
        authorization: ExtensionStorageWriteAuthorization
    ) async throws -> String {
        let namespace = primaryNamespace(
            repositoryID: installed.repositoryID,
            sourceID: installed.sourceID
        )
        let legacyNamespace = legacyNamespace(
            repositoryID: installed.repositoryID,
            sourceID: installed.sourceID
        )
        guard namespace != legacyNamespace else { return namespace }

        let ledger = try await stateStore.values(namespace: Self.namespaceMigrationLedger)
        if let marker = ledger[namespace],
           NamespaceMigrationState(rawValue: String(decoding: marker, as: UTF8.self)) != nil {
            return namespace
        }

        let currentOrdinary = try await stateStore.values(namespace: namespace)
        let legacyOrdinary = try await stateStore.values(namespace: legacyNamespace)
        for (key, value) in legacyOrdinary where currentOrdinary[key] == nil {
            try await stateStore.set(
                value,
                key: key,
                namespace: namespace,
                authorization: authorization
            )
        }

        let currentSecure = try await secureStateStore.values(namespace: namespace)
        let legacySecure = try await secureStateStore.values(namespace: legacyNamespace)
        for (key, value) in legacySecure where currentSecure[key] == nil {
            try await secureStateStore.setIndexed(
                value,
                namespace: namespace,
                key: key,
                authorization: authorization
            )
        }

        try await setNamespaceMigrationState(
            .migrated,
            namespace: namespace,
            authorization: authorization
        )
        return namespace
    }

    private func preventLegacyStateResurrection(
        for installed: InstalledRepositorySource,
        namespace: String
    ) async throws {
        let legacyNamespace = legacyNamespace(
            repositoryID: installed.repositoryID,
            sourceID: installed.sourceID
        )
        guard namespace != legacyNamespace else { return }
        // Persist the tombstone before deleting canonical state. If cleanup is
        // interrupted, the pending-cleanup ledger retries the deletion while a
        // reinstall can never copy the ambiguous legacy namespace again.
        try await setNamespaceMigrationState(.removed, namespace: namespace)
    }

    private func setNamespaceMigrationState(
        _ state: NamespaceMigrationState,
        namespace: String,
        authorization: ExtensionStorageWriteAuthorization? = nil
    ) async throws {
        if let authorization {
            try await stateStore.set(
                Data(state.rawValue.utf8),
                key: namespace,
                namespace: Self.namespaceMigrationLedger,
                authorization: authorization
            )
        } else {
            try await stateStore.set(
                Data(state.rawValue.utf8),
                key: namespace,
                namespace: Self.namespaceMigrationLedger
            )
        }
    }
}
