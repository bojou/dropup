import AppKit
import SwiftUI
import DropUpCore

/// Temporary probe: renders the drop panel, the popover and Settings at the three drop zone sizes. Not for merging.
@MainActor
enum LayoutProbe {
    static func run(model: AppModel) {
        setvbuf(stdout, nil, _IOLBF, 0)
        let saved = ServerConfig(transferProtocol: .sftp, host: "files.example.com", username: "deploy", remoteDirectory: "/var/www/uploads")
        try? model.save(saved, secret: "")

        func shot<V: View>(_ label: String, _ view: V, size: CGSize, dark: Bool) {
            let host = NSHostingController(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setContentSize(size)
            window.orderFrontRegardless()
            host.view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
            host.view.layoutSubtreeIfNeeded()
            if let rep = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
                host.view.cacheDisplay(in: host.view.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    print("PROBE-PNG \(label) \(png.base64EncodedString())")
                }
            }
            window.orderOut(nil)
        }

        func backdrop(dark: Bool) -> some View {
            LinearGradient(colors: dark ? [Color(white: 0.16), Color(white: 0.28)] : [Color(red: 0.78, green: 0.84, blue: 0.92), Color(red: 0.93, green: 0.9, blue: 0.86)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }

        for dark in [false, true] {
            model.updatePreferences { $0.dropZoneSize = .standard }
            shot("settings-general-\(dark ? "dark" : "light")", SettingsView(model: model, close: {}), size: SettingsView.size, dark: dark)
        }
        print("PROBE done")
    }
}
