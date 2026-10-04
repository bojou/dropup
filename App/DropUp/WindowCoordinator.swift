import AppKit
import SwiftUI
import DropUpCore

/// Opens the Onboarding, Settings, Browse and Change Folder windows.
///
/// DropUp lives in the menubar only (LSUIElement): no Dock icon and no entry in the app switcher, also while one of
/// these windows is open. A window can end up behind other windows. The way back to it is in the menubar: the icon
/// brings the setup window to the front until setup is done, and Settings, Browse and Change Folder open from the
/// popover, which brings an open one forward instead of making a second.
///
/// Only the window the person asked for comes forward. macOS would bring more: it raises the app's last key window
/// when the app is activated, and when the window with the keyboard closes it gives the keyboard to the next one and
/// brings that forward, however many other apps' windows it sat under. So the popover is shown before the app is
/// activated (see `StatusItemController.togglePopover`), and a window that is covered by other apps is not eligible
/// for the keyboard while another one closes (`holdBackCoveredWindows`).
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var browseWindow: NSWindow?
    private var browseModel: BrowseModel?
    private var chooseWindow: NSWindow?
    private var chooseModel: BrowseModel?

    #if DEBUG
    /// For WindowOrderSelfTest: the windows that are open, by name.
    var windowsForSelfTest: [String: NSWindow?] {
        ["onboarding": onboardingWindow, "settings": settingsWindow, "browse": browseWindow, "choose": chooseWindow]
    }
    #endif

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
        let window = DropUpWindow(contentViewController: NSHostingController(rootView: content))
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
        (window as? DropUpWindow)?.stopHoldingBack()
        Self.raise(window)
        // The activation can land after the window was ordered in, so ask once more.
        Task { @MainActor in Self.raise(window) }
    }

    /// Keeps the windows that are open but covered by other apps from taking over when `closing` goes, which would
    /// bring them to the front. Windows in plain view are left as they are and still get the keyboard.
    private func holdBackCoveredWindows(except closing: NSWindow) {
        let others = [onboardingWindow, settingsWindow, browseWindow, chooseWindow]
            .compactMap { $0 as? DropUpWindow }
            .filter { $0 !== closing && $0.isVisible }
        guard !others.isEmpty else { return }
        let stack = Self.windowsOnScreen()
        // The window server counts from the top left of the main screen, AppKit from the bottom left.
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        for window in others {
            let frame = CGRect(x: window.frame.minX, y: screenHeight - window.frame.maxY, width: window.frame.width, height: window.frame.height)
            if WindowCover.isCovered(windowNumber: window.windowNumber, frame: frame, ownProcess: getpid(), stack: stack) {
                window.holdBack(for: Self.holdBackTime)
            }
        }
    }

    /// Long enough for macOS to be done choosing which window gets the keyboard.
    private static let holdBackTime: TimeInterval = 0.6

    /// The windows on screen, front to back. Only ordinary windows: the menubar, the Dock and other layers of the
    /// window server are not windows that cover anything of ours. Names and contents are not read.
    private static func windowsOnScreen() -> [StackedWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let number = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let owner = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return StackedWindow(number: number, ownerProcess: owner, frame: frame)
        }
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
        holdBackCoveredWindows(except: closing)
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

/// A window that can be told not to take over for a moment. macOS skips a window that cannot become key or main when it
/// looks for the one to give the keyboard to after another window closes.
final class DropUpWindow: NSWindow {
    private var heldBackUntil = Date.distantPast

    func holdBack(for seconds: TimeInterval) {
        heldBackUntil = Date().addingTimeInterval(seconds)
    }

    func stopHoldingBack() {
        heldBackUntil = .distantPast
    }

    private var isHeldBack: Bool { Date() < heldBackUntil }

    override var canBecomeKey: Bool { !isHeldBack && super.canBecomeKey }
    override var canBecomeMain: Bool { !isHeldBack && super.canBecomeMain }
}
