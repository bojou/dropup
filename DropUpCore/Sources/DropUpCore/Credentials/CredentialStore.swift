import Foundation

/// Stores secrets (passwords) keyed by `ServerConfig.credentialKey`.
public protocol CredentialStore: Sendable {
    func password(for key: String) throws -> String?
    func setPassword(_ password: String, for key: String) throws
    func removePassword(for key: String) throws
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
