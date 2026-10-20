import Darwin
import Foundation
import Network
import Synchronization

protocol ExtensionProxyTransport: Sendable {
    var isHealthy: Bool { get }
    func start() async throws -> ProxyConfiguration
    func cancel()
}

public enum ExtensionTransportError: Error, Equatable, Sendable, LocalizedError {
    case proxyStartupFailed

    public var errorDescription: String? {
        "Mango Reader couldn’t start its secure local connection service. Try again. If this continues, restart Mango Reader."
    }
}

/// Local CONNECT transport. TLS stays end-to-end in URLSession/WebKit. The
/// proxy resolves once, rejects non-public addresses and connects to that exact
/// numeric address, preventing a second DNS lookup from bypassing the policy.
public final class ExtensionEgressProxy: ExtensionProxyTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.k800k.manko.extension-egress")
    private let listener: NWListener
    private let policy: ExtensionNetworkPolicy
    private let password = UUID().uuidString + UUID().uuidString
    private var tunnels: [UUID: Tunnel] = [:]
    private var completedStart = false
    // Listener callbacks are queue-confined; consumers read terminal health
    // synchronously so actor reentrancy cannot return an already retired entry.
    private let healthy = Mutex(true)
    var isHealthy: Bool { healthy.withLock { $0 } }
    private var acceptedConnections = 0
    private let resolve: @Sendable (String) -> [String]

    public convenience init(policy: ExtensionNetworkPolicy) throws {
        try self.init(policy: policy, resolve: Self.resolveAddresses)
    }

    // Injectable DNS keeps transport tests independent of external resolvers.
    init(policy: ExtensionNetworkPolicy, resolve: @escaping @Sendable (String) -> [String],
         listener suppliedListener: NWListener? = nil) throws {
        self.policy = policy
        self.resolve = resolve
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        do {
            listener = try suppliedListener ?? NWListener(using: parameters)
        } catch {
            throw ExtensionTransportError.proxyStartupFailed
        }
    }

    public func start() async throws -> ProxyConfiguration {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed, .cancelled: healthy.withLock { $0 = false }
                default: break
                }
                guard !completedStart else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else { return }
                    completedStart = true
                    var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .ipv4(.loopback), port: port))
                    proxy.allowFailover = false
                    proxy.matchDomains = [""]
                    proxy.excludedDomains = []
                    proxy.applyCredential(username: "manko", password: password)
                    continuation.resume(returning: proxy)
                case .failed:
                    completedStart = true; listener.stateUpdateHandler = nil; listener.cancel()
                    continuation.resume(throwing: ExtensionTransportError.proxyStartupFailed)
                case .cancelled:
                    completedStart = true; listener.stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + 10) { [self] in
                guard !completedStart else { return }
                completedStart = true
                healthy.withLock { $0 = false }
                listener.stateUpdateHandler = nil
                listener.cancel()
                continuation.resume(throwing: ExtensionTransportError.proxyStartupFailed)
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.tunnels.count < 64 else { connection.cancel(); return }
                self.acceptedConnections += 1
                let id = UUID()
                let tunnel = Tunnel(connection: connection, policy: self.policy, password: self.password, queue: self.queue, resolve: self.resolve) { [weak self] in
                    self?.tunnels[id] = nil
                }
                self.tunnels[id] = tunnel
                tunnel.start()
            }
            listener.start(queue: queue)
        }
    }

    public func cancel() {
        healthy.withLock { $0 = false }
        queue.async { [self] in
            listener.cancel()
            for tunnel in Array(tunnels.values) { tunnel.cancel() }
        }
    }

    func connectionCount() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: acceptedConnections) }
        }
    }

    /// CONNECT carries an authority, not a scheme. Public grants always use
    /// HTTPS; HTTP is permitted only for the exact configured server origin.
    static func tunnelTarget(_ authority: String, policy: ExtensionNetworkPolicy) -> URL? {
        for scheme in ["https", "http"] {
            guard let url = URL(string: scheme + "://" + authority),
                  url.path.isEmpty, url.query == nil, url.fragment == nil,
                  policy.allows(url) else { continue }
            return url
        }
        return nil
    }

    static func resolvedAddress(_ addresses: [String], allowsPrivate: Bool) -> String? {
        guard !addresses.isEmpty,
              addresses.allSatisfy({ isNumericAddress($0) && (allowsPrivate || publicAddress($0)) }) else { return nil }
        return addresses[0]
    }

    private static func isNumericAddress(_ address: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, address, &v4) == 1 || inet_pton(AF_INET6, address, &v6) == 1
    }

    private static func resolveAddresses(_ host: String) -> [String] {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else { return [] }
        defer { freeaddrinfo(result) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let current = cursor {
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 else { return [] }
            addresses.append(String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            cursor = current.pointee.ai_next
        }
        return addresses
    }

    public static func publicAddress(_ address: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            let a = value >> 24, b = (value >> 16) & 255, c = (value >> 8) & 255
            return a != 0 && a != 10 && a != 127 && a < 224
                && !(a == 100 && (64...127).contains(b))
                && !(a == 169 && b == 254) && !(a == 172 && (16...31).contains(b))
                && !(a == 192 && (b == 168 || b == 0 || (b == 88 && c == 99)))
                && !(a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100)))
                && !(a == 203 && b == 0 && c == 113)
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, address, &ipv6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
        // Global unicast only; excludes mapped IPv4, local, multicast, NAT64,
        // 6to4/Teredo and documentation/special-use ranges.
        guard bytes[0] & 0xe0 == 0x20 else { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x02 { return false }
        if bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] & 0xf0 == 0 { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x01 {
            if bytes[2] < 2 || (bytes[2] == 0x0d && bytes[3] == 0xb8) { return false }
        }
        return true
    }

    private final class Tunnel: @unchecked Sendable {
        let client: NWConnection
        let policy: ExtensionNetworkPolicy
        let password: String
        let queue: DispatchQueue
        let finished: @Sendable () -> Void
        let resolve: @Sendable (String) -> [String]
        var upstream: NWConnection?
        var buffer = Data()
        var ended = false

        init(connection: NWConnection, policy: ExtensionNetworkPolicy, password: String,
             queue: DispatchQueue, resolve: @escaping @Sendable (String) -> [String], finished: @escaping @Sendable () -> Void) {
            client = connection; self.policy = policy; self.password = password
            self.queue = queue; self.finished = finished; self.resolve = resolve
        }
        func start() {
            client.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 300) { [weak self] in self?.cancel() }
            readHeader()
        }
        func cancel() {
            guard !ended else { return }
            ended = true
            upstream?.stateUpdateHandler = nil
            client.cancel(); upstream?.cancel(); upstream = nil
            finished()
        }
        func readHeader() {
            client.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, complete, error in
                guard !ended else { return }
                if let data { buffer.append(data) }
                guard error == nil, !complete, buffer.count <= 8192 else { cancel(); return }
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { readHeader(); return }
                let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                guard let first = lines.first else { cancel(); return }
                let parts = first.split(separator: " ")
                let expected = "Basic " + Data("manko:\(password)".utf8).base64EncodedString()
                let credentials = lines.dropFirst().first { $0.lowercased().hasPrefix("proxy-authorization:") }?
                    .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
                guard credentials == expected else {
                    client.send(content: Data("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"Mango Reader\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { [self] _ in cancel() })
                    return
                }
                guard parts.count == 3, parts[0] == "CONNECT",
                      let target = ExtensionEgressProxy.tunnelTarget(String(parts[1]), policy: policy),
                      let rawHost = target.host,
                      let portValue = UInt16(exactly: target.port ?? (target.scheme == "http" ? 80 : 443)),
                      let port = NWEndpoint.Port(rawValue: portValue)
                else { cancel(); return }
                let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
                let remainder = Data(buffer[end.upperBound...]); buffer = Data()
                DispatchQueue.global(qos: .utility).async { [self] in
                    let addresses = resolve(host)
                    let server = policy.serverOrigin.map { SourceRequestAuthorizer.isSameOrigin(target, as: $0) } ?? false
                    // Mixed public/private DNS answers fail closed too.
                    guard let address = ExtensionEgressProxy.resolvedAddress(addresses, allowsPrivate: server)
                    else { queue.async { [self] in cancel() }; return }
                    queue.async { [self] in
                        guard !ended else { return }
                        let remote = NWConnection(host: NWEndpoint.Host(address), port: port, using: .tcp)
                        upstream = remote
                        remote.stateUpdateHandler = { [self] state in
                            switch state {
                            case .ready:
                                remote.stateUpdateHandler = nil
                                client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { [self] error in
                                    guard error == nil else { cancel(); return }
                                    // CONNECT usually ends at the headers. Start reading the
                                    // tunnel immediately instead of sending an empty TCP frame.
                                    guard !remainder.isEmpty else {
                                        pipe(client, to: remote); pipe(remote, to: client)
                                        return
                                    }
                                    remote.send(content: remainder, completion: .contentProcessed { [self] error in
                                        guard error == nil else { cancel(); return }
                                        pipe(client, to: remote); pipe(remote, to: client)
                                    })
                                })
                            case .failed, .cancelled: cancel()
                            default: break
                            }
                        }
                        remote.start(queue: queue)
                    }
                }
            }
        }
        func pipe(_ source: NWConnection, to destination: NWConnection) {
            guard !ended else { return }
            source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
                guard error == nil, let data, !data.isEmpty else { cancel(); return }
                destination.send(content: data, completion: .contentProcessed { [self] error in
                    if error != nil || complete { cancel() } else { pipe(source, to: destination) }
                })
            }
        }
    }
}

