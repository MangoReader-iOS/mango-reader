import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A cookie from a browser-verified session that may be re-applied when an
/// HTTP redirect reaches that session's exact origin. Domain validation stays
/// with the browser-session owner; this value only performs path and transport
/// matching at the final redirect URL.
public struct HTTPRedirectCookie: Hashable, Sendable {
    public var name: String
    public var value: String
    public var path: String
    public var secure: Bool

    public init(name: String, value: String, path: String, secure: Bool = false) {
        self.name = name
        self.value = value
        self.path = path
        self.secure = secure
    }

    fileprivate func isApplicable(to url: URL) -> Bool {
        guard Self.hasValidName(name),
              Self.hasValidValue(value),
              path.hasPrefix("/"),
              !secure || url.scheme?.lowercased() == "https"
        else { return false }
        let requestPath = url.path.isEmpty ? "/" : url.path
        if requestPath == path { return true }
        guard requestPath.hasPrefix(path) else { return false }
        return path.hasSuffix("/") || requestPath.dropFirst(path.count).first == "/"
    }

    private static func hasValidName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        let punctuation = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~")
        return value.unicodeScalars.allSatisfy {
            (0x30 ... 0x39).contains($0.value) ||
                (0x41 ... 0x5A).contains($0.value) ||
                (0x61 ... 0x7A).contains($0.value) ||
                punctuation.contains($0)
        }
    }

    private static func hasValidValue(_ value: String) -> Bool {
        guard value.utf8.count <= 4_096 else { return false }
        return value.unicodeScalars.allSatisfy {
            $0.value > 0x1F && $0.value != 0x7F && $0.value != 0x3B && $0.value != 0x2C
        }
    }
}

/// The exact browser identity established by a visible verification handoff.
/// It is never sent merely because a host is related by domain; redirects must
/// arrive at this precise scheme, host, and effective port.
public struct HTTPRedirectIdentity: Hashable, Sendable {
    public var origin: URL
    public var userAgent: String
    public var cookies: [HTTPRedirectCookie]

    public init(origin: URL, userAgent: String, cookies: [HTTPRedirectCookie]) {
        self.origin = origin
        self.userAgent = userAgent
        self.cookies = cookies
    }
}

/// Applies endpoint and credential-origin rules to every redirect followed by
/// the foreground HTTP client. Valid cross-origin redirects remain followable,
/// but their redirected requests must not carry credentials from the previous
/// origin.
struct SourceRequestRedirectPolicy: Sendable {
    var endpointAccess: EndpointAccess
    var credentialOrigin: URL?
    var allowedHTTPSHosts: Set<String>?
    var redirectIdentity: HTTPRedirectIdentity?
    var networkPolicy: ExtensionNetworkPolicy?
    var followsRedirects: Bool

    init(
        endpointAccess: EndpointAccess,
        credentialOrigin: URL?,
        allowedHTTPSHosts: Set<String>? = nil,
        redirectIdentity: HTTPRedirectIdentity? = nil,
        networkPolicy: ExtensionNetworkPolicy? = nil,
        followsRedirects: Bool = true
    ) {
        self.endpointAccess = endpointAccess
        self.credentialOrigin = credentialOrigin
        self.allowedHTTPSHosts = allowedHTTPSHosts
        self.redirectIdentity = redirectIdentity
        self.networkPolicy = networkPolicy
        self.followsRedirects = followsRedirects
    }

    func shouldFollow(to destination: URL) -> Bool {
        guard followsRedirects, networkPolicy?.allows(destination) != false else { return false }
        do {
            try EndpointPolicy().validate(destination, access: endpointAccess)
        } catch {
            return false
        }

        if let allowedHTTPSHosts {
            guard destination.scheme?.lowercased() == "https",
                  let host = destination.host?.lowercased(),
                  HTTPSHostAccess.allows(host, declarations: allowedHTTPSHosts)
            else { return false }
        }

        return true
    }

    /// Returns the request that may be followed after enforcing endpoint and
    /// credential rules. `source` should be the URL that produced the redirect.
    /// The configured credential origin is only a conservative fallback for a
    /// malformed response that does not expose its URL.
    func requestForFollowing(_ request: URLRequest, from source: URL?) -> URLRequest? {
        guard let destination = request.url, shouldFollow(to: destination) else {
            return nil
        }

        var followed: URLRequest
        if let source = source ?? credentialOrigin,
           SourceCredentialOriginPolicy.isSameOrigin(destination, as: source) {
            followed = request
        } else {
            followed = request.removingRedirectCredentials()
        }

        if let redirectIdentity,
           !SourceCredentialOriginPolicy.isSameOrigin(destination, as: redirectIdentity.origin)
        {
            let leavesVerifiedOrigin = source.map {
                SourceCredentialOriginPolicy.isSameOrigin($0, as: redirectIdentity.origin)
            } ?? false
            let carriesVerifiedUserAgent = followed.value(
                forHTTPHeaderField: "User-Agent"
            ) == redirectIdentity.userAgent
            if leavesVerifiedOrigin || carriesVerifiedUserAgent {
                followed.setValue(nil, forHTTPHeaderField: "User-Agent")
            }
        }
        return followed.applyingRedirectIdentity(redirectIdentity, for: destination)
    }
}

