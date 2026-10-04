import AppKit
import DropUpCore

/// PROBE-ONLY (not for merging): drives the real window coordinator and popover while another app sits in front, and
/// reads the window server's front-to-back order to see which of DropUp's windows end up above that app.
@MainActor
enum WindowProbe {
    static func zorder() -> [(number: Int, pid: Int32)] {
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
            return (number, pid)
        }
    }

    /// Whether the window is open but covered by a window of another app (or not on this desktop).
    static func isBuried(_ window: NSWindow) -> Bool {
        guard window.isVisible, !window.isMiniaturized else { return false }
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let me = ProcessInfo.processInfo.processIdentifier
        let top = NSScreen.screens.first?.frame.height ?? 0
        let f = window.frame
        let mine = CGRect(x: f.minX, y: top - f.maxY, width: f.width, height: f.height)
        for entry in info {
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            if number == window.windowNumber { return false }
            if pid != me, let bounds = entry[kCGWindowBounds as String] as? [String: Any],
               let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.intersects(mine) { return true }
        }
        return true
    }

    private static func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    private static var counter = 0
    private static var helperNumber = 0

    private static func helperFront() async {
        counter += 1
        try? "\(counter)".write(toFile: "/tmp/probe-helper.cmd", atomically: true, encoding: .utf8)
        for _ in 0..<100 {
            if (try? String(contentsOfFile: "/tmp/probe-helper.ack", encoding: .utf8)) == "\(counter)" { break }
            await sleep(0.05)
        }
        await sleep(0.35)
    }

    private static func state(_ window: NSWindow??) -> String {
        guard let window, let window else { return "none" }
        let order = zorder()
        guard let mine = order.firstIndex(where: { $0.number == window.windowNumber }) else { return "offscreen" }
        guard let theirs = order.firstIndex(where: { $0.number == helperNumber }) else { return "?" }
        return mine < theirs ? "ABOVE" : "below"
    }

    static func run(model: AppModel, windows: WindowCoordinator, status: StatusItemController) async {
        setvbuf(stdout, nil, _IOLBF, 0)
        print("PROBE policy=\(NSApp.activationPolicy().rawValue) screen=\(String(describing: NSScreen.main?.frame)) needsOnboarding=\(model.needsOnboarding)")
        for name in ["ready", "cmd", "ack"] { try? FileManager.default.removeItem(atPath: "/tmp/probe-helper.\(name)") }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DROPUP_PROBE_HELPER"] ?? "")
        do { try helper.run() } catch { print("PROBE could not start the other app: \(error)"); return }
        for _ in 0..<200 {
            if let text = try? String(contentsOfFile: "/tmp/probe-helper.ready", encoding: .utf8), let first = text.split(separator: " ").first, let n = Int(first) {
                helperNumber = n
                break
            }
            await sleep(0.1)
        }
        guard helperNumber != 0 else { print("PROBE the other app never showed a window"); return }
        print("PROBE other app window \(helperNumber)")

        func windowFor(_ name: String) -> NSWindow? { windows.probeWindows[name] ?? nil }
        func closeAll() async {
            for name in ["onboarding", "settings", "browse", "choose"] { windowFor(name)?.close() }
            await sleep(0.8)
            await helperFront()
        }
        func open(_ name: String) {
            switch name {
            case "settings": windows.showSettings()
            case "browse": windows.showBrowse()
            case "choose": windows.showChooseFolder()
            default: windows.showOnboarding()
            }
        }
        func st(_ name: String) -> String { state(windowFor(name)) }
        func key(_ name: String) -> String { (windowFor(name)?.isKeyWindow ?? false) ? "key" : "notkey" }

        /// A: `hidden` is open and covered by the other app; the popover is opened and Settings chosen from it, twice,
        /// then Settings is closed with Done.
        func scenarioA(_ hidden: String, _ tag: String) async -> String {
            await closeAll()
            open(hidden); await sleep(0.6)
            await helperFront()
            let pre = st(hidden)
            status.togglePopover(); await sleep(0.6)
            let popOpen = st(hidden)
            status.probeOpen("settings"); await sleep(0.8)
            let first = (st("settings"), st(hidden), key("settings"))
            await helperFront()
            status.togglePopover(); await sleep(0.6)
            let popOpen2 = (st("settings"), st(hidden))
            status.probeOpen("settings"); await sleep(0.8)
            let second = (st("settings"), st(hidden), key("settings"))
            windowFor("settings")?.close(); await sleep(0.8)
            let closed = st(hidden)
            let bad = [popOpen != "below" ? "popover raised \(hidden)" : nil,
                       first.0 != "ABOVE" ? "settings not above" : nil, first.1 != "below" ? "open raised \(hidden)" : nil,
                       first.2 != "key" ? "settings not key" : nil,
                       popOpen2.0 != "below" || popOpen2.1 != "below" ? "2nd popover raised \(popOpen2)" : nil,
                       second.0 != "ABOVE" ? "2nd settings not above" : nil, second.1 != "below" ? "2nd open raised \(hidden)" : nil,
                       second.2 != "key" ? "2nd settings not key" : nil,
                       closed != "below" ? "close raised \(hidden)" : nil].compactMap { $0 }
            return "\(tag) pre=\(pre) popover=\(popOpen) open=\(first) popover2=\(popOpen2) open2=\(second) afterClose=\(closed) active=\(NSApp.isActive) -> \(bad.isEmpty ? "PASS" : "FAIL " + bad.joined(separator: ", "))"
        }

        /// B: Settings is open and covered; `other` is opened from the popover and closed.
        func scenarioB(_ other: String, _ tag: String) async -> String {
            await closeAll()
            open("settings"); await sleep(0.6)
            await helperFront()
            let pre = st("settings")
            status.togglePopover(); await sleep(0.6)
            let popOpen = st("settings")
            status.probeOpen(other); await sleep(0.8)
            let opened = (st(other), st("settings"), key(other))
            windowFor(other)?.close(); await sleep(0.8)
            let closed = st("settings")
            let bad = [popOpen != "below" ? "popover raised settings" : nil,
                       opened.0 != "ABOVE" ? "\(other) not above" : nil, opened.1 != "below" ? "open raised settings" : nil,
                       opened.2 != "key" ? "\(other) not key" : nil,
                       closed != "below" ? "close raised settings" : nil].compactMap { $0 }
            return "\(tag) pre=\(pre) popover=\(popOpen) open=\(opened) afterClose=\(closed) active=\(NSApp.isActive) -> \(bad.isEmpty ? "PASS" : "FAIL " + bad.joined(separator: ", "))"
        }

        /// V: two windows in plain view: closing the front one must still hand the keyboard to the other, which stays put.
        func scenarioV(_ tag: String) async -> String {
            await closeAll()
            open("browse"); await sleep(0.6)
            open("settings"); await sleep(0.8)
            windowFor("settings")?.close(); await sleep(0.8)
            let after = (st("browse"), key("browse"))
            let bad = [after.0 != "ABOVE" ? "browse went away" : nil].compactMap { $0 }
            return "\(tag) afterClose=\(after) -> \(bad.isEmpty ? "PASS" : "FAIL " + bad.joined(separator: ", "))"
        }

        /// O: onboarding hidden, Settings opened directly (as the app does) and closed; and the mirror.
        func scenarioO(_ tag: String) async -> String {
            await closeAll()
            open("onboarding"); await sleep(0.6)
            await helperFront()
            let pre = st("onboarding")
            open("settings"); await sleep(0.8)
            let opened = (st("settings"), st("onboarding"), key("settings"))
            windowFor("settings")?.close(); await sleep(0.8)
            let closed = st("onboarding")
            await closeAll()
            open("settings"); await sleep(0.6)
            await helperFront()
            open("onboarding"); await sleep(0.8)
            let opened2 = (st("onboarding"), st("settings"), key("onboarding"))
            windowFor("onboarding")?.close(); await sleep(0.8)
            let closed2 = st("settings")
            let bad = [opened.0 != "ABOVE" ? "settings not above" : nil, opened.1 != "below" ? "open raised onboarding" : nil,
                       closed != "below" ? "close raised onboarding" : nil,
                       opened2.0 != "ABOVE" ? "onboarding not above" : nil, opened2.1 != "below" ? "open raised settings" : nil,
                       closed2 != "below" ? "close raised settings" : nil].compactMap { $0 }
            return "\(tag) pre=\(pre) open=\(opened) afterClose=\(closed) | open2=\(opened2) afterClose2=\(closed2) -> \(bad.isEmpty ? "PASS" : "FAIL " + bad.joined(separator: ", "))"
        }

        let environment = ProcessInfo.processInfo.environment
        let fixes = (environment["DROPUP_PROBE_FIXES"] ?? "0").split(separator: ",").compactMap { Int($0) }
        for fix in fixes {
            WindowCoordinator.fix = fix
            let name = "fix\(fix)"
            print("PROBE \(name) A-browse: \(await scenarioA("browse", "A-browse"))")
            print("PROBE \(name) B-browse: \(await scenarioB("browse", "B-browse"))")
            print("PROBE \(name) A-choose: \(await scenarioA("choose", "A-choose"))")
            print("PROBE \(name) B-choose: \(await scenarioB("choose", "B-choose"))")
            print("PROBE \(name) V: \(await scenarioV("V"))")
            print("PROBE \(name) O: \(await scenarioO("O"))")
        }
        await closeAll()
        helper.terminate()
        print("PROBE done")
    }
}
