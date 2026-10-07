import AppKit
import DropUpCore

/// PROBE ONLY, never merged: times opening Settings, Browse and Change Folder from the popover.
@MainActor
enum Probe {
    static let enabled = ProcessInfo.processInfo.environment["DROPUP_PROBE_OPEN"] != nil
    static let keeperOff = ProcessInfo.processInfo.environment["DROPUP_PROBE_NOKEEPER"] != nil
    static var marks: [(String, Double)] = []
    static var beginTime = 0.0, beginCalls = 0, lookTime = 0.0, lookCalls = 0, stackTime = 0.0, stackCalls = 0
    nonisolated static func now() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }
    static func mark(_ name: String) { if enabled { marks.append((name, now())) } }
    static func reset() {
        marks = []
        beginTime = 0; beginCalls = 0; lookTime = 0; lookCalls = 0; stackTime = 0; stackCalls = 0
    }
}

/// Watches from a background thread when a window of this app first shows on screen, so a busy main thread can't hide it.
final class OnScreenWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var seenAt: Double?

    func start() {
        let pid = getpid()
        Thread.detachNewThread { [self] in
            while true {
                lock.lock(); let stop = stopped; lock.unlock()
                if stop { return }
                let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                let found = list.contains { entry in
                    (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                        && (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
                        && ((entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0
                }
                if found {
                    lock.lock(); seenAt = Probe.now(); stopped = true; lock.unlock()
                    return
                }
                usleep(1000)
            }
        }
    }

    func result() -> Double? {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        return seenAt
    }
}

/// Records how long the main thread was unable to run a 2 ms timer.
@MainActor
final class HitchMonitor {
    private var timer: Timer?
    private var last = 0.0
    private(set) var worst = 0.0
    private(set) var over16 = 0
    private(set) var lostOver16 = 0.0

    func start() {
        last = Probe.now()
        let timer = Timer(timeInterval: 0.002, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = Probe.now()
        let gap = now - last
        last = now
        worst = max(worst, gap)
        if gap > 16 { over16 += 1; lostOver16 += gap }
    }

    func stop() { timer?.invalidate(); timer = nil }
}

@MainActor
enum OpenProbe {
    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    static func run(model: AppModel, windows: WindowCoordinator, status: StatusItemController) async -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        let label = ProcessInfo.processInfo.environment["DROPUP_PROBE_LABEL"] ?? "?"
        try? model.save(ServerConfig(transferProtocol: .sftp, host: "127.0.0.1", port: 1, username: "test", remoteDirectory: "/"), secret: "")
        guard let config = model.config else { print("PROBE no config"); return 1 }
        var keychain: [String] = []
        for _ in 0..<3 {
            let t = Probe.now()
            _ = model.password(for: config)
            keychain.append(String(format: "%.1f", Probe.now() - t))
        }
        let ownWindows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).count
        let t = Probe.now()
        for _ in 0..<20 { _ = WindowOrderKeeper.windowsOnScreen() }
        print("PROBE [\(label)] keychain ms \(keychain) onscreen windows (all layers) \(ownWindows) stackRead avg \(String(format: "%.2f", (Probe.now() - t) / 20)) ms")
        await sleep(1.5)

        for name in ["settings", "browse", "choose"] {
            for round in 0..<6 {
                status.togglePopover()
                await sleep(0.7)
                Probe.reset()
                let hitches = HitchMonitor()
                hitches.start()
                let watcher = OnScreenWatcher()
                watcher.start()
                let click = Probe.now()
                Probe.mark("click")
                status.probeChoose(name)
                Probe.mark("returned")
                let mainFree = FreeBox()
                DispatchQueue.main.async { mainFree.at = Probe.now() }
                await sleep(1.8)
                hitches.stop()
                let onScreen = watcher.result()
                func rel(_ v: Double?) -> String { v.map { String(format: "%.0f", $0 - click) } ?? "never" }
                let steps = Probe.marks.map { "\($0.0)=\(String(format: "%.0f", $0.1 - click))" }.joined(separator: " ")
                print(String(
                    format: "PROBE [%@] %@ #%d %@ mainFree=%@ onScreen=%@ | keeper begin %d calls %.1f ms, look %d calls %.1f ms, stackReads %d %.1f ms | hitches>16ms %d (%.0f ms) worst %.0f ms",
                    label, name, round, steps, rel(mainFree.at), rel(onScreen),
                    Probe.beginCalls, Probe.beginTime, Probe.lookCalls, Probe.lookTime, Probe.stackCalls, Probe.stackTime,
                    hitches.over16, hitches.lostOver16, hitches.worst
                ))
                windows.probeWindows[name]??.close()
                await sleep(1.0)
            }
        }
        return 0
    }
}

final class FreeBox: @unchecked Sendable { var at: Double? }
