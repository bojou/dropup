import AppKit
import DropUpCore

/// Makes sure that opening, reopening or closing a DropUp window, or opening the popover, brings forward only the
/// window that was asked for. Every other DropUp window keeps its place in the stack of all windows on screen: one that
/// was behind another app stays behind it.
///
/// macOS has more than one way of bringing a window forward that nobody asked for: activating the app raises its last
/// key or main window, closing the window that has the keyboard hands it to the next one and brings that forward, a
/// popover going away does the same, and what it does can depend on timing. So this does not rely on stopping each of
/// them, and it is not specific to a pair of windows. Whenever the app is about to do something that can move windows
/// (`begin`), it notes the stack of windows on screen. For the next moments it
///
///  - keeps the app's windows that are behind other apps from being handed the keyboard (they cannot become key or main,
///    which is how macOS picks the window to bring forward), and
///  - when anything happens that can mean a window moved (a window became key or main, appeared on screen, or the app
///    became active, and at a few fixed moments), puts every window that came in front of a window of another app that
///    was in front of it before back behind that window. The window that was asked for is the exception, and so is a
///    window the person clicks.
///
/// It does nothing between actions, and only watches for `watchTime` after each one.
@MainActor
final class WindowOrderKeeper {
    static let shared = WindowOrderKeeper()

    /// How long after an action macOS may still be moving windows around.
    static let watchTime: TimeInterval = 1.5
    /// When, within that time, the stack is looked at even if nothing was noticed.
    private static let checkTimes: [TimeInterval] = [0.05, 0.2, 0.5, 1.0, 1.4]

    private struct Asked {
        weak var window: NSWindow?
    }

    private var baseline: [StackedWindow] = []
    private var asked: [Asked] = []
    private var watchUntil: TimeInterval = 0
    private var generation = 0
    private var lastLook: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    private var clickMonitor: Any?

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private var isWatching: Bool { Self.now < watchUntil }

    /// The app is about to do something that can move windows: open or close one, show or hide the popover, or show an
    /// alert. `window` is the one the person asked for, which comes forward; `closing` is one that is going away.
    func begin(asking window: NSWindow? = nil, closing: NSWindow? = nil) {
        if !isWatching {
            baseline = Self.windowsOnScreen()
            asked = []
        }
        if let window { asked.append(Asked(window: window)) }
        watchUntil = Self.now + Self.watchTime
        startObserving()
        holdBackWindowsBehindOtherApps(except: [window, closing])
        scheduleLooks()
    }

    /// Runs something that blocks until the person answers, such as an alert. The windows are watched all the while, and
    /// for `watchTime` after.
    func whileBlocked<T>(_ body: () -> T) -> T {
        begin()
        watchUntil = .infinity
        let result = body()
        watchUntil = Self.now + Self.watchTime
        holdBackWindowsBehindOtherApps(except: [])
        scheduleLooks()
        return result
    }

    // MARK: Keeping the keyboard away from windows behind other apps

    /// The windows that are open and behind (even partly behind) another app's window cannot become key or main until
    /// the watching is over; the ones in plain view can, and so can the one that was asked for.
    private func holdBackWindowsBehindOtherApps(except exceptions: [NSWindow?]) {
        let stack = Self.windowsOnScreen()
        // The window server counts from the top left of the main screen, AppKit from the bottom left.
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        for window in NSApp.windows.compactMap({ $0 as? DropUpWindow }) where window.isVisible {
            if exceptions.contains(where: { $0 === window }) || asked.contains(where: { $0.window === window }) {
                window.stopHoldingBack()
                continue
            }
            let frame = CGRect(x: window.frame.minX, y: screenHeight - window.frame.maxY, width: window.frame.width, height: window.frame.height)
            if WindowCover.isCovered(windowNumber: window.windowNumber, frame: frame, ownProcess: getpid(), stack: stack) {
                window.holdBack(until: watchUntil + 0.1)
            } else {
                window.stopHoldingBack()
            }
        }
    }

