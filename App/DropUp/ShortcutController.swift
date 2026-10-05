import AppKit
import DropUpCore
import Observation

/// Runs the global shortcuts: keeps their keys registered as the settings say, does what a key press asks for, and walks
/// the user through the macOS permissions a shortcut needs when it is switched on.
///
/// Deciding what to upload is DropUpCore's job (`QuickUploadPlanner`, `ClipboardPlanner`, `ScreenshotPicker`); this
/// only reads the Mac for them and hands the result to the upload queue.
@MainActor
@Observable
final class ShortcutController {
    /// The actions whose key could not be taken, for the Settings tab to say so.
    private(set) var failures: [ShortcutAction: HotKeyFailure] = [:]
    /// Whether macOS lets DropUp read the Finder selection. Only looked up while Quick Upload is on.
    private(set) var finderAccess = AutomationAccess.unknown

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let coordinator: ShortcutCoordinator

    /// Folders whose permission has been explained already, so the explanation comes once.
    private static let explainedFoldersKey = "screenshotFoldersExplained"

    init(model: AppModel) {
        self.model = model
        coordinator = ShortcutCoordinator(registrar: CarbonHotKeys()) { [weak model] action in
            model?.shortcuts.perform(action)
        }
    }

    var settings: ShortcutSettings { model.preferences.shortcuts }

    /// Registers the keys of the actions that are on. Called once DropUp has started.
    func start() {
        sync()
        refreshAccess()
    }

    // MARK: Settings

    func setOn(_ isOn: Bool, for action: ShortcutAction) {
        change(action) { $0.isOn = isOn }
        guard isOn else { return }
        switch action {
        case .quickUpload: Task { await askForFinderAccess() }
        case .uploadScreenshot: Task { await askForScreenshotFolder() }
        case .uploadClipboard: break
        }
    }

    func setCombo(_ combo: KeyCombo, for action: ShortcutAction) {
        change(action) { $0.combo = combo }
    }

    func reset(_ action: ShortcutAction) {
        change(action) { $0.combo = action.defaultCombo }
    }

    /// While the recorder listens, pressing a shortcut records it instead of running it.
    func beginRecording() {
        coordinator.pause()
    }

    func endRecording() {
        coordinator.resume()
        failures = coordinator.failures
    }

    /// Looks up the Finder permission again, for when the user may have changed it in System Settings.
    func refreshAccess() {
        guard settings[.quickUpload].isOn else { return }
        Task { finderAccess = await Task.detached { AutomationAccess.current(asking: false) }.value }
    }

    private func change(_ action: ShortcutAction, _ edit: (inout Shortcut) -> Void) {
        model.updatePreferences { edit(&$0.shortcuts[action]) }
        sync()
    }

    private func sync() {
        coordinator.apply(model.preferences.shortcuts)
        failures = coordinator.failures
    }

    // MARK: Pressing a key

    func perform(_ action: ShortcutAction) {
        guard !model.needsOnboarding else {
            notify(action, ShortcutNotice.noServer)
            return
        }
        switch action {
        case .quickUpload:
            run(QuickUploadPlanner.plan(FinderSelection()), for: action)
        case .uploadClipboard:
            run(ClipboardPlanner.plan(SystemClipboard(), now: Date()), for: action)
        case .uploadScreenshot:
            let folder = ScreenshotFolder.location()
            Task {
                let found = await Task.detached { Result { try ScreenshotFolder.candidates(in: folder) } }.value
                switch found {
                case .success(let candidates): run(ScreenshotPicker.plan(candidates, now: Date()), for: action)
                case .failure: notify(action, ShortcutNotice.screenshotFolderUnreadable)
                }
            }
        }
    }

    private func run(_ outcome: ShortcutOutcome, for action: ShortcutAction) {
        switch outcome {
        case .upload(let urls):
            model.upload(urls)
        case .stage(let name, let data):
            if !model.uploadStaged(name: name, data: data) { notify(action, ShortcutNotice.clipboardNotSaved) }
        case .notice(let text):
            notify(action, text)
        }
    }

    /// Says why a key press did nothing, the way everything else in DropUp speaks up: a notification, and the lower
    /// sound if sounds are on.
    private func notify(_ action: ShortcutAction, _ text: String) {
        Notifier.post(title: action.title, body: text)
        if model.preferences.playSound { NSSound(named: "Basso")?.play() }
    }

    // MARK: Permissions

    /// Quick Upload asks Finder for its selection, which macOS lets an app do only with the user's say-so. It is asked
    /// for here, when the switch goes on, and not at the first key press, so the prompt isn't a surprise.
    private func askForFinderAccess() async {
        var access = await Task.detached { AutomationAccess.current(asking: false) }.value
        finderAccess = access
        switch access {
        case .granted:
            return
        case .denied:
            break
        case .notAsked, .unknown:
            let go = ShortcutAlerts.confirm(
                title: "Allow DropUp to read the Finder selection?",
                message: "macOS asks for your permission next. DropUp only looks at what is selected in Finder when you press the shortcut.",
                button: "Continue"
            )
            guard go else {
                change(.quickUpload) { $0.isOn = false }
                return
            }
            access = await Task.detached { AutomationAccess.current(asking: true) }.value
            finderAccess = access
        }
        if access == .denied {
            ShortcutAlerts.offerSettings(
                title: "DropUp can’t read the Finder selection",
                message: "Switch DropUp on under Finder in System Settings > Privacy & Security > Automation.",
                opening: ShortcutAlerts.automationSettings
            )
        }
    }

    /// The Desktop, Documents and Downloads folders are ones macOS keeps behind a permission. Looking in the screenshot
    /// folder now, with an explanation first, brings that prompt up here and not at the first key press.
    private func askForScreenshotFolder() async {
        let folder = ScreenshotFolder.location()
        var explained = UserDefaults.standard.stringArray(forKey: Self.explainedFoldersKey) ?? []
        if ScreenshotFolder.needsPermission(folder), !explained.contains(folder.path) {
            let go = ShortcutAlerts.confirm(
                title: "Allow DropUp to look in \(folder.lastPathComponent)?",
                message: "macOS may ask for your permission next. DropUp only looks for the newest screenshot when you press the shortcut.",
                button: "Continue"
            )
            guard go else {
                change(.uploadScreenshot) { $0.isOn = false }
                return
            }
            explained.append(folder.path)
            UserDefaults.standard.set(explained, forKey: Self.explainedFoldersKey)
        }
        let readable = await Task.detached { (try? ScreenshotFolder.candidates(in: folder)) != nil }.value
        if !readable {
            ShortcutAlerts.offerSettings(
                title: "DropUp can’t read the \(folder.lastPathComponent) folder",
                message: "Allow it in System Settings > Privacy & Security > Files & Folders, then try the shortcut.",
                opening: ShortcutAlerts.filesAndFoldersSettings
            )
        }
    }
}

/// The two alerts around a permission: the explanation before macOS asks, and the way to System Settings after a no.
@MainActor
enum ShortcutAlerts {
    static let automationSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
    static let filesAndFoldersSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!

    /// Returns whether the user chose to go on.
    static func confirm(title: String, message: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return WindowOrderKeeper.shared.whileBlocked {
            NSApp.activate()
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    static func offerSettings(title: String, message: String, opening url: URL) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        let open = WindowOrderKeeper.shared.whileBlocked {
            NSApp.activate()
            return alert.runModal() == .alertFirstButtonReturn
        }
        if open { NSWorkspace.shared.open(url) }
    }
}
