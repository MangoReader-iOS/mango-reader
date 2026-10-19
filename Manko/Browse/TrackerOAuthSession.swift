import MankoSources
import AuthenticationServices
import CryptoKit
import Foundation
import MankoDomain
import MankoExtensions
import UIKit

@MainActor
final class TrackerOAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let maximumTokenResponseBytes = 1_048_576
    static let appCallbackScheme = "manko"

    struct Credential: Sendable {
        var accessToken: String
        var refreshToken: String?
        var tokenType: String?
        var expiresAt: Date?
    }

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

    private var webSession: ASWebAuthenticationSession?
    private var callbackContinuation: CheckedContinuation<URL, any Error>?
    private var callbackRequestID: UUID?

    func authorize(descriptor: TrackerAuthenticationDescriptor) async throws -> Credential {
        try Task.checkCancellation()
        guard descriptor.mode == .oauth2Implicit || descriptor.mode == .oauth2PKCE,
              let authorizationURL = descriptor.authorizationURL,
              Self.isPermittedNetworkURL(authorizationURL),
              let callbackURL = descriptor.callbackURL,
              let declaredCallbackScheme = descriptor.callbackScheme,
              Self.isPermittedCallbackURL(callbackURL, declaredScheme: declaredCallbackScheme)
        else { throw TrackerOAuthError.invalidConfiguration }

        let callbackScheme = Self.appCallbackScheme
        let clientID = try TrackerOAuthConfiguration.clientID(for: descriptor)
        let state = UUID().uuidString
        let verifier = descriptor.mode == .oauth2PKCE ? Self.randomVerifier() : nil
        let url = try Self.authorizationRequestURL(
            descriptor: descriptor, clientID: clientID, state: state, verifier: verifier
        )

        let callback = try await open(url: url, callbackScheme: callbackScheme)
        let values = try Self.validatedCallbackValues(callback, expectedURL: callbackURL, state: state)
        if descriptor.mode == .oauth2Implicit {
            guard let accessToken = values["access_token"], !accessToken.isEmpty else {
                throw TrackerOAuthError.invalidTokenResponse
            }
            return Credential(
                accessToken: accessToken,
                refreshToken: nil,
                tokenType: values["token_type"],
                expiresAt: values["expires_in"].flatMap(Double.init).map { Date.now.addingTimeInterval($0) }
            )
        }

        guard let code = values["code"], let verifier, let tokenURL = descriptor.tokenURL,
              Self.isPermittedNetworkURL(tokenURL)
        else { throw TrackerOAuthError.invalidConfiguration }
        var tokenParameters = descriptor.tokenParameters ?? [:]
        tokenParameters["grant_type"] = "authorization_code"
        tokenParameters["client_id"] = clientID
        tokenParameters["code"] = code
        tokenParameters["code_verifier"] = verifier
        tokenParameters["redirect_uri"] = callbackURL.absoluteString
        var form = URLComponents()
        form.queryItems = tokenParameters.sorted(by: { $0.key < $1.key }).map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        guard let body = form.percentEncodedQuery?.data(using: .utf8) else {
            throw TrackerOAuthError.invalidConfiguration
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        request.timeoutInterval = 30
        let (data, http) = try await Self.exchangeToken(using: request)
        guard (200 ..< 300).contains(http.statusCode),
              let token = try? JSONDecoder().decode(TokenResponse.self, from: data), !token.accessToken.isEmpty
        else { throw TrackerOAuthError.invalidTokenResponse }
        return Credential(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            tokenType: token.tokenType,
            expiresAt: token.expiresIn.map { Date.now.addingTimeInterval($0) }
        )
    }

    static func authorizationRequestURL(
        descriptor: TrackerAuthenticationDescriptor,
        clientID: String,
        state: String,
        verifier: String?
    ) throws -> URL {
        guard let authorizationURL = descriptor.authorizationURL,
              isPermittedNetworkURL(authorizationURL),
              let callbackURL = descriptor.callbackURL,
              let callbackScheme = descriptor.callbackScheme,
              isPermittedCallbackURL(callbackURL, declaredScheme: callbackScheme),
              descriptor.mode == .oauth2Implicit || descriptor.mode == .oauth2PKCE
        else { throw TrackerOAuthError.invalidConfiguration }

        var parameters = descriptor.authorizationParameters ?? [:]
        parameters["client_id"] = clientID
        parameters["response_type"] = descriptor.responseType ?? (descriptor.mode == .oauth2Implicit ? "token" : "code")
        parameters["state"] = state
        // AniList's implicit flow uses the dashboard's registered callback.
        // An extension can explicitly request this parameter, but cannot change
        // the callback route that Manko validates after authorization.
        if descriptor.mode == .oauth2PKCE || parameters["redirect_uri"] != nil {
            parameters["redirect_uri"] = callbackURL.absoluteString
        }
        if let scopes = descriptor.scopes, !scopes.isEmpty { parameters["scope"] = scopes.joined(separator: " ") }
        if descriptor.mode == .oauth2PKCE {
            guard let verifier, !verifier.isEmpty else { throw TrackerOAuthError.invalidConfiguration }
            let method = descriptor.pkceMethod ?? .S256
            parameters["code_challenge"] = challenge(for: verifier, method: method)
            parameters["code_challenge_method"] = method.rawValue
        }
        var components = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)
        components?.queryItems = parameters.sorted(by: { $0.key < $1.key }).map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        guard let url = components?.url else { throw TrackerOAuthError.invalidConfiguration }
        return url
    }

    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }

    private func open(url: URL, callbackScheme: String) async throws -> URL {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let requestID = UUID()
                callbackRequestID = requestID
                callbackContinuation = continuation
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callback, error in
                    Task { @MainActor in
                        let result: Result<URL, any Error>
                        if let authenticationError = error as? ASWebAuthenticationSessionError,
                           authenticationError.code == .canceledLogin {
                            result = .failure(CancellationError())
                        } else if let error {
                            result = .failure(error)
                        } else if let callback {
                            result = .success(callback)
                        } else {
                            result = .failure(TrackerOAuthError.invalidConfiguration)
                        }
                        self?.finishCallback(requestID: requestID, result: result)
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                webSession = session
                if !session.start() {
                    finishCallback(requestID: requestID, result: .failure(TrackerOAuthError.invalidConfiguration))
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
    }

    func cancel() {
        webSession?.cancel()
        guard let requestID = callbackRequestID else { return }
        finishCallback(requestID: requestID, result: .failure(CancellationError()))
    }

    private func finishCallback(requestID: UUID, result: Result<URL, any Error>) {
        guard callbackRequestID == requestID else { return }
        let continuation = callbackContinuation
        callbackContinuation = nil
        callbackRequestID = nil
        webSession = nil
        continuation?.resume(with: result)
    }

    static func validatedCallbackValues(_ url: URL, expectedURL: URL, state: String) throws -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              let callbackScheme = url.scheme,
              let expectedScheme = expectedURL.scheme,
              callbackScheme.caseInsensitiveCompare(expectedScheme) == .orderedSame,
              (url.host ?? "").caseInsensitiveCompare(expectedURL.host ?? "") == .orderedSame,
              url.path == expectedURL.path
        else {
            throw TrackerOAuthError.invalidConfiguration
        }
        let values = callbackValues(url)
        guard values["state"] == state else { throw TrackerOAuthError.invalidConfiguration }
        return values
    }

    static func isPermittedNetworkURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil
        else { return false }
        return ExtensionNetworkPolicy(hosts: [host.lowercased()]).allows(url)
    }

    static func isPermittedCallbackURL(_ url: URL, declaredScheme: String) -> Bool {
        guard declaredScheme.caseInsensitiveCompare(appCallbackScheme) == .orderedSame,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              scheme.caseInsensitiveCompare(appCallbackScheme) == .orderedSame,
              components.user == nil,
              components.password == nil
        else { return false }
        return true
    }

    static func tokenSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        return configuration
    }

    static func tokenResponseFitsLimit(_ byteCount: Int64) -> Bool {
        byteCount >= 0 && byteCount <= Int64(maximumTokenResponseBytes)
    }

    private static func exchangeToken(using request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw TrackerOAuthError.invalidConfiguration }
        let result = try await HTTPClient().response(for: HTTPRequest(
            url: url, method: .post, headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody,
            usesConditionalCache: false,
            networkPolicy: ExtensionNetworkPolicy(hosts: [url.host?.lowercased() ?? ""]),
            followsRedirects: false, maximumResponseBytes: maximumTokenResponseBytes,
            statusPolicy: .returnResponse))
        guard let response = HTTPURLResponse(url: result.url, statusCode: result.statusCode,
            httpVersion: "HTTP/1.1", headerFields: result.headers) else { throw TrackerOAuthError.invalidTokenResponse }
        return (result.data, response)
    }

    static func callbackValues(_ url: URL) -> [String: String] {
        var result: [String: String] = [:]
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.forEach { result[$0.name] = $0.value }
        if let fragment = url.fragment,
           let items = URLComponents(string: "?\(fragment)")?.queryItems {
            items.forEach { result[$0.name] = $0.value }
        }
        return result
    }

    private static func randomVerifier() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0 ..< 64).map { _ in alphabet.randomElement(using: &generator)! })
    }

    private static func challenge(for verifier: String, method: TrackerOAuthPKCEMethod) -> String {
        guard method == .S256 else { return verifier }
        return Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
