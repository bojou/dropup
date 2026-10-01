import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private lazy var windows = WindowCoordinator(model: model)
    private var statusItem: StatusItemController?
    private var dropPanel: DropPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = StatusItemController(model: model, onOpenSettings: { [weak self] in self?.windows.showSettings() })
        self.statusItem = statusItem
        let dropPanel = DropPanelController(model: model, statusItem: statusItem)
        dropPanel.start()
        self.dropPanel = dropPanel

        model.onNeedsOnboarding = { [weak self] in self?.windows.showOnboarding() }
        if model.needsOnboarding {
            windows.showOnboarding()
        }
    }
}
