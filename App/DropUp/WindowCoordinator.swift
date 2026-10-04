import AppKit
import SwiftUI
import DropUpCore

/// Opens the Onboarding, Settings, Browse and Change Folder windows.
///
/// DropUp lives in the menubar only (LSUIElement): no Dock icon and no entry in the app switcher, also while one of
/// these windows is open. A window can end up behind other windows. The way back to it is in the menubar: the icon
/// brings the setup window to the front until setup is done, and Settings, Browse and Change Folder open from the
/// popover, which brings an open one forward instead of making a second.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var browseWindow: NSWindow?
    private var browseModel: BrowseModel?
    private var chooseWindow: NSWindow?
    private var chooseModel: BrowseModel?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(model: model) { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            }
            onboardingWindow = makeWindow(title: "Welcome to DropUp", content: view)
        }
        present(onboardingWindow)
    }

    func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(model: model) { [weak self] in self?.settingsWindow?.close() }
            settingsWindow = makeWindow(title: "DropUp Settings", content: view)
        }
        present(settingsWindow)
    }

    /// The window for browsing the server and dropping files into its folders. One at a time.
    func showBrowse() {
        if browseWindow == nil {
            guard let browse = model.makeBrowseModel() else { return }
            browseModel = browse
            model.onUploadSucceeded = { [weak browse] remotePath in
                // A file that just landed in the folder on screen should appear without a manual reload.
                guard let browse, RemotePath.parent(of: remotePath) == browse.path, !browse.isLoading else { return }
                browse.reload()
            }
            let window = makeWindow(title: "Browse \(browse.serverName)", content: BrowseView(model: model, browse: browse))
            window.styleMask.insert([.resizable, .miniaturizable])
            window.setContentSize(BrowseView.idealSize)
            window.contentMinSize = BrowseView.minimumSize
            window.center()
            browseWindow = window
        }
        present(browseWindow)
    }

    /// Change Folder: the Browse view with nothing that changes files, and a button that makes the folder on screen
    /// the upload folder. One at a time.
    func showChooseFolder() {
        if chooseWindow == nil {
            guard let browse = model.makeBrowseModel(purpose: .chooseFolder) else { return }
            chooseModel = browse
            let view = BrowseView(model: model, browse: browse, finishChoosing: { [weak self] in self?.chooseWindow?.close() })
            let window = makeWindow(title: "Choose Upload Folder", content: view)
            window.styleMask.insert([.resizable, .miniaturizable])
            window.setContentSize(BrowseView.chooserSize)
            window.contentMinSize = BrowseView.minimumSize
            window.center()
            chooseWindow = window
        }
        present(chooseWindow)
    }

    private func makeWindow<Content: View>(title: String, content: Content) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Opens on the desktop in use, not on the one the window was left on.
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        return window
    }

    /// Brings the window to the front, gives it the keyboard and takes it out of the minimized state.
    private func present(_ window: NSWindow?) {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        Self.raise(window)
        // The activation can land after the window was ordered in, so ask once more.
        Task { @MainActor in Self.raise(window) }
    }

    private static func raise(_ window: NSWindow) {
        // Deprecated since macOS 14, but the plain `activate()` is only a request that macOS can ignore, and for an app
        // without a Dock icon it often does. This form takes the keyboard.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Puts the window in front even when macOS has not made DropUp the active app yet.
        window.orderFrontRegardless()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        // Closing Settings, however it happens, throws away unsaved edits: the next open starts from what is saved.
        if closing === settingsWindow { settingsWindow = nil }
        if closing === browseWindow {
            browseWindow = nil
            browseModel?.close()
            browseModel = nil
            model.onUploadSucceeded = nil
            // Whatever was dragged out has long been copied to where it was dropped.
            let export = model.dragExport
            Task { await export.removeFetchedFiles() }
        }
        if closing === chooseWindow {
            chooseWindow = nil
            chooseModel?.close()
            chooseModel = nil
        }
    }
}
