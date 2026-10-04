import Foundation

/// What the recorder says about a key someone just pressed.
public enum ShortcutVerdict: Equatable, Sendable {
    case accepted
    /// Usable, with something worth knowing (macOS uses it too).
    case warning(String)
    case rejected(String)
}

/// What a shortcut has to look like, and the combinations macOS uses for itself.
public enum ShortcutRules {
    /// Keys the system already uses everywhere. They can still be chosen, with a warning.
    static let systemShortcuts: [(combo: (keyCode: UInt16, modifiers: KeyModifiers), use: String)] = [
        ((49, [.control, .command]), "Emoji & Symbols"),
        ((49, [.option, .command]), "Finder search"),
        ((12, [.control, .command]), "Lock Screen"),
        ((12, [.shift, .command]), "Log Out"),
        ((3, [.control, .command]), "Enter Full Screen"),
        ((2, [.control, .command]), "Look Up"),
        ((2, [.option, .command]), "show or hide the Dock"),
        ((53, [.option, .command]), "Force Quit"),
        ((20, [.shift, .command]), "Screenshot"),
        ((21, [.shift, .command]), "Screenshot"),
        ((23, [.shift, .command]), "Screenshot"),
        ((22, [.shift, .command]), "Screenshot"),
        ((28, [.control, .option, .command]), "invert colors"),
    ]

    /// Checks `combo` as the key for `action`, given everything already set.
    ///
    /// It needs two modifier keys, one of them Control or Command: macOS 15 no longer delivers global shortcuts
    /// made of Option, or Option and Shift, with a key, and a combo like that would register and then never fire.
    public static func check(_ combo: KeyCombo, for action: ShortcutAction, in settings: ShortcutSettings) -> ShortcutVerdict {
        let modifiers = combo.modifiers
        if modifiers.count < 2 || !(modifiers.contains(.control) || modifiers.contains(.command)) {
            return .rejected("Use at least two of ⌃ ⌥ ⇧ ⌘ with the key, and one of them ⌃ or ⌘.")
        }
        for other in ShortcutAction.allCases where other != action {
            let theirs = settings[other].combo
            if theirs.keyCode == combo.keyCode && theirs.modifiers == modifiers {
                return .rejected("\(combo.display) is already used by \(other.title).")
            }
        }
        if let match = systemShortcuts.first(where: { $0.combo.keyCode == combo.keyCode && $0.combo.modifiers == modifiers }) {
            return .warning("macOS uses \(combo.display) for \(match.use).")
        }
        return .accepted
    }
}
