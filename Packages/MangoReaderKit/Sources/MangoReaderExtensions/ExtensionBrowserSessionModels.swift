import CryptoKit
import Foundation
import MangoReaderDomain
import MangoReaderSources
import SwiftPublicSuffixList

public struct ExtensionHTTPStateCookie: Codable, Hashable, Sendable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var expires: String?
    public var secure: Bool
    public var httpOnly: Bool
    public var hostOnly: Bool

    public init(
        name: String,
        value: String,
        domain: String,
        path: String,
        expires: String? = nil,
        secure: Bool = false,
        httpOnly: Bool = false,
        hostOnly: Bool = false
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.secure = secure
        self.httpOnly = httpOnly
        self.hostOnly = hostOnly
    }

    private enum CodingKeys: String, CodingKey {
        case name, value, domain, path, expires, secure, httpOnly, hostOnly
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        value = try values.decode(String.self, forKey: .value)
        domain = try values.decode(String.self, forKey: .domain)
        path = try values.decode(String.self, forKey: .path)
        expires = try values.decodeIfPresent(String.self, forKey: .expires)
        // Older records did not retain transport or host-only provenance.
        // Decode them conservatively so an upgrade cannot broaden a cookie to
        // subdomains or send a formerly Secure cookie over HTTP.
        secure = try values.decodeIfPresent(Bool.self, forKey: .secure) ?? true
        httpOnly = try values.decodeIfPresent(Bool.self, forKey: .httpOnly) ?? false
        hostOnly = try values.decodeIfPresent(Bool.self, forKey: .hostOnly) ?? true
    }

    public func isApplicable(to url: URL, at date: Date = .now) -> Bool {
        guard isValidForOrigin(url, at: date),
              !secure || url.scheme?.lowercased() == "https"
        else { return false }
        let requestPath = url.path.isEmpty ? "/" : url.path
        if requestPath == path { return true }
        guard requestPath.hasPrefix(path) else { return false }
        return path.hasSuffix("/") || requestPath.dropFirst(path.count).first == "/"
    }

    func isValidForOrigin(_ origin: URL, at date: Date = .now) -> Bool {
        guard Self.hasValidName(name),
              Self.hasValidValue(value),
              let host = origin.host.map(Self.normalizedHost),
              !host.isEmpty,
              path.hasPrefix("/"),
              path.utf8.count <= 2_048,
              !isExpired(at: date)
        else { return false }

        let cookieDomain = Self.normalizedHost(domain)
        guard !cookieDomain.isEmpty else { return false }
        if hostOnly {
            return host == cookieDomain
        }
        guard !Self.isPublicSuffixDomain(cookieDomain) else { return false }
        return host == cookieDomain || host.hasSuffix(".\(cookieDomain)")
    }

    func isExpired(at date: Date = .now) -> Bool {
        guard let expires else { return false }
        let formatter = ISO8601DateFormatter()
        let expiration: Date?
        if let parsed = formatter.date(from: expires) {
            expiration = parsed
        } else {
            formatter.formatOptions.insert(.withFractionalSeconds)
            expiration = formatter.date(from: expires)
        }
        guard let expiration else { return true }
        return expiration <= date
    }

    func hasSameIdentity(as other: Self) -> Bool {
        name == other.name
            && Self.normalizedHost(domain) == Self.normalizedHost(other.domain)
            && path == other.path
    }

    private static func normalizedHost(_ value: String) -> String {
        var result = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while result.hasPrefix(".") { result.removeFirst() }
        while result.hasSuffix(".") { result.removeLast() }
        return result
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

    /// Cookie domain boundaries follow the complete Mozilla Public Suffix List,
    /// including wildcard and exception rules plus private hosting suffixes.
    /// Treat malformed or unknown wire-format hostnames as restricted.
    public static func isPublicSuffixDomain(_ domain: String) -> Bool {
        let ace = PublicSuffixList.ace(domain)
        // The PSL deliberately has no rule for RFC 2606's reserved `.example`
        // namespace, so the package's fail-closed unknown-TLD behavior would
        // otherwise reject domain cookies used by deterministic local fixtures.
        // Keep the reserved TLD itself restricted while treating names below it
        // like ordinary registrable test domains.
        if ace == "example" { return true }
        if ace.hasSuffix(".example") { return false }
        return !PublicSuffixList.isUnrestricted(ace)
    }
}

