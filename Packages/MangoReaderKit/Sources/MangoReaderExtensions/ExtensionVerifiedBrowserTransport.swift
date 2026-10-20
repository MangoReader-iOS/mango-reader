import Foundation
import MangoReaderSources
import OSLog
import UIKit
import WebKit

enum ExtensionVerifiedBrowserTransportError: Error, Equatable {
    case requiresForeground
    case invalidRequest
    case redirectNotAllowed
    case invalidResponse
    case responseTooLarge
}

struct ExtensionVerifiedBrowserRequest: Hashable, Sendable {
    var url: URL
    var method: HTTPMethod
    var headers: [String: String]
}

struct ExtensionVerifiedBrowserResult: Sendable {
    var response: HTTPResponse
    var cookies: [ExtensionHTTPStateCookie]
}

/// Transfers the exact WebKit instance that completed a visible verification
/// into the native request broker. The broker replaces the verified site page
/// with its app-owned minimal document before issuing any extension request.
@MainActor
public enum ExtensionVerifiedBrowserSessionPool {
    private struct Entry {
        var webView: WKWebView
        var canonicalHTTPSOrigin: URL
        var userAgent: String
    }

    private static var entries: [String: Entry] = [:]

    public static func store(
        webView: WKWebView,
        namespace: String,
        canonicalHTTPSOrigin: URL,
        userAgent: String
    ) {
        guard !namespace.isEmpty,
              let normalizedOrigin = ExtensionBrowserSessionProfile.canonicalHTTPSOrigin(
                  for: canonicalHTTPSOrigin
              ),
              ExtensionBrowserSessionProfile.hasValidUserAgent(userAgent)
        else { return }
        if let replaced = entries.updateValue(
            Entry(
                webView: webView,
                canonicalHTTPSOrigin: normalizedOrigin,
                userAgent: userAgent
            ),
            forKey: namespace
        ) {
            replaced.webView.stopLoading()
            replaced.webView.navigationDelegate = nil
        }
    }

    public static func discardPrivateSessions() {
        for namespace in entries.keys.filter({ $0.hasPrefix("private-") }) {
            let entry = entries.removeValue(forKey: namespace)
            entry?.webView.stopLoading()
            entry?.webView.navigationDelegate = nil
        }
    }

    static func take(
        namespace: String,
        profile: ExtensionBrowserSessionProfile
    ) -> WKWebView? {
        guard let entry = entries.removeValue(forKey: namespace) else {
            return nil
        }
        guard entry.canonicalHTTPSOrigin == profile.canonicalHTTPSOrigin,
              entry.userAgent == profile.userAgent
        else {
            entry.webView.stopLoading()
            entry.webView.navigationDelegate = nil
            return nil
        }
        return entry.webView
    }
}

@MainActor
protocol ExtensionVerifiedBrowserTransport: AnyObject {
    func response(
        for request: ExtensionVerifiedBrowserRequest,
        profile: ExtensionBrowserSessionProfile,
        cookies: [ExtensionHTTPStateCookie]
    ) async throws -> ExtensionVerifiedBrowserResult

    func invalidate()
}

enum ExtensionVerifiedBrowserRequestPolicy {
    private static let forbiddenHeaders: Set<String> = [
        "accept-encoding",
        "connection",
        "content-length",
        "cookie",
        "host",
        "origin",
        "proxy-authorization",
        "referer",
        "set-cookie",
        "set-cookie2",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
        "user-agent",
    ]

    nonisolated static func permits(
        url: URL,
        method: HTTPMethod,
        permissions: ExtensionPermissionSet,
        profile: ExtensionBrowserSessionProfile?
    ) -> Bool {
        guard permissions.values.contains(.network),
              permissions.values.contains(.challengeHandoff),
              method == .get || method == .head,
              let profile,
              profile.isValid(),
              profile.matchesOrigin(of: url)
        else { return false }
        return true
    }

    nonisolated static func sanitizedHeaders(_ headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (rawName, rawValue) in headers {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = name.lowercased()
            guard !name.isEmpty,
                  name.utf8.count <= 128,
                  name.unicodeScalars.allSatisfy({
                      (0x30 ... 0x39).contains($0.value)
                          || (0x41 ... 0x5A).contains($0.value)
                          || (0x61 ... 0x7A).contains($0.value)
                          || $0.value == 0x2D
                  }),
                  !forbiddenHeaders.contains(lowercased),
                  !lowercased.hasPrefix("sec-"),
                  rawValue.utf8.count <= 8 * 1_024,
                  !rawValue.unicodeScalars.contains(where: {
                      $0.value < 0x20 && $0.value != 0x09 || $0.value == 0x7F
                  })
            else { continue }
            result[name] = rawValue
        }
        return result
    }
}

