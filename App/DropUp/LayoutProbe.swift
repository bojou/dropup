import AppKit
import SwiftUI
import DropUpCore

/// Temporary probe: renders the Settings window with the new tabs. Not for merging.
@MainActor
enum LayoutProbe {
    static func run(model: AppModel) {
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

        // What the old segmented picker row took, to size the new row against.
        let old = VStack(spacing: 0) {
            Picker("", selection: .constant(1)) {
                Text("Connection").tag(0)
                Text("General").tag(1)
                Text("Shortcuts").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)
            .padding(.vertical, 14)
            Divider()
        }
        print("PROBE old picker row: \(Int(NSHostingView(rootView: old).fittingSize.height)) pt; new row \(Int(SettingsView.tabBarHeight)) pt; window \(Int(SettingsView.size.width)) x \(Int(SettingsView.size.height))")

        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            shot("settings-\(mode)", SettingsView(model: model, close: {}), size: SettingsView.size, dark: dark)
            for tab in SettingsTab.allCases {
                let size = CGSize(width: 600, height: SettingsView.tabBarHeight - 1)
                shot("tabs-\(tab.title.lowercased())-\(mode)", SettingsTabBar(selection: .constant(tab)), size: size, dark: dark)
            }
        }
    }
}
