import Foundation
import MankoDomain
import Security

public protocol SourceCredentialLoading: Sendable {
    func credential(account: String) async throws -> SourceCredential?
}

public enum KeychainCredentialError: Error, Hashable, Sendable, LocalizedError {
    case encoding(String)
    case decoding(String)
    case unexpectedResult
    case operationFailed(operation: String, status: OSStatus, message: String)

    public var errorDescription: String? {
        switch self {
        case let .encoding(message): "Unable to encode the credential: \(message)"
        case let .decoding(message): "Unable to decode the credential: \(message)"
        case .unexpectedResult: "The keychain returned an unexpected result."
        case let .operationFailed(operation, status, message): "Keychain \(operation) failed (\(status)): \(message)"
        }
    }
}

enum KeychainQueryFactory {
    static func lookup(service: String, account: String) -> [String: Any] {
        platformQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ])
    }

    static func read(service: String, account: String) -> [String: Any] {
        var query = lookup(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    static func add(service: String, account: String, data: Data) -> [String: Any] {
        var query = lookup(service: service, account: account)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecValueData as String] = data
        return query
    }

    static func updateAttributes(data: Data) -> [String: Any] {
        [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
    }

    static func delete(service: String, account: String) -> [String: Any] {
        lookup(service: service, account: account)
    }

    private static func platformQuery(_ query: [String: Any]) -> [String: Any] {
        var query = query
        #if os(macOS) || targetEnvironment(macCatalyst)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
}

/// Direct SecItem-backed storage for source passwords, tokens, and API keys.
/// Credentials are deliberately device-only, not synchronizable, and remain
/// available to background refresh after the first device unlock.
public actor KeychainCredentialStore: SourceCredentialLoading {
    private let isPrivate: Bool
    public let service: String

    public init(service: String = "com.k800k.manko.sources", isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        self.service = service
    }

    public func save(_ credential: SourceCredential, account: String) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(credential)
        } catch {
            throw KeychainCredentialError.encoding(error.localizedDescription)
        }

        let lookup = KeychainQueryFactory.lookup(service: service, account: account)
        var attributes = KeychainQueryFactory.updateAttributes(data: data)
        if isPrivate { attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly }
        var status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var add = KeychainQueryFactory.add(service: service, account: account, data: data)
            if isPrivate { add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly }
            status = SecItemAdd(add as CFDictionary, nil)

            // Another process can win the add between update and add. Preserve
            // the item and update it rather than deleting and recreating it.
            if status == errSecDuplicateItem {
                status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
            }
        }

        try check(status, operation: "save")
    }

    public func credential(account: String) throws -> SourceCredential? {
        let query = KeychainQueryFactory.read(service: service, account: account)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        try check(status, operation: "read")

        guard let data = result as? Data else {
            throw KeychainCredentialError.unexpectedResult
        }
        do {
            return try JSONDecoder().decode(SourceCredential.self, from: data)
        } catch {
            throw KeychainCredentialError.decoding(error.localizedDescription)
        }
    }

    public func remove(account: String) throws {
        let query = KeychainQueryFactory.delete(service: service, account: account)
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound {
            return
        }
        try check(status, operation: "delete")
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
            throw KeychainCredentialError.operationFailed(operation: operation, status: status, message: message)
        }
    }
}
