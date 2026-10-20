import Foundation
import MangoReaderDomain
import MangoReaderSources

public enum RepositoryClientError: Error, Equatable, Sendable, LocalizedError {
    case connectionFailed(host: String, reason: String)
    case missingManifest
    case invalidManifest(String)
    case responseTooLarge(String)

    public var errorDescription: String? {
        switch self {
        case let .connectionFailed(host, reason): "Couldn’t load the repository at \(host). \(reason) Check your connection and try again."
        case .missingManifest: "No versioning.json was found."
        case let .invalidManifest(message): "The repository manifest is invalid: \(message)"
        case let .responseTooLarge(resource): "The repository \(resource) exceeds Mango Reader’s size limit."
        }
    }
}

public struct RepositoryIconContent: Hashable, Sendable {
    public var data: Data
    public var mediaType: String?

    public init(data: Data, mediaType: String?) {
        self.data = data
        self.mediaType = mediaType
    }
}

public actor SourceRepositoryClient {
    private let httpClient: HTTPClient
    private let verifier: RepositoryVerifier

    public init(
        httpClient: HTTPClient = HTTPClient(),
        verifier: RepositoryVerifier = RepositoryVerifier()
    ) {
        self.httpClient = httpClient
        self.verifier = verifier
    }

    public func fetchRepository(at inputURL: URL) async throws -> RepositoryRecord {
        let root = try RepositoryURLPolicy.repositoryRoot(for: inputURL)
        let manifestURL = root.appending(path: "versioning.json", directoryHint: .notDirectory)
        let response: HTTPResponse
        do {
            response = try await fetch(
                manifestURL,
                maximumBytes: SourceRepositoryLimits.manifestBytes,
                resource: "manifest"
            )
        } catch HTTPClientError.notFound {
            throw RepositoryClientError.missingManifest
        }

        let manifest: SourceRepositoryManifestV2
        do {
            manifest = try Self.decodeManifest(response.data)
            try verifier.validateManifest(manifest, baseURL: root)
        } catch {
            throw RepositoryClientError.invalidManifest(error.localizedDescription)
        }

        return RepositoryRecord(
            manifest: manifest,
            repositoryURL: root,
            manifestURL: response.url,
            isBlocked: false
        )
    }

    public func fetchIcon(for entry: SourceRepositoryEntryV2, in record: RepositoryRecord) async throws -> Data {
        try await fetchIconContent(for: entry, in: record).data
    }

    public func fetchIconContent(
        for entry: SourceRepositoryEntryV2,
        in record: RepositoryRecord
    ) async throws -> RepositoryIconContent {
        let url = try RepositoryURLPolicy.resolvedURL(entry.icon, relativeTo: record.repositoryURL)
        guard SourceRequestAuthorizer.isSameOrigin(url, as: record.repositoryURL) else { throw ExtensionSecurityError.denied(url.host ?? "unknown") }
        let response = try await fetch(url, maximumBytes: SourceRepositoryLimits.iconBytes, resource: "icon")
        let mediaType = response.header("Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return RepositoryIconContent(data: response.data, mediaType: mediaType)
    }

    public func fetchScript(for entry: SourceRepositoryEntryV2, in record: RepositoryRecord) async throws -> Data {
        guard let payload = entry.mangoReaderExtension else {
            throw RepositoryVerificationError.invalidEntry(entry.id)
        }
        guard payload.isExecutable else { throw RepositoryVerificationError.unsupportedAPI(payload.apiVersion) }
        let url = try RepositoryURLPolicy.resolvedURL(payload.artifactURL, relativeTo: record.repositoryURL)
        guard SourceRequestAuthorizer.isSameOrigin(url, as: record.repositoryURL) else { throw ExtensionSecurityError.denied(url.host ?? "unknown") }
        return try await fetch(
            url,
            maximumBytes: min(SourceRepositoryLimits.scriptBytes, payload.size),
            resource: "script"
        ).data
    }

    public nonisolated static func decodeManifest(_ data: Data) throws -> SourceRepositoryManifestV2 {
        try JSONDecoder().decode(SourceRepositoryManifestV2.self, from: data)
    }

    private func fetch(_ url: URL, maximumBytes: Int, resource: String) async throws -> HTTPResponse {
        try RepositoryURLPolicy.validatePublicHTTPS(url)
        let response: HTTPResponse
        do {
            response = try await httpClient.response(
            for: HTTPRequest(url: url, allowedHTTPSHosts: Set([url.host!.lowercased()]), usesConditionalCache: false,
            networkPolicy: ExtensionNetworkPolicy(hosts: Set([url.host?.lowercased() ?? ""])),
            maximumResponseBytes: maximumBytes)
        )
        } catch HTTPClientError.cancelled {
            throw CancellationError()
        } catch let HTTPClientError.transport(_, description) {
            if Task.isCancelled { throw CancellationError() }
            throw RepositoryClientError.connectionFailed(host: url.host ?? "repository", reason: description)
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw RepositoryClientError.connectionFailed(host: url.host ?? "repository", reason: error.localizedDescription)
        }
        try RepositoryURLPolicy.validatePublicHTTPS(response.url)
        guard response.data.count <= maximumBytes else {
            throw RepositoryClientError.responseTooLarge(resource)
        }
        return response
    }
}