extension URLRequest {
    func removingRedirectCredentials() -> URLRequest {
        var sanitized = self
        for name in allHTTPHeaderFields?.keys ?? Dictionary<String, String>().keys
        where RedirectCredentialHeaderPolicy.shouldRemoveOnCrossOriginRedirect(name) {
            sanitized.setValue(nil, forHTTPHeaderField: name)
        }
        return sanitized
    }

    func applyingRedirectIdentity(
        _ identity: HTTPRedirectIdentity?,
        for destination: URL
    ) -> URLRequest {
        guard let identity,
              SourceCredentialOriginPolicy.isSameOrigin(destination, as: identity.origin),
              SourceCredentialOriginPolicy.origin(for: identity.origin)?.scheme == "https",
              RedirectCredentialHeaderPolicy.isSafeUserAgent(identity.userAgent)
        else { return self }

        var result = self
        result.setValue(nil, forHTTPHeaderField: "Cookie")
        result.setValue(nil, forHTTPHeaderField: "User-Agent")
        result.setValue(identity.userAgent, forHTTPHeaderField: "User-Agent")

        let sortedCookies = identity.cookies
            .filter { $0.isApplicable(to: destination) }
            .sorted { lhs, rhs in
                if lhs.path.count != rhs.path.count { return lhs.path.count > rhs.path.count }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        var seenCookieNames: Set<String> = []
        let cookies = sortedCookies.filter { seenCookieNames.insert($0.name).inserted }
        if !cookies.isEmpty {
            result.setValue(
                cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "),
                forHTTPHeaderField: "Cookie"
            )
        }
        return result
    }
}

private enum RedirectCredentialHeaderPolicy {
    /// Cross-origin redirects retain only standard representation and cache
    /// negotiation fields. A configured API-key header may have any valid
    /// name, so a denylist alone cannot prevent secrets such as `X-Secret` or
    /// `CF-Access-Client-Secret` from leaving the credential origin.
    private static let crossOriginSafeNames: Set<String> = [
        "accept",
        "accept-charset",
        "accept-encoding",
        "accept-language",
        "cache-control",
        "content-type",
        "if-match",
        "if-modified-since",
        "if-none-match",
        "if-range",
        "if-unmodified-since",
        "pragma",
        "range",
        "user-agent",
    ]

    private static let exactNames: Set<String> = [
        "authorization",
        "cookie",
        "cookie2",
        "proxy-authorization",
        "api-key",
        "dpop",
        "x-api-key",
        "x-auth-token",
        "x-access-token",
        "x-amz-security-token",
        "x-goog-api-key",
    ]

    static func shouldRemoveOnCrossOriginRedirect(_ name: String) -> Bool {
        let normalized = name.lowercased()
        if exactNames.contains(normalized)
            || normalized.hasSuffix("-authorization")
            || normalized.hasSuffix("-api-key")
            || normalized.hasSuffix("-token")
            || normalized.contains("credential")
        {
            return true
        }
        return !crossOriginSafeNames.contains(normalized)
    }

    static func isSafeUserAgent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= 2_048
            && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }
}

/// A false negative only omits credentials. A false positive can disclose a
/// password or token, so malformed and unfamiliar origins never compare equal.
enum SourceCredentialOriginPolicy {
    struct Origin: Hashable, Sendable {
        var scheme: String
        var host: String
        var effectivePort: Int
    }

    static func origin(for url: URL) -> Origin? {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.user == nil,
            components.password == nil,
            let scheme = components.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            let rawHost = components.host,
            !rawHost.isEmpty
        else {
            return nil
        }

        var host = rawHost
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty else { return nil }

        return Origin(
            scheme: scheme,
            host: host,
            effectivePort: components.port ?? (scheme == "https" ? 443 : 80)
        )
    }

    static func isSameOrigin(_ candidate: URL, as allowedOrigin: URL) -> Bool {
        guard
            let candidateOrigin = origin(for: candidate),
            let allowed = origin(for: allowedOrigin)
        else {
            return false
        }
        return candidateOrigin == allowed
    }
}

private final class SourceRequestRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let policy: SourceRequestRedirectPolicy

    init(policy: SourceRequestRedirectPolicy) {
        self.policy = policy
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(policy.requestForFollowing(request, from: response.url))
    }
}

extension SourceRequestRedirectPolicy {
    func makeDelegate() -> any URLSessionTaskDelegate {
        SourceRequestRedirectDelegate(policy: self)
    }
}
