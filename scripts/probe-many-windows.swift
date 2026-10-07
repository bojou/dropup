// PROBE ONLY: another app with many ordinary windows on screen, like a busy Mac.
import AppKit
let count = Int(CommandLine.arguments.dropFirst().first ?? "60") ?? 60
let app = NSApplication.shared
app.setActivationPolicy(.regular)
var keep: [NSWindow] = []
for i in 0..<count {
    let w = NSWindow(contentRect: NSRect(x: 40 + (i % 12) * 60, y: 60 + (i / 12) * 50, width: 500, height: 350),
                     styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    w.title = "Other \(i)"
    w.isReleasedWhenClosed = false
    w.orderFront(nil)
    keep.append(w)
}
app.activate(ignoringOtherApps: true)
app.run()
