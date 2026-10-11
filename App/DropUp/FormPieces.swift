import AppKit
import SwiftUI
import DropUpCore

/// A small label above a rounded text field, as used in onboarding and Settings.
struct FormField: View {
    let label: String
    @Binding var text: String
    var prompt = ""
    var secure = false
    /// Runs once the person is done with the field (see `onEditFinished`).
    var finished: (() -> Void)?

    init(_ label: String, text: Binding<String>, prompt: String = "", secure: Bool = false, finished: (() -> Void)? = nil) {
        self.label = label
        self._text = text
        self.prompt = prompt
        self.secure = secure
        self.finished = finished
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            if secure {
                SecureField("", text: $text, prompt: Text(prompt)).textFieldStyle(.roundedBorder).onEditFinished(finished)
            } else {
                TextField("", text: $text, prompt: Text(prompt)).textFieldStyle(.roundedBorder).onEditFinished(finished)
            }
        }
    }
}

extension View {
    /// Runs `action` once the person is done with this text field: it loses the keyboard, or Return is pressed in it.
    /// Not at each key, so nothing half typed is acted on. Without an action the field is left as it is.
    func onEditFinished(_ action: (() -> Void)?) -> some View {
        modifier(EditFinished(action: action))
    }
}

private struct EditFinished: ViewModifier {
    let action: (() -> Void)?
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if let action {
            content
                .focused($focused)
                .onSubmit(action)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { action() }
                }
        } else {
            content
        }
    }
}

/// The "Private key" row of an SSH key login: the chosen file's name and a button to choose another.
/// The key stays where it is; only the location of the file is kept.
struct KeyFileField: View {
    @Binding var path: String
    /// Runs after a file has been chosen.
    var chosen: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Private key").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Group {
                    if path.isEmpty {
                        Text("No file chosen").foregroundStyle(.tertiary)
                    } else {
                        Text((path as NSString).lastPathComponent).truncationMode(.middle)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                .help(path)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Private key")
                .accessibilityValue(path.isEmpty ? "No file chosen" : (path as NSString).lastPathComponent)
                Button("Choose…", action: choose)
            }
        }
    }

    /// Asks for the key file. Hidden files are shown and the panel starts in `~/.ssh`, where keys live.
    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose your private key"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: ssh.path, isDirectory: &isFolder), isFolder.boolValue {
            panel.directoryURL = ssh
        }
        NSApp.activate(ignoringOtherApps: true)
        let chosen: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url {
                path = url.path
                chosen?()
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: chosen)
        } else {
            panel.begin(completionHandler: chosen)
        }
    }
}

/// "Sign in with: Password | SSH key". An SSH key is for SFTP only, so with FTP the choice is shown but greyed out.
struct LoginMethodPicker: View {
    @Binding var draft: ServerDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Sign in with").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { draft.usesKey ? LoginMethod.sshKey : .password },
                set: { draft.selectLoginMethod($0) }
            )) {
                Text("Password").tag(LoginMethod.password)
                Text("SSH key").tag(LoginMethod.sshKey)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            .disabled(draft.transferProtocol == .ftp)
        }
    }
}
