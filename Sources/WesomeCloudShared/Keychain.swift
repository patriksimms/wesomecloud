import Foundation
import Security

public struct Credential: Codable, Equatable, Sendable {
    public var accountID: UUID
    public var username: String
    public var secret: String
    public var kind: CredentialKind

    public init(accountID: UUID, username: String, secret: String, kind: CredentialKind) {
        self.accountID = accountID
        self.username = username
        self.secret = secret
        self.kind = kind
    }
}

public enum CredentialKind: String, Codable, Equatable, Sendable {
    case appPassword
    case basicPassword
    case oauthRefreshToken
}

public protocol CredentialStore: Sendable {
    func save(_ credential: Credential) async throws
    func credential(accountID: UUID) async throws -> Credential?
    func delete(accountID: UUID) async throws
}

/// Stores credentials in the data protection keychain so the app and the File Provider extension
/// share them through the `keychain-access-groups` entitlement both targets carry. Items are added to
/// the first group in that entitlement, so no team-prefixed group name is needed at runtime.
///
/// Earlier builds wrote to the legacy login keychain, where each item is owned by the binary that
/// last wrote it and every other process gets an "allow access" prompt. Those items are moved over
/// on first read. Unsigned builds (`swift run`, tests) have no entitlement and stay on the legacy keychain.
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    private let service: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(service: String = "cloud.wesome.wesomecloud.credentials") {
        self.service = service
    }

    public func save(_ credential: Credential) async throws {
        let data = try encoder.encode(credential)
        let status = add(data, accountID: credential.accountID, dataProtection: true)
        if status == errSecMissingEntitlement {
            let legacyStatus = add(data, accountID: credential.accountID, dataProtection: false)
            guard legacyStatus == errSecSuccess else { throw KeychainError.status(legacyStatus) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        SecItemDelete(baseQuery(accountID: credential.accountID, dataProtection: false) as CFDictionary)
    }

    public func credential(accountID: UUID) async throws -> Credential? {
        switch read(accountID: accountID, dataProtection: true) {
        case .success(let data?):
            return try decoder.decode(Credential.self, from: data)
        case .success(nil), .failure(.status(errSecMissingEntitlement)):
            break
        case .failure(let error):
            throw error
        }
        guard let legacyData = try read(accountID: accountID, dataProtection: false).get() else { return nil }
        if add(legacyData, accountID: accountID, dataProtection: true) == errSecSuccess {
            SecItemDelete(baseQuery(accountID: accountID, dataProtection: false) as CFDictionary)
        }
        return try decoder.decode(Credential.self, from: legacyData)
    }

    public func delete(accountID: UUID) async throws {
        for dataProtection in [true, false] {
            let status = SecItemDelete(baseQuery(accountID: accountID, dataProtection: dataProtection) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement else {
                throw KeychainError.status(status)
            }
        }
    }

    private func add(_ data: Data, accountID: UUID, dataProtection: Bool) -> OSStatus {
        let query = baseQuery(accountID: accountID, dataProtection: dataProtection)
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    private func read(accountID: UUID, dataProtection: Bool) -> Result<Data?, KeychainError> {
        var query = baseQuery(accountID: accountID, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .success(nil) }
        guard status == errSecSuccess, let data = result as? Data else { return .failure(.status(status)) }
        return .success(data)
    }

    private func baseQuery(accountID: UUID, dataProtection: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
            kSecUseDataProtectionKeychain as String: dataProtection,
        ]
    }
}

public actor MemoryCredentialStore: CredentialStore {
    private var credentials: [UUID: Credential] = [:]

    public init() {}

    public func save(_ credential: Credential) async throws {
        credentials[credential.accountID] = credential
    }

    public func credential(accountID: UUID) async throws -> Credential? {
        credentials[accountID]
    }

    public func delete(accountID: UUID) async throws {
        credentials[accountID] = nil
    }
}

public enum KeychainError: Error, Equatable, Sendable {
    case status(OSStatus)
}
