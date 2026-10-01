import Foundation

/// Persists the non-secret server configuration.
public protocol SettingsStore: Sendable {
    func loadServerConfig() -> ServerConfig?
    func saveServerConfig(_ config: ServerConfig) throws
    func clearServerConfig()
}

extension SettingsStore {
    /// Onboarding is shown until a valid config has been saved.
    public var needsOnboarding: Bool {
        guard let config = loadServerConfig() else { return true }
        return !config.isValid
    }
}

/// Production store backed by `UserDefaults`.
public final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    // UserDefaults is documented as thread-safe.
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "serverConfig") {
        self.defaults = defaults
        self.key = key
    }

    public func loadServerConfig() -> ServerConfig? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ServerConfig.self, from: data)
    }

    public func saveServerConfig(_ config: ServerConfig) throws {
        let data = try JSONEncoder().encode(config)
        defaults.set(data, forKey: key)
    }

    public func clearServerConfig() {
        defaults.removeObject(forKey: key)
    }
}
