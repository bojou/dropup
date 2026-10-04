import AppKit

// A stand-in for "some other app", for the window test in CI (see WindowOrderSelfTest.swift): a regular app with a
// window that covers the screen. It comes to the front whenever /tmp/dropup-window-test.cmd changes, and says so in
// /tmp/dropup-window-test.ack. The command "<n> yield <pid>" also lets that process take over the active app, the way
// macOS does when a person clicks on its menubar icon.
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
try? "\(window.windowNumber)".write(toFile: "/tmp/dropup-window-test.ready", atomically: true, encoding: .utf8)
var last = ""
Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
    guard let command = try? String(contentsOfFile: "/tmp/dropup-window-test.cmd", encoding: .utf8), command != last else { return }
    last = command
    let words = command.split(separator: " ")
    if words.count == 3, words[1] == "yield", let pid = Int32(words[2]), let target = NSRunningApplication(processIdentifier: pid) {
        app.yieldActivation(to: target)
    } else {
        front()
    }
    try? command.write(toFile: "/tmp/dropup-window-test.ack", atomically: true, encoding: .utf8)
}
app.run()