public struct CloudflareChallengeContext: Codable, Hashable, Sendable {
    static let pendingSecureStateKey = "pending_browser_verification"

    public var url: URL?
    public var namespace: String
    public var permittedBrowserHosts: Set<String>
    public private(set) var brokerObservedBrowserHosts: Set<String>

    public var authorizedBrowserHosts: Set<String> {
        permittedBrowserHosts.union(brokerObservedBrowserHosts)
    }

    public init(url: URL?, namespace: String, permittedBrowserHosts: Set<String> = []) {
        self.url = url
        self.namespace = namespace
        self.permittedBrowserHosts = Self.normalizedHosts(permittedBrowserHosts)
        brokerObservedBrowserHosts = []
    }

    /// Creates a handoff context from a URL returned by the native HTTP
    /// broker. Unlike an extension-thrown URL, this URL was observed after
    /// transport and redirect policy ran, so its exact HTTPS host can be
    /// retained separately from catalog-declared browser hosts.
    public static func brokerObserved(
        url: URL?,
        namespace: String,
        permittedBrowserHosts: Set<String> = []
    ) -> Self {
        var context = Self(
            url: url,
            namespace: namespace,
            permittedBrowserHosts: permittedBrowserHosts
        )
        if let url,
           let origin = ExtensionBrowserSessionProfile.canonicalHTTPSOrigin(for: url),
           let host = origin.host.map(Self.normalizedHost),
           Self.isSafeExactBrowserHost(host)
        {
            context.brokerObservedBrowserHosts.insert(host)
        }
        return context
    }

    public func authorizesHandoffURL(_ candidate: URL) -> Bool {
        guard let origin = ExtensionBrowserSessionProfile.canonicalHTTPSOrigin(for: candidate),
              let host = origin.host.map(Self.normalizedHost),
              !host.isEmpty
        else { return false }
        let declarations = Set(authorizedBrowserHosts.filter(Self.isSafeBrowserHostDeclaration))
        return HTTPSHostAccess.allows(host, declarations: declarations)
    }

    public func merging(_ other: Self) -> Self {
        guard namespace == other.namespace else { return self }
        var merged = Self(
            url: url ?? other.url,
            namespace: namespace,
            permittedBrowserHosts: permittedBrowserHosts.union(other.permittedBrowserHosts)
        )
        merged.brokerObservedBrowserHosts = brokerObservedBrowserHosts
            .union(other.brokerObservedBrowserHosts)
        return merged
    }

    /// Rebinds declared hosts to the source record currently installed by the
    /// app. Broker-observed hosts keep their separate transport provenance.
    public func bindingDeclaredBrowserHosts(to installedHosts: Set<String>) -> Self {
        var bound = Self(
            url: url,
            namespace: namespace,
            permittedBrowserHosts: permittedBrowserHosts.intersection(
                Self.normalizedHosts(installedHosts)
            )
        )
        bound.brokerObservedBrowserHosts = brokerObservedBrowserHosts
        return bound
    }

