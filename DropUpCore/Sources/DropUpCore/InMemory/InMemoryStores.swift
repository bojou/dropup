import Foundation

/// In-memory stores for unit tests and SwiftUI previews.
public final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var config: ServerConfig?

    public init(config: ServerConfig? = nil) {
        self.config = config
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
