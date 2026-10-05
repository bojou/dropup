import Foundation

/// Persists the non-secret server configuration.
public protocol SettingsStore: Sendable {
    func loadServerConfig() -> ServerConfig?
    func saveServerConfig(_ config: ServerConfig) throws
    func clearServerConfig()
    func loadPreferences() -> Preferences
    func savePreferences(_ preferences: Preferences) throws
    /// The credential keys of servers replaced in Settings whose Keychain password is still kept (see `RetiredPasswords`).
    func loadRetiredServerKeys() -> Set<String>
    func saveRetiredServerKeys(_ keys: Set<String>)
}

/// App behavior settings from the General tab. Everything has a sensible default.
public struct Preferences: Codable, Equatable, Sendable {
    public var conflictPolicy: ConflictPolicy
    public var notifyWhenDone: Bool
    public var playSound: Bool
    /// How many finished uploads the popover's Recent list keeps. Zero keeps none (see `RecentPolicy`).
    public var recentLimit: Int
    /// When the Recent list empties itself. The defaults keep it as it always was: it lasts until DropUp quits.
    public var recentClearMode: RecentClearMode
    /// For `RecentClearMode.custom`: this many of `recentClearUnit`.
    public var recentClearAmount: Int
    public var recentClearUnit: RecentClearUnit
    /// Shows "Uploaded file" in the Recent list and in notifications instead of the file's name.
    public var hideRecentNames: Bool
    /// The global keyboard shortcuts (Settings > Shortcuts). All off until the user turns one on.
    public var shortcuts: ShortcutSettings
    /// The size of the drop panel and of the popover's drop area. Preferences saved before it existed get the standard size.
    public var dropZoneSize: DropZoneSize

    public static let recentLimitOptions = [5, 10, 25, 50]
    public static let recentClearAmountRange = 1...999

    public init(
        conflictPolicy: ConflictPolicy = .keepBoth,
        notifyWhenDone: Bool = true,
        playSound: Bool = false,
        recentLimit: Int = 10,
        recentClearMode: RecentClearMode = .onQuit,
        recentClearAmount: Int = 2,
        recentClearUnit: RecentClearUnit = .hours,
        hideRecentNames: Bool = false,
        shortcuts: ShortcutSettings = ShortcutSettings(),
        dropZoneSize: DropZoneSize = .standard
    ) {
        self.conflictPolicy = conflictPolicy
        self.notifyWhenDone = notifyWhenDone
        self.playSound = playSound
        self.recentLimit = recentLimit
        self.recentClearMode = recentClearMode
        self.recentClearAmount = recentClearAmount
        self.recentClearUnit = recentClearUnit
        self.hideRecentNames = hideRecentNames
        self.shortcuts = shortcuts
        self.dropZoneSize = dropZoneSize
    }

    /// The counts the Keep picker offers: the fixed ones, plus the saved count when an earlier version let it be
    /// something else (such as 20). Off is not in the list; it is zero.
    public var recentLimitChoices: [Int] {
        Array(Set(Self.recentLimitOptions + (recentLimit > 0 ? [recentLimit] : []))).sorted()
    }

    /// How long finished uploads stay listed, or nil if the clock never removes them.
    public var recentLifetime: TimeInterval? {
        switch recentClearMode {
        case .onQuit, .never: nil
        case .hour: 3_600
        case .day: 86_400
        case .week: 604_800
        case .custom:
            Double(min(max(recentClearAmount, Self.recentClearAmountRange.lowerBound), Self.recentClearAmountRange.upperBound)) * recentClearUnit.seconds
        }
    }

    public var recentPolicy: RecentPolicy {
        RecentPolicy(limit: max(recentLimit, 0), lifetime: recentLifetime)
    }

    /// Whether the Recent list is kept between launches. Anything but "when DropUp quits" asks for that.
    public var recentSurvivesQuit: Bool { recentClearMode != .onQuit }

    // Decodes field by field so preferences saved by an older version keep working
    // when new fields are added.
    public init(from decoder: any Decoder) throws {
        let defaults = Preferences()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conflictPolicy = (try? container.decode(ConflictPolicy.self, forKey: .conflictPolicy)) ?? defaults.conflictPolicy
        notifyWhenDone = (try? container.decode(Bool.self, forKey: .notifyWhenDone)) ?? defaults.notifyWhenDone
        playSound = (try? container.decode(Bool.self, forKey: .playSound)) ?? defaults.playSound
        recentLimit = (try? container.decode(Int.self, forKey: .recentLimit)) ?? defaults.recentLimit
        recentClearMode = (try? container.decode(RecentClearMode.self, forKey: .recentClearMode)) ?? defaults.recentClearMode
        recentClearAmount = (try? container.decode(Int.self, forKey: .recentClearAmount)) ?? defaults.recentClearAmount
        recentClearUnit = (try? container.decode(RecentClearUnit.self, forKey: .recentClearUnit)) ?? defaults.recentClearUnit
        hideRecentNames = (try? container.decode(Bool.self, forKey: .hideRecentNames)) ?? defaults.hideRecentNames
        shortcuts = (try? container.decode(ShortcutSettings.self, forKey: .shortcuts)) ?? defaults.shortcuts
        dropZoneSize = (try? container.decode(DropZoneSize.self, forKey: .dropZoneSize)) ?? defaults.dropZoneSize
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
    private let retiredKeysKey: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = "serverConfig",
        preferencesKey: String = "preferences",
        retiredKeysKey: String = "retiredServerKeys"
    ) {
        self.defaults = defaults
        self.key = key
        self.preferencesKey = preferencesKey
        self.retiredKeysKey = retiredKeysKey
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

    public func loadRetiredServerKeys() -> Set<String> {
        Set(defaults.stringArray(forKey: retiredKeysKey) ?? [])
    }

    public func saveRetiredServerKeys(_ keys: Set<String>) {
        if keys.isEmpty {
            defaults.removeObject(forKey: retiredKeysKey)
        } else {
            defaults.set(keys.sorted(), forKey: retiredKeysKey)
        }
    }
}
