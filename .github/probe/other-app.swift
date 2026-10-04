import AppKit

// A stand-in for "some other app": a regular app with a window that covers the screen. It brings itself to the front
// whenever /tmp/probe-helper.cmd changes and says so in /tmp/probe-helper.ack.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Other app"
window.backgroundColor = .systemRed
window.isReleasedWhenClosed = false
func front() {
    app.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
}
front()
try? "\(window.windowNumber) \(getpid())".write(toFile: "/tmp/probe-helper.ready", atomically: true, encoding: .utf8)
var last = ""
Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
    guard let command = try? String(contentsOfFile: "/tmp/probe-helper.cmd", encoding: .utf8), command != last else { return }
    last = command
    front()
    try? command.write(toFile: "/tmp/probe-helper.ack", atomically: true, encoding: .utf8)
}
app.run()
