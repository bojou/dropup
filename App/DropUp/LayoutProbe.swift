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
            let host = NSHostingController(rootView: view.frame(width: size.width, height: size.height))
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
            let mode = dark ? "dark" : "light"
            for zone in DropZoneSize.allCases {
                model.updatePreferences { $0.dropZoneSize = zone }
                let panel = DropZoneGeometry.panelSize(for: zone)
                let canvas = CGSize(width: panel.width + 2 * DropZoneGeometry.shadowMargin + 24, height: panel.height + 2 * DropZoneGeometry.shadowMargin + 24)
                for state in [DropPanelState.open, .hot] {
                    model.panelState = state
                    shot("panel-\(zone.rawValue)-\(state == .hot ? "hot" : "open")-\(mode)",
                         DropPanelView(model: model).frame(width: canvas.width, height: canvas.height).background(backdrop(dark: dark)),
                         size: canvas, dark: dark)
                }
                model.panelState = .hidden

                let popover = PopoverView(model: model, openSettings: {}, openBrowse: {}, openChooseFolder: {}, openUpdate: {})
                let fit = NSHostingView(rootView: popover).fittingSize
                print("PROBE popover \(zone.rawValue) \(mode) empty list: \(Int(fit.width)) x \(Int(fit.height)) pt")
                shot("popover-\(zone.rawValue)-\(mode)", popover.background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 380, height: ceil(fit.height)), dark: dark)
            }
        }

        // The longest list at the largest size: the cap and the scrolling must still keep the popover short.
        model.updatePreferences { $0.dropZoneSize = .large }
        for index in 1...9 {
            let id = UUID()
            model.activity.apply(.queued(id: id, fileName: "holiday-photo-\(index).jpg", totalBytes: 4_000_000))
            if index <= 2 {
                model.activity.apply(.started(id: id))
                model.activity.apply(.progress(id: id, UploadProgress(bytesSent: 1_500_000, totalBytes: 4_000_000)))
            }
        }
        let busy = PopoverView(model: model, openSettings: {}, openBrowse: {}, openChooseFolder: {}, openUpdate: {})
        let busyFit = NSHostingView(rootView: busy).fittingSize
        print("PROBE popover large with 9 uploads: \(Int(busyFit.width)) x \(Int(busyFit.height)) pt, main screen \(Int(NSScreen.main?.visibleFrame.height ?? 0)) pt")
        shot("popover-large-9uploads-light", busy.background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 380, height: ceil(busyFit.height)), dark: false)

        for dark in [false, true] {
            model.updatePreferences { $0.dropZoneSize = .standard }
            shot("settings-general-\(dark ? "dark" : "light")", SettingsView(model: model, close: {}), size: SettingsView.size, dark: dark)
        }
        print("PROBE done")
    }
}