public actor ExtensionNetworkSessions {
    public static let shared = ExtensionNetworkSessions()
    public struct Lease: Sendable {
        public let generation: UUID
        public let session: URLSession
        public let configuration: ProxyConfiguration
    }
    private struct Entry: Sendable {
        let proxy: any ExtensionProxyTransport
        let lease: Lease
    }
    private var entries: [ExtensionNetworkPolicy: Entry] = [:]
    private var starting: [ExtensionNetworkPolicy: (id: UUID, task: Task<Entry, Error>)] = [:]
    private let makeProxy: @Sendable (ExtensionNetworkPolicy) throws -> any ExtensionProxyTransport
    private let makeSession: @Sendable (ProxyConfiguration) -> URLSession

    public init() {
        makeProxy = { try ExtensionEgressProxy(policy: $0) }
        makeSession = Self.makeSession
    }

    init(makeProxy: @escaping @Sendable (ExtensionNetworkPolicy) throws -> any ExtensionProxyTransport,
         makeSession: @escaping @Sendable (ProxyConfiguration) -> URLSession = ExtensionNetworkSessions.makeSession) {
        self.makeProxy = makeProxy
        self.makeSession = makeSession
    }

    deinit {
        for pending in starting.values { pending.task.cancel() }
        for entry in entries.values {
            entry.proxy.cancel()
            entry.lease.session.invalidateAndCancel()
        }
    }

    private static func makeSession(_ proxy: ProxyConfiguration) -> URLSession {
        let settings = URLSessionConfiguration.ephemeral
        settings.httpCookieStorage = nil; settings.urlCredentialStorage = nil; settings.urlCache = nil
        settings.httpShouldSetCookies = false; settings.proxyConfigurations = [proxy]
        settings.timeoutIntervalForRequest = 30; settings.timeoutIntervalForResource = 300
        return URLSession(configuration: settings)
    }

    /// One startup per policy, including recovery. A cancelled caller never
    /// cancels the shared startup that other consumers are awaiting.
    public func lease(for policy: ExtensionNetworkPolicy) async throws -> Lease {
        try Task.checkCancellation()
        if let entry = entries[policy] {
            if entry.proxy.isHealthy { return entry.lease }
            entries[policy] = nil
            entry.proxy.cancel()
            entry.lease.session.finishTasksAndInvalidate()
        }
        let pending: (id: UUID, task: Task<Entry, Error>)
        if let existing = starting[policy] { pending = existing }
        else {
            guard entries.count + starting.count < 128 else { throw HTTPClientError.forbidden }
            let id = UUID(), makeProxy = self.makeProxy, makeSession = self.makeSession
            let task = Task {
                let proxy = try makeProxy(policy)
                do {
                    let configuration = try await proxy.start()
                    try Task.checkCancellation()
                    guard proxy.isHealthy else { throw ExtensionTransportError.proxyStartupFailed }
                    return Entry(proxy: proxy, lease: Lease(generation: id,
                        session: makeSession(configuration), configuration: configuration))
                } catch {
                    proxy.cancel()
                    throw error
                }
            }
            pending = (id, task)
            starting[policy] = pending
        }
        do {
            let entry = try await pending.task.value
            if starting[policy]?.id == pending.id {
                starting[policy] = nil
                entries[policy] = entry
            }
            try Task.checkCancellation()
            // A different consumer may already have retired this generation.
            guard entry.proxy.isHealthy else { throw ExtensionTransportError.proxyStartupFailed }
            guard entries[policy]?.lease.generation == entry.lease.generation else {
                return try await lease(for: policy)
            }
            return entry.lease
        } catch {
            if starting[policy]?.id == pending.id { starting[policy] = nil }
            throw error
        }
    }

    public func configuration(for policy: ExtensionNetworkPolicy) async throws -> ProxyConfiguration {
        try await lease(for: policy).configuration
    }
    public func session(for policy: ExtensionNetworkPolicy) async throws -> URLSession {
        try await lease(for: policy).session
    }
}
