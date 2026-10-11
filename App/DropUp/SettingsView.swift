import SwiftUI
import Observation
import DropUpCore

/// The tabs of the Settings window, in the order they are shown.
private enum SettingsTab: CaseIterable {
    case connection, general, shortcuts

    var title: String {
        switch self {
        case .connection: "Connection"
        case .general: "General"
        case .shortcuts: "Shortcuts"
        }
    }

    /// SF Symbols that exist since macOS 11, so on every macOS DropUp runs on.
    var symbol: String {
        switch self {
        case .connection: "network"
        case .general: "gearshape"
        case .shortcuts: "command"
        }
    }
}

/// Settings: a Connection tab for the server, a General tab for most things and a Shortcuts tab for the global keys.
/// The tabs are a row of icons with their names below, at the top of the window.
struct SettingsView: View {
    /// The height of the tab row, its divider included.
    static let tabBarHeight: CGFloat = 71
    /// What each tab has to itself below the row.
    static let contentHeight: CGFloat = 409
    static let size = CGSize(width: 600, height: tabBarHeight + contentHeight)

    let model: AppModel
    let connection: ConnectionEditing
    /// Closes the Settings window.
    let close: () -> Void
    @State private var tab = SettingsTab.general
    /// The tabs that have been shown. A tab is built the first time it is opened and kept from then on, so opening
    /// Settings builds only the one that shows.
    @State private var visited: Set<SettingsTab> = [.general]

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: Binding(get: { tab }, set: { new in
                // Going to another tab finishes the edit in progress on Connection.
                if tab == .connection, new != .connection { connection.finishEdit() }
                tab = new
                visited.insert(new)
            }))
                .frame(height: Self.tabBarHeight - 1)
            Divider()
            // A tab stays alive once it has been shown, so a Connection form not complete enough to save survives a
            // peek at the others.
            ZStack {
                if visited.contains(.connection) {
                    ConnectionSettings(model: model, editing: connection, close: close)
                        .opacity(tab == .connection ? 1 : 0)
                        .disabled(tab != .connection)
                        .accessibilityHidden(tab != .connection)
                }
                if visited.contains(.general) {
                    GeneralSettings(model: model, close: close)
                        .opacity(tab == .general ? 1 : 0)
                        .disabled(tab != .general)
                        .accessibilityHidden(tab != .general)
                }
                if visited.contains(.shortcuts) {
                    ShortcutsSettings(model: model, close: close)
                        .opacity(tab == .shortcuts ? 1 : 0)
                        .disabled(tab != .shortcuts)
                        .accessibilityHidden(tab != .shortcuts)
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// The row of tabs: an icon above its name, the chosen one in a rounded tile with the accent colour, the others grey
/// with a light tint under the pointer.
private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                SettingsTabButton(tab: tab, isSelected: selection == tab) { selection = tab }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
    }
}

private struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    private let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 20))
                    .frame(height: 24)
                Text(tab.title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(width: 86, height: 54)
            .background(shape.fill(isSelected ? Color.primary.opacity(0.09) : isHovering ? Color.primary.opacity(0.05) : Color.clear))
            .overlay(shape.strokeBorder(Color.primary.opacity(isSelected ? 0.1 : 0), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The Connection tab's form for as long as the Settings window is open. It belongs to the window rather than to the
/// tab, so that closing the window, however it happens, can save the last edit.
@MainActor
@Observable
final class ConnectionEditing {
    private let model: AppModel
    private var editor = ServerEditor(saved: nil, secret: "")
    /// Whether the form has been filled from what is saved. Not until the tab is first shown, as that reads the Keychain.
    private var isLoaded = false
    /// Why the last finished edit could not be saved, until one is.
    private(set) var saveError: String?

    init(model: AppModel) {
        self.model = model
    }

    var draft: ServerDraft {
        get { editor.draft }
        set { editor.draft = newValue }
    }

    /// Fills the form from what is saved, the first time the tab shows. After that it stays as the person left it.
    func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        editor = ServerEditor(saved: model.config, secret: model.config.map { model.password(for: $0) } ?? "")
    }

    /// Saves the form if the edit just finished left it complete and different from what is saved (see `ServerEditor`).
    func finishEdit(showingProblems: Bool = true) {
        guard isLoaded, let change = editor.finishEdit(showingProblems: showingProblems) else { return }
        do {
            try model.save(change.config, secret: change.secret)
            editor.didSave(change.config, secret: change.secret)
            saveError = nil
        } catch {
            saveError = "Couldn’t save: \(error.localizedDescription)"
        }
    }

    /// Takes in a server saved from somewhere else while the window is open, such as a folder picked in Change Folder.
    func followSavedServer() {
        guard isLoaded, model.config != editor.saved else { return }
        editor.savedElsewhere(model.config, secret: model.config.map { model.password(for: $0) } ?? "")
    }
}

/// The server. There is no Save button: each edit is saved once it is finished (see `ServerEditor`), like the other
/// tabs, which apply each change as it is made.
private struct ConnectionSettings: View {
    let model: AppModel
    @Bindable var editing: ConnectionEditing
    let close: () -> Void
    @State private var tester = ConnectionTester()
    @State private var folders = FolderBrowserModel()
    @State private var showBrowser = false
    @State private var browsePath = "/"

    private var draft: ServerDraft { editing.draft }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Connection type").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            Picker("", selection: Binding(
                                get: { draft.transferProtocol },
                                set: {
                                    editing.draft.selectProtocol($0)
                                    // A type not used before starts empty, which isn't a mistake to point out yet.
                                    editing.finishEdit(showingProblems: false)
                                }
                            )) {
                                Text("SFTP").tag(TransferProtocol.sftp)
                                Text("FTP").tag(TransferProtocol.ftp)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 170)
                        }
                        LoginMethodPicker(draft: $editing.draft)
                    }
                    FormField("Display name (optional)", text: $editing.draft.displayName, prompt: "My website", finished: finish)
                    HStack(alignment: .top, spacing: 12) {
                        FormField("Host", text: $editing.draft.host, prompt: "files.example.com", finished: finish)
                        FormField("Port", text: $editing.draft.port, finished: finish).frame(width: 96)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        FormField("Username", text: $editing.draft.username, finished: finish)
                        if draft.usesKey {
                            FormField("Passphrase (optional)", text: $editing.draft.passphrase, secure: true, finished: finish)
                        } else {
                            FormField("Password", text: $editing.draft.password, secure: true, finished: finish)
                        }
                    }
                    if draft.usesKey {
                        KeyFileField(path: $editing.draft.keyFilePath, chosen: finish)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Remote folder").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            TextField("", text: $editing.draft.remoteDirectory)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .onEditFinished(finish)
                            Button("Browse…") {
                                guard draft.isValid else { editing.draft.showProblems = true; return }
                                browsePath = RemotePath.normalizedDirectory(draft.remoteDirectory)
                                showBrowser = true
                            }
                        }
                    }

                    ForEach(draft.problems, id: \.self) { Text($0).font(.callout).foregroundStyle(.red) }

                    HStack(spacing: 12) {
                        Button("Test Connection") {
                            editing.draft.showProblems = true
                            guard draft.isValid else { return }
                            tester.test(draft, using: model.browser)
                        }
                        .disabled(tester.state == .testing)
                        status
                    }

                    serverIdentity
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 18)
            }

            Divider()
            HStack {
                Text(editing.saveError ?? "Changes apply from the next upload.")
                    .font(.system(size: 11))
                    .foregroundStyle(editing.saveError == nil ? Color.secondary : Color.red)
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 22)
            .frame(height: 60)
        }
        .onAppear {
            editing.loadIfNeeded()
            tester.reset()
        }
        .onChange(of: draft.config) { tester.reset() }
        .onChange(of: draft.secret) { tester.reset() }
        // A sign-in method not used before has nothing filled in, which isn't a mistake to point out yet.
        .onChange(of: draft.loginMethod) { editing.finishEdit(showingProblems: false) }
        .onChange(of: model.config) { editing.followSavedServer() }
        .sheet(isPresented: $showBrowser) {
            VStack(spacing: 12) {
                Text("Choose a folder").font(.headline)
                FolderListView(model: model, path: $browsePath, draft: draft, folders: folders)
                    .frame(height: 220)
                Text(browsePath).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { showBrowser = false }
                    Button("Choose") {
                        editing.draft.remoteDirectory = RemotePath.normalizedDirectory(browsePath)
                        showBrowser = false
                        editing.finishEdit()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 380)
        }
    }

    /// The SFTP server's remembered key. Always shown; it is greyed out for FTP, which has none, and until the first
    /// SFTP connection has saved one.
    private var serverIdentity: some View {
        let fingerprint = model.hostKeyFingerprint(for: draft.config)
        let note = draft.transferProtocol == .ftp
            ? "FTP has none. Choose SFTP to see it."
            : "Saved the first time you connect."
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Server identity").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            if let fingerprint {
                Text(fingerprint)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            } else {
                Text(note).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Button("Forget") { model.forgetHostKey(for: draft.config) }
                .controlSize(.small)
                .disabled(fingerprint == nil)
                .help("Trust whatever key this server shows next time you connect.")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch tester.state {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Connecting…") }
                .font(.system(size: 12)).foregroundStyle(.secondary)
        case .success(let ms):
            Label("Connected · \(ms) ms", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(.green)
        case .failure(let message):
            Text(message).font(.system(size: 12)).foregroundStyle(.red).lineLimit(3)
        }
    }

    private func finish() {
        editing.finishEdit()
    }
}