enum ExtensionVerifiedBrowserResponsePolicy {
    private static let maximumChallengeMarkupBytes = 256 * 1_024

    nonisolated static func isCloudflareChallenge(_ response: HTTPResponse) -> Bool {
        if response.header("cf-mitigated")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("challenge") == .orderedSame {
            return true
        }
        let html = String(
            decoding: response.data.prefix(maximumChallengeMarkupBytes),
            as: UTF8.self
        )
        return isCloudflareChallengeHTML(html)
    }

    nonisolated static func isCloudflareChallengeHTML(_ html: String) -> Bool {
        let value = String(html.prefix(maximumChallengeMarkupBytes)).lowercased()
        let hasManagedChallengeForm = value.range(
            of: #"<form\b[^>]*(?:id\s*=\s*['\"]challenge-form['\"]|action\s*=\s*['\"][^'\"]*(?:__cf_chl|/cdn-cgi/challenge-platform))"#,
            options: .regularExpression
        ) != nil
        let hasManagedChallengeTitle = value.range(
            of: #"<title\b[^>]*>\s*just a moment(?:\.\.\.)?\s*</title>"#,
            options: .regularExpression
        ) != nil
        return hasManagedChallengeForm || hasManagedChallengeTitle
    }

    nonisolated static func supportsNavigationBody(
        mimeType: String?,
        method: HTTPMethod,
        statusCode: Int
    ) -> Bool {
        if method == .head || statusCode == 204 || statusCode == 205 || statusCode == 304 {
            return true
        }
        guard let mimeType = mimeType?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !mimeType.isEmpty
        else { return false }
        return mimeType.hasPrefix("text/")
            || mimeType == "application/json"
            || mimeType.hasSuffix("+json")
            || mimeType == "application/xml"
            || mimeType.hasSuffix("+xml")
    }

    @MainActor
    static func resolve(
        fetch: @escaping @MainActor () async throws -> HTTPResponse,
        navigation: @escaping @MainActor () async throws -> HTTPResponse
    ) async throws -> HTTPResponse {
        let response = try await fetch()
        guard isCloudflareChallenge(response) else { return response }
        return try await navigation()
    }
}

enum ExtensionVerifiedBrowserCookiePolicy {
    nonisolated static func cookiesToSeed(
        _ stored: [ExtensionHTTPStateCookie],
        existingInWebKit: [ExtensionHTTPStateCookie],
        origin: URL
    ) -> [ExtensionHTTPStateCookie] {
        var hasWebKitClearance = existingInWebKit.contains {
            $0.name.caseInsensitiveCompare("cf_clearance") == .orderedSame
                && $0.isApplicable(to: origin)
        }
        var result: [ExtensionHTTPStateCookie] = []
        for cookie in stored.prefix(100) where cookie.isValidForOrigin(origin) {
            if cookie.name.caseInsensitiveCompare("cf_clearance") == .orderedSame {
                guard !hasWebKitClearance else { continue }
                hasWebKitClearance = true
            }
            result.append(cookie)
        }
        return result
    }
}

/// Fetches may overlap; browser navigation and cookie seeding require exclusive access.
@MainActor
final class ExtensionBrowserSessionAccess {
    private struct Waiter {
        let id: UUID
        let exclusive: Bool
        let continuation: CheckedContinuation<Void, Error>
    }
    private let limit: Int
    private var readers = 0
    private var writer = false
    private var waiters: [Waiter] = []

    init(limit: Int = 4) { self.limit = max(1, limit) }

    func acquire(exclusive: Bool = false) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: id, exclusive: exclusive, continuation: continuation))
                drain()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let index = waiters.firstIndex(where: { $0.id == id }) else { return }
                waiters.remove(at: index).continuation.resume(throwing: CancellationError())
                drain()
            }
        }
        if Task.isCancelled {
            release(exclusive: exclusive)
            throw CancellationError()
        }
    }

    func release(exclusive: Bool = false) {
        if exclusive { writer = false } else { readers -= 1 }
        assert(readers >= 0)
        drain()
    }

    private func drain() {
        while !writer, let first = waiters.first {
            if first.exclusive {
                guard readers == 0 else { return }
                writer = true
            } else {
                guard readers < limit else { return }
                readers += 1
            }
            waiters.removeFirst().continuation.resume()
        }
    }
}