    private enum CodingKeys: String, CodingKey {
        case url, namespace, permittedBrowserHosts, brokerObservedBrowserHosts
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        url = try values.decodeIfPresent(URL.self, forKey: .url)
        namespace = try values.decode(String.self, forKey: .namespace)
        permittedBrowserHosts = Self.normalizedHosts(
            try values.decodeIfPresent(Set<String>.self, forKey: .permittedBrowserHosts) ?? []
        )
        if values.contains(.brokerObservedBrowserHosts) {
            brokerObservedBrowserHosts = Set(Self.normalizedHosts(
                try values.decodeIfPresent(
                    Set<String>.self,
                    forKey: .brokerObservedBrowserHosts
                ) ?? []
            ).filter(Self.isSafeExactBrowserHost))
        } else {
            // Older encodings implicitly inserted the URL host into
            // `permittedBrowserHosts`, so that exact host has no trustworthy
            // declaration provenance. Drop it and let the source report a
            // fresh challenge under the explicit representation.
            brokerObservedBrowserHosts = []
            if let host = url?.host.map(Self.normalizedHost) {
                permittedBrowserHosts.remove(host)
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(url, forKey: .url)
        try values.encode(namespace, forKey: .namespace)
        try values.encode(permittedBrowserHosts, forKey: .permittedBrowserHosts)
        // Always encode this key, including an empty set, so new contexts are
        // distinguishable from legacy auto-whitelisting encodings.
        try values.encode(brokerObservedBrowserHosts, forKey: .brokerObservedBrowserHosts)
    }

    private static func normalizedHosts(_ values: Set<String>) -> Set<String> {
        Set(values.map(normalizedHost).filter { !$0.isEmpty })
    }

    private static func normalizedHost(_ value: String) -> String {
        var result = value
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        while result.hasSuffix(".") { result.removeLast() }
        return result
    }

    private static func isSafeExactBrowserHost(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("*")
    }

    private static func isSafeBrowserHostDeclaration(_ rawValue: String) -> Bool {
        let value = normalizedHost(rawValue)
        guard !value.isEmpty else { return false }
        if value.hasPrefix("*.") {
            let suffix = String(value.dropFirst(2))
            return !suffix.isEmpty &&
                !suffix.contains("*") &&
                !ExtensionHTTPStateCookie.isPublicSuffixDomain(suffix)
        }
        return !value.contains("*")
    }
}

public struct ExtensionBrowserSessionProfile: Codable, Hashable, Sendable {
    static let secureStateKey = "browser_session_profile"

    public var canonicalHTTPSOrigin: URL
    public var userAgent: String
    public var updatedAt: Date

    public init(
        canonicalHTTPSOrigin: URL,
        userAgent: String,
        updatedAt: Date = .now
    ) {
        self.canonicalHTTPSOrigin = canonicalHTTPSOrigin
        self.userAgent = userAgent
        self.updatedAt = updatedAt
    }

    public static func canonicalHTTPSOrigin(for url: URL) -> URL? {
        guard let input = URLComponents(url: url, resolvingAgainstBaseURL: false),
              input.scheme?.lowercased() == "https",
              input.user == nil,
              input.password == nil,
              let inputHost = input.host?.lowercased(),
              !inputHost.isEmpty
        else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = inputHost
        if input.port != 443 { components.port = input.port }
        components.path = ""
        return components.url
    }

    public static func websiteDataStoreIdentifier(for namespace: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("manko.WebKit.\(namespace)".utf8)).prefix(16))
        // Mark this as a deterministic, name-derived UUID while retaining the
        // SHA-256 entropy used to isolate source namespaces.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    func isValid() -> Bool {
        Self.canonicalHTTPSOrigin(for: canonicalHTTPSOrigin) == canonicalHTTPSOrigin
            && Self.hasValidUserAgent(userAgent)
    }

    func matchesOrigin(of url: URL) -> Bool {
        Self.canonicalHTTPSOrigin(for: url) == canonicalHTTPSOrigin
    }

    static func hasValidUserAgent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= 2_048
            && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}

public struct ExtensionBrowserSessionSeed: Codable, Hashable, Sendable {
    public var profile: ExtensionBrowserSessionProfile?
    public var cookies: [ExtensionHTTPStateCookie]

    public init(
        profile: ExtensionBrowserSessionProfile? = nil,
        cookies: [ExtensionHTTPStateCookie] = []
    ) {
        self.profile = profile
        self.cookies = cookies
    }
}

public enum ExtensionBrowserSessionError: Error, Equatable, Sendable, LocalizedError {
    case invalidHTTPSOrigin
    case invalidUserAgent
    case missingClearanceCookie

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPSOrigin:
            "Cloudflare verification requires a valid HTTPS source origin."
        case .invalidUserAgent:
            "WebKit did not provide a valid browser identity for this verification."
        case .missingClearanceCookie:
            "Cloudflare verification did not issue an applicable clearance cookie."
        }
    }
}
