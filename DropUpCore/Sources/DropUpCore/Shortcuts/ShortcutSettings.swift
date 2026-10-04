import Foundation

/// What a global shortcut does.
public enum ShortcutAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case quickUpload
    case uploadClipboard
    case uploadScreenshot

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .quickUpload: "Quick Upload"
        case .uploadClipboard: "Upload from Clipboard"
        case .uploadScreenshot: "Upload Latest Screenshot"
        }
    }

    /// What it does, for a tooltip.
    public var summary: String {
        switch self {
        case .quickUpload: "Uploads the files and folders selected in Finder."
        case .uploadClipboard: "Uploads what is on the clipboard: files, an image or text."
        case .uploadScreenshot: "Uploads the newest screenshot, if it is from the last 10 minutes."
        }
    }

    /// ⌃⌥⌘ and a letter: hard to hit by accident and rarely taken.
    public var defaultCombo: KeyCombo {
        let modifiers: KeyModifiers = [.control, .option, .command]
        switch self {
        case .quickUpload: return KeyCombo(keyCode: 32, modifiers: modifiers, label: "U")
        case .uploadClipboard: return KeyCombo(keyCode: 9, modifiers: modifiers, label: "V")
        case .uploadScreenshot: return KeyCombo(keyCode: 1, modifiers: modifiers, label: "S")
        }
    }
}

/// One action's switch and key.
public struct Shortcut: Codable, Equatable, Sendable {
    public var isOn: Bool
    public var combo: KeyCombo

    public init(isOn: Bool, combo: KeyCombo) {
        self.isOn = isOn
        self.combo = combo
    }
}

/// The switch and the key of every action. All of them start off: taking over a key everywhere is something to ask for.
public struct ShortcutSettings: Codable, Equatable, Sendable {
    private var entries: [ShortcutAction: Shortcut]

    public init() {
        entries = [:]
    }

    public subscript(action: ShortcutAction) -> Shortcut {
        get { entries[action] ?? Shortcut(isOn: false, combo: action.defaultCombo) }
        set { entries[action] = newValue }
    }

    /// Two settings are equal when every action reads the same, whether or not it was ever touched.
    public static func == (lhs: ShortcutSettings, rhs: ShortcutSettings) -> Bool {
        ShortcutAction.allCases.allSatisfy { lhs[$0] == rhs[$0] }
    }

    /// The actions that are on, with their keys.
    public var active: [(action: ShortcutAction, combo: KeyCombo)] {
        ShortcutAction.allCases.compactMap { action in
            let shortcut = self[action]
            return shortcut.isOn ? (action, shortcut.combo) : nil
        }
    }

    // Stored by name, so a later version can add actions and an earlier one still reads the file.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let stored = (try? container.decode([String: Shortcut].self)) ?? [:]
        entries = [:]
        for action in ShortcutAction.allCases {
            if let shortcut = stored[action.rawValue] { entries[action] = shortcut }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: entries.map { ($0.key.rawValue, $0.value) }))
    }
}