private struct GeneralSettings: View {
    let model: AppModel
    let close: () -> Void
    /// Whether DropUp opens at login. Nil until it has been looked up: asking the system takes a moment, so it is
    /// done after the window is up and not while it is being built.
    @State private var openAtLogin: Bool?
    @State private var loginError: String?

    var body: some View {
        VStack(spacing: 0) {
            form
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
    }

    private var form: some View {
        Form {
            Section("Startup") {
                Toggle("Open DropUp at login", isOn: Binding(
                    get: { openAtLogin ?? false },
                    set: { newValue in
                        do {
                            try LaunchAtLogin.set(newValue)
                            loginError = nil
                        } catch {
                            loginError = "Couldn’t change this: \(error.localizedDescription)"
                        }
                        openAtLogin = LaunchAtLogin.isEnabled
                    }
                ))
                .disabled(openAtLogin == nil)
                if let loginError { Text(loginError).font(.callout).foregroundStyle(.red) }
            }
            Section {
                Picker("Drop zone size", selection: preference(\.dropZoneSize)) {
                    Text("Small").tag(DropZoneSize.small)
                    Text("Default").tag(DropZoneSize.standard)
                    Text("Large").tag(DropZoneSize.large)
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle("Show a notification", isOn: preference(\.notifyWhenDone))
                Toggle("Play a sound", isOn: preference(\.playSound))
            } header: {
                Text("When uploads finish")
            } footer: {
                Text("A lower sound plays when an upload failed.")
                    .font(.system(size: 11))
            }
            Section {
                Picker("When a file already exists", selection: preference(\.conflictPolicy)) {
                    Text("Keep both (add a number)").tag(ConflictPolicy.keepBoth)
                    Text("Replace the existing file").tag(ConflictPolicy.replace)
                }
            }
            recentSection
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { model.updates.automaticallyChecks },
                    set: { model.updates.setAutomaticallyChecks($0) }
                ))
                .disabled(!Updates.isConfigured)
                LabeledContent("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")") {
                    Button("Check Now") { model.updates.checkNow() }
                        .disabled(!model.updates.canCheckNow)
                }
            }
        }
        .formStyle(.grouped)
        .task { openAtLogin = await Task.detached { LaunchAtLogin.isEnabled }.value }
    }

    /// How the popover's Recent list is kept. Every row is always shown: with the list off, the ones that only matter
    /// while it is on are greyed out, and the amount and unit are greyed out unless "Custom" is picked.
    private var recentSection: some View {
        let preferences = model.preferences
        let listIsOn = preferences.recentLimit > 0
        return Section {
            Picker("Keep recent uploads", selection: preference(\.recentLimit)) {
                Text("Off").tag(0)
                ForEach(preferences.recentLimitChoices, id: \.self) { Text("The last \($0)").tag($0) }
            }
            if !listIsOn {
                Label("Failed uploads won’t be saved either.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            Picker("Clear automatically", selection: preference(\.recentClearMode)) {
                Text("When DropUp quits").tag(RecentClearMode.onQuit)
                Text("Never").tag(RecentClearMode.never)
                Text("After 1 hour").tag(RecentClearMode.hour)
                Text("After 1 day").tag(RecentClearMode.day)
                Text("After 1 week").tag(RecentClearMode.week)
                Text("Custom").tag(RecentClearMode.custom)
            }
            .disabled(!listIsOn)
            LabeledContent("Clear after") {
                HStack(spacing: 8) {
                    TextField("", value: clearAmount, format: .number)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        .accessibilityLabel("Amount")
                    Picker("Unit", selection: preference(\.recentClearUnit)) {
                        ForEach(RecentClearUnit.allCases, id: \.self) { unit in
                            Text(Self.name(of: unit, for: preferences.recentClearAmount)).tag(unit)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .disabled(!listIsOn || preferences.recentClearMode != .custom)
            Toggle("Hide file names", isOn: preference(\.hideRecentNames))
        } header: {
            Text("Recent uploads")
        }
    }

    /// The custom clearing time's amount, kept within what `Preferences` accepts.
    private var clearAmount: Binding<Int> {
        Binding(
            get: { model.preferences.recentClearAmount },
            set: { value in
                let range = Preferences.recentClearAmountRange
                model.updatePreferences { $0.recentClearAmount = min(max(value, range.lowerBound), range.upperBound) }
            }
        )
    }

    private static func name(of unit: RecentClearUnit, for amount: Int) -> String {
        let single = amount == 1
        switch unit {
        case .minutes: return single ? "minute" : "minutes"
        case .hours: return single ? "hour" : "hours"
        case .days: return single ? "day" : "days"
        }
    }

    private func preference<Value>(_ keyPath: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(
            get: { model.preferences[keyPath: keyPath] },
            set: { value in model.updatePreferences { $0[keyPath: keyPath] = value } }
        )
    }
}
