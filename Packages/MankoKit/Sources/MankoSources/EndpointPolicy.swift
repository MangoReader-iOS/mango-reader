import Foundation

/// The per-source transport decision applied before URLSession and ATS.
/// Default first-party requests accept plain HTTP only for a user-confirmed
/// local endpoint. Downloaded extensions can instead defer HTTP transport
/// acceptance to the system while retaining syntax and credential checks.
public struct EndpointAccess: Codable, Hashable, Sendable {
    public var allowsUserConfirmedLANHTTP: Bool
    /// Defers HTTP transport acceptance to URLSession and App Transport
    /// Security. Downloaded extensions use this because they are no longer
    /// constrained by per-source destination declarations.
    public var allowsSystemPermittedHTTP: Bool

    public init(
        allowsUserConfirmedLANHTTP: Bool = false,
        allowsSystemPermittedHTTP: Bool = false
    ) {
        self.allowsUserConfirmedLANHTTP = allowsUserConfirmedLANHTTP
        self.allowsSystemPermittedHTTP = allowsSystemPermittedHTTP
    }

    private enum CodingKeys: String, CodingKey {
        case allowsUserConfirmedLANHTTP, allowsSystemPermittedHTTP
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        allowsUserConfirmedLANHTTP = try values.decodeIfPresent(
            Bool.self,
            forKey: .allowsUserConfirmedLANHTTP
        ) ?? false
        allowsSystemPermittedHTTP = try values.decodeIfPresent(
            Bool.self,
            forKey: .allowsSystemPermittedHTTP
        ) ?? false
    }
}

/// Matches an HTTPS host against exact declarations and explicit `*.`
/// subdomain declarations. A wildcard never matches its apex or a lookalike
/// suffix, so `*.example.com` permits `cdn.example.com` but not `example.com`
/// or `notexample.com`.
public enum HTTPSHostAccess {
    public static func allows(_ host: String, declarations: Set<String>) -> Bool {
        let host = normalized(host)
        guard !host.isEmpty else { return false }
        return declarations.contains { declaration in
            let declaration = normalized(declaration)
            if declaration.hasPrefix("*.") {
                let suffix = String(declaration.dropFirst(2))
                return !suffix.isEmpty && host.hasSuffix(".\(suffix)")
            }
            return host == declaration
        }
    }

    private static func normalized(_ value: String) -> String {
        var value = value
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while value.hasSuffix(".") {
            value.removeLast()
        }
        return value
    }
}

public struct EndpointPolicy: Sendable {
    public init() {}

    public func validate(_ url: URL, access: EndpointAccess = EndpointAccess()) throws {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            !host.isEmpty
        else {
            throw HTTPClientError.invalidURL
        }
        guard components.user == nil, components.password == nil else {
            throw HTTPClientError.invalidURL
        }

        if scheme == "https" {
            return
        }

        guard scheme == "http" else {
            throw HTTPClientError.unsupportedScheme(scheme)
        }

        if access.allowsSystemPermittedHTTP {
            return
        }

        guard access.allowsUserConfirmedLANHTTP, Self.isLocalNetworkHost(host) else {
            throw HTTPClientError.insecurePublicEndpoint
        }
    }

    public static func isLocalNetworkHost(_ host: String) -> Bool {
        let host = host
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".home.arpa") {
            return true
        }

        // A single-label hostname can only be trusted after the explicit LAN
        // confirmation represented by EndpointAccess.
        if !host.contains(".") && !host.contains(":") {
            return true
        }

        if let octets = ipv4Octets(host) {
            switch (octets[0], octets[1]) {
            case (10, _), (127, _), (169, 254), (192, 168):
                return true
            case (172, 16 ... 31):
                return true
            default:
                return false
            }
        }

        if host == "::1" {
            return true
        }

        // fc00::/7 (unique local) and fe80::/10 (link local).
        if host.hasPrefix("fc") || host.hasPrefix("fd") {
            return true
        }
        if let firstGroup = host.split(separator: ":").first,
           let value = UInt16(firstGroup, radix: 16),
           (0xFE80 ... 0xFEBF).contains(value) {
            return true
        }

        return false
    }

    private static func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }

        var result: [UInt8] = []
        result.reserveCapacity(4)
        for part in parts {
            guard
                !part.isEmpty,
                part.allSatisfy(\.isNumber),
                let value = UInt8(part)
            else {
                return nil
            }
            result.append(value)
        }
        return result
    }
}
