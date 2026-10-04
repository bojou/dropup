import AppKit
import SwiftUI

/// THROWAWAY: runs on a CI runner to see how the menubar-only app behaves. Not part of the change.
@MainActor
enum MenubarProbe {
    struct Harness: View {
        @State private var host = ""
        @State private var password = ""
        var body: some View {
            VStack {
                FormField("Host", text: $host)
                FormField("Password", text: $password, secure: true)
            }
            .padding()
            .frame(width: 320)
        }
    }

    static func log(_ text: String) {
        fputs("PROBE \(text)\n", stderr)
    }

    static func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func state(_ window: NSWindow?) -> String {
        guard let window else { return "nil" }
        let order = NSWindow.windowNumbers(options: [])?.map { $0.intValue } ?? []
        let place = order.firstIndex(of: window.windowNumber).map(String.init) ?? "none"
        return "visible=\(window.isVisible) key=\(window.isKeyWindow) app.active=\(NSApp.isActive) place=\(place) of \(order.count)"
    }

    static func run(statusItem: StatusItemController) async {
        log("policy accessory=\(NSApp.activationPolicy() == .accessory) mainMenu=\(NSApp.mainMenu?.items.map(\.title) ?? [])")
        await wait(1.5)
        let onboarding = NSApp.windows.first { $0.title == "Welcome to DropUp" }
        log("1 onboarding at launch: \(state(onboarding))")

        // A window in front of it, then a click on the icon.
        let cover = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.title = "Cover"
        cover.center()
        cover.orderFrontRegardless()
        await wait(0.5)
        log("2 cover in front: onboarding \(state(onboarding)) | cover \(state(cover))")
        statusItem.togglePopover()
        await wait(0.8)
        log("3 after icon click: onboarding \(state(onboarding)) | cover \(state(cover))")

        // Closed with its red button, then a click on the icon.
        onboarding?.close()
        await wait(0.3)
        log("4 onboarding closed: \(state(onboarding))")
        statusItem.togglePopover()
        await wait(0.8)
        log("5 after icon click: onboarding \(state(onboarding))")
        cover.close()
        onboarding?.close()

        // Text fields in a window of this app: paste, select all, copy, cut, close.
        let window = NSWindow(contentViewController: NSHostingController(rootView: Harness()))
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.title = "Harness"
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        await wait(1.0)
        log("6 harness: \(state(window)) keyWindow=\(NSApp.keyWindow?.title ?? "nil")")

        func fields(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { sub -> [NSTextField] in
                (sub is NSTextField && (sub as! NSTextField).isEditable ? [sub as! NSTextField] : []) + fields(in: sub)
            }
        }
        func press(_ key: String, code: UInt16) async {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: code
            )
            if let event { NSApp.postEvent(event, atStart: true) }
            await wait(0.4)
        }
        func editing() -> String? { (window.firstResponder as? NSTextView)?.string }

        let all = fields(in: window.contentView!)
        log("7 text fields found: \(all.map { String(describing: type(of: $0)) })")
        for (index, field) in all.enumerated() {
            let kind = String(describing: type(of: field))
            let focused = window.makeFirstResponder(field)
            log("8.\(index) \(kind) focus=\(focused) responder=\(String(describing: type(of: window.firstResponder!)))")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("pasted-text", forType: .string)
            await press("v", code: 9)
            log("9.\(index) \(kind) after paste: \(editing().map { "'\($0)'" } ?? "not editing")")
            NSPasteboard.general.clearContents()
            await press("a", code: 0)
            await press("c", code: 8)
            log("10.\(index) \(kind) pasteboard after select all + copy: \(NSPasteboard.general.string(forType: .string).map { "'\($0)'" } ?? "empty")")
            await press("x", code: 7)
            log("11.\(index) \(kind) after cut: \(editing().map { "'\($0)'" } ?? "not editing") pasteboard=\(NSPasteboard.general.string(forType: .string).map { "'\($0)'" } ?? "empty")")
        }
        await press("w", code: 13)
        log("12 after Cmd+W: \(state(window))")
        log("DONE")
    }
}
