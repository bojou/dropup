import AppKit
import Observation
import SwiftUI
import DropUpCore

/// Owns the menubar icon: draws its state, takes files dropped straight onto it, opens the popover
/// on click and a small menu on right-click.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: AppModel
    private let onOpenSettings: () -> Void
    private let onOpenBrowse: () -> Void
    private let onChooseFolder: () -> Void
    private let popover = NSPopover()
    private let badge = CALayer()
    /// Purple dot in the same corner: a new version is waiting. A failed upload's red dot takes its place when both apply.
    private let updateBadge = CALayer()
    /// Both dots are this wide (edge included) and have a thin white edge, so they stay visible on any menubar background.
    private static let dotSize: CGFloat = 10
    private static let dotEdge: CGFloat = 1
    private var clickAwayMonitor: Any?
    private var escapeMonitor: Any?
    /// The popover is open, as far as the icon's look goes: false from the moment it starts to close, while it fades.
    private var popoverOpen = false

    init(
        model: AppModel,
        onOpenSettings: @escaping () -> Void,
        onOpenBrowse: @escaping () -> Void,
        onChooseFolder: @escaping () -> Void
    ) {
        self.model = model
        self.onOpenSettings = onOpenSettings
        self.onOpenBrowse = onOpenBrowse
        self.onChooseFolder = onChooseFolder
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            // A transparent view over the button takes files dropped straight onto the icon.
            let dropView = StatusDropView(frame: button.bounds)
            dropView.autoresizingMask = [.width, .height]
            dropView.onHover = { [model] hovering in model.isDragOverIcon = hovering }
            dropView.onDrop = { [model] urls in model.upload(urls) }
            button.addSubview(dropView)

            button.wantsLayer = true
            for (layer, color) in [(badge, NSColor.systemRed), (updateBadge, NSColor.systemPurple)] {
                layer.backgroundColor = color.cgColor
                layer.frame = Self.dotFrame(in: button.bounds)
                layer.cornerRadius = Self.dotSize / 2
                layer.borderColor = NSColor.white.cgColor
                layer.borderWidth = Self.dotEdge
                layer.isHidden = true
                button.layer?.addSublayer(layer)
            }
        }

        let content = PopoverView(
            model: model,
            openSettings: { [weak self] in self?.openSettings() },
            openBrowse: { [weak self] in self?.openBrowse() },
            openChooseFolder: { [weak self] in self?.openChooseFolder() },
            openUpdate: { [weak self] in self?.openUpdate() }
        )
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        render()
    }

    /// The dot's place: its centre sits 7 pt in from the icon's top and right edges.
    private static func dotFrame(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.width - 7 - dotSize / 2, y: bounds.height - 7 - dotSize / 2, width: dotSize, height: dotSize)
    }

    /// The icon's rectangle in screen coordinates, or nil when it isn't on screen.
    var iconFrame: CGRect? {
        guard let window = statusItem.button?.window, window.isVisible else { return nil }
        return window.frame
    }

    var screen: NSScreen? { statusItem.button?.window?.screen }

    // MARK: Rendering

    /// Redraws whenever anything the icon depends on changes.
    private func render() {
        withObservationTracking {
            apply(state: model.menubarState, highlighted: model.isDragOverIcon || model.panelState != .hidden)
        } onChange: { [weak self] in
            Task { @MainActor in self?.render() }
        }
    }

    private func apply(state: MenubarState, highlighted: Bool) {
        guard let button = statusItem.button else { return }
        button.image = StatusIcon.image(for: state)
        button.appearsDisabled = false
        button.highlight(highlighted || popoverOpen)
        badge.isHidden = state != .failed
        let newVersion = model.updates.availableVersion
        updateBadge.isHidden = newVersion == nil || state == .failed

        switch state {
        case .idle:
            if let newVersion {
                button.toolTip = "DropUp \(newVersion) is available. Click to see it."
            } else {
                button.toolTip = model.config == nil ? "Click to set up DropUp" : "Drop files here to upload"
            }
        case .uploading(let fraction):
            let active = model.activity.active
            let name = model.preferences.hideRecentNames ? "" : " \(active.first?.fileName ?? "")"
            let more = active.count > 1 ? " (+\(active.count - 1) more)" : ""
            button.toolTip = "Uploading\(name)\(more): \(Int(fraction * 100))%"
        case .succeeded:
            button.toolTip = "Upload finished"
        case .failed:
            // With the list off there is nothing to open the popover for.
            button.toolTip = model.preferences.recentLimit > 0
                ? "An upload failed. Click to see why."
                : "An upload failed. Recent uploads is off, so it isn’t listed."
        }
    }

    // MARK: Clicks

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if model.needsOnboarding {
            model.onNeedsOnboarding?()
        } else if let button = statusItem.button {
            WindowOrderKeeper.shared.begin()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popoverOpen = true
            popover.contentViewController?.view.window?.makeKey()
            // After the popover is up and has the keyboard: activating raises the app's key window, and activating
            // first made that a Settings or Browse window hidden behind other apps instead of the popover.
            NSApp.activate()
            model.popoverVisibilityChanged(true)
            startWatchingForDismissal()
        }
    }

    /// `.transient` only closes the popover when this app is the active one, and a menubar app often
    /// isn't. So also close it on any click in another app, and on Escape.
    private func startWatchingForDismissal() {
        stopWatchingForDismissal()
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.popover.performClose(nil) }
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let closed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.popover.isShown else { return false }
                self.popover.performClose(nil)
                return true
            }
            return closed ? nil : event
        }
    }

    private func stopWatchingForDismissal() {
        if let clickAwayMonitor { NSEvent.removeMonitor(clickAwayMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        clickAwayMonitor = nil
        escapeMonitor = nil
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(MenuAction.item("Settings…", key: ",") { [weak self] in self?.openSettings() })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DropUp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        // Attaching the menu for one click is the supported way to show a menu on a status item.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    #if DEBUG
    /// For WindowOrderSelfTest: clicking a tile in the popover.
    func selfTestChoose(_ name: String) {
        switch name {
        case "settings": openSettings()
        case "browse": openBrowse()
        default: openChooseFolder()
        }
    }

    var popoverWindowForSelfTest: NSWindow? { popover.contentViewController?.view.window }
    var popoverShownForSelfTest: Bool { popover.isShown }
    /// Whether the icon looks pressed.
    var iconPressedForSelfTest: Bool { statusItem.button?.isHighlighted ?? false }
    /// Called when a window chosen in the popover is about to be built.
    var selfTestWindowStarting: (() -> Void)?
    #endif

    private func openSettings() {
        closePopoverForWindow()
        onOpenSettings()
    }

    private func openBrowse() {
        closePopoverForWindow()
        onOpenBrowse()
    }

    private func openChooseFolder() {
        closePopoverForWindow()
        onChooseFolder()
    }

    private func openUpdate() {
        closePopoverForWindow()
        model.updates.showAvailableUpdate()
    }

    /// Closes the popover for a window that opens in its place. Building the window keeps the app busy for a moment, and
    /// the popover's fade can't end before it has, so the icon lets go of its pressed look here rather than when the
    /// popover is gone.
    private func closePopoverForWindow() {
        WindowOrderKeeper.shared.begin()
        letGoOfIcon()
        popover.performClose(nil)
        #if DEBUG
        selfTestWindowStarting?()
        #endif
    }

    /// The icon stops looking pressed, on screen at once: the app may be busy for a moment after this.
    private func letGoOfIcon() {
        popoverOpen = false
        guard let button = statusItem.button else { return }
        button.highlight(model.isDragOverIcon || model.panelState != .hidden)
        button.display()
        CATransaction.flush()
    }

    func popoverWillClose(_ notification: Notification) {
        // When the popover goes, macOS hands the keyboard to another window of the app, and may bring it forward.
        WindowOrderKeeper.shared.begin()
        letGoOfIcon()
    }

    func popoverDidClose(_ notification: Notification) {
        WindowOrderKeeper.shared.begin()
        stopWatchingForDismissal()
        model.popoverVisibilityChanged(false)
        render()
    }
}

/// Sits over the status button. Accepts dragged files and passes plain clicks through to the button's action.
final class StatusDropView: NSView {
    var onHover: ((Bool) -> Void)?
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) {
        // The button's own action fires on mouse-up; clicks land here first, so forward them.
        superview?.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        superview?.rightMouseDown(with: event)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !Self.fileURLs(from: sender).isEmpty else { return [] }
        onHover?(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onHover?(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onHover?(false)
        let urls = Self.fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    static func fileURLs(from info: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}

/// Menu items that run a closure.
@MainActor
final class MenuAction: NSObject {
    private let run: () -> Void
    private init(_ run: @escaping () -> Void) { self.run = run }

    @objc private func fire() { run() }

    static func item(_ title: String, key: String = "", run: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: key)
        item.target = action
        // The menu item doesn't retain its target, so tie the action's lifetime to the item.
        item.representedObject = action
        return item
    }
}