@MainActor
final class ExtensionVerifiedBrowserWebKitTransport: NSObject, ExtensionVerifiedBrowserTransport {
    private static let maximumResponseBytes = 16 * 1_024 * 1_024
    private static let maximumResponseBase64Bytes = ((maximumResponseBytes + 2) / 3) * 4
    private static let logger = Logger(
        subsystem: "com.k800k.manko",
        category: "VerifiedBrowser"
    )
    private let namespace: String
    private let sessionAccess = ExtensionBrowserSessionAccess()
    private var seededCookies: [ExtensionHTTPStateCookie]?
    private enum NavigationKind: Equatable {
        case idle
        case minimalDocument
        case sourceRequest
    }

    private var webView: WKWebView?
    private var cookieStore: WKHTTPCookieStore?
    private var loadedProfile: ExtensionBrowserSessionProfile?
    private var proxyGeneration: UUID?
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var responseContinuation: CheckedContinuation<HTTPResponse, Error>?
    private var navigationKind = NavigationKind.idle
    private var navigationRequest: ExtensionVerifiedBrowserRequest?
    private var navigationResponse: HTTPURLResponse?
    private var activeNavigation: WKNavigation?
    private var didLoad = false

    init(namespace: String) {
        self.namespace = namespace
    }

    func response(
        for request: ExtensionVerifiedBrowserRequest,
        profile: ExtensionBrowserSessionProfile,
        cookies: [ExtensionHTTPStateCookie]
    ) async throws -> ExtensionVerifiedBrowserResult {
        guard UIApplication.shared.applicationState == .active else {
            throw ExtensionVerifiedBrowserTransportError.requiresForeground
        }
        guard profile.isValid(), profile.matchesOrigin(of: request.url),
              request.method == .get || request.method == .head else {
            throw ExtensionVerifiedBrowserTransportError.invalidRequest
        }
        let fetched: HTTPResponse
        // Acquire a stable document before starting a fetch. A changed profile or
        // cookie snapshot is prepared only after all previous fetches finish.
        while true {
            try await sessionAccess.acquire()
            do {
                let lease = try await networkLease(for: profile)
                if loadedProfile == profile, seededCookies == cookies, webView != nil, didLoad,
                   proxyGeneration == lease.generation { break }
            } catch {
                sessionAccess.release()
                throw error
            }
            sessionAccess.release()
            try await prepareExclusively(profile: profile, cookies: cookies)
        }
        do {
            try Task.checkCancellation()
            let requestID = UUID().uuidString
            let fetchWebView = webView
            do {
                let encoded = try await MangoReaderOperationRace().run(
                    timeout: .seconds(30),
                    operation: { [self] in try await fetch(request, profile: profile, requestID: requestID) },
                    onTimeout: {}
                )
                fetched = try decode(encoded, request: request, profile: profile)
            } catch {
                await abortFetch(requestID, webView: fetchWebView)
                throw error
            }
            sessionAccess.release()
        } catch {
            sessionAccess.release()
            throw error
        }
        log(fetched, request: request, route: "fetch")
        let response: HTTPResponse
        if ExtensionVerifiedBrowserResponsePolicy.isCloudflareChallenge(fetched) {
            response = try await navigateExclusively(request, profile: profile, cookies: cookies)
        } else {
            response = fetched
        }
        try Task.checkCancellation()
        return ExtensionVerifiedBrowserResult(
            response: response,
            cookies: await currentCookies(for: profile.canonicalHTTPSOrigin)
        )
    }

    private func prepareExclusively(
        profile: ExtensionBrowserSessionProfile,
        cookies: [ExtensionHTTPStateCookie]
    ) async throws {
        try await sessionAccess.acquire(exclusive: true)
        defer { sessionAccess.release(exclusive: true) }
        try Task.checkCancellation()
        let lease = try await networkLease(for: profile)
        guard loadedProfile != profile || seededCookies != cookies || webView == nil || !didLoad
                || proxyGeneration != lease.generation else { return }
        _ = try await MangoReaderOperationRace().run(
            timeout: .seconds(30),
            operation: { [self] in
                try await prepare(profile: profile, cookies: cookies)
                return ""
            },
            onTimeout: { [weak self] in self?.invalidate() },
            onCancellation: { [weak self] in self?.invalidate() }
        )
    }

