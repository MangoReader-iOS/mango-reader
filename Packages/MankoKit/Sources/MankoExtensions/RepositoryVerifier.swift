import Foundation
import MankoSources

public enum RepositoryVerificationError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedSchema
    case tooLarge(String)
    case tooManyEntries
    case duplicateSourceID(String)
    case invalidIdentifier(String)
    case invalidEntry(String)
    case invalidURL(String)
    case invalidHash(String)
    case unsupportedAPI(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "The repository uses an unsupported manifest version."
        case let .tooLarge(resource): "The repository \(resource) exceeds Manko’s size limit."
        case .tooManyEntries: "A repository can contain at most 500 entries."
        case let .duplicateSourceID(sourceID): "The repository contains the duplicate extension ID “\(sourceID)”."
        case let .invalidIdentifier(identifier): "The repository identifier “\(identifier)” is invalid."
        case let .invalidEntry(sourceID): "The extension “\(sourceID)” has an invalid entry payload."
        case let .invalidURL(value): "The repository contains an invalid or non-public HTTPS URL: \(value)"
        case let .invalidHash(sourceID): "The extension “\(sourceID)” has an invalid SHA-256 hash."
        case let .unsupportedAPI(version): "Manko Extension API \(version) is not supported."
        }
    }
}

public struct RepositoryVerifier: Sendable {
    public init() {}

    public func validateManifest(_ manifest: SourceRepositoryManifestV2, baseURL: URL) throws {
        guard manifest.schemaVersion == 3 else { throw RepositoryVerificationError.unsupportedSchema }
        guard manifest.sources.count <= SourceRepositoryLimits.maximumEntries else {
            throw RepositoryVerificationError.tooManyEntries
        }
        guard RepositoryURLPolicy.isSafeIdentifier(manifest.repository.id) else {
            throw RepositoryVerificationError.invalidIdentifier(manifest.repository.id)
        }
        var sourceIDs: Set<String> = []
        for entry in manifest.sources {
            guard RepositoryURLPolicy.isSafeIdentifier(entry.id) else {
                throw RepositoryVerificationError.invalidIdentifier(entry.id)
            }
            guard sourceIDs.insert(entry.id).inserted else {
                throw RepositoryVerificationError.duplicateSourceID(entry.id)
            }
            guard !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !entry.version.isEmpty
            else { throw RepositoryVerificationError.invalidEntry(entry.id) }

            if !entry.icon.isEmpty { try validateURL(entry.icon, baseURL: baseURL) }
            if let universalLink = entry.universalLink { try validateURL(universalLink, baseURL: baseURL) }

            switch entry.entryType {
            case .connectorPreset:
                throw RepositoryVerificationError.invalidEntry(entry.id)

            case .mankoExtension:
                guard let payload = entry.mankoExtension,
                      entry.connectorPreset == nil,
                      entry.kind != nil,
                      MankoExtensionPayload.supportedAPIVersions.contains(payload.apiVersion)
                else {
                    if let version = entry.mankoExtension?.apiVersion,
                       !MankoExtensionPayload.supportedAPIVersions.contains(version) {
                        throw RepositoryVerificationError.unsupportedAPI(version)
                    }
                    throw RepositoryVerificationError.invalidEntry(entry.id)
                }
                if let connectorKind = payload.connectorKind {
                    guard [.opds, .komga, .kavita, .suwayomi].contains(connectorKind), entry.kind == .content else {
                        throw RepositoryVerificationError.invalidEntry(entry.id)
                    }
                }
                if payload.isExecutable {
                    guard payload.allowedHTTPSHosts.count <= 128,
                          payload.allowedHTTPSHosts.allSatisfy(ExtensionNetworkPolicy.validHost),
                          payload.connectorKind != nil || !payload.allowedHTTPSHosts.isEmpty
                    else { throw ExtensionSecurityError.invalidPolicy }
                    try payload.accountPolicy?.validate(hosts: Set(payload.allowedHTTPSHosts))
                    if entry.kind == .tracker, payload.accountPolicy == nil { throw ExtensionSecurityError.invalidPolicy }
                }
                try validateURL(payload.artifactURL, baseURL: baseURL)
                guard (1 ... SourceRepositoryLimits.scriptBytes).contains(payload.size) else {
                    throw RepositoryVerificationError.invalidEntry(entry.id)
                }
                guard payload.sha256.count == 64,
                      payload.sha256.unicodeScalars.allSatisfy({
                          CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
                      })
                else { throw RepositoryVerificationError.invalidHash(entry.id) }
            }
        }
    }

    public func isExecutable(entry: SourceRepositoryEntryV2, in record: RepositoryRecord) -> Bool {
        entry.entryType == .mankoExtension
            && entry.availability == .available
            && entry.mankoExtension?.isExecutable == true
    }

    private func validateURL(_ value: String, baseURL: URL) throws {
        do { _ = try RepositoryURLPolicy.resolvedURL(value, relativeTo: baseURL) }
        catch { throw RepositoryVerificationError.invalidURL(value) }
    }

}