    // MARK: Putting back what moved

    /// Looks at the stack and puts back every window that came forward without being asked for.
    private func look() {
        guard isWatching else { return }
        lastLook = Self.now
        let askedNumbers = Set(asked.compactMap { $0.window?.windowNumber })
        let restores = WindowStack.restores(before: baseline, now: Self.windowsOnScreen(), ownProcess: getpid(), allowed: askedNumbers)
        guard !restores.isEmpty else { return }
        for restore in restores {
            guard let window = NSApp.window(withWindowNumber: restore.window) as? DropUpWindow else { continue }
            window.order(.below, relativeTo: restore.below)
        }
        // Should the window server not take a place next to another app's window, behind everything is behind it too.
        let stillForward = WindowStack.restores(before: baseline, now: Self.windowsOnScreen(), ownProcess: getpid(), allowed: askedNumbers)
        for restore in stillForward {
            (NSApp.window(withWindowNumber: restore.window) as? DropUpWindow)?.orderBack(nil)
        }
        // The window that was asked for keeps the keyboard.
        if let wanted = asked.last?.window, wanted.isVisible, !wanted.isKeyWindow, wanted.canBecomeKey { wanted.makeKey() }
    }

    private func noticed() {
        // Notifications can come in dozens for one event; once in 20 ms is plenty.
        guard isWatching, Self.now - lastLook >= 0.02 else { return }
        look()
    }

    private func scheduleLooks() {
        generation += 1
        let mine = generation
        for time in Self.checkTimes {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(time * 1e9))
                guard self.generation == mine else { return }
                self.look()
            }
        }
        // Nothing is kept or watched once it is over.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((Self.watchTime + 0.1) * 1e9))
            guard self.generation == mine, !self.isWatching else { return }
            self.stopObserving()
            self.asked = []
            self.baseline = []
        }
    }

    // MARK: Noticing

    private func startObserving() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didChangeOcclusionStateNotification,
            NSApplication.didBecomeActiveNotification, NSApplication.didUpdateNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noticed() }
            }
        }
        // A click on one of the app's windows is the person asking for it, and macOS brings it forward.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, let window = event.window as? DropUpWindow {
                    self.asked.append(Asked(window: window))
                    window.stopHoldingBack()
                }
            }
            return event
        }
    }

    private func stopObserving() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    // MARK: The stack

    /// The windows on screen, front to back. Only ordinary windows: the menubar, the Dock, the popover and other layers
    /// of the window server are not windows that cover anything of ours. A window of this app that is not one of the
    /// windows kept here (an update window, a file chooser) counts like a window of another app. Names and contents are
    /// not read.
    static func windowsOnScreen() -> [StackedWindow] {
        let ownProcess = getpid()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let number = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let owner = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            let kept = owner == ownProcess && NSApp.window(withWindowNumber: number) is DropUpWindow
            return StackedWindow(number: number, ownerProcess: owner == ownProcess && !kept ? -1 : owner, frame: frame)
        }
    }
}

/// A window that can be told not to take over for a moment. macOS skips a window that cannot become key or main when it
/// looks for the one to give the keyboard to, or to bring forward when the app is activated.
final class DropUpWindow: NSWindow {
    private var heldBackUntil: TimeInterval = 0

    func holdBack(until time: TimeInterval) {
        heldBackUntil = time
    }

    func stopHoldingBack() {
        heldBackUntil = 0
    }

    private var isHeldBack: Bool {
        guard ProcessInfo.processInfo.systemUptime < heldBackUntil else { return false }
        // A click on the window is the person asking for it.
        if let event = NSApp.currentEvent, event.window === self,
           [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            return false
        }
        return true
    }

    override var canBecomeKey: Bool { !isHeldBack && super.canBecomeKey }
    override var canBecomeMain: Bool { !isHeldBack && super.canBecomeMain }
}
