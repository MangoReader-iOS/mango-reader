import Foundation
import MankoDomain

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Everything needed to restart an acquisition without asking the source for
/// its publication link again.
public struct DownloadTransfer: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var workID: WorkID
    public var installmentID: InstallmentID
    public var remoteURL: URL
    public var suggestedFilename: String
    /// The publication format expected after this transfer completes. A
    /// remote image sequence can materialize as a validated CBZ.
    public var expectedFormat: PublicationFormat?
    /// Ephemeral non-persistent headers. Secrets are rebuilt from Keychain.
    public var headers: [String: String]
    /// Ephemeral provenance for credential headers rebuilt from Keychain.
    /// Names are non-secret and copied into the background task description;
    /// values remain memory-only.
    var credentialHeaderNames: Set<String>
    /// Non-secret source identity used to rebuild a browser-verified session
    /// from secure extension state whenever this durable transfer starts.
    public var verificationReference: DownloadVerificationReference?
    /// Ephemeral WebKit identity. This is rebuilt from secure state and never
    /// encoded into the durable queue or URLSession task description.
    var redirectIdentity: HTTPRedirectIdentity?
    /// A non-secret Keychain account identifier used to rebuild auth headers.
    public var credentialAccount: String?
    /// The source origin that is allowed to receive the rebuilt credential.
    ///
    /// This is intentionally persisted while credential headers are not.
    public var credentialOrigin: URL?
    public var endpointAccess: EndpointAccess
    public var priority: Int

    public init(
        id: UUID = UUID(),
        workID: WorkID,
        installmentID: InstallmentID,
        remoteURL: URL,
        suggestedFilename: String? = nil,
        expectedFormat: PublicationFormat? = nil,
        headers: [String: String] = [:],
        verificationReference: DownloadVerificationReference? = nil,
        credentialAccount: String? = nil,
        credentialOrigin: URL? = nil,
        endpointAccess: EndpointAccess = EndpointAccess(),
        priority: Int = 0
    ) {
        self.id = id
        self.workID = workID
        self.installmentID = installmentID
        self.remoteURL = remoteURL
        self.suggestedFilename = suggestedFilename ?? remoteURL.lastPathComponent
        self.expectedFormat = expectedFormat
        self.headers = headers
        self.credentialHeaderNames = []
        self.verificationReference = verificationReference
        self.redirectIdentity = nil
        self.credentialAccount = credentialAccount
        self.credentialOrigin = credentialOrigin
        self.endpointAccess = endpointAccess
        self.priority = priority
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case workID
        case installmentID
        case remoteURL
        case suggestedFilename
        case expectedFormat
        case verificationReference
        case credentialAccount
        case credentialOrigin
        case endpointAccess
        case priority
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        workID = try container.decode(WorkID.self, forKey: .workID)
        installmentID = try container.decode(InstallmentID.self, forKey: .installmentID)
        remoteURL = try container.decode(URL.self, forKey: .remoteURL)
        suggestedFilename = try container.decode(String.self, forKey: .suggestedFilename)
        expectedFormat = try container.decode(PublicationFormat?.self, forKey: .expectedFormat)
        verificationReference = try container.decodeIfPresent(
            DownloadVerificationReference.self,
            forKey: .verificationReference
        )
        credentialAccount = try container.decode(String?.self, forKey: .credentialAccount)
        credentialOrigin = try container.decode(URL?.self, forKey: .credentialOrigin)
        endpointAccess = try container.decode(EndpointAccess.self, forKey: .endpointAccess)
        priority = try container.decode(Int.self, forKey: .priority)
        headers = [:]
        credentialHeaderNames = []
        redirectIdentity = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(workID, forKey: .workID)
        try container.encode(installmentID, forKey: .installmentID)
        try container.encode(remoteURL, forKey: .remoteURL)
        try container.encode(suggestedFilename, forKey: .suggestedFilename)
        try container.encode(expectedFormat, forKey: .expectedFormat)
        try container.encodeIfPresent(verificationReference, forKey: .verificationReference)
        try container.encode(credentialAccount, forKey: .credentialAccount)
        try container.encode(credentialOrigin, forKey: .credentialOrigin)
        try container.encode(endpointAccess, forKey: .endpointAccess)
        try container.encode(priority, forKey: .priority)
    }
}

/// Durable, non-secret provenance for an extension-backed download. Cookie
/// values and the browser user agent remain in secure extension storage.
public struct DownloadVerificationReference: Codable, Hashable, Sendable {
    public var namespace: String
    public var permittedBrowserHosts: Set<String>
    public var serverOrigin: URL?
    public var accessGeneration: UUID?

