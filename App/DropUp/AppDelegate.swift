import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    // Created on first use, which is after the install check in applicationDidFinishLaunching.
    private lazy var model = AppModel()
    private lazy var windows = WindowCoordinator(model: model)
    private var statusItem: StatusItemController?
    private var dropPanel: DropPanelController?

    // False while the install offer is on screen: nothing else may start (or read settings) before it.
    private var started = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SelfInstall.mightBeOnDiskImage else {
            start()
            return
        }
        // Opened from inside the disk image: offer to install, and carry on normally only if declined.
        Task { @MainActor in
            if await SelfInstall.offerIfRunningFromDiskImage() { return }
            start()
        }
    }

    private func start() {
        started = true
        // First, before anything reads settings: a reinstall must not inherit the old connection.
        InstallReset.reconcile()
        UNUserNotificationCenter.current().delegate = self
        let statusItem = StatusItemController(model: model, onOpenSettings: { [weak self] in self?.windows.showSettings() })
        self.statusItem = statusItem
        let dropPanel = DropPanelController(model: model, statusItem: statusItem)
        dropPanel.start()
        self.dropPanel = dropPanel

        model.onNeedsOnboarding = { [weak self] in self?.windows.showOnboarding() }
        Task { @MainActor in
            // First thing after installing: tidy up the mounted DMG, then start setup.
            await InstallerCleanup.offerIfNeeded()
            if model.needsOnboarding {
                windows.showOnboarding()
            }
        }
    }

    func showSettings() {
        guard started else { return }
        windows.showSettings()
    }

    // The menubar icon keeps the app alive when the last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Launching DropUp again from Finder or Spotlight while it runs in the menubar opens its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if started, !flag {
            if model.needsOnboarding { windows.showOnboarding() } else { windows.showSettings() }
        }
        return true
    }

    // An accessory app is never "frontmost", but still show the banner if it happens to be.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}
