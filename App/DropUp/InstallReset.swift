import AppKit
import ServiceManagement
import DropUpCore

/// Makes "remove the app, install it again" start from scratch.
///
/// Tools like AppCleaner delete the app's files but leave the Keychain alone, and the system's preferences
/// cache can hand old settings back. So the app keeps a marker file in its own Application Support folder,
/// which does get removed with it. Launching without that marker means this is a new install: anything
/// left over (saved connection, Keychain password, host keys, login item) is cleared. See `FreshInstall`.
@MainActor
enum InstallReset {
    /// Run once at launch, before any settings are read.
    static func reconcile() {
        let marker = InstallMarker(directory: supportDirectory)
        let defaults = UserDefaults.standard
        let settings = UserDefaultsSettingsStore()
        let config = settings.loadServerConfig()

        let state = FreshInstall.reconcile(marker: marker, defaults: defaults, hasSettings: config != nil, wipe: wipe)
        guard state == .legacySettings, let config else { return }

        // Settings from a version before this check existed. An update and a reinstall look the same, so ask.
        let alert = NSAlert()
        alert.messageText = "Keep your DropUp settings?"
        alert.informativeText = "DropUp found a saved connection (\(config.transferProtocol.rawValue.uppercased()) · \(config.host)) from an earlier version. If you just reinstalled DropUp and want a clean start, choose Start Fresh."
        alert.addButton(withTitle: "Keep Settings")
        alert.addButton(withTitle: "Start Fresh")
        let keep = WindowOrderKeeper.shared.whileBlocked {
            NSApp.activate()
            return alert.runModal() == .alertFirstButtonReturn
        }
        if keep {
            FreshInstall.adoptLegacy(marker: marker, defaults: defaults)
        } else {
            FreshInstall.startFresh(marker: marker, defaults: defaults, wipe: wipe)
        }
    }

    private static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.dropup.DropUp", isDirectory: true)
    }

    /// Everything DropUp keeps outside its own folder: preferences, Keychain passwords and the login item.
    private static func wipe() {
        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
        }
        try? KeychainCredentialStore().removeAllPasswords()
        try? SMAppService.mainApp.unregister()
    }
}
