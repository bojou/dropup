import SwiftUI
import DropUpCore

/// Settings: a Connection tab for the server, a General tab for most things and a Shortcuts tab for the global keys.
/// Same window size and chrome as onboarding, so the two read as one app.
struct SettingsView: View {
    static let size = CGSize(width: 600, height: 460)

    let model: AppModel
    /// Closes the Settings window.
    let close: () -> Void
    @State private var tab = Tab.general
    /// The tabs that have been shown. A tab is built the first time it is opened and kept from then on, so opening
    /// Settings builds only the one that shows, and unsaved edits on Connection still survive a peek at the others.
    @State private var visited: Set<Tab> = [.general]

    private enum Tab { case connection, general, shortcuts }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { tab }, set: { tab = $0; visited.insert($0) })) {
                Text("Connection").tag(Tab.connection)
                Text("General").tag(Tab.general)
                Text("Shortcuts").tag(Tab.shortcuts)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)
            .padding(.vertical, 14)
            Divider()
            // A tab stays alive once it has been shown, so unsaved edits on Connection survive a peek at the others.
            ZStack {
                if visited.contains(.connection) {
                    ConnectionSettings(model: model, close: close)
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

private struct ConnectionSettings: View {
    let model: AppModel
    let close: () -> Void
    @State private var draft = ServerDraft()
    @State private var tester = ConnectionTester()
    @State private var folders = FolderBrowserModel()
    @State private var showBrowser = false
    @State private var browsePath = "/"
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Connection type").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { draft.transferProtocol },
                            set: { draft.selectProtocol($0) }
                        )) {
                            Text("SFTP").tag(TransferProtocol.sftp)
                            Text("FTP").tag(TransferProtocol.ftp)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 170)
                    }
                    FormField("Display name (optional)", text: $draft.displayName, prompt: "My website")
                    HStack(alignment: .top, spacing: 12) {
                        FormField("Host", text: $draft.host, prompt: "files.example.com")
                        FormField("Port", text: $draft.port).frame(width: 96)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        FormField("Username", text: $draft.username)
                        FormField("Password", text: $draft.password, secure: true)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Remote folder").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            TextField("", text: $draft.remoteDirectory)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            Button("Browse…") {
                                guard draft.isValid else { draft.showProblems = true; return }
                                browsePath = RemotePath.normalizedDirectory(draft.remoteDirectory)
                                showBrowser = true
                            }
                        }
                    }

                    ForEach(draft.problems, id: \.self) { Text($0).font(.callout).foregroundStyle(.red) }

                    HStack(spacing: 12) {
                        Button("Test Connection") {
                            draft.showProblems = true
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
                Text(saveError ?? "Changes apply from the next upload.")
                    .font(.system(size: 11))
                    .foregroundStyle(saveError == nil ? Color.secondary : Color.red)
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 22)
            .frame(height: 60)
        }
        .onAppear(perform: load)
        .onChange(of: draft.config) { tester.reset() }
        .onChange(of: draft.password) { tester.reset() }
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
                        draft.remoteDirectory = RemotePath.normalizedDirectory(browsePath)
                        showBrowser = false
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

    private func load() {
        if let config = model.config {
            draft = ServerDraft(config: config, password: model.password(for: config))
        } else {
            draft = ServerDraft()
        }
        tester.reset()
        saveError = nil
    }

    private func save() {
        draft.showProblems = true
        guard draft.isValid else { return }
        do {
            try model.save(draft.config, password: draft.password)
            saveError = nil
            close()
        } catch {
            saveError = "Couldn’t save: \(error.localizedDescription)"
        }
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
