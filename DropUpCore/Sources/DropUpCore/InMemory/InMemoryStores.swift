import Foundation

/// In-memory stores for unit tests and SwiftUI previews.
public final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var config: ServerConfig?
    private var preferences: Preferences

    public init(config: ServerConfig? = nil, preferences: Preferences = Preferences()) {
        self.config = config
        self.preferences = preferences
    }

    public func loadServerConfig() -> ServerConfig? {
        lock.withLock { config }
    }

    public func saveServerConfig(_ config: ServerConfig) throws {
        lock.withLock { self.config = config }
    }

    public func clearServerConfig() {
        lock.withLock { config = nil }
    }

    public func loadPreferences() -> Preferences {
        lock.withLock { preferences }
    }

    public func savePreferences(_ preferences: Preferences) throws {
        lock.withLock { self.preferences = preferences }
    }
}

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [String: String]

    public init(passwords: [String: String] = [:]) {
        self.passwords = passwords
    }

    public func password(for key: String) throws -> String? {
        lock.withLock { passwords[key] }
    }

    public func setPassword(_ password: String, for key: String) throws {
        lock.withLock { passwords[key] = password }
    }

    public func removePassword(for key: String) throws {
        lock.withLock { _ = passwords.removeValue(forKey: key) }
    }
}

public final class InMemoryHostKeyStore: HostKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String]

    public init(keys: [String: String] = [:]) {
        self.keys = keys
    }

    public func trustedKey(for hostID: String) -> String? {
        lock.withLock { keys[hostID] }
    }

    public func trust(_ key: String, for hostID: String) {
        lock.withLock { keys[hostID] = key }
    }

    public func forget(hostID: String) {
        lock.withLock { _ = keys.removeValue(forKey: hostID) }
    }
}