    public init(namespace: String, permittedBrowserHosts: Set<String>, serverOrigin: URL? = nil, accessGeneration: UUID? = nil) {
        self.namespace = namespace
        self.serverOrigin = serverOrigin
        self.accessGeneration = accessGeneration
        self.permittedBrowserHosts = Set(permittedBrowserHosts.map(Self.normalizedHost))
    }

    public var isValid: Bool {
        guard !namespace.isEmpty, namespace.utf8.count <= 128 else { return false }
        let identifierCharacters = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_."))
        guard namespace.unicodeScalars.allSatisfy(identifierCharacters.contains),
              permittedBrowserHosts.count <= 128
        else { return false }
        return permittedBrowserHosts.allSatisfy(Self.isValidHostDeclaration)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            namespace: try values.decode(String.self, forKey: .namespace),
            permittedBrowserHosts: try values.decode(
                Set<String>.self,
                forKey: .permittedBrowserHosts
            ),
            serverOrigin: try values.decodeIfPresent(URL.self, forKey: .serverOrigin),
            accessGeneration: try values.decodeIfPresent(UUID.self, forKey: .accessGeneration)
        )
        guard isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .namespace,
                in: values,
                debugDescription: "Invalid extension download verification provenance."
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case namespace, permittedBrowserHosts, serverOrigin, accessGeneration
    }

    private static func normalizedHost(_ rawValue: String) -> String {
        var value = rawValue
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    private static func isValidHostDeclaration(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253 else { return false }
        let candidate: String
        if value.hasPrefix("*.") {
            candidate = String(value.dropFirst(2))
            guard !candidate.isEmpty, !candidate.contains("*") else { return false }
        } else {
            candidate = value
            guard !candidate.contains("*") else { return false }
        }
        guard !candidate.contains(where: { $0.isWhitespace }),
              !candidate.contains("/"),
              !candidate.contains("@"),
              !candidate.contains("?")
        else { return false }
        var components = URLComponents()
        components.scheme = "https"
        components.host = candidate
        return components.url?.host?.lowercased() == candidate
    }

    func authorizes(_ identity: HTTPRedirectIdentity) -> Bool {
        guard isValid,
              DownloadCredentialPolicy.origin(for: identity.origin)?.scheme == "https",
              let identityHost = identity.origin.host?.lowercased()
        else { return false }
        return HTTPSHostAccess.allows(
                identityHost,
                declarations: permittedBrowserHosts
            )
    }
}

/// Loads an exact-origin browser identity from secure storage immediately
/// before a transfer starts. Returning `nil` starts anonymously.
public typealias DownloadRedirectIdentityLoader = @Sendable (
    _ reference: DownloadVerificationReference,
    _ requestURL: URL
) async throws -> HTTPRedirectIdentity?

/// Centralizes the origin boundary for source credentials. A false negative
/// merely causes an unauthenticated request; a false positive could disclose a
/// password or token, so malformed and unfamiliar origins never compare equal.
enum DownloadCredentialPolicy {
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