    private func navigateExclusively(
        _ request: ExtensionVerifiedBrowserRequest,
        profile: ExtensionBrowserSessionProfile,
        cookies: [ExtensionHTTPStateCookie]
    ) async throws -> HTTPResponse {
        try await sessionAccess.acquire(exclusive: true)
        defer { sessionAccess.release(exclusive: true) }
        try Task.checkCancellation()
        let encoded = try await MangoReaderOperationRace().run(
            timeout: .seconds(30),
            operation: { [self] in
                try await prepare(profile: profile, cookies: cookies)
                return try encode(try await navigateAndReset(request, profile: profile))
            },
            onTimeout: { [weak self] in self?.invalidate() },
            onCancellation: { [weak self] in self?.invalidate() }
        )
        return try decode(encoded, request: request, profile: profile)
    }

    private func abortFetch(_ requestID: String, webView: WKWebView?) async {
        _ = try? await webView?.callAsyncJavaScript(
            "globalThis.__mankoFetchControllers?.get(requestID)?.abort(); return true;",
            arguments: ["requestID": requestID], in: nil, contentWorld: .defaultClient
        )
    }

    func invalidate() {
        loadContinuation?.resume(throwing: MangoReaderExtensionRuntimeError.runtimeTerminated)
        loadContinuation = nil
        responseContinuation?.resume(throwing: MangoReaderExtensionRuntimeError.runtimeTerminated)
        responseContinuation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        cookieStore = nil
        loadedProfile = nil
        proxyGeneration = nil
        seededCookies = nil
        navigationKind = .idle
        navigationRequest = nil
        navigationResponse = nil
        activeNavigation = nil
        didLoad = false
    }

    private func log(
        _ response: HTTPResponse,
        request: ExtensionVerifiedBrowserRequest,
        route: String
    ) {
        Self.logger.debug(
            """
            \(self.namespace, privacy: .public) \(route, privacy: .public) \
            \(request.method.rawValue, privacy: .public) \
            \(request.url.path, privacy: .public) -> \(response.statusCode, privacy: .public); \
            cf-mitigated=\(response.header("cf-mitigated") ?? "-", privacy: .public); \
            content-type=\(response.header("content-type") ?? "-", privacy: .public)
            """
        )
    }

    private func prepare(
        profile: ExtensionBrowserSessionProfile,
        cookies: [ExtensionHTTPStateCookie]
    ) async throws {
        if loadedProfile != profile || webView == nil || cookieStore == nil || !didLoad {
            invalidate()
            let webView: WKWebView
            if let verified = ExtensionVerifiedBrowserSessionPool.take(
                namespace: namespace,
                profile: profile
            ) {
                webView = verified
                Self.logger.debug(
                    "Reusing verified WebKit session for \(self.namespace, privacy: .public)"
                )
            } else {
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = namespace.hasPrefix("private-") ? .nonPersistent() : WKWebsiteDataStore(
                    forIdentifier: ExtensionBrowserSessionProfile.websiteDataStoreIdentifier(
                        for: namespace
                    )
                )
                configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
                configuration.defaultWebpagePreferences.allowsContentJavaScript = true

                webView = WKWebView(frame: .zero, configuration: configuration)
                Self.logger.debug(
                    "Creating persistent WebKit session for \(self.namespace, privacy: .public)"
                )
            }
            guard let host = profile.canonicalHTTPSOrigin.host else { throw ExtensionVerifiedBrowserTransportError.invalidRequest }
            proxyGeneration = try await ExtensionNetworkPolicy(hosts: [host]).configureBrowser(webView.configuration)
            webView.customUserAgent = profile.userAgent
            webView.navigationDelegate = self
            self.webView = webView
            cookieStore = webView.configuration.websiteDataStore.httpCookieStore
            loadedProfile = profile
            try await seed(cookies, profile: profile)
            try await loadMinimalDocument(profile: profile)
        } else {
            let lease = try await networkLease(for: profile)
            try Task.checkCancellation()
            if proxyGeneration != lease.generation {
                webView?.configuration.websiteDataStore.proxyConfigurations = [lease.configuration]
                proxyGeneration = lease.generation
            }
            if seededCookies != cookies { try await seed(cookies, profile: profile) }
        }
        seededCookies = cookies
    }

