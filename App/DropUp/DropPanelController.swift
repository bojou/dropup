import AppKit
import SwiftUI
import DropUpCore

/// The large drop target that springs open under the menubar icon when a dragged file gets close.
///
/// How it works: global mouse monitors watch for a drag that carries file URLs (the drag pasteboard's
/// change count moves when any app starts a drag). Once the pointer comes within
/// `DropZoneGeometry.proximityRadius` of the icon, a borderless floating panel opens below it. The panel
/// is a real drag destination, so dropping on it uploads. It closes when the drag leaves, ends or is cancelled.
/// Its size is `DropZoneGeometry.panelSize`, the single constant to tune.
@MainActor
final class DropPanelController {
    private let model: AppModel
    private let statusItem: StatusItemController
    private var panel: NSPanel?
    /// Where the visible card sits (the window is a little larger, for the shadow).
    private var cardFrame: CGRect = .zero
    private var monitors: [Any] = []
    private var pollTimer: Timer?

    private var pasteboardBaseline = NSPasteboard(name: .drag).changeCount
    private var isFileDrag = false
    private var mouseUpTicks = 0
    private var hideGeneration = 0

    init(model: AppModel, statusItem: StatusItemController) {
        self.model = model
        self.statusItem = statusItem
    }

    func start() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        // Global monitors see events aimed at other apps (Finder, a browser), which is where drags start.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.mouse(type, at: NSEvent.mouseLocation) }
        }) {
            monitors.append(global)
        }
    }

    // MARK: Mouse tracking

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint) {
        switch type {
        case .leftMouseDown:
            pasteboardBaseline = NSPasteboard(name: .drag).changeCount
            isFileDrag = false
        case .leftMouseDragged:
            if !isFileDrag { isFileDrag = dragCarriesFiles() }
            if isFileDrag { evaluate(point) }
        case .leftMouseUp:
            isFileDrag = false
            // If the drop lands on the panel it closes itself. Otherwise close it now.
            if model.panelState == .open { hide() }
        default:
            break
        }
    }

    private func dragCarriesFiles() -> Bool {
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != pasteboardBaseline else { return false }
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    private func evaluate(_ point: CGPoint) {
        guard let iconFrame = statusItem.iconFrame else { return }
        if model.panelState == .hidden {
            if DropZoneGeometry.isNearIcon(point, iconFrame: iconFrame) {
                show(iconFrame: iconFrame)
            }
        } else if !DropZoneGeometry.shouldStayOpen(point, iconFrame: iconFrame, panelFrame: cardFrame) {
            hide()
        }
    }

    // MARK: Showing and hiding

    private func show(iconFrame: CGRect) {
        let visible = statusItem.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let panel = self.panel ?? makePanel()
        self.panel = panel
        hideGeneration += 1
        cardFrame = DropZoneGeometry.panelFrame(iconFrame: iconFrame, visibleScreenFrame: visible)
        panel.setFrame(DropZoneGeometry.windowFrame(forCard: cardFrame), display: false)
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
            model.panelState = .open
        }
        startPolling()
    }

    func hide() {
        guard model.panelState != .hidden else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        mouseUpTicks = 0
        withAnimation(.easeOut(duration: 0.15)) {
            model.panelState = .hidden
        }
        hideGeneration += 1
        let generation = hideGeneration
        // Let the close animation play, unless the panel was reopened in the meantime.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.hideGeneration, self.model.panelState == .hidden else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    /// Safety net for drags that end without a mouse-up we can see (Escape, a drop onto another app):
    /// close once the button has been up for a moment and the pointer isn't over the panel.
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NSEvent.pressedMouseButtons & 1 == 0, self.model.panelState != .hot {
                    self.mouseUpTicks += 1
                    if self.mouseUpTicks >= 3 { self.hide() }
                } else {
                    self.mouseUpTicks = 0
                }
            }
        }
    }

    // MARK: Panel

    private func makePanel() -> NSPanel {
        let windowSize = DropZoneGeometry.windowFrame(forCard: CGRect(origin: .zero, size: DropZoneGeometry.panelSize)).size
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // the SwiftUI card draws its own shadow
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let host = DropTargetHostView(frame: CGRect(origin: .zero, size: windowSize))
        host.onHot = { [weak self] hot in
            guard let self else { return }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                self.model.panelState = hot ? .hot : .open
            }
        }
        host.onDrop = { [weak self] urls in
            self?.model.upload(urls)
            self?.hide()
        }
        let content = NSHostingView(rootView: DropPanelView(model: model))
        content.frame = host.bounds
        content.autoresizingMask = [.width, .height]
        host.addSubview(content)
        panel.contentView = host
        return panel
    }
}

/// The panel's content view. It is the drag destination, so SwiftUI only has to draw.
final class DropTargetHostView: NSView {
    var onHot: ((Bool) -> Void)?
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !StatusDropView.fileURLs(from: sender).isEmpty else { return [] }
        onHot?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onHot?(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = StatusDropView.fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
