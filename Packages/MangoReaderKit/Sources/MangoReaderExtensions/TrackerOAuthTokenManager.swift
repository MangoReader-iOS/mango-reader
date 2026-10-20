import Foundation
import MangoReaderDomain
@_spi(Testing) import MangoReaderSources

public enum TrackerOAuthError: Error, Equatable, Sendable, LocalizedError {
    case missingClientID
    case invalidConfiguration
    case invalidTokenResponse

    public var errorDescription: String? {
        switch self {
        case .missingClientID: "This build does not have the tracker’s public OAuth client ID configured."
        case .invalidConfiguration: "The tracker returned an invalid OAuth configuration."
        case .invalidTokenResponse: "The tracker authorization server returned an invalid token response."
        }
    }
}

public enum TrackerOAuthConfiguration {
    public static func clientID(for descriptor: TrackerAuthenticationDescriptor, bundle: Bundle = .main) throws -> String {
        if let value = descriptor.clientID?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        if let key = descriptor.clientIDInfoPlistKey,
           let value = bundle.object(forInfoDictionaryKey: key) as? String {
            let resolved = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !resolved.isEmpty, !resolved.hasPrefix("$(") { return resolved }
        }
        throw TrackerOAuthError.missingClientID
    }
}

actor TrackerOAuthTokenManager {
    static let maximumTokenResponseBytes = 256 * 1_024
    static let credentialKeys = [
        "__native_oauth_access_token", "__native_oauth_refresh_token", "__native_oauth_token_type", "__native_oauth_expires_at"
    ]
    private struct TokenResponse: Decodable {
        var accessToken: String
        var refreshToken: String?
        var tokenType: String?
        var expiresIn: Double?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
        }
    }

    private let secureStateStore: ExtensionSecureStateStore
    private let httpClient: HTTPClient

    init(secureStateStore: ExtensionSecureStateStore, session: URLSession? = nil) {
        self.secureStateStore = secureStateStore
        if let session {
            self.httpClient = HTTPClient(testingSession: session, retryPolicy: .init(maximumAttempts: 1))
        } else {
            self.httpClient = HTTPClient(retryPolicy: .init(maximumAttempts: 1))
        }
    }

    func refreshIfNeeded(
        descriptor: TrackerAuthenticationDescriptor,
        namespace: String,
        authorization: ExtensionStorageWriteAuthorization? = nil,
        now: Date = .now
    ) async throws -> Bool {
        guard descriptor.mode == .oauth2PKCE,
              let accessToken = try await stringValue(namespace: namespace, key: "__native_oauth_access_token")
        else { return false }

        guard let expiresAtValue = try await stringValue(namespace: namespace, key: "__native_oauth_expires_at"),
              let expiresAt = ISO8601DateFormatter().date(from: expiresAtValue),
              expiresAt <= now.addingTimeInterval(60)
        else { return false }

        guard !accessToken.isEmpty,
              let refreshToken = try await stringValue(namespace: namespace, key: "__native_oauth_refresh_token"),
              !refreshToken.isEmpty,
              let tokenURL = descriptor.tokenURL,
              (try? EndpointPolicy().validate(
                  tokenURL,
                  access: EndpointAccess()
              )) != nil
        else { throw SourceError.unauthorized }

        let clientID = try TrackerOAuthConfiguration.clientID(for: descriptor)
        var fields = descriptor.tokenParameters ?? [:]
        fields["grant_type"] = "refresh_token"
        fields["refresh_token"] = refreshToken
        fields["client_id"] = clientID
        var components = URLComponents()
        components.queryItems = fields.sorted(by: { $0.key < $1.key }).map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        guard let body = components.percentEncodedQuery?.data(using: .utf8) else {
            throw TrackerOAuthError.invalidConfiguration
        }

        let response: HTTPResponse
        do { response = try await httpClient.response(for: HTTPRequest(
            url: tokenURL,
            method: .post,
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json",
            ],
            body: body,
            endpointAccess: EndpointAccess(),
            usesConditionalCache: false,
            networkPolicy: ExtensionNetworkPolicy(hosts: [tokenURL.host?.lowercased() ?? ""]),
            followsRedirects: false,
            maximumResponseBytes: Self.maximumTokenResponseBytes,
            statusPolicy: .returnResponse
        )) } catch HTTPClientError.invalidResponse { throw TrackerOAuthError.invalidTokenResponse }
        guard (200 ..< 300).contains(response.statusCode) else { throw SourceError.unauthorized }
        guard response.data.count <= Self.maximumTokenResponseBytes else {
            throw TrackerOAuthError.invalidTokenResponse
        }
        let data = response.data
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data), !token.accessToken.isEmpty else {
            throw TrackerOAuthError.invalidTokenResponse
        }
        try await store(
            token: token,
            namespace: namespace,
            fallbackRefreshToken: refreshToken,
            authorization: authorization,
            now: now
        )
        return true
    }

    func clearCredentials(
        namespace: String,
        authorization: ExtensionStorageWriteAuthorization? = nil
    ) async throws {
        for key in Self.credentialKeys + ["oauth_access_token", "oauth_refresh_token", "oauth_token_type", "oauth_expires_at"] {
            try await setData(
                nil,
                namespace: namespace,
                key: key,
                authorization: authorization
            )
        }
    }

    private func store(
        token: TokenResponse,
        namespace: String,
        fallbackRefreshToken: String?,
        authorization: ExtensionStorageWriteAuthorization?,
        now: Date
    ) async throws {
        try await setString(token.accessToken, namespace: namespace, key: "__native_oauth_access_token", authorization: authorization)
        try await setString(token.refreshToken ?? fallbackRefreshToken, namespace: namespace, key: "__native_oauth_refresh_token", authorization: authorization)
        try await setString(token.tokenType ?? "Bearer", namespace: namespace, key: "__native_oauth_token_type", authorization: authorization)
        let expiry = token.expiresIn.map { now.addingTimeInterval(max(0, $0)).ISO8601Format() }
        try await setString(expiry, namespace: namespace, key: "__native_oauth_expires_at", authorization: authorization)
    }

    private func stringValue(namespace: String, key: String) async throws -> String? {
        guard let data = try await secureStateStore.value(namespace: namespace, key: key) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    private func setString(
        _ value: String?,
        namespace: String,
        key: String,
        authorization: ExtensionStorageWriteAuthorization?
    ) async throws {
        let data = try value.map { try JSONEncoder().encode($0) }
        try await setData(
            data,
            namespace: namespace,
            key: key,
            authorization: authorization
        )
    }

    private func setData(
        _ value: Data?,
        namespace: String,
        key: String,
        authorization: ExtensionStorageWriteAuthorization?
    ) async throws {
        if let authorization {
            try await secureStateStore.setIndexed(
                value,
                namespace: namespace,
                key: key,
                authorization: authorization
            )
        } else {
            try await secureStateStore.setIndexed(value, namespace: namespace, key: key)
        }
    }

}
