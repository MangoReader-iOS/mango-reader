import Foundation
import MankoSources

public enum RepositoryDeepLinkAction: Equatable, Sendable {
    case add(repositoryURL: URL)
    case install(repositoryURL: URL, sourceIDs: [String])
}

public enum RepositoryDeepLinkError: Error, Equatable, Sendable, LocalizedError {
    case tooLarge
    case unsupported
    case missingRepositoryURL
    case invalidRepositoryURL
    case missingSources
    case tooManySources
    case duplicateSource(String)
    case invalidSourceID

    public var errorDescription: String? {
        switch self {
        case .tooLarge: "This Manko link is larger than 8 KiB."
        case .unsupported: "This is not a supported Manko repository link."
        case .missingRepositoryURL: "The repository link does not include a repository URL."
        case .invalidRepositoryURL: "The repository URL must be a public HTTPS address without embedded credentials."
        case .missingSources: "The install link does not select any extensions."
        case .tooManySources: "A link can select at most 100 extensions."
        case let .duplicateSource(sourceID): "The extension “\(sourceID)” is selected more than once."
        case .invalidSourceID: "A selected extension identifier is invalid."
        }
    }
}

public struct RepositoryDeepLinkParser: Sendable {
    public init() {}

    /// Pasted addresses and website handoffs share the same URL and selection policy.
    public func parseInput(_ input: String) throws -> RepositoryDeepLinkAction {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= SourceRepositoryLimits.deepLinkBytes else {
            throw RepositoryDeepLinkError.tooLarge
        }
        guard !value.isEmpty, let url = URL(string: value) else {
            throw RepositoryDeepLinkError.invalidRepositoryURL
        }
        if url.scheme?.lowercased() == "manko" { return try parse(url) }
        return .add(repositoryURL: try RepositoryURLPolicy.repositoryRoot(for: url))
    }

    public func parse(_ url: URL) throws -> RepositoryDeepLinkAction {
        guard url.absoluteString.lengthOfBytes(using: .utf8) <= SourceRepositoryLimits.deepLinkBytes else {
            throw RepositoryDeepLinkError.tooLarge
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw RepositoryDeepLinkError.unsupported
        }

        let actionName: String
        switch components.scheme?.lowercased() {
        case "manko":
            guard components.host?.lowercased() == "repository",
                  components.user == nil, components.password == nil, components.port == nil,
                  components.path.split(separator: "/").count == 1 else {
                throw RepositoryDeepLinkError.unsupported
            }
            actionName = components.path.split(separator: "/").first.map(String.init) ?? ""
        default:
            throw RepositoryDeepLinkError.unsupported
        }

        let queryItems = components.queryItems ?? []
        guard queryItems.filter({ $0.name == "url" }).count == 1,
              let rawRepositoryURL = queryItems.first(where: { $0.name == "url" })?.value else {
            throw RepositoryDeepLinkError.missingRepositoryURL
        }
        guard let repositoryURL = URL(string: rawRepositoryURL) else {
            throw RepositoryDeepLinkError.invalidRepositoryURL
        }
        do {
            try RepositoryURLPolicy.validatePublicHTTPS(repositoryURL)
        } catch {
            throw RepositoryDeepLinkError.invalidRepositoryURL
        }

        switch actionName {
        case "add":
            return .add(repositoryURL: repositoryURL)
        case "install":
            let sourceIDs = queryItems.filter { $0.name == "source" }.compactMap(\.value)
            guard !sourceIDs.isEmpty else { throw RepositoryDeepLinkError.missingSources }
            guard sourceIDs.count <= SourceRepositoryLimits.selectedEntries else {
                throw RepositoryDeepLinkError.tooManySources
            }
            var seen: Set<String> = []
            for sourceID in sourceIDs {
                guard RepositoryURLPolicy.isSafeIdentifier(sourceID) else {
                    throw RepositoryDeepLinkError.invalidSourceID
                }
                guard seen.insert(sourceID).inserted else {
                    throw RepositoryDeepLinkError.duplicateSource(sourceID)
                }
            }
            return .install(repositoryURL: repositoryURL, sourceIDs: sourceIDs)
        default:
            throw RepositoryDeepLinkError.unsupported
        }
    }
}

public enum RepositoryURLPolicy {
    public static func validatePublicHTTPS(_ url: URL) throws {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "https",
            let host = components.host?.lowercased(),
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            !host.hasSuffix(".local"),
            !host.hasSuffix(".localhost"),
            host != "localhost",
            !MankoSources.EndpointPolicy.isLocalNetworkHost(host)
        else {
            throw RepositoryDeepLinkError.invalidRepositoryURL
        }
    }

    public static func resolvedURL(_ value: String, relativeTo baseURL: URL) throws -> URL {
        guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL else {
            throw RepositoryDeepLinkError.invalidRepositoryURL
        }
        try validatePublicHTTPS(url)
        return url
    }

    public static func repositoryRoot(for input: URL) throws -> URL {
        try validatePublicHTTPS(input)
        var components = URLComponents(url: input, resolvingAgainstBaseURL: false)!
        components.query = nil
        components.fragment = nil
        var root = components.url!
        if input.lastPathComponent.lowercased() == "versioning.json" {
            root.deleteLastPathComponent()
        }
        if !root.hasDirectoryPath {
            root.appendPathComponent("")
        }
        return root
    }

    public static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}
