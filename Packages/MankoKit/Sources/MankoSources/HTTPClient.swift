import Foundation
import MankoDomain
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HTTPMethod: String, Codable, Hashable, Sendable {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case options = "OPTIONS"

    public var isIdempotent: Bool {
        switch self {
        case .get, .head, .put, .delete, .options:
            true
        case .post, .patch:
            false
        }
    }
}

/// Controls whether an HTTP response status is interpreted by ``HTTPClient``
/// or returned to the caller for application-specific handling.
public enum HTTPStatusPolicy: Hashable, Sendable {
    /// Return successful responses and translate non-successful statuses into
    /// ``HTTPClientError`` values, including the client's bounded status retry
    /// behavior.
    case requireSuccess
    /// Return every valid HTTP response without status retries or status-error
    /// translation. Transport, redirect, endpoint-policy, and cancellation
    /// failures still throw.
    case returnResponse
}

public struct HTTPRequest: Hashable, Sendable {
    public var url: URL
    public var method: HTTPMethod
    public var headers: [String: String]
    public var body: Data?
    public var endpointAccess: EndpointAccess
    /// Reference origin allowed to retain source credentials across redirects.
    /// Even when this is `nil`, credential-bearing headers are removed whenever
    /// an actual redirect crosses origins.
    public var credentialOrigin: URL?
    /// When present, the initial request and every redirect must remain on one
    /// of these exact lowercased HTTPS hosts. This remains available to compiled
    /// first-party clients and downloaded extensions.
    public var allowedHTTPSHosts: Set<String>?
    /// Non-secret cache namespace, normally the Keychain account identifier.
    public var cachePartition: String?
    /// Browser-verified identity to apply only if a redirect reaches its exact
    /// HTTPS origin. This lets a retry survive a source-to-challenge-host
    /// redirect without forwarding the source origin's credentials.
    public var redirectIdentity: HTTPRedirectIdentity?
    public var usesConditionalCache: Bool
    /// Determines whether non-successful HTTP status codes throw or are
    /// returned for caller inspection. Defaults to ``.requireSuccess`` so
    /// existing first-party requests retain their status-error behavior.
    public var networkPolicy: ExtensionNetworkPolicy?
    public var followsRedirects: Bool
    public var maximumResponseBytes: Int?
    public var statusPolicy: HTTPStatusPolicy

    public init(
        url: URL,
        method: HTTPMethod = .get,
        headers: [String: String] = [:],
        body: Data? = nil,
        endpointAccess: EndpointAccess = EndpointAccess(),
        credentialOrigin: URL? = nil,
        allowedHTTPSHosts: Set<String>? = nil,
        cachePartition: String? = nil,
        redirectIdentity: HTTPRedirectIdentity? = nil,
        usesConditionalCache: Bool = true,
        networkPolicy: ExtensionNetworkPolicy? = nil,
        followsRedirects: Bool = true,
        maximumResponseBytes: Int? = nil,
        statusPolicy: HTTPStatusPolicy = .requireSuccess
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.endpointAccess = endpointAccess
        self.credentialOrigin = credentialOrigin
        self.allowedHTTPSHosts = allowedHTTPSHosts
        self.cachePartition = cachePartition
        self.redirectIdentity = redirectIdentity
        self.usesConditionalCache = usesConditionalCache
        self.networkPolicy = networkPolicy
        self.followsRedirects = followsRedirects
        self.maximumResponseBytes = maximumResponseBytes
        self.statusPolicy = statusPolicy
    }
}

public struct HTTPResponse: Codable, Hashable, Sendable {
    public var url: URL
    public var statusCode: Int
    public var headers: [String: String]
    public var data: Data
    public var wasRevalidatedFromCache: Bool