    private func networkLease(for profile: ExtensionBrowserSessionProfile) async throws -> ExtensionNetworkSessions.Lease {
        guard let host = profile.canonicalHTTPSOrigin.host else {
            throw ExtensionVerifiedBrowserTransportError.invalidRequest
        }
        return try await ExtensionNetworkSessions.shared.lease(for: ExtensionNetworkPolicy(hosts: [host]))
    }

    private func loadMinimalDocument(
        profile: ExtensionBrowserSessionProfile
    ) async throws {
        guard let webView else {
            throw ExtensionVerifiedBrowserTransportError.invalidResponse
        }
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        didLoad = false
        navigationKind = .minimalDocument
        navigationRequest = nil
        navigationResponse = nil
        let html = """
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; connect-src 'self' \(profile.canonicalHTTPSOrigin.absoluteString); img-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'">
        </head><body></body></html>
        """
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            activeNavigation = webView.loadHTMLString(
                html,
                baseURL: profile.canonicalHTTPSOrigin
            )
        }
    }

    private func seed(
        _ cookies: [ExtensionHTTPStateCookie],
        profile: ExtensionBrowserSessionProfile
    ) async throws {
        guard let cookieStore else {
            throw ExtensionVerifiedBrowserTransportError.invalidResponse
        }
        let existing = await cookieStore.allCookies()
        // `WKHTTPCookieStore` can expose both partitioned and unpartitioned
        // cookies as otherwise identical `HTTPCookie` values. Partition
        // provenance is not represented by Foundation, so the browser's jar
        // remains authoritative and is never flattened or deduplicated here.
        let statesToSeed = ExtensionVerifiedBrowserCookiePolicy.cookiesToSeed(
            cookies,
            existingInWebKit: existing.map(stateCookie),
            origin: profile.canonicalHTTPSOrigin
        )
        for state in statesToSeed {
            guard let cookie = httpCookie(state, origin: profile.canonicalHTTPSOrigin) else {
                continue
            }
            await cookieStore.setCookie(cookie)
        }
    }

    private func fetch(
        _ request: ExtensionVerifiedBrowserRequest,
        profile: ExtensionBrowserSessionProfile,
        requestID: String
    ) async throws -> String {
        guard let webView else {
            throw ExtensionVerifiedBrowserTransportError.invalidResponse
        }
        let headers = ExtensionVerifiedBrowserRequestPolicy.sanitizedHeaders(request.headers)
        let script = """
        const controllers = globalThis.__mankoFetchControllers ||= new Map();
        const controller = new AbortController();
        controllers.set(requestID, controller);
        try {
        const target = new URL(url);
        if (target.protocol !== "https:" || target.origin !== expectedOrigin) {
          return JSON.stringify({ ok: false, error: "invalidRequest" });
        }
        let response;
        try {
          response = await fetch(target.href, {
            signal: controller.signal,
            method,
            headers,
            credentials: "include",
            cache: "no-store",
            redirect: "follow",
            mode: "same-origin",
            referrer: expectedOrigin + "/",
            referrerPolicy: "strict-origin-when-cross-origin"
          });
        } catch (_) {
          return JSON.stringify({ ok: false, error: "network" });
        }
        const responseURL = new URL(response.url || target.href);
        if (responseURL.origin !== expectedOrigin) {
          return JSON.stringify({ ok: false, error: "redirect" });
        }
        const chunks = [];
        let total = 0;
        if (method !== "HEAD" && response.body) {
          const reader = response.body.getReader();
          while (true) {
            const value = await reader.read();
            if (value.done) break;
            total += value.value.byteLength;
            if (total > maximumBytes) {
              try { await reader.cancel(); } catch (_) {}
              return JSON.stringify({ ok: false, error: "tooLarge" });
            }
            chunks.push(value.value);
          }
        }
        const bytes = new Uint8Array(total);
        let offset = 0;
        for (const chunk of chunks) {
          bytes.set(chunk, offset);
          offset += chunk.byteLength;
        }
        let binary = "";
        for (let index = 0; index < bytes.length; index += 0x8000) {
          binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
        }
        const responseHeaders = {};
        let headerCount = 0;
        for (const [name, value] of response.headers.entries()) {
          if (++headerCount > 200) break;
          responseHeaders[String(name).slice(0, 128)] = String(value).slice(0, 8192);
        }
        return JSON.stringify({
          ok: true,
          url: responseURL.href,
          status: response.status,
          headers: responseHeaders,
          dataBase64: btoa(binary)
        });
        } finally { controllers.delete(requestID); }
        """
        guard let encoded = try await webView.callAsyncJavaScript(
            script,
            arguments: [
                "requestID": requestID,
                "url": request.url.absoluteString,
                "expectedOrigin": profile.canonicalHTTPSOrigin.absoluteString,
                "method": request.method.rawValue,
                "headers": headers,
                "maximumBytes": Self.maximumResponseBytes,
            ],
            in: nil,
            contentWorld: .defaultClient
        ) as? String else {
            throw ExtensionVerifiedBrowserTransportError.invalidResponse
        }
        return encoded
    }

    private func navigate(
        _ request: ExtensionVerifiedBrowserRequest,
        profile: ExtensionBrowserSessionProfile
    ) async throws -> HTTPResponse {
        guard let webView,
              profile.matchesOrigin(of: request.url),
              navigationKind == .idle
        else {
            throw ExtensionVerifiedBrowserTransportError.invalidRequest
        }
        var urlRequest = URLRequest(
            url: request.url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 30
        )
        urlRequest.httpMethod = request.method.rawValue
        for (name, value) in ExtensionVerifiedBrowserRequestPolicy.sanitizedHeaders(
            request.headers
        ) {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        didLoad = false
        navigationKind = .sourceRequest
        navigationRequest = request
        navigationResponse = nil
        return try await withCheckedThrowingContinuation { continuation in
            responseContinuation = continuation
            activeNavigation = webView.load(urlRequest)
        }
    }

    private func navigateAndReset(
        _ request: ExtensionVerifiedBrowserRequest,
        profile: ExtensionBrowserSessionProfile
    ) async throws -> HTTPResponse {
        do {
            let response = try await navigate(request, profile: profile)
            log(response, request: request, route: "navigation")
            try await loadMinimalDocument(profile: profile)
            return response
        } catch {
            do {
                try await loadMinimalDocument(profile: profile)
            } catch {
                invalidate()
            }
            throw error
        }
    }

    private func encode(_ response: HTTPResponse) throws -> String {
        let value: [String: Any] = [
            "ok": true,
            "url": response.url.absoluteString,
            "status": response.statusCode,
            "headers": response.headers,
            "dataBase64": response.data.base64EncodedString(),
        ]
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= Self.maximumResponseBase64Bytes + 256 * 1_024 else {
            throw ExtensionVerifiedBrowserTransportError.responseTooLarge
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func decode(
        _ encoded: String,
        request: ExtensionVerifiedBrowserRequest,
        profile: ExtensionBrowserSessionProfile
    ) throws -> HTTPResponse {
        guard encoded.utf8.count <= Self.maximumResponseBase64Bytes + 256 * 1_024,
              let data = encoded.data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["ok"] as? Bool == true
        else {
            if let data = encoded.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = value["error"] as? String {
                switch error {
                case "invalidRequest":
                    throw ExtensionVerifiedBrowserTransportError.invalidRequest
                case "redirect":
                    throw ExtensionVerifiedBrowserTransportError.redirectNotAllowed
                case "tooLarge":
                    throw ExtensionVerifiedBrowserTransportError.responseTooLarge
                default:
                    throw ExtensionVerifiedBrowserTransportError.invalidResponse
                }
            }
            throw ExtensionVerifiedBrowserTransportError.invalidResponse
        }
        guard let rawURL = value["url"] as? String,
              let url = URL(string: rawURL),
              profile.matchesOrigin(of: url),
              let status = value["status"] as? Int,
              (100 ... 599).contains(status),
              let rawHeaders = value["headers"] as? [String: String],
              let dataBase64 = value["dataBase64"] as? String,
              dataBase64.utf8.count <= Self.maximumResponseBase64Bytes,
              let responseData = Data(base64Encoded: dataBase64),
              responseData.count <= Self.maximumResponseBytes
        else {
            throw ExtensionVerifiedBrowserTransportError.invalidResponse
        }
        return HTTPResponse(
            url: url,
            statusCode: status,
            headers: ExtensionVerifiedBrowserRequestPolicy.sanitizedHeaders(rawHeaders),
            data: responseData
        )
    }

    private func navigationBody(
        mimeType: String?,
        method: HTTPMethod,
        statusCode: Int
    ) async throws -> Data {
        guard method != .head,
              statusCode != 204,
              statusCode != 205,
              statusCode != 304
        else { return Data() }
        guard let webView else {
            throw ExtensionVerifiedBrowserTransportError.invalidResponse
        }
        let script = """
        const type = String(mimeType || "").split(";", 1)[0].trim().toLowerCase();
        let text;
        if (type === "text/html" || type === "application/xhtml+xml") {
          text = document.documentElement ? document.documentElement.outerHTML : "";
        } else if (type === "application/xml" || type.endsWith("+xml")) {
          text = document.documentElement
            ? new XMLSerializer().serializeToString(document)
            : "";
        } else {
          text = document.body?.innerText ?? document.documentElement?.textContent ?? "";
        }
        const bytes = new TextEncoder().encode(text);
        if (bytes.byteLength > maximumBytes) {
          return JSON.stringify({ ok: false, error: "tooLarge" });
        }
        let binary = "";
        for (let index = 0; index < bytes.length; index += 0x8000) {
          binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
        }
        return JSON.stringify({ ok: true, dataBase64: btoa(binary) });
        """
        guard let encoded = try await webView.callAsyncJavaScript(
            script,
            arguments: [
                "mimeType": mimeType ?? "",
                "maximumBytes": Self.maximumResponseBytes,
            ],
            in: nil,
            contentWorld: .defaultClient
        ) as? String,
              encoded.utf8.count <= Self.maximumResponseBase64Bytes + 1_024,
              let data = encoded.data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ExtensionVerifiedBrowserTransportError.invalidResponse
        }
        if value["error"] as? String == "tooLarge" {
            throw ExtensionVerifiedBrowserTransportError.responseTooLarge
        }
        guard value["ok"] as? Bool == true,
              let dataBase64 = value["dataBase64"] as? String,
              dataBase64.utf8.count <= Self.maximumResponseBase64Bytes,
              let result = Data(base64Encoded: dataBase64),
              result.count <= Self.maximumResponseBytes
        else {
            throw ExtensionVerifiedBrowserTransportError.invalidResponse
        }
        return result
    }

    private func currentCookies(for origin: URL) async -> [ExtensionHTTPStateCookie] {
        guard let cookieStore else { return [] }
        return Array(await cookieStore.allCookies()
            .lazy
            .map(stateCookie)
            .filter { $0.isValidForOrigin(origin) }
            .prefix(100))
    }

    private func stateCookie(_ cookie: HTTPCookie) -> ExtensionHTTPStateCookie {
        ExtensionHTTPStateCookie(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
            path: cookie.path,
            expires: cookie.expiresDate?.ISO8601Format(),
            secure: cookie.isSecure,
            httpOnly: cookie.isHTTPOnly,
            hostOnly: !cookie.domain.hasPrefix(".")
        )
    }

    private func httpCookie(
        _ cookie: ExtensionHTTPStateCookie,
        origin: URL
    ) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookie.name,
            .value: cookie.value,
            .path: cookie.path,
        ]
        if cookie.hostOnly {
            properties[.originURL] = origin
        } else {
            properties[.domain] = cookie.domain
        }
        if cookie.secure { properties[.secure] = "TRUE" }
        if cookie.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let expires = cookie.expires,
           let date = ISO8601DateFormatter().date(from: expires) {
            properties[.expires] = date
        }
        return HTTPCookie(properties: properties)
    }
}

