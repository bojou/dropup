import Foundation

/// The modifier keys of a shortcut. Kept apart from AppKit's flag values so the rules around them can be tested anywhere.
public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)

    public var count: Int { rawValue.nonzeroBitCount }

    /// ⌃⌥⇧⌘, in the order macOS writes them.
    public var symbols: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }
}

/// A key with its modifiers, such as ⌃⌥⌘U.
public struct KeyCombo: Codable, Hashable, Sendable {
    /// The virtual key code the system reports for the key.
    public var keyCode: UInt16
    public var modifiers: KeyModifiers
    /// What the key is called on the keyboard that recorded it ("U"), so the shortcut reads right on any layout.
    public var label: String

    public init(keyCode: UInt16, modifiers: KeyModifiers, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    /// `⌃⌥⌘U`
    public var display: String { modifiers.symbols + label }
}
