import Foundation

/// Stores secrets (passwords) keyed by `ServerConfig.credentialKey`.
public protocol CredentialStore: Sendable {
    func password(for key: String) throws -> String?
    func setPassword(_ password: String, for key: String) throws
    func removePassword(for key: String) throws
}

extension CredentialStore {
    /// What signing in to `config` needs from the Keychain: the password, or for an SSH key its passphrase. Nil when a
    /// password login has none saved. A key login always has an answer: a key that has no passphrase has nothing saved,
    /// and the empty passphrase it is read as is what such a key is opened with.
    public func loginSecret(for config: ServerConfig) -> String? {
        if config.usesKey { return (try? password(for: config.credentialKey)) ?? "" }
        return try? password(for: config.credentialKey)
    }

    /// Keeps the secret for `config`. A password login saves whatever was typed, as it always did. A key without a
    /// passphrase has nothing to keep, and a passphrase saved before is removed.
    public func saveLoginSecret(_ secret: String, for config: ServerConfig) throws {
        if config.usesKey, secret.isEmpty {
            try removePassword(for: config.credentialKey)
        } else {
            try setPassword(secret, for: config.credentialKey)
        }
    }
}

public enum CredentialStoreError: Error, Equatable, Sendable {
    case unexpectedStatus(Int32)
    case invalidData
}

#if canImport(Security)
import Security

/// Production store backed by the macOS Keychain (generic password items).
public struct KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "app.dropup.credentials") {
        self.service = service
    }

    public func password(for key: String) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
                throw CredentialStoreError.invalidData
            }
            return password
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }

    public func setPassword(_ password: String, for key: String) throws {
        let data = Data(password.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery(for: key) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = baseQuery(for: key)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialStoreError.unexpectedStatus(addStatus) }
        default:
            throw CredentialStoreError.unexpectedStatus(updateStatus)
        }
    }

    public func removePassword(for key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }

    /// Deletes every password this app stored, whatever server it was for.
    public func removeAllPasswords() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        // The older macOS keychain can stop after the first match, so repeat until nothing is left.
        for _ in 0..<50 {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw CredentialStoreError.unexpectedStatus(status) }
        }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
#endif
