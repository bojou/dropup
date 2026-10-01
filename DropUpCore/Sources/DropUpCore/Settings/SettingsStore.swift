import Foundation

/// Persists the non-secret server configuration.
public protocol SettingsStore: Sendable {
    func loadServerConfig() -> ServerConfig?
    func saveServerConfig(_ config: ServerConfig) throws
    func clearServerConfig()
    func loadPreferences() -> Preferences
    func savePreferences(_ preferences: Preferences) throws
}

/// App behavior settings from the General tab. Everything has a sensible default.
public struct Preferences: Codable, Equatable, Sendable {
    public var conflictPolicy: ConflictPolicy
    public var notifyWhenDone: Bool
    public var playSound: Bool
    /// How many finished uploads the popover's Recent list keeps.
    public var recentLimit: Int

    public static let recentLimitOptions = [5, 10, 20]

    public init(
        conflictPolicy: ConflictPolicy = .keepBoth,
        notifyWhenDone: Bool = true,
        playSound: Bool = false,
        recentLimit: Int = 10
    ) {
        self.conflictPolicy = conflictPolicy
        self.notifyWhenDone = notifyWhenDone
        self.playSound = playSound
        self.recentLimit = recentLimit
    }

    // Decodes field by field so preferences saved by an older version keep working
    // when new fields are added.
    public init(from decoder: any Decoder) throws {
        let defaults = Preferences()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conflictPolicy = (try? container.decode(ConflictPolicy.self, forKey: .conflictPolicy)) ?? defaults.conflictPolicy
        notifyWhenDone = (try? container.decode(Bool.self, forKey: .notifyWhenDone)) ?? defaults.notifyWhenDone
        playSound = (try? container.decode(Bool.self, forKey: .playSound)) ?? defaults.playSound
        recentLimit = (try? container.decode(Int.self, forKey: .recentLimit)) ?? defaults.recentLimit
    }
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

    private let preferencesKey: String

    public init(defaults: UserDefaults = .standard, key: String = "serverConfig", preferencesKey: String = "preferences") {
        self.defaults = defaults
        self.key = key
        self.preferencesKey = preferencesKey
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

    public func loadPreferences() -> Preferences {
        guard let data = defaults.data(forKey: preferencesKey),
              let preferences = try? JSONDecoder().decode(Preferences.self, from: data)
        else { return Preferences() }
        return preferences
    }

    public func savePreferences(_ preferences: Preferences) throws {
        defaults.set(try JSONEncoder().encode(preferences), forKey: preferencesKey)
    }
}