extension ExtensionVerifiedBrowserWebKitTransport: WKNavigationDelegate {
    func webView(_: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === activeNavigation else { return }
        guard !didLoad else { return }
        didLoad = true
        switch navigationKind {
        case .idle:
            return
        case .minimalDocument:
            navigationKind = .idle
            activeNavigation = nil
            loadContinuation?.resume()
            loadContinuation = nil
        case .sourceRequest:
            guard let request = navigationRequest,
                  let response = navigationResponse,
                  loadedProfile?.matchesOrigin(of: response.url ?? request.url) == true
            else {
                finishSourceNavigation(.failure(
                    ExtensionVerifiedBrowserTransportError.invalidResponse
                ))
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let body = try await self.navigationBody(
                        mimeType: response.mimeType,
                        method: request.method,
                        statusCode: response.statusCode
                    )
                    self.finishSourceNavigation(.success(HTTPResponse(
                        url: response.url ?? request.url,
                        statusCode: response.statusCode,
                        headers: ExtensionVerifiedBrowserRequestPolicy.sanitizedHeaders(
                            Self.stringHeaders(response)
                        ),
                        data: body
                    )))
                } catch {
                    self.finishSourceNavigation(.failure(error))
                }
            }
        }
    }

    func webView(_: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === activeNavigation else { return }
        finishActiveNavigation(.failure(error))
    }

    func webView(
        _: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard navigation === activeNavigation else { return }
        finishActiveNavigation(.failure(error))
    }

    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor @Sendable (
            WKNavigationActionPolicy,
            WKWebpagePreferences
        ) -> Void
    ) {
        guard !navigationAction.shouldPerformDownload,
              let url = navigationAction.request.url
        else {
            decisionHandler(.cancel, preferences)
            finishActiveNavigation(.failure(
                ExtensionVerifiedBrowserTransportError.invalidResponse
            ))
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if navigationKind == .minimalDocument,
           ["about", "data", "blob"].contains(scheme) {
            decisionHandler(.allow, preferences)
            return
        }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        guard isMainFrame,
              !didLoad,
              loadedProfile?.matchesOrigin(of: url) == true
        else {
            decisionHandler(.cancel, preferences)
            if isMainFrame {
                finishActiveNavigation(.failure(
                    ExtensionVerifiedBrowserTransportError.redirectNotAllowed
                ))
            }
            return
        }
        preferences.allowsContentJavaScript = navigationKind == .minimalDocument
        decisionHandler(.allow, preferences)
    }

    func webView(
        _: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        guard navigationKind == .sourceRequest,
              navigationResponse.isForMainFrame,
              let response = navigationResponse.response as? HTTPURLResponse,
              let request = navigationRequest
        else {
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
            return
        }
        guard loadedProfile?.matchesOrigin(of: response.url ?? request.url) == true else {
            decisionHandler(.cancel)
            finishSourceNavigation(.failure(
                ExtensionVerifiedBrowserTransportError.redirectNotAllowed
            ))
            return
        }

        self.navigationResponse = response
        let headers = ExtensionVerifiedBrowserRequestPolicy.sanitizedHeaders(
            Self.stringHeaders(response)
        )
        let shell = HTTPResponse(
            url: response.url ?? request.url,
            statusCode: response.statusCode,
            headers: headers,
            data: Data()
        )
        if shell.header("cf-mitigated")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("challenge") == .orderedSame {
            // Do not run an invisible challenge. The explicit header is enough
            // for the runtime to return to the visible verification policy.
            decisionHandler(.cancel)
            finishSourceNavigation(.success(shell))
            return
        }
        guard navigationResponse.canShowMIMEType,
              ExtensionVerifiedBrowserResponsePolicy.supportsNavigationBody(
                mimeType: response.mimeType,
                method: request.method,
                statusCode: response.statusCode
              )
        else {
            decisionHandler(.cancel)
            finishSourceNavigation(.failure(
                ExtensionVerifiedBrowserTransportError.invalidResponse
            ))
            return
        }
        decisionHandler(.allow)
    }

    private func finishActiveNavigation(_ result: Result<Void, Error>) {
        switch navigationKind {
        case .idle:
            return
        case .minimalDocument:
            navigationKind = .idle
            activeNavigation = nil
            let continuation = loadContinuation
            loadContinuation = nil
            continuation?.resume(with: result)
        case .sourceRequest:
            switch result {
            case .success:
                finishSourceNavigation(.failure(
                    ExtensionVerifiedBrowserTransportError.invalidResponse
                ))
            case let .failure(error):
                finishSourceNavigation(.failure(error))
            }
        }
    }

    private func finishSourceNavigation(_ result: Result<HTTPResponse, Error>) {
        guard navigationKind == .sourceRequest else { return }
        navigationKind = .idle
        navigationRequest = nil
        navigationResponse = nil
        activeNavigation = nil
        let continuation = responseContinuation
        responseContinuation = nil
        continuation?.resume(with: result)
    }

    private static func stringHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (rawName, rawValue) in response.allHeaderFields.prefix(200) {
            guard let name = rawName as? String else { continue }
            result[name] = String(describing: rawValue)
        }
        return result
    }
}
