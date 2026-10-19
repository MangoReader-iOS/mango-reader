import CryptoKit
import Foundation
import MankoDomain
import MankoSources

public enum ExtensionSecurityError: Error, Equatable, Sendable, LocalizedError {
    case approvalRequired, invalidPolicy, repositoryAddressChanged, artifactChanged, incompatible
    case denied(String)

    public var errorDescription: String? {
        switch self {
        case .approvalRequired: "Review and approve this extension’s website access before installing it."
        case .invalidPolicy: "The extension’s website or account permissions are invalid."
        case .repositoryAddressChanged: "The repository’s address changed. Remove and explicitly add the repository again to approve a different address."
        case .artifactChanged: "The repository tried to replace an already published extension version."
        case .incompatible: "An API 3.0 update and access review are required. Your library and downloads are preserved."
        case let .denied(host): "This extension tried to contact \(host), which you haven’t approved."
        }
    }
}

/// The user-reviewed account surface. Secrets are owned by the host.
public struct ExtensionAccountPolicy: Codable, Hashable, Sendable {
    public var authentication: TrackerAuthenticationDescriptor
    public var requests: [Rule]
    public struct Rule: Codable, Hashable, Sendable {
        public var origin: String
        public var pathPrefix: String
        public var methods: Set<String>
        public var operations: Set<String>
        public var bodyKind: String? = nil
    }

    public func permits(_ url: URL, method: String, operation: String, body: Data? = nil) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              let decodedPath = components.percentEncodedPath.removingPercentEncoding,
              Self.isUnambiguousPath(decodedPath) else { return false }
        let path = decodedPath.isEmpty ? "/" : decodedPath
        return requests.contains { rule in
            guard let origin = URL(string: rule.origin), SourceRequestAuthorizer.isSameOrigin(url, as: origin),
                  ["GET", "HEAD"].contains(method) || rule.bodyKind == "graphqlQuery" || operation == "update"
            else { return false }
            if let bodyKind = rule.bodyKind {
                guard let body, body.count <= 256 * 1024,
                      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      Set(object.keys).isSubset(of: ["query", "variables", "operationName"]),
                      let query = object["query"] as? String else { return false }
                let document = query.replacingOccurrences(of: "#[^\\n\\r]*", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if bodyKind == "graphqlQuery" {
                    guard !document.contains("mutation"), !document.contains("subscription"),
                          document.hasPrefix("{") || document.hasPrefix("query") else { return false }
                } else if bodyKind == "graphqlMutation" {
                    guard document.hasPrefix("mutation") else { return false }
                } else { return false }
            }
            let prefix = rule.pathPrefix
            return (path == prefix || (prefix.hasSuffix("/") && path.hasPrefix(prefix)))
                && rule.methods.contains(method) && rule.operations.contains(operation)
        }
    }

    private static func isUnambiguousPath(_ path: String) -> Bool {
        // Different servers normalize escaped separators, dot segments and
        // repeated percent encoding differently. Never send a token with a
        // path that could escape its approved prefix after normalization.
        !path.contains("%") && !path.contains("\\") && !path.contains(";")
            && !path.utf8.contains { $0 < 0x20 || $0 == 0x7f }
            && !path.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }

    public func validate(hosts: Set<String>) throws {
        guard [.oauth2Implicit, .oauth2PKCE].contains(authentication.mode),
              let authorizationURL = authentication.authorizationURL,
              ExtensionNetworkPolicy(hosts: hosts).allows(authorizationURL),
              authorizationURL.query == nil, authorizationURL.fragment == nil,
              let callback = authentication.callbackURL, callback.scheme == "manko", callback.host == "oauth",
              callback.user == nil, callback.password == nil, callback.query == nil, callback.fragment == nil,
              authentication.callbackScheme == "manko", !requests.isEmpty, requests.count <= 32
        else { throw ExtensionSecurityError.invalidPolicy }
        if authentication.mode == .oauth2PKCE {
            guard let tokenURL = authentication.tokenURL, ExtensionNetworkPolicy(hosts: hosts).allows(tokenURL),
                  tokenURL.query == nil, tokenURL.fragment == nil else { throw ExtensionSecurityError.invalidPolicy }
        }
        for rule in requests {
            guard rule.methods.isSubset(of: ["GET", "HEAD"]) || rule.bodyKind == "graphqlQuery" || rule.operations == ["update"],
                  rule.bodyKind == nil || ["graphqlQuery", "graphqlMutation"].contains(rule.bodyKind!),
                  rule.bodyKind == nil || rule.methods == ["POST"],
                  rule.bodyKind != "graphqlMutation" || rule.operations == ["update"],
                  let url = URL(string: rule.origin), ExtensionNetworkPolicy(hosts: hosts).allows(url),
                  url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil,
                  rule.pathPrefix.hasPrefix("/"), Self.isUnambiguousPath(rule.pathPrefix),
                  !rule.methods.isEmpty, rule.methods.isSubset(of: ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]),
                  !rule.operations.isEmpty, rule.operations.isSubset(of: ["trackerSearch", "progress", "progressBatch", "update", "collections"])
            else { throw ExtensionSecurityError.invalidPolicy }
        }
    }
}

public struct ExtensionAccessGrant: Codable, Hashable, Sendable {
    public let repositoryID: String
    public let sourceID: String
    // Missing in old saved approvals; those installations require a fresh review.
    public let repositoryURL: URL?
    public let artifactHash: String
    public let policyDigest: String
    public let generation: UUID

    public init(entry: SourceRepositoryEntry, record: RepositoryRecord) throws {
        guard entry.mankoExtension?.isExecutable == true,
              record.manifest.sources.contains(entry) else { throw ExtensionSecurityError.incompatible }
        repositoryID = record.id
        sourceID = entry.id
        repositoryURL = try RepositoryURLPolicy.repositoryRoot(for: record.repositoryURL)
        artifactHash = entry.mankoExtension!.sha256.lowercased()
        policyDigest = try Self.digest(entry)
        generation = UUID()
    }

    public func matches(_ entry: SourceRepositoryEntry, record: RepositoryRecord) -> Bool {
        record.manifest.sources.contains(entry)
            && repositoryID == record.id && sourceID == entry.id && repositoryURL == record.repositoryURL
            && artifactHash == entry.mankoExtension?.sha256.lowercased() && policyDigest == (try? Self.digest(entry))
    }

    public static func digest(_ entry: SourceRepositoryEntry) throws -> String {
        // Arrays are sorted explicitly because Set's Codable order is unspecified.
        let object: [String: Any] = [
            "hosts": (entry.mankoExtension?.allowedHTTPSHosts ?? []).sorted(),
            "permissions": entry.permissions.values.map(\.rawValue).sorted(),
            "capabilities": entry.capabilities.map(\.rawValue).sorted(),
            "authenticationModes": (entry.mankoExtension?.authenticationModes ?? []).map(\.rawValue).sorted(),
            "account": try entry.mankoExtension?.accountPolicy.map { policy in
                let data = try JSONEncoder().encode(policy)
                var value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                value["requests"] = policy.requests.map { ["origin": $0.origin, "pathPrefix": $0.pathPrefix,
                    "methods": $0.methods.sorted(), "operations": $0.operations.sorted(), "bodyKind": $0.bodyKind ?? ""] as [String: Any] }
                return value
            } ?? [:],
            "connector": entry.mankoExtension?.connectorKind?.rawValue ?? ""
        ]
        return SHA256.hash(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            .map { String(format: "%02x", $0) }.joined()
    }
}