    public init(url: URL, statusCode: Int, headers: [String: String], data: Data, wasRevalidatedFromCache: Bool = false) {
        self.url = url
        self.statusCode = statusCode
        self.headers = headers
        self.data = data
        self.wasRevalidatedFromCache = wasRevalidatedFromCache
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public enum HTTPClientError: Error, Hashable, Sendable, LocalizedError {
    case invalidURL
    case unsupportedScheme(String)
    case insecurePublicEndpoint
    case cancelled
    case transport(code: Int, description: String)
    case invalidResponse
    case unauthorized
    case forbidden
    case notFound
    case rateLimited(retryAfterSeconds: Double?)
    case server(statusCode: Int, retryAfterSeconds: Double?)
    case client(statusCode: Int)
    case encoding(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The endpoint URL is invalid."
        case let .unsupportedScheme(scheme): "The URL scheme \(scheme) is not supported."
        case .insecurePublicEndpoint: "Public endpoints must use HTTPS."
        case .cancelled: "The request was cancelled."
        case let .transport(_, description): description
        case .invalidResponse: "The server returned an invalid HTTP response."
        case .unauthorized: "Authentication is required."
        case .forbidden: "The server denied access."
        case .notFound: "The requested resource was not found."
        case let .rateLimited(delay): delay.map { "The server is rate limited. Try again in \(Int($0)) seconds." } ?? "The server is rate limited."
        case let .server(code, _): "The server returned HTTP \(code)."
        case let .client(code): "The request failed with HTTP \(code)."
        case let .encoding(message): "Unable to encode the request: \(message)"
        case let .decoding(message): "Unable to decode the response: \(message)"
        }
    }
}

public actor HTTPClient {
    public struct RetryPolicy: Hashable, Sendable {
        public var maximumAttempts: Int
        public var initialBackoffSeconds: Double
        public var maximumDelaySeconds: Double

        public init(maximumAttempts: Int = 3, initialBackoffSeconds: Double = 0.5, maximumDelaySeconds: Double = 60) {
            self.maximumAttempts = max(1, maximumAttempts)
            self.initialBackoffSeconds = max(0, initialBackoffSeconds)
            self.maximumDelaySeconds = max(0, maximumDelaySeconds)
        }
    }

    private struct CacheEntry: Codable, Sendable {
        var response: HTTPResponse
        var etag: String?
        var lastModified: String?
    }

    private let session: URLSession
    private let extensionTestSession: URLSession?
    private let networkSessions: ExtensionNetworkSessions
    private let endpointPolicy: EndpointPolicy
    private let retryPolicy: RetryPolicy
    private var conditionalCache: [String: CacheEntry] = [:]

    public init(
        session: URLSession? = nil,
        endpointPolicy: EndpointPolicy = EndpointPolicy(),
        retryPolicy: RetryPolicy = RetryPolicy()
    ) {
        self.extensionTestSession = nil
        self.networkSessions = .shared
        self.session = session ?? URLSession(configuration: Self.defaultSessionConfiguration())
        self.endpointPolicy = endpointPolicy
        self.retryPolicy = retryPolicy
    }

    /// Native requests carry source cookies and credentials explicitly. The
    /// default transport therefore has no process-global storage that could
    /// silently attach identity from another source or cache partition.
    static func defaultSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    /// Explicit fixture transport; production initializers always enforce egress.
    public init(testingSession: URLSession, retryPolicy: RetryPolicy = .init()) {
        self.session = testingSession
        self.extensionTestSession = testingSession
        self.networkSessions = .shared
        self.endpointPolicy = EndpointPolicy()
        self.retryPolicy = retryPolicy
    }

    init(networkSessions: ExtensionNetworkSessions, retryPolicy: RetryPolicy = .init()) {
        self.session = URLSession(configuration: Self.defaultSessionConfiguration())
        self.extensionTestSession = nil
        self.networkSessions = networkSessions
        self.endpointPolicy = EndpointPolicy()
        self.retryPolicy = retryPolicy
    }

    public func response(for request: HTTPRequest,
        onProgress: RemoteImageDownloadProgressHandler? = nil,
        onPartialImage: (@Sendable (Data, String?) async -> Void)? = nil,
        onChunk: (@Sendable (HTTPResponse, Data) async throws -> Void)? = nil) async throws -> HTTPResponse {
        try endpointPolicy.validate(request.url, access: request.endpointAccess)
        try request.networkPolicy?.validate(request.url)
        let responseLimit = request.maximumResponseBytes ?? (request.networkPolicy == nil ? nil : 16 * 1_024 * 1_024)
        if let allowedHTTPSHosts = request.allowedHTTPSHosts {
            guard request.url.scheme?.lowercased() == "https",
                  let host = request.url.host?.lowercased(),
                  HTTPSHostAccess.allows(host, declarations: allowedHTTPSHosts)
            else {
                throw HTTPClientError.forbidden
            }
        }

        let cacheKey = Self.cacheKey(for: request)
        let persistentKey = ContentCache.key(["http-validator", cacheKey])
        if request.method == .get, request.usesConditionalCache, request.cachePartition != nil,
           conditionalCache[cacheKey] == nil, let stored = await ContentCache.shared.entry(for: persistentKey) {
            conditionalCache[cacheKey] = try? stored.decode(CacheEntry.self)
        }
        var attempt = 1

        while true {
            try Task.checkCancellation()
            var urlRequest = URLRequest(url: request.url)
            urlRequest.httpMethod = request.method.rawValue
            urlRequest.httpBody = request.body
            urlRequest.timeoutInterval = 30
            for (name, value) in request.headers {
                urlRequest.setValue(value, forHTTPHeaderField: name)
            }

            if request.method == .get, request.usesConditionalCache, let cached = conditionalCache[cacheKey] {
                if urlRequest.value(forHTTPHeaderField: "If-None-Match") == nil, let etag = cached.etag {
                    urlRequest.setValue(etag, forHTTPHeaderField: "If-None-Match")
                }
                if urlRequest.value(forHTTPHeaderField: "If-Modified-Since") == nil, let modified = cached.lastModified {
                    urlRequest.setValue(modified, forHTTPHeaderField: "If-Modified-Since")
                }
            }

            do {
                // A retry must not keep using a proxy generation that failed
                // while the app was suspended.
                let transport: URLSession
                if request.networkPolicy != nil, let fixture = extensionTestSession { transport = fixture }
                else if let policy = request.networkPolicy, request.url.scheme?.lowercased() == "https" {
                    transport = try await networkSessions.session(for: policy)
                } else { transport = session }
                try Task.checkCancellation()
                let redirectPolicy = SourceRequestRedirectPolicy(
                    endpointAccess: request.endpointAccess,
                    credentialOrigin: request.credentialOrigin,
                    allowedHTTPSHosts: request.allowedHTTPSHosts,
                    redirectIdentity: request.redirectIdentity,
                    networkPolicy: request.networkPolicy,
                    followsRedirects: request.followsRedirects
                )
                let data: Data
                let rawResponse: URLResponse
                if onPartialImage != nil || onProgress != nil || onChunk != nil || responseLimit != nil {
                    let (bytes, response) = try await transport.bytes(for: urlRequest, delegate: redirectPolicy.makeDelegate())
                    defer { bytes.task.cancel() }
                    rawResponse = response
                    let head = HTTPResponse(url: response.url ?? request.url, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
                        headers: Self.stringHeaders((response as? HTTPURLResponse)?.allHeaderFields ?? [:]), data: Data())
                    var accumulated = Data()
                    var chunk: [UInt8] = []; chunk.reserveCapacity(65_536)
                    let mime = response.mimeType
                    // URLSession yields decoded bytes. An encoded response's wire length
                    // is not a reliable denominator for that stream.
                    let httpResponse = response as? HTTPURLResponse
                    let encoding = httpResponse?.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
                    let expected = encoding == nil || encoding == "identity" ? response.expectedContentLength : -1
                    let successful = httpResponse.map { (200..<300).contains($0.statusCode) } == true
                    if let onProgress { await onProgress(.init(receivedBytes: 0, expectedBytes: successful ? expected : nil)) }
                    var lastDelivery = ContinuousClock.now
                    var deliveredHeader = false
                    var lastProgressDelivery = ContinuousClock.now
                    for try await byte in bytes {
                        if let responseLimit, accumulated.count + chunk.count >= responseLimit { throw HTTPClientError.invalidResponse }
                        chunk.append(byte)
                        if chunk.count == (onChunk == nil ? 65_536 : 2_048) || (!deliveredHeader && successful && onPartialImage != nil && chunk.count == 4_096) {
                            if successful, let onChunk { try await onChunk(head, Data(chunk)) }
                            accumulated.append(contentsOf: chunk)
                            chunk.removeAll(keepingCapacity: true)
                            try Task.checkCancellation()
                            guard (onPartialImage == nil && onChunk == nil) || accumulated.count <= 16 * 1_024 * 1_024 else { throw HTTPClientError.invalidResponse }
                            // Header metadata is useful even when this format cannot
                            // produce a progressive bitmap. Let the decoder validate it.
                            if successful, let onPartialImage,
                               !deliveredHeader || lastDelivery.duration(to: .now) >= .milliseconds(250) {
                                await onPartialImage(accumulated, mime)
                                deliveredHeader = true
                                lastDelivery = .now
                            }
                        }
                        // Avoid reading the clock for every byte in large images.
                        if let onProgress, (accumulated.count + chunk.count).isMultiple(of: 256),
                           lastProgressDelivery.duration(to: .now) >= .milliseconds(250) {
                            try Task.checkCancellation()
                            await onProgress(.init(receivedBytes: Int64(accumulated.count + chunk.count),
                                expectedBytes: successful ? expected : nil))
                            lastProgressDelivery = .now
                        }
                    }
                    if successful, let onChunk, !chunk.isEmpty { try await onChunk(head, Data(chunk)) }
                    accumulated.append(contentsOf: chunk)
                    guard (onPartialImage == nil && onChunk == nil) || accumulated.count <= 16 * 1_024 * 1_024 else { throw HTTPClientError.invalidResponse }
                    try Task.checkCancellation()
                    if successful, let onPartialImage, !accumulated.isEmpty {
                        await onPartialImage(accumulated, mime)
                        try Task.checkCancellation()
                    }
                    if let onProgress { await onProgress(.init(receivedBytes: Int64(accumulated.count), expectedBytes: successful ? expected : nil)) }
                    data = accumulated
                } else {
                    (data, rawResponse) = try await transport.data(for: urlRequest, delegate: redirectPolicy.makeDelegate())
                }
                try Task.checkCancellation()

                guard let response = rawResponse as? HTTPURLResponse else {
                    throw HTTPClientError.invalidResponse
                }

                let headers = Self.stringHeaders(response.allHeaderFields)
                let result = HTTPResponse(
                    url: response.url ?? request.url,
                    statusCode: response.statusCode,
                    headers: headers,
                    data: data
                )

                if request.statusPolicy == .returnResponse {
                    return result
                }

                if response.statusCode == 304 {
                    guard var cached = conditionalCache[cacheKey] else {
                        throw HTTPClientError.invalidResponse
                    }
                    cached.response.wasRevalidatedFromCache = true
                    conditionalCache[cacheKey] = cached
                    return cached.response
                }

                if (200 ..< 300).contains(response.statusCode) {
                    let forbidsStorage = result.header("Cache-Control")?.lowercased().contains("no-store") == true
                    if forbidsStorage {
                        conditionalCache[cacheKey] = nil
                        await ContentCache.shared.remove(persistentKey)
                    } else if request.method == .get, request.usesConditionalCache {
                        let etag = result.header("ETag")
                        let lastModified = result.header("Last-Modified")
                        if etag != nil || lastModified != nil {
                            var storedResponse = result
                            storedResponse.headers = result.headers.filter { !["set-cookie", "authorization", "proxy-authorization"].contains($0.key.lowercased()) }
                            conditionalCache[cacheKey] = CacheEntry(response: storedResponse, etag: etag, lastModified: lastModified)
                            if request.cachePartition != nil,
                               result.header("Cache-Control")?.lowercased().contains("no-store") != true,
                               let entry = conditionalCache[cacheKey] {
                                await ContentCache.shared.store(entry, for: persistentKey)
                            }
                        }
                    }
                    return result
                }

                let retryAfter = Self.retryDelay(from: result.header("Retry-After"), now: .now)
                if request.method.isIdempotent,
                   attempt < retryPolicy.maximumAttempts,
                   Self.isRetryableStatus(response.statusCode) {
                    let delay = min(retryPolicy.maximumDelaySeconds, retryAfter ?? backoff(forAttempt: attempt))
                    attempt += 1
                    try await sleep(seconds: delay)
                    continue
                }

                throw Self.statusError(response.statusCode, retryAfter: retryAfter)
            } catch is CancellationError {
                throw HTTPClientError.cancelled
            } catch let error as HTTPClientError {
                throw error
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled {
                    throw HTTPClientError.cancelled
                }
                if onChunk == nil, request.method.isIdempotent,
                   attempt < retryPolicy.maximumAttempts,
                   Self.isRetryableTransport(error.code) {
                    let delay = min(retryPolicy.maximumDelaySeconds, backoff(forAttempt: attempt))
                    attempt += 1
                    try await sleep(seconds: delay)
                    continue
                }
                throw HTTPClientError.transport(code: error.errorCode, description: error.localizedDescription)
            } catch {
                if Task.isCancelled {
                    throw HTTPClientError.cancelled
                }
                throw HTTPClientError.transport(code: 0, description: error.localizedDescription)
            }
        }
    }

    public func decode<Value: Decodable & Sendable>(
        _ type: Value.Type = Value.self,
        from request: HTTPRequest
    ) async throws -> Value {
        let response = try await response(for: request)
        do {
            return try JSONDecoder().decode(type, from: response.data)
        } catch {
            throw HTTPClientError.decoding(error.localizedDescription)
        }
    }

    public func jsonResponse<RequestBody: Encodable & Sendable, ResponseBody: Decodable & Sendable>(
        for request: HTTPRequest,
        body: RequestBody,
        as type: ResponseBody.Type = ResponseBody.self
    ) async throws -> ResponseBody {
        var request = request
        do {
            request.body = try JSONEncoder().encode(body)
        } catch {
            throw HTTPClientError.encoding(error.localizedDescription)
        }
        if request.headers.keys.allSatisfy({ $0.caseInsensitiveCompare("Content-Type") != .orderedSame }) {
            request.headers["Content-Type"] = "application/json"
        }
        return try await decode(type, from: request)
    }

    public func removeCachedResponse(for request: HTTPRequest) {
        conditionalCache.removeValue(forKey: Self.cacheKey(for: request))
    }

    public func removeAllCachedResponses() {
        conditionalCache.removeAll(keepingCapacity: false)
    }

    public static func retryDelay(from value: String?, now: Date) -> Double? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if let seconds = Double(value), seconds >= 0 {
            return seconds
        }

        let formats = [
            "EEE',' dd MMM yyyy HH':'mm':'ss z",
            "EEEE',' dd-MMM-yy HH':'mm':'ss z",
            "EEE MMM d HH':'mm':'ss yyyy",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return max(0, date.timeIntervalSince(now))
            }
        }
        return nil
    }

    private func backoff(forAttempt attempt: Int) -> Double {
        retryPolicy.initialBackoffSeconds * pow(2, Double(max(0, attempt - 1)))
    }

    private func sleep(seconds: Double) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds))
    }

    private static func cacheKey(for request: HTTPRequest) -> String {
        let accept = request.headers.first { $0.key.caseInsensitiveCompare("Accept") == .orderedSame }?.value ?? ""
        let partition = request.cachePartition ?? "anonymous"
        return "\(partition)|\(request.method.rawValue)|\(request.url.absoluteString)|\(accept)"
    }

    private static func stringHeaders(_ fields: [AnyHashable: Any]) -> [String: String] {
        var headers: [String: String] = [:]
        headers.reserveCapacity(fields.count)
        for (key, value) in fields {
            headers[String(describing: key)] = String(describing: value)
        }
        return headers
    }

    private static func isRetryableStatus(_ statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 425 || statusCode == 429 || [500, 502, 503, 504].contains(statusCode)
    }

    private static func isRetryableTransport(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet, .internationalRoamingOff,
             .callIsActive, .dataNotAllowed, .resourceUnavailable:
            true
        default:
            false
        }
    }

    private static func statusError(_ statusCode: Int, retryAfter: Double?) -> HTTPClientError {
        switch statusCode {
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        case 429: .rateLimited(retryAfterSeconds: retryAfter)
        case 500 ... 599: .server(statusCode: statusCode, retryAfterSeconds: retryAfter)
        default: .client(statusCode: statusCode)
        }
    }
}
