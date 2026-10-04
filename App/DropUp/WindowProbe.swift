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

    /// Whether another window of this app is above every window of other apps.
    static func otherDropUpWindowIsOnTop(excluding window: NSWindow) -> Bool {
        let order = zorder()
        let me = ProcessInfo.processInfo.processIdentifier
        let foreignTop = order.firstIndex { $0.pid != me } ?? Int.max
        return NSApp.windows.contains { other in
            guard other !== window, other.isVisible, let index = order.firstIndex(where: { $0.number == other.windowNumber }) else { return false }
            return index < foreignTop
        }
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
            await sleep(0.3)
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
        func popover() async {
            status.togglePopover()
            await sleep(0.4)
            status.togglePopover()
            await sleep(0.3)
        }

        /// A: `hidden` is open and covered by the other app; Settings is opened, again, and closed.
        func scenarioA(_ hidden: String, _ tag: String) async -> String {
            await closeAll()
            open(hidden); await sleep(0.5)
            await helperFront()
            let pre = state(windowFor(hidden))
            await popover()
            let afterPopover = state(windowFor(hidden))
            open("settings"); await sleep(0.6)
            let open1 = (state(windowFor("settings")), state(windowFor(hidden)))
            await helperFront()
            open("settings"); await sleep(0.6)
            let open2 = (state(windowFor("settings")), state(windowFor(hidden)))
            windowFor("settings")?.close(); await sleep(0.6)
            let closed = state(windowFor(hidden))
            let bad = [afterPopover != "below" ? "popover raised \(hidden)" : nil,
                       open1.0 != "ABOVE" ? "settings not above" : nil, open1.1 != "below" ? "open raised \(hidden)" : nil,
                       open2.0 != "ABOVE" ? "2nd settings not above" : nil, open2.1 != "below" ? "2nd open raised \(hidden)" : nil,
                       closed != "below" ? "close raised \(hidden)" : nil].compactMap { $0 }
            return "\(tag) pre=\(pre) afterPopover=\(afterPopover) open=\(open1) open2=\(open2) afterClose=\(closed) -> \(bad.isEmpty ? "PASS" : "FAIL " + bad.joined(separator: ", "))"
        }

        /// B: Settings is open and covered; `other` is opened and closed.
        func scenarioB(_ other: String, _ tag: String) async -> String {
            await closeAll()
            open("settings"); await sleep(0.5)
            await helperFront()
            let pre = state(windowFor("settings"))
            open(other); await sleep(0.6)
            let opened = (state(windowFor(other)), state(windowFor("settings")))
            windowFor(other)?.close(); await sleep(0.6)
            let closed = state(windowFor("settings"))
            let bad = [opened.0 != "ABOVE" ? "\(other) not above" : nil, opened.1 != "below" ? "open raised settings" : nil,
                       closed != "below" ? "close raised settings" : nil].compactMap { $0 }
            return "\(tag) pre=\(pre) open=\(opened) afterClose=\(closed) -> \(bad.isEmpty ? "PASS" : "FAIL " + bad.joined(separator: ", "))"
        }

        let environment = ProcessInfo.processInfo.environment
        let only = environment["DROPUP_PROBE_COMBO"]
        for o in 0...3 { for c in 0...2 { for p in 0...2 {
            if let only, only != "\(o)\(c)\(p)" { continue }
            WindowCoordinator.openStrategy = o
            WindowCoordinator.closeStrategy = c
            StatusItemController.popoverStrategy = p
            let name = "o\(o) c\(c) p\(p)"
            print("PROBE \(name) A-browse: \(await scenarioA("browse", "A-browse"))")
            print("PROBE \(name) B-browse: \(await scenarioB("browse", "B-browse"))")
            print("PROBE \(name) A-choose: \(await scenarioA("choose", "A-choose"))")
            print("PROBE \(name) B-choose: \(await scenarioB("choose", "B-choose"))")
        } } }
        await closeAll()
        helper.terminate()
        print("PROBE done")
    }
}
