import AppKit
import SwiftUI
import DropUpCore

/// Temporary probe: times building and showing the Settings window, the way 0.1.40 was measured. Not for merging.
@MainActor
enum TimingProbe {
    static func run(model: AppModel) {
        setvbuf(stdout, nil, _IOLBF, 0)
        let sample = ServerConfig(transferProtocol: .sftp, host: "files.example.com", username: "deploy", remoteDirectory: "/var/www")
        try? model.save(sample, secret: "pw")
        var builds: [Double] = []
        var busy: [Double] = []
        for round in 1...8 {
            let start = CFAbsoluteTimeGetCurrent()
            let host = NSHostingController(rootView: SettingsView(model: model, close: {}))
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.orderFrontRegardless()
            host.view.layoutSubtreeIfNeeded()
            if let rep = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
                host.view.cacheDisplay(in: host.view.bounds, to: rep)
            }
            let built = CFAbsoluteTimeGetCurrent()
            let settleStart = CFAbsoluteTimeGetCurrent()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
            let overrun = max((CFAbsoluteTimeGetCurrent() - settleStart - 0.2) * 1000, 0)
            let size = window.contentView?.frame.size ?? .zero
            window.orderOut(nil)
            builds.append((built - start) * 1000)
            busy.append(overrun)
            print(String(format: "PROBE round %d: build+layout+draw %.1f ms, then busy %.1f ms, content %dx%d", round, (built - start) * 1000, overrun, Int(size.width), Int(size.height)))
        }
        let warm = builds.dropFirst().sorted()
        print(String(format: "PROBE summary: first %.1f ms, warm median %.1f ms, warm max %.1f ms", builds[0], warm[warm.count / 2], warm.last ?? 0))
    }
}
