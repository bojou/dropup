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

    /// Whether the window is on screen at all, at any level: the popover floats above ordinary windows.
    private static func shown(_ window: NSWindow?) -> String {
        guard let window else { return "none" }
        return stack().contains { $0.number == window.windowNumber } ? "shown" : "not shown"
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
            let popover = (place(hidden), Self.shown(status.popoverWindowForSelfTest))
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
            need(popover.1 == "shown", "the popover is not on screen")
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

        // A second run with another setting of the system (Prefer tabs when opening documents) only needs the sequences.
        let quick = ProcessInfo.processInfo.environment["DROPUP_WINDOW_TEST_QUICK"] != nil
        if !quick {
            await caseA("browse")
            await caseB("browse")
            await caseA("choose")
            await caseB("choose")
            await caseVisible()
            await caseSetup()
        }
        await closeAll()

        let rig = Rig(model: model, windows: windows, status: status)
        await rig.reportedSteps()
        await rig.sequences(only: quick ? 2 : nil)
        if rig.failed { failed = true }
        await closeAll()
        return failed ? 1 : 0
    }

    // MARK: Sequences

    private enum Name: String, CaseIterable, Comparable {
        case settings, browse, choose, onboarding
        static func < (a: Name, b: Name) -> Bool { a.rawValue < b.rawValue }
    }

    /// What a person does with the windows, one thing at a time.
    private enum Step: CustomStringConvertible {
        /// Clicks in another app, which covers every DropUp window.
        case hide
        /// Opens a window, or opens one again that is already open: from the popover, and for the setup window from the icon.
        case open(Name)
        /// Closes a window with its button (Done in Settings does the same).
        case close(Name)
        /// Opens the popover and closes it again without choosing anything.
        case peek

        var description: String {
            switch self {
            case .hide: "hide"
            case .open(let name): "open \(name.rawValue)"
            case .close(let name): "close \(name.rawValue)"
            case .peek: "peek"
            }
        }
    }

    /// Something else brings a window of DropUp forward while a step runs, the way macOS can, whatever the reason:
    /// the stack has to be put right again.
    private struct Pull {
        /// Seconds after the step starts.
        var after: Double
        /// `false` only orders the window to the front; `true` also activates the app and asks for the keyboard.
        var activating: Bool
    }

    private struct Move {
        var step: Step
        /// Seconds to wait before the step, a short time to catch anything that is still going on.
        var gap: Double
        var pull: Pull?

        init(_ step: Step, _ gap: Double, pull: Pull? = nil) {
            self.step = step
            self.gap = gap
            self.pull = pull
        }
    }

    /// What was seen while a step ran: the places of the windows every 30 ms, and which window was pulled.
    @MainActor
    private final class Samples {
        var list: [(at: Double, places: [Name: String])] = []
        var running = true
        var pulled: Name?
    }

    /// Plays steps against the real windows and checks after each one that only the window that was asked for moved
    /// forward: every other window of DropUp keeps its place behind the other app, also for a moment in between.
    @MainActor
    private final class Rig {
        let model: AppModel
        let windows: WindowCoordinator
        let status: StatusItemController
        var failed = false

        init(model: AppModel, windows: WindowCoordinator, status: StatusItemController) {
            self.model = model
            self.windows = windows
            self.status = status
        }

        func window(_ name: Name) -> NSWindow? { windows.windowsForSelfTest[name.rawValue] ?? nil }

        func place(_ name: Name) -> String { WindowOrderSelfTest.place(window(name)) }

        /// The windows that are open and where they are.
        func places() -> [Name: String] {
            var result: [Name: String] = [:]
            for name in Name.allCases where window(name)?.isVisible == true { result[name] = place(name) }
            return result
        }

        func describe(_ places: [Name: String]) -> String {
            places.sorted { $0.key < $1.key }.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: " ")
        }

        func reset() async {
            for name in Name.allCases { window(name)?.close() }
            await WindowOrderSelfTest.sleep(0.6)
            await WindowOrderSelfTest.otherAppFront()
        }

        /// Clicking on the menubar icon: the app becomes the active one if it is not.
        func openPopover() async {
            if !NSApp.isActive { await WindowOrderSelfTest.otherAppFront(yielding: true) }
            status.togglePopover()
            await WindowOrderSelfTest.sleep(0.4)
        }

        private func perform(_ step: Step) async {
            switch step {
            case .hide:
                await WindowOrderSelfTest.otherAppFront()
            case .open(.onboarding):
                if !NSApp.isActive { await WindowOrderSelfTest.otherAppFront(yielding: true) }
                windows.showOnboarding()
            case .open(let name):
                await openPopover()
                status.selfTestChoose(name.rawValue)
            case .close(let name):
                window(name)?.close()
            case .peek:
                await openPopover()
                status.togglePopover()
            }
        }

        /// Brings a window that is behind the other app forward, as if macOS had.
        private func pull(_ pull: Pull, requested: Name?, before: [Name: String], samples: Samples) async {
            try? await Task.sleep(nanoseconds: UInt64(pull.after * 1e9))
            guard let victim = Name.allCases.first(where: { $0 != requested && before[$0] == "below" && window($0)?.isVisible == true }),
                  let window = window(victim) else { return }
            samples.pulled = victim
            if pull.activating {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFrontRegardless()
            }
        }

        /// One step. Returns what is wrong, and a line for the trace.
        private func play(_ move: Move) async -> (problems: [String], line: String) {
            let step = move.step
            await WindowOrderSelfTest.sleep(move.gap)
            let before = places()
            let wasActive = NSApp.isActive
            let started = Date()
            let samples = Samples()
            var requested: Name?
            if case .open(let name) = step { requested = name }
            var closed: Name?
            if case .close(let name) = step { closed = name }

            let sampler = Task { @MainActor in
                while samples.running {
                    samples.list.append((Date().timeIntervalSince(started), self.places()))
                    await WindowOrderSelfTest.sleep(0.03)
                }
            }
            var puller: Task<Void, Never>?
            if let wanted = move.pull {
                puller = Task { @MainActor in await self.pull(wanted, requested: requested, before: before, samples: samples) }
            }
            await perform(step)
            await puller?.value
            await WindowOrderSelfTest.sleep(0.6)
            samples.running = false
            await sampler.value
            let after = places()

            var bad: [String] = []
            for (name, was) in before where name != requested && name != closed {
                guard let now = after[name] else { bad.append("\(name.rawValue) went away"); continue }
                if case .hide = step {
                    if now != "below" { bad.append("\(name.rawValue) was not covered by the other app") }
                    continue
                }
                if now != was { bad.append("\(name.rawValue) was \(was), is now \(now)") }
                guard was == "below", let first = samples.list.first(where: { $0.places[name] == "ABOVE" }) else { continue }
                if name == samples.pulled {
                    // Pulled on purpose: it may show for a moment, but has to be put back at once.
                    let last = samples.list.last(where: { $0.places[name] == "ABOVE" }) ?? first
                    if last.at - first.at > 0.4 {
                        bad.append("\(name.rawValue) was pulled forward and stayed there for \(Int((last.at - first.at) * 1000)) ms")
                    }
                } else {
                    bad.append("\(name.rawValue) came forward for a moment, \(Int(first.at * 1000)) ms in")
                }
            }
            for name in Name.allCases {
                if let window = window(name), window.isVisible, (window.tabGroup?.windows.count ?? 1) > 1 {
                    bad.append("\(name.rawValue) became a tab of another window")
                }
            }
            if let requested {
                if after[requested] != "ABOVE" { bad.append("\(requested.rawValue) did not come forward (\(after[requested] ?? "gone"))") }
                else if window(requested)?.isKeyWindow != true { bad.append("\(requested.rawValue) did not get the keyboard") }
            }
            let pulled = samples.pulled.map { ", pulled \($0.rawValue)" } ?? ""
            let line = "\(step) after \(String(format: "%.2f", move.gap)) s, active \(wasActive)->\(NSApp.isActive)\(pulled): \(describe(before)) => \(describe(after))"
            return (bad, line)
        }

        /// Runs the moves one after another from a clean start and reports one line.
        func play(_ title: String, _ moves: [Move]) async {
            await reset()
            var trace: [String] = []
            var problems: [String] = []
            for (index, move) in moves.enumerated() {
                let result = await play(move)
                trace.append("    \(index + 1). \(result.line)")
                for problem in result.problems { problems.append("step \(index + 1) (\(move.step)): \(problem)") }
            }
            if !problems.isEmpty { failed = true }
            print("SELFTEST \(title): \(moves.count) steps -> \(problems.isEmpty ? "PASS" : "FAIL " + problems.joined(separator: "; "))")
            if !problems.isEmpty { trace.forEach { print($0) } }
        }

        /// The steps of the report, in both directions, repeated: the one window is open and hidden, the other opens
        /// and closes, then opens again.
        func reportedSteps() async {
            for (first, second) in [(Name.settings, Name.browse), (.browse, .settings)] {
                for round in 1...3 {
                    // Waiting a good while before opening again, or hardly any, and once with windows being pulled.
                    let wait = round == 2 ? 0.1 : 1.2
                    let pulled: (Double) -> Pull? = { round == 3 ? Pull(after: $0, activating: $0 > 0.1) : nil }
                    await play("reported steps, \(first.rawValue) hidden then \(second.rawValue) twice (round \(round))", [
                        Move(.open(first), 0.3), Move(.hide, 0.3), Move(.open(second), 0.5, pull: pulled(0.05)),
                        Move(.close(second), 0.5, pull: pulled(0.0)), Move(.open(second), wait, pull: pulled(0.3)),
                        Move(.close(second), 0.5, pull: pulled(0.1)), Move(.hide, 0.2), Move(.open(second), wait, pull: pulled(0.0)),
                        Move(.close(second), 0.5),
                    ])
                }
            }
        }

        /// A made-up but fixed sequence of things a person might do, over 2, 3 and 4 windows. Every other sequence also
        /// has windows pulled forward now and then.
        func sequences(only count: Int? = nil) async {
            let sets: [[Name]] = [
                [.settings, .browse], [.browse, .choose], [.settings, .browse, .choose],
                [.settings, .browse, .onboarding], [.settings, .browse, .choose, .onboarding], [.browse, .choose, .onboarding, .settings],
            ]
            for (index, names) in sets.enumerated() where index < (count ?? sets.count) {
                let moves = Self.sequence(names: names, seed: UInt64(index + 1) &* 7919, length: 12, pulling: index % 2 == 1)
                await play("sequence \(index + 1) over \(names.map(\.rawValue).joined(separator: ", "))\(index % 2 == 1 ? " with windows pulled forward" : "")", moves)
            }
        }

        private struct Random {
            var state: UInt64
            mutating func next(_ limit: Int) -> Int {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Int((state >> 33) % UInt64(limit))
            }
        }

        static func sequence(names: [Name], seed: UInt64, length: Int, pulling: Bool) -> [Move] {
            var random = Random(state: seed)
            var open = Set<Name>()
            var moves: [Move] = []
            for _ in 0..<length {
                let step: Step
                switch random.next(10) {
                case 0, 1: step = .hide
                case 2: step = .peek
                case 3...4 where !open.isEmpty: step = .close(open.sorted()[random.next(open.count)])
                default: step = .open(names[random.next(names.count)])
                }
                switch step {
                case .open(let name): open.insert(name)
                case .close(let name): open.remove(name)
                default: break
                }
                let gap = [0.05, 0.4, 1.0][random.next(3)]
                var pull: Pull?
                if pulling, random.next(5) < 3 {
                    if case .hide = step {} else { pull = Pull(after: [0.0, 0.05, 0.3, 0.7][random.next(4)], activating: random.next(2) == 0) }
                }
                moves.append(Move(step, gap, pull: pull))
            }
            return moves
        }
    }
}
#endif