        let defaultPort = scheme == "https" ? 443 : 80
        return Origin(
            scheme: scheme,
            host: host,
            effectivePort: components.port ?? defaultPort
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

    static func credentialHeaderNames(for credential: SourceCredential) -> Set<String> {
        switch credential {
        case .basic, .bearer:
            ["Authorization"]
        case let .apiKey(name, _):
            [name]
        }
    }

    /// Returns a redirect request with credentials retained only while the
    /// redirect remains on both the current and configured credential origins.
    /// Current tasks may follow CDN redirects after exact credential scrubbing;
    /// legacy credential-bearing tasks stop because their exact headers are
    /// unknowable after an upgrade.
    static func requestForFollowing(
        _ request: URLRequest,
        from source: URL?,
        credentialOrigin: URL?,
        credentialHeaderNames: Set<String>?
    ) -> URLRequest? {
        guard let destination = request.url else { return nil }

        let source = source ?? credentialOrigin
        let staysOnCurrentOrigin = source.map { isSameOrigin(destination, as: $0) } ?? false
        let staysOnCredentialOrigin = credentialOrigin.map {
            isSameOrigin(destination, as: $0)
        } ?? true
        guard staysOnCurrentOrigin, staysOnCredentialOrigin else {
            // A v1 background task can prove where its credential belongs but
            // cannot prove which header carried it. Following a cross-origin
            // redirect could therefore leak an API key hidden in a normally
            // preserved header such as Accept or User-Agent.
            guard credentialOrigin == nil || credentialHeaderNames != nil else {
                return nil
            }

            var sanitized = request.removingRedirectCredentials()
            let normalizedCredentialNames = Set(
                (credentialHeaderNames ?? []).map { $0.lowercased() }
            )
            for name in sanitized.allHTTPHeaderFields?.keys ?? Dictionary<String, String>().keys
            where normalizedCredentialNames.contains(name.lowercased()) {
                sanitized.setValue(nil, forHTTPHeaderField: name)
            }
            return sanitized
        }
        return request
    }
}

public enum DownloadCoordinatorError: Error, Codable, Hashable, Sendable, LocalizedError {
    case unknownDownload(UUID)
    case duplicateDownload(UUID)
    case invalidMove(String)
    case invalidURL
    case insecureEndpoint
    case unsupportedScheme(String)
    case invalidState(expected: String, actual: DownloadState)
    case network(code: Int, description: String)
    case httpStatus(Int)
    case verificationRequired
    case invalidVerificationContext
    case chapterOwnershipMismatch
    case browserOnlyProtection
    case missingDownloadedFile
    case invalidPublication(String)
    case storage(String)
    case persistence(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .unknownDownload(id): "Download \(id.uuidString) does not exist."
        case let .duplicateDownload(id): "Download \(id.uuidString) already exists."
        case let .invalidMove(message): message
        case .invalidURL: "The download address is invalid."
        case .insecureEndpoint: "Public downloads must use HTTPS."
        case let .unsupportedScheme(scheme): "Downloads using \(scheme) are not supported."
        case let .invalidState(expected, actual): "This action requires \(expected), not \(actual.rawValue)."
        case let .network(_, description): description
        case let .httpStatus(status): "The download server returned HTTP \(status)."
        case .verificationRequired:
            "Source verification is required. Open Manko to verify this source before the download resumes."
        case .invalidVerificationContext:
            "The installed source no longer authorizes this download’s verification address. Remove and queue the download again."
        case .chapterOwnershipMismatch:
            "Chapter ownership could not be verified. Refresh the source and queue this chapter again. The original file is retained for recovery."
        case .browserOnlyProtection:
            "This download still requires browser-only protection after verification. Try another source; Manko won’t loop or automate around stronger protection."
        case .missingDownloadedFile: "The downloaded temporary file is missing."
        case let .invalidPublication(message): "The downloaded publication is invalid: \(message)"
        case let .storage(message): "The download could not be stored: \(message)"
        case let .persistence(message): "The download queue could not be saved: \(message)"
        case .cancelled: "The download was cancelled."
        }
    }
}

/// The durable representation of a queue item. Resume data is deliberately
/// stored separately because it can be large and is replaced frequently.
public struct DownloadSnapshot: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID { transfer.id }
    public var transfer: DownloadTransfer
    public var state: DownloadState
    public var completedBytes: Int64
    public var totalBytes: Int64?
    public var localRelativePath: String?
    public var lastError: DownloadCoordinatorError?
    /// The challenged response URL is non-secret and lets a foreground launch
    /// reconstruct a visible handoff even if the background event was already
    /// delivered before the app model started observing the queue.
    public var verificationURL: URL?
    /// Nil is the backwards-compatible representation of zero. The value is
    /// set to one before the verified retry starts, making the no-loop bound
    /// durable across process death.
    public var verificationRetryCount: Int?
    /// True only when the URL came from a definitive native transport
    /// response. This distinguishes legacy empty-host catalogs from arbitrary
    /// declared browser URLs.
    public var verificationWasTransportObserved: Bool?
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        transfer: DownloadTransfer,
        state: DownloadState = .queued,
        completedBytes: Int64 = 0,
        totalBytes: Int64? = nil,
        localRelativePath: String? = nil,
        lastError: DownloadCoordinatorError? = nil,
        verificationURL: URL? = nil,
        verificationRetryCount: Int? = nil,
        verificationWasTransportObserved: Bool? = nil,
        createdAt: Date = .now,
        modifiedAt: Date = .now
    ) {
        self.transfer = transfer
        self.state = state
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.localRelativePath = localRelativePath
        self.lastError = lastError
        self.verificationURL = verificationURL
        self.verificationRetryCount = verificationRetryCount
        self.verificationWasTransportObserved = verificationWasTransportObserved
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    public var domainJob: DownloadJob {
        DownloadJob(
            id: id,
            workID: transfer.workID,
            installmentID: transfer.installmentID,
            state: state,
            priority: transfer.priority,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            localRelativePath: localRelativePath,
            lastError: lastError?.localizedDescription,
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )
    }

    public var verificationRequirement: DownloadVerificationRequirement? {
        guard state == .paused,
              lastError == .verificationRequired,
              let verificationURL,
              let reference = transfer.verificationReference,
              reference.isValid,
              verificationWasTransportObserved == true,
              DownloadVerificationRequirement.sanitizedChallengeURL(verificationURL)
                == verificationURL
        else { return nil }
        return DownloadVerificationRequirement(
            transferID: id,
            url: verificationURL,
            namespace: reference.namespace,
            permittedBrowserHosts: reference.permittedBrowserHosts,
            isTransportObserved: true
        )
    }
}

