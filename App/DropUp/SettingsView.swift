import SwiftUI
import DropUpCore

/// Settings: a Connection tab for the server and a General tab for everything else.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            ConnectionSettings(model: model)
                .tabItem { Label("Connection", systemImage: "externaldrive.connected.to.line.below") }
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 480)
    }
}

private struct ConnectionSettings: View {
    let model: AppModel
    @State private var draft = ServerDraft()
    @State private var tester = ConnectionTester()
    @State private var folders = FolderBrowserModel()
    @State private var showBrowser = false
    @State private var browsePath = "/"
    @State private var saved = false
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Protocol", selection: Binding(
                    get: { draft.transferProtocol },
                    set: { draft.selectProtocol($0) }
                )) {
                    Text("SFTP").tag(TransferProtocol.sftp)
                    Text("FTP").tag(TransferProtocol.ftp)
                }
                .pickerStyle(.segmented)

                LabeledContent("Server") {
                    HStack(spacing: 6) {
                        TextField("", text: $draft.host, prompt: Text("files.example.com")).labelsHidden()
                        Text(":").foregroundStyle(.secondary)
                        TextField("Port", text: $draft.port).labelsHidden().frame(width: 64)
                    }
                }
                TextField("Username", text: $draft.username)
                SecureField("Password", text: $draft.password)
                LabeledContent("Remote folder") {
                    HStack(spacing: 6) {
                        TextField("", text: $draft.remoteDirectory).labelsHidden()
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

                if draft.transferProtocol == .sftp, let fingerprint = model.hostKeyFingerprint(for: draft.config) {
                    LabeledContent("Server identity") {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(fingerprint)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                            Button("Forget") { model.forgetHostKey(for: draft.config) }
                                .controlSize(.small)
                                .help("Trust whatever key this server shows next time you connect.")
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text(saveError ?? (saved ? "Saved. Changes apply from the next upload." : "Changes apply from the next upload."))
                    .font(.system(size: 11))
                    .foregroundStyle(saveError == nil ? Color.secondary : Color.red)
                Spacer()
                Button("Revert") { load() }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .onAppear(perform: load)
        .onChange(of: draft.config) { tester.reset(); saved = false }
        .onChange(of: draft.password) { tester.reset(); saved = false }
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
        saved = false
        saveError = nil
    }

    private func save() {
        draft.showProblems = true
        guard draft.isValid else { return }
        do {
            try model.save(draft.config, password: draft.password)
            saveError = nil
            // `saved` is set after the draft settles, because editing the draft clears it.
            DispatchQueue.main.async { saved = true }
        } catch {
            saveError = "Couldn’t save: \(error.localizedDescription)"
        }
    }
}

private struct GeneralSettings: View {
    let model: AppModel
    @State private var openAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open DropUp at login", isOn: Binding(
                    get: { openAtLogin },
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
                if let loginError { Text(loginError).font(.callout).foregroundStyle(.red) }
            }
            Section("When uploads finish") {
                Toggle("Show a notification", isOn: preference(\.notifyWhenDone))
                Toggle("Play a sound", isOn: preference(\.playSound))
            }
            Section {
                Picker("Same file name", selection: preference(\.conflictPolicy)) {
                    Text("Keep both (add a number)").tag(ConflictPolicy.keepBoth)
                    Text("Replace the existing file").tag(ConflictPolicy.replace)
                }
                Picker("Recent list", selection: preference(\.recentLimit)) {
                    ForEach(Preferences.recentLimitOptions, id: \.self) { Text("Show the last \($0) uploads").tag($0) }
                }
            } footer: {
                Text("“Same file name” is what happens when the folder already has a file with that name.")
                    .font(.system(size: 11))
            }
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            }
        }
        .formStyle(.grouped)
        .onAppear { openAtLogin = LaunchAtLogin.isEnabled }
    }

    private func preference<Value>(_ keyPath: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(
            get: { model.preferences[keyPath: keyPath] },
            set: { value in model.updatePreferences { $0[keyPath: keyPath] = value } }
        )
    }
}
