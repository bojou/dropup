import AppKit
import Carbon.HIToolbox
import Combine
import DropUpCore
import Observation
import SwiftUI

/// The Shortcuts tab of Settings: one row per action with its switch, its key and Reset. Every control is always
/// shown. When an action is off its key and Reset are greyed out.
struct ShortcutsSettings: View {
    let model: AppModel
    let close: () -> Void
    @State private var recorder = ShortcutRecorder()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(ShortcutAction.allCases) { action in row(action) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text("Changes here apply right away.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 22)
            .frame(height: 60)
        }
        .onAppear { model.shortcuts.refreshAccess() }
        // The user may have allowed or refused Finder in System Settings and come back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.shortcuts.refreshAccess()
        }
    }

    private func row(_ action: ShortcutAction) -> some View {
        let shortcuts: ShortcutController = model.shortcuts
        let settings = shortcuts.settings
        let shortcut = settings[action]
        let verdict = ShortcutRules.check(shortcut.combo, for: action, in: settings)
        let canReset = shortcut.isOn && shortcut.combo != action.defaultCombo
            && !ShortcutRules.check(action.defaultCombo, for: action, in: settings).isRejected
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle(action.title, isOn: Binding(
                    get: { shortcut.isOn },
                    set: { shortcuts.setOn($0, for: action) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                Text(action.title)
                Spacer(minLength: 8)
                Button {
                    recorder.toggle(action, using: shortcuts)
                } label: {
                    Text(recorder.listening == action ? "Type shortcut" : shortcut.combo.display)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minWidth: 92)
                }
                .background(ViewReader { recorder.register($0, for: action) })
                .disabled(!shortcut.isOn)
                Button("Reset") { shortcuts.reset(action) }
                    .disabled(!canReset)
            }
            .help(action.summary)
            if recorder.listening == action, let refusal = recorder.refusal {
                Text(refusal).font(.system(size: 11)).foregroundStyle(.red)
            }
            if shortcut.isOn {
                ForEach(warnings(for: action, shortcut: shortcut, verdict: verdict, shortcuts: shortcuts), id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                if action == .quickUpload, shortcuts.finderAccess == .denied {
                    HStack(spacing: 6) {
                        Label("DropUp isn’t allowed to read the Finder selection.", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Button("Open Settings") { NSWorkspace.shared.open(ShortcutAlerts.automationSettings) }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Things worth knowing about a key that is in use: macOS has it too, or another app got to it first.
    private func warnings(for action: ShortcutAction, shortcut: Shortcut, verdict: ShortcutVerdict, shortcuts: ShortcutController) -> [String] {
        var lines: [String] = []
        if case .warning(let text) = verdict { lines.append(text) }
        switch shortcuts.failures[action] {
        case .takenByAnotherApp?: lines.append("Another app already uses \(shortcut.combo.display).")
        case .unavailable?: lines.append("\(shortcut.combo.display) can’t be used as a shortcut.")
        case nil: break
        }
        return lines
    }
}

private extension ShortcutVerdict {
    var isRejected: Bool {
        if case .rejected = self { return true }
        return false
    }
}

/// Listens for the next key combination, for the key button that was clicked. The key is taken before the rest of the
/// app sees it, so a combination macOS menus use, such as ⌘Q, is recorded and doesn't run.
@MainActor
@Observable
final class ShortcutRecorder {
    /// The action whose key is being recorded.
    private(set) var listening: ShortcutAction?
    /// Why the last key was refused. The recorder keeps listening.
    private(set) var refusal: String?

    @ObservationIgnored private var shortcuts: ShortcutController?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var resignObserver: Any?
    @ObservationIgnored private var buttons: [ShortcutAction: WeakView] = [:]

    /// The key button for `action`, so a click outside it can end the recording.
    func register(_ view: NSView, for action: ShortcutAction) {
        buttons[action] = WeakView(view)
    }

    func toggle(_ action: ShortcutAction, using shortcuts: ShortcutController) {
        if listening == action {
            stop()
        } else {
            start(action, using: shortcuts)
        }
    }

    func stop() {
        guard listening != nil else { return }
        listening = nil
        refusal = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        resignObserver = nil
        shortcuts?.endRecording()
    }

    private func start(_ action: ShortcutAction, using shortcuts: ShortcutController) {
        stop()
        self.shortcuts = shortcuts
        listening = action
        refusal = nil
        shortcuts.beginRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            let swallowed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return swallowed ? nil : event
        }
        // Switching to another window or app ends it, so keys typed elsewhere are never taken for a shortcut.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    /// Returns whether the event was used up here.
    private func handle(_ event: NSEvent) -> Bool {
        guard let action = listening, let shortcuts else { return false }
        switch event.type {
        case .keyDown:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if Int(event.keyCode) == kVK_Escape, flags.isDisjoint(with: [.command, .control, .option, .shift]) {
                stop()
                return true
            }
            guard !event.isARepeat else { return true }
            let combo = KeyCombo(keyCode: event.keyCode, modifiers: Self.modifiers(of: flags), label: Self.label(for: event))
            switch ShortcutRules.check(combo, for: action, in: shortcuts.settings) {
            case .rejected(let text):
                refusal = text
            case .accepted, .warning:
                shortcuts.setCombo(combo, for: action)
                stop()
            }
            return true
        case .leftMouseDown, .rightMouseDown:
            // A click on the key button itself is its own action (it stops the recording); any other click ends it.
            if let button = buttons[action]?.value, event.window === button.window,
               button.convert(button.bounds, to: nil).contains(event.locationInWindow) {
                return false
            }
            stop()
            return false
        default:
            return false
        }
    }

    private static func modifiers(of flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var result: KeyModifiers = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    private static let keyNames: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// What the key is called on the keyboard that pressed it.
    private static func label(for event: NSEvent) -> String {
        if let name = keyNames[Int(event.keyCode)] { return name }
        let letters = (event.charactersIgnoringModifiers ?? "").uppercased()
        return letters.isEmpty ? "Key \(event.keyCode)" : letters
    }
}

private final class WeakView {
    weak var value: NSView?
    init(_ value: NSView) { self.value = value }
}

/// Hands over the AppKit view behind a SwiftUI one, to find out where it is on screen.
private struct ViewReader: NSViewRepresentable {
    let onCreate: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        onCreate(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
