#if DEBUG
import AppKit
import DropUpCore

/// A test of the real app that CI runs on a Mac: `DROPUP_WINDOW_TEST=<scripts/window-test-other-app, built>` makes a
/// debug build run it after launch instead of waiting for a person, print one SELFTEST line per case and quit with 1
/// if any failed. It is left out of release builds.
///
/// Another app (the helper) covers the screen while DropUp's windows are open. Every case then asks which of DropUp's
/// windows ended up above that app, which is what a person sees. The rule: opening a window, or the popover, brings
/// forward only what was asked for, and closing a window brings nothing forward.
///
/// It saves a made-up server to the settings, so only run it where that does not matter.
@MainActor
enum WindowOrderSelfTest {
    private struct Entry {
        var number: Int
        var pid: Int32
        var layer: Int
    }

    /// Front to back, every layer.
    private static func stack() -> [Entry] {
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return info.compactMap { entry in
            guard let number = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue else { return nil }
            return Entry(number: number, pid: pid, layer: layer)
        }
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    private static let command = "/tmp/dropup-window-test.cmd"
    private static var commands = 0
    private static var otherApp = 0

    /// Brings the other app to the front, as if a person clicked in it. With `yielding`, it also lets DropUp take over
    /// as the active app, which macOS allows when a person has just clicked on DropUp's menubar icon.
    private static func otherAppFront(yielding: Bool = false) async {
        commands += 1
        let text = yielding ? "\(commands) yield \(getpid())" : "\(commands)"
        try? text.write(toFile: command, atomically: true, encoding: .utf8)
        for _ in 0..<100 {
            if (try? String(contentsOfFile: "/tmp/dropup-window-test.ack", encoding: .utf8)) == text { break }
            await sleep(0.05)
        }
        await sleep(0.35)
    }

    /// Whether the window is in front of the other app's window, behind it, or not on screen at all.
    private static func place(_ window: NSWindow??) -> String {
        guard let window, let window else { return "none" }
        let order = stack().filter { $0.layer == 0 }
        guard let mine = order.firstIndex(where: { $0.number == window.windowNumber }) else { return "offscreen" }
        guard let theirs = order.firstIndex(where: { $0.number == otherApp }) else { return "?" }
        return mine < theirs ? "ABOVE" : "below"
    }

    static func run(helper: String, model: AppModel, windows: WindowCoordinator, status: StatusItemController) async -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        var failed = false
        func report(_ name: String, _ details: String, _ problems: [String]) {
            if !problems.isEmpty { failed = true }
            print("SELFTEST \(name): \(details) -> \(problems.isEmpty ? "PASS" : "FAIL " + problems.joined(separator: ", "))")
        }

        try? model.save(ServerConfig(transferProtocol: .sftp, host: "127.0.0.1", port: 1, username: "test", remoteDirectory: "/"), secret: "")
        var setupProblems: [String] = []
        if model.needsOnboarding { setupProblems.append("the made-up server was not saved") }
        if NSApp.activationPolicy() != .accessory { setupProblems.append("the app has a Dock icon") }
        report("setup", "needsOnboarding=\(model.needsOnboarding) policy=\(NSApp.activationPolicy().rawValue)", setupProblems)
        guard !model.needsOnboarding else { return 1 }

        for name in ["ready", "cmd", "ack"] { try? FileManager.default.removeItem(atPath: "/tmp/dropup-window-test.\(name)") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        do { try process.run() } catch {
            print("SELFTEST setup: the other app did not start: \(error) -> FAIL")
            return 1
        }
        defer { process.terminate() }
        for _ in 0..<200 {
            if let text = try? String(contentsOfFile: "/tmp/dropup-window-test.ready", encoding: .utf8), let number = Int(text) {
                otherApp = number
                break
            }
            await sleep(0.1)
        }
        guard otherApp != 0 else {
            print("SELFTEST setup: the other app never showed a window -> FAIL")
            return 1
        }

        func window(_ name: String) -> NSWindow? { windows.windowsForSelfTest[name] ?? nil }
        func place(_ name: String) -> String { Self.place(window(name)) }
        func keyState(_ name: String) -> String { (window(name)?.isKeyWindow ?? false) ? "key" : "notkey" }
        func closeAll() async {
            for name in ["onboarding", "settings", "browse", "choose"] { window(name)?.close() }
            await sleep(0.8)
            await otherAppFront()
        }
        func open(_ name: String) {
            switch name {
            case "settings": windows.showSettings()
            case "browse": windows.showBrowse()
            case "choose": windows.showChooseFolder()
            default: windows.showOnboarding()
            }
        }
        /// Clicking on the menubar icon.
        func openPopover() async {
            await otherAppFront(yielding: true)
            status.togglePopover()
            await sleep(0.6)
        }

        /// `hidden` is open and covered by the other app. The popover is opened and Settings chosen from it, then once
        /// more after a click in the other app, then Settings is closed with Done.
        func caseA(_ hidden: String) async {
            await closeAll()
            open(hidden); await sleep(0.6)
            await otherAppFront()
            let before = place(hidden)
            await openPopover()
            let popover = (place(hidden), Self.place(status.popoverWindowForSelfTest))
            status.selfTestChoose("settings"); await sleep(0.8)
            let first = (place("settings"), place(hidden), keyState("settings"))
            await otherAppFront()
            await openPopover()
            let popoverAgain = (place("settings"), place(hidden))
            status.selfTestChoose("settings"); await sleep(0.8)
            let second = (place("settings"), place(hidden), keyState("settings"))
            window("settings")?.close(); await sleep(0.8)
            let closed = place(hidden)
            var bad: [String] = []
            func need(_ ok: Bool, _ problem: String) { if !ok { bad.append(problem) } }
            need(popover.0 == "below", "opening the popover brought \(hidden) forward")
            need(popover.1 != "offscreen" && popover.1 != "none", "the popover is not on screen")
            need(first.0 == "ABOVE", "Settings did not come forward")
            need(first.1 == "below", "opening Settings brought \(hidden) forward")
            need(first.2 == "key", "Settings did not get the keyboard")
            need(popoverAgain.0 == "below" && popoverAgain.1 == "below", "opening the popover brought a window forward")
            need(second.0 == "ABOVE", "Settings did not come forward the second time")
            need(second.1 == "below", "opening Settings again brought \(hidden) forward")
            need(second.2 == "key", "Settings did not get the keyboard the second time")
            need(closed == "below", "closing Settings brought \(hidden) forward")
            report("\(hidden) hidden, Settings from the popover",
                   "before=\(before) popover=\(popover) first=\(first) popoverAgain=\(popoverAgain) second=\(second) afterClose=\(closed)", bad)
        }

        /// Settings is open and covered. `other` is opened from the popover and closed.
        func caseB(_ other: String) async {
            await closeAll()
            open("settings"); await sleep(0.6)
            await otherAppFront()
            let before = place("settings")
            await openPopover()
            let popover = place("settings")
            status.selfTestChoose(other); await sleep(0.8)
            let opened = (place(other), place("settings"), keyState(other))
            window(other)?.close(); await sleep(0.8)
            let closed = place("settings")
            var bad: [String] = []
            func need(_ ok: Bool, _ problem: String) { if !ok { bad.append(problem) } }
            need(popover == "below", "opening the popover brought Settings forward")
            need(opened.0 == "ABOVE", "\(other) did not come forward")
            need(opened.1 == "below", "opening \(other) brought Settings forward")
            need(opened.2 == "key", "\(other) did not get the keyboard")
            need(closed == "below", "closing \(other) brought Settings forward")
            report("Settings hidden, \(other) from the popover", "before=\(before) popover=\(popover) opened=\(opened) afterClose=\(closed)", bad)
        }

        /// Two windows in plain view: closing the front one leaves the other where it is.
        func caseVisible() async {
            await closeAll()
            open("browse"); await sleep(0.6)
            open("settings"); await sleep(0.8)
            window("settings")?.close(); await sleep(0.8)
            let after = (place("browse"), keyState("browse"))
            report("two windows in view, one closed", "browse afterClose=\(after)",
                   after.0 == "ABOVE" ? [] : ["the window left open went away"])
        }

        /// The setup window and Settings, opened directly the way the app does, in both orders.
        func caseSetup() async {
            await closeAll()
            open("onboarding"); await sleep(0.6)
            await otherAppFront()
            open("settings"); await sleep(0.8)
            let opened = (place("settings"), place("onboarding"), keyState("settings"))
            window("settings")?.close(); await sleep(0.8)
            let closed = place("onboarding")
            await closeAll()
            open("settings"); await sleep(0.6)
            await otherAppFront()
            open("onboarding"); await sleep(0.8)
            let openedOnboarding = (place("onboarding"), place("settings"), keyState("onboarding"))
            window("onboarding")?.close(); await sleep(0.8)
            let closedOnboarding = place("settings")
            var bad: [String] = []
            func need(_ ok: Bool, _ problem: String) { if !ok { bad.append(problem) } }
            need(opened.0 == "ABOVE", "Settings did not come forward")
            need(opened.1 == "below", "opening Settings brought the setup window forward")
            need(closed == "below", "closing Settings brought the setup window forward")
            need(openedOnboarding.0 == "ABOVE", "the setup window did not come forward")
            need(openedOnboarding.1 == "below", "opening the setup window brought Settings forward")
            need(closedOnboarding == "below", "closing the setup window brought Settings forward")
            report("setup window and Settings",
                   "opened=\(opened) afterClose=\(closed) | openedOnboarding=\(openedOnboarding) afterClose=\(closedOnboarding)", bad)
        }

        await caseA("browse")
        await caseB("browse")
        await caseA("choose")
        await caseB("choose")
        await caseVisible()
        await caseSetup()
        await closeAll()
        return failed ? 1 : 0
    }
}
#endif
