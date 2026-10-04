import AppKit

/// Cut, copy, paste and select all in text fields, and ⌘W for the window in front.
///
/// DropUp is a menubar-only app, so it has no menu bar on screen to carry Edit > Cut, Copy, Paste and Select All, and
/// macOS turns those keys into actions through that menu. This answers them itself, but only while a text field is
/// being edited (a list in the Browse window keeps its own ⌘C and ⌘V).
@MainActor
final class EditKeys {
    private var monitor: Any?
    /// True while something else wants every key, such as the shortcut recorder in Settings.
    private let isPaused: @MainActor () -> Bool

    init(isPaused: @escaping @MainActor () -> Bool) {
        self.isPaused = isPaused
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let used = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return used ? nil : event
        }
    }

    /// Returns whether the key was used up here.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command, !isPaused(), let window = NSApp.keyWindow,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }

        if key == "w" {
            // A sheet or a panel has no close button, so ⌘W leaves it alone.
            guard window.styleMask.contains(.closable) else { return false }
            window.performClose(nil)
            return true
        }
        guard let text = window.firstResponder as? NSText else { return false }
        switch key {
        case "x": text.cut(nil)
        case "c": text.copy(nil)
        case "v": text.paste(nil)
        case "a": text.selectAll(nil)
        default: return false
        }
        return true
    }
}
