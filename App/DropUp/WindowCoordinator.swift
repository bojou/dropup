import AppKit
import SwiftUI

/// Opens the Onboarding and Settings windows.
///
/// DropUp normally lives in the menubar only (LSUIElement). While one of its windows is open it also
/// gets a Dock icon, so the window is easy to find again after switching to another app. Closing the
/// last window takes the Dock icon away again; the menubar icon stays.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?

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

    private func makeWindow<Content: View>(title: String, content: Content) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // The first activation after the Dock icon appears can land before the switch has settled.
        Task { @MainActor in
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        // Closing Settings, however it happens, throws away unsaved edits: the next open starts from what is saved.
        if closing === settingsWindow { settingsWindow = nil }
        let anotherIsOpen = [onboardingWindow, settingsWindow].contains { window in
            guard let window else { return false }
            return window !== closing && window.isVisible
        }
        if !anotherIsOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
