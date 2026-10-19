import Foundation
import SwiftPublicSuffixList

/// A native-owned destination policy. Empty host sets deny all network access.
public struct ExtensionNetworkPolicy: Codable, Hashable, Sendable {
    public var hosts: Set<String>
    public var serverOrigin: URL?
    public init(hosts: Set<String>, serverOrigin: URL? = nil) {
        self.hosts = hosts
        self.serverOrigin = serverOrigin
    }

    public static func validHost(_ host: String) -> Bool {
        if host.hasPrefix("*.") {
            let base = String(host.dropFirst(2))
            return validHost(base) && PublicSuffixList.isUnrestricted(PublicSuffixList.ace(base))
        }
        guard host == host.lowercased(), host.count <= 253, host.contains("."),
              !host.hasSuffix("."), !host.contains("*"), !host.contains(":"),
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              host != "localhost", !host.allSatisfy({ $0.isNumber || $0 == "." }) else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    public func allows(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased(), !host.hasSuffix(".") else { return false }
        if let serverOrigin, SourceRequestAuthorizer.isSameOrigin(url, as: serverOrigin) {
            return ["https", "http"].contains(url.scheme?.lowercased() ?? "")
        }
        return url.scheme?.lowercased() == "https" && (url.port == nil || url.port == 443)
            && Self.validHost(host) && hosts.contains { declaration in
                Self.validHost(declaration) && (declaration == host ||
                    (declaration.hasPrefix("*.") && host.hasSuffix(String(declaration.dropFirst(1)))))
            }
    }

    public func validate(_ url: URL) throws {
        guard allows(url) else { throw HTTPClientError.invalidURL }
    }
}

import WebKit

extension ExtensionNetworkPolicy {
    /// WebKit may bypass platform proxies for loopback destinations. Content
    /// rules independently fence subresources before transport selection.
    /// Navigation delegates must still validate top-level and frame URLs.
    @MainActor
    @discardableResult
    public func configureBrowser(_ configuration: WKWebViewConfiguration) async throws -> UUID {
        let encoded = try browserRules()
        let identifier = "manko-egress-" + ContentCache.key([encoded])
        let ruleList = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: encoded)
        guard let ruleList else { throw HTTPClientError.forbidden }
        configuration.userContentController.removeAllContentRuleLists()
        configuration.userContentController.add(ruleList)
        let lease = try await ExtensionNetworkSessions.shared.lease(for: self)
        try Task.checkCancellation()
        configuration.websiteDataStore.proxyConfigurations = [lease.configuration]
        return lease.generation
    }

    func browserRules() throws -> String {
        var rules: [[String: Any]] = [
            ["trigger": ["url-filter": "^https?://"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^wss?://"], "action": ["type": "block"]]
        ]
        for host in hosts.sorted() where Self.validHost(host) {
            let base = host.hasPrefix("*.") ? String(host.dropFirst(2)) : host
            let escaped = base.replacingOccurrences(of: ".", with: "\\.")
            let prefix = host.hasPrefix("*.") ? "([a-z0-9-]+\\.)+" : ""
            rules.append(["trigger": ["url-filter": "^https://" + prefix + escaped + "(:443)?/"],
                          "action": ["type": "ignore-previous-rules"]])
        }
        if let serverOrigin, let origin = URLComponents(url: serverOrigin, resolvingAgainstBaseURL: false),
           let scheme = origin.scheme, ["http", "https"].contains(scheme), let host = origin.host,
           origin.user == nil, origin.password == nil {
            let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            let escaped = NSRegularExpression.escapedPattern(for: authority)
            let defaultPort = scheme == "https" ? 443 : 80
            let port = origin.port.map { $0 == defaultPort ? "(:\(defaultPort))?" : ":\($0)" }
                ?? "(:\(defaultPort))?"
            rules.append(["trigger": ["url-filter": "^" + scheme + "://" + escaped + port + "/"],
                          "action": ["type": "ignore-previous-rules"]])
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]), as: UTF8.self)
    }
}
