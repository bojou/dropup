import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    // Created on first use, which is after the reinstall check in applicationDidFinishLaunching.
    private lazy var model = AppModel()
    private lazy var windows = WindowCoordinator(model: model)
    private var statusItem: StatusItemController?
    private var dropPanel: DropPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First, before anything reads settings: a reinstall must not inherit the old connection.
        InstallReset.reconcile()
        UNUserNotificationCenter.current().delegate = self
        let statusItem = StatusItemController(
            model: model,
            onOpenSettings: { [weak self] in self?.windows.showSettings() },
            onOpenBrowse: { [weak self] in self?.windows.showBrowse() },
            onChooseFolder: { [weak self] in self?.windows.showChooseFolder() }
        )
        self.statusItem = statusItem
        let dropPanel = DropPanelController(model: model, statusItem: statusItem)
        dropPanel.start()
        self.dropPanel = dropPanel

        model.onNeedsOnboarding = { [weak self] in self?.windows.showOnboarding() }
        if model.needsOnboarding {
            windows.showOnboarding()
        }
        model.shortcuts.start()
        #if DEBUG
        // CI's test of the windows (WindowOrderSelfTest.swift).
        if let helper = ProcessInfo.processInfo.environment["DROPUP_WINDOW_TEST"] {
            Task { @MainActor in exit(await WindowOrderSelfTest.run(helper: helper, model: model, windows: windows, status: statusItem)) }
        }
        #endif
    }

    func showSettings() {
        windows.showSettings()
    }

    // Uploads still running when DropUp quits are kept, so they can be resumed: write down where they got to.
    func applicationWillTerminate(_ notification: Notification) {
        model.flushRecent()
    }

    // The menubar icon keeps the app alive when the last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Launching DropUp again from Finder or Spotlight while it runs in the menubar opens its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
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