/// Non-secret signal emitted when a background transfer has stopped for a
/// visible source verification handoff.
public struct DownloadVerificationRequirement: Codable, Hashable, Sendable {
    public var transferID: UUID
    public var url: URL
    public var namespace: String
    public var permittedBrowserHosts: Set<String>
    public var isTransportObserved: Bool

    public init(
        transferID: UUID,
        url: URL,
        namespace: String,
        permittedBrowserHosts: Set<String>,
        isTransportObserved: Bool = false
    ) {
        self.transferID = transferID
        self.url = url
        self.namespace = namespace
        self.permittedBrowserHosts = permittedBrowserHosts
        self.isTransportObserved = isTransportObserved
    }

    public static func sanitizedChallengeURL(_ url: URL) -> URL? {
        guard let input = URLComponents(url: url, resolvingAgainstBaseURL: false),
              input.scheme?.lowercased() == "https",
              input.user == nil,
              input.password == nil,
              let host = input.host?.lowercased(),
              !host.isEmpty
        else { return nil }
        var sanitized = input
        sanitized.scheme = "https"
        sanitized.host = host
        sanitized.query = nil
        sanitized.fragment = nil
        if sanitized.path.isEmpty { sanitized.path = "/" }
        guard let result = sanitized.url,
              let output = URLComponents(url: result, resolvingAgainstBaseURL: false),
              output.user == nil,
              output.password == nil,
              output.query == nil,
              output.fragment == nil
        else { return nil }
        return result
    }
}

/// Queue metadata and resume blobs are intentionally abstracted from the
/// coordinator so the database package can persist them transactionally.
public protocol DownloadStateStore: Sendable {
    func loadDownloads() async throws -> [DownloadSnapshot]
    func saveDownloads(_ snapshots: [DownloadSnapshot]) async throws
    func loadResumeData(for id: UUID) async throws -> Data?
    func saveResumeData(_ data: Data?, for id: UUID) async throws
}

public struct TransientDownloadStateStore: DownloadStateStore {
    public init() {}
    public func loadDownloads() async throws -> [DownloadSnapshot] { [] }
    public func saveDownloads(_: [DownloadSnapshot]) async throws {}
    public func loadResumeData(for _: UUID) async throws -> Data? { nil }
    public func saveResumeData(_: Data?, for _: UUID) async throws {}
}

public struct DownloadTransportResponse: Codable, Hashable, Sendable {
    public var url: URL?
    public var statusCode: Int
    public var suggestedFilename: String?
    public var mimeType: String?
    public var expectedContentLength: Int64?
    /// True only for Cloudflare's explicit mitigation header or bounded
    /// managed-challenge markup. HTTP status alone never sets this flag.
    public var isDefinitiveCloudflareChallenge: Bool

    public init(
        url: URL? = nil,
        statusCode: Int,
        suggestedFilename: String? = nil,
        mimeType: String? = nil,
        expectedContentLength: Int64? = nil,
        isDefinitiveCloudflareChallenge: Bool = false
    ) {
        self.url = url
        self.statusCode = statusCode
        self.suggestedFilename = suggestedFilename
        self.mimeType = mimeType
        self.expectedContentLength = expectedContentLength
        self.isDefinitiveCloudflareChallenge = isDefinitiveCloudflareChallenge
    }
}

public enum DownloadTransportEvent: Sendable {
    case progress(id: UUID, completedBytes: Int64, totalBytes: Int64?)
    case finished(id: UUID, stagedFile: URL, response: DownloadTransportResponse)
    case failed(id: UUID, error: DownloadCoordinatorError, resumeData: Data?)
    case backgroundEventsFinished
}

/// Injectable so queue behavior and recovery can be tested without weakening
/// the production URLSession configuration.
public protocol DownloadTransport: Sendable {
    func events() async -> AsyncStream<DownloadTransportEvent>
    func prepare() async -> Set<UUID>
    func start(_ transfer: DownloadTransfer, resumeData: Data?, wifiOnly: Bool) async throws
    func pause(_ id: UUID) async -> Data?
    func cancel(_ id: UUID) async
    func setPriority(_ priority: Int, for id: UUID) async
    func setBackgroundEventsCompletionHandler(_ handler: (@MainActor @Sendable () -> Void)?) async
}

public enum DownloadEventKind: String, Codable, Hashable, Sendable {
    case restored
    case enqueued
    case stateChanged
    case progress
    case completed
    case failed
    case verificationRequired
    case removed
    case backgroundEventsFinished
}

public struct DownloadEvent: Sendable, Hashable {
    public var kind: DownloadEventKind
    public var snapshot: DownloadSnapshot?

    public init(kind: DownloadEventKind, snapshot: DownloadSnapshot? = nil) {
        self.kind = kind
        self.snapshot = snapshot
    }
}
