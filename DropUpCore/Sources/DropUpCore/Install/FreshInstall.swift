import Foundation

/// A small file in the app's own Application Support folder. Removing the app with a tool such as
/// AppCleaner deletes that folder, and this file with it, while UserDefaults and the Keychain can
/// survive. Its absence next to leftover settings is how a reinstall is recognised.
public struct InstallMarker: Sendable {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("install-id")
    }

    /// The stored token, or nil if the file doesn't exist. A file that exists but can't be read gives
    /// an empty token, so a hiccup is never mistaken for a missing file.
    public func read() -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func write(_ token: String) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(token.utf8).write(to: fileURL, options: .atomic)
    }
}

public enum InstallState: Equatable, Sendable {
    /// Same install as last time. Nothing to do.
    case continuing
    /// Settings exist from a version that predates the marker. It can't be told whether this is an
    /// update or a reinstall, so the caller asks, then calls `adoptLegacy` or `startFresh`.
    case legacySettings
    /// No trace of an earlier install, or a reinstall with leftovers. Leftovers have been wiped.
    case fresh
}

/// Makes "delete the app, install it again" start from scratch. AppCleaner and similar tools remove the
/// app's files but leave Keychain items, and the preferences cache can bring old settings back.
public enum FreshInstall {
    static let tokenKey = "installToken"

    /// - Parameters:
    ///   - markerToken: What the marker file holds (nil if there is no file).
    ///   - defaultsToken: What the preferences remember of the marker.
    ///   - hasSettings: Whether a saved server connection exists.
    public static func decide(markerToken: String?, defaultsToken: String?, hasSettings: Bool) -> InstallState {
        switch (markerToken, defaultsToken) {
        case (nil, nil): hasSettings ? .legacySettings : .fresh
        case (nil, .some(_)): .fresh // the app's files are gone but preferences came back: a reinstall
        case (.some(_), _): .continuing
        }
    }

    /// Looks at the marker and the preferences. A fresh install is wiped and recorded right away; for
    /// `.legacySettings` nothing is changed yet.
    public static func reconcile(
        marker: InstallMarker,
        defaults: UserDefaults,
        hasSettings: Bool,
        wipe: () -> Void
    ) -> InstallState {
        let markerToken = marker.read()
        let defaultsToken = defaults.string(forKey: tokenKey)
        let state = decide(markerToken: markerToken, defaultsToken: defaultsToken, hasSettings: hasSettings)
        switch state {
        case .continuing:
            // Repair preferences that lost the token (reset by hand) so they match the marker again.
            if let markerToken, !markerToken.isEmpty, defaultsToken != markerToken {
                defaults.set(markerToken, forKey: tokenKey)
            }
        case .fresh:
            startFresh(marker: marker, defaults: defaults, wipe: wipe)
        case .legacySettings:
            break
        }
        return state
    }

    /// Records this install and keeps whatever settings exist.
    public static func adoptLegacy(marker: InstallMarker, defaults: UserDefaults) {
        let token = UUID().uuidString
        guard (try? marker.write(token)) != nil else { return }
        defaults.set(token, forKey: tokenKey)
    }

    /// Wipes every leftover and records this install.
    public static func startFresh(marker: InstallMarker, defaults: UserDefaults, wipe: () -> Void) {
        let token = UUID().uuidString
        // Write the marker first. If it can't be written, wiping would repeat on every launch.
        guard (try? marker.write(token)) != nil else { return }
        wipe()
        defaults.set(token, forKey: tokenKey)
    }
}
