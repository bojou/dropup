import SwiftUI
import DropUpCore

/// First-run setup: welcome, connection type, server details, upload folder, done.
struct OnboardingView: View {
    let model: AppModel
    let onFinish: () -> Void

    @State private var step = OnboardingStep.welcome
    @State private var draft = ServerDraft()
    @State private var tester = ConnectionTester()
    @State private var folders = FolderBrowserModel()
    @State private var openAtLogin = true
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case .welcome: welcome
                case .connectionType: connectionType
                case .server: serverDetails
                case .folder: uploadFolder
                case .done: allSet
                }
            }
            .padding(.horizontal, 48)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(width: 600, height: 460)
        .onChange(of: draft.config) { tester.reset() }
        .onChange(of: draft.password) { tester.reset() }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.up.to.line")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Color.accentColor))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                .padding(.bottom, 6)
            Text("Welcome to DropUp").font(.system(size: 24, weight: .semibold))
            Text("Drop a file on the menubar icon and it uploads straight to your server. Let’s connect it first.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
    }

    private var connectionType: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading("How do you connect to your server?", subtitle: "You can change this later in Settings.")
            HStack(spacing: 14) {
                protocolCard(.sftp, title: "SFTP", recommended: true,
                             detail: "Encrypted over SSH. The safer choice, and most hosts offer it.")
                protocolCard(.ftp, title: "FTP", recommended: false,
                             detail: "Not encrypted. Use it only if your server has no SFTP.")
            }
            .padding(.top, 18)
            Spacer()
        }
        .padding(.top, 18)
    }

    private func protocolCard(_ proto: TransferProtocol, title: String, recommended: Bool, detail: String) -> some View {
        let selected = draft.transferProtocol == proto
        return Button {
            draft.selectProtocol(proto)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.system(size: 16, weight: .semibold))
                    if recommended {
                        Text("RECOMMENDED")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Text("Port \(proto.defaultPort)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Color.accentColor.opacity(0.07) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.18), lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var serverDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Server details", subtitle: "Connecting over \(draft.transferProtocol.rawValue.uppercased()).")
            HStack(alignment: .top, spacing: 12) {
                field("Host", text: $draft.host, prompt: "files.example.com")
                field("Port", text: $draft.port, prompt: "").frame(width: 96)
            }
            HStack(alignment: .top, spacing: 12) {
                field("Username", text: $draft.username, prompt: "")
                FormField("Password", text: $draft.password, secure: true)
            }
            ForEach(draft.problems, id: \.self) { Text($0).font(.callout).foregroundStyle(.red) }
            HStack(spacing: 12) {
                Button("Test Connection") { runTest() }
                    .disabled(tester.state == .testing)
                testStatus
            }
            Spacer()
            Label("Your password is stored in the macOS Keychain.", systemImage: "lock")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.bottom, 14)
        }
        .padding(.top, 18)
    }

    @ViewBuilder
    private var testStatus: some View {
        switch tester.state {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Connecting…") }
                .font(.system(size: 12)).foregroundStyle(.secondary)
        case .success(let ms):
            Label("Connected. The server answered in \(ms) ms.", systemImage: "checkmark")
                .font(.system(size: 12)).foregroundStyle(.green)
        case .failure(let message):
            Text(message).font(.system(size: 12)).foregroundStyle(.red).lineLimit(3)
        }
    }

    private var uploadFolder: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Where should uploads go?", subtitle: "Pick a folder on \(draft.host), or type a path.")
            TextField("Remote folder", text: $draft.remoteDirectory)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { reloadFolders() }
                .padding(.top, 6)
            FolderListView(model: model, path: $draft.remoteDirectory, draft: draft, folders: folders)
                .frame(height: 150)
            HStack {
                Text("If a file with the same name exists").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { model.preferences.conflictPolicy },
                    set: { value in model.updatePreferences { $0.conflictPolicy = value } }
                )) {
                    Text("Keep both").tag(ConflictPolicy.keepBoth)
                    Text("Replace").tag(ConflictPolicy.replace)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
            }
            if let saveError { Text(saveError).font(.callout).foregroundStyle(.red) }
            ForEach(draft.problems, id: \.self) { Text($0).font(.callout).foregroundStyle(.red) }
        }
        .padding(.top, 18)
    }

    private var allSet: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.green))
            Text("You’re all set").font(.system(size: 22, weight: .semibold))
            Text("Drag any file onto the DropUp icon in your menubar. It goes to \(draft.config.remoteDirectory) on \(draft.host).")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Toggle("Open DropUp at login", isOn: $openAtLogin).padding(.top, 10)
        }
    }

    // MARK: Pieces

    private func heading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 20, weight: .semibold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        FormField(label, text: text, prompt: prompt)
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.self) { dot in
                    Capsule()
                        .fill(dot.rawValue <= step.rawValue ? Color.accentColor : Color.primary.opacity(0.18))
                        .frame(width: dot == step ? 18 : 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(step.accessibilityLabel)
            Spacer()
            Button("Back") { go(to: step.previous) }
                .disabled(!step.showsBack)
            Button(step.nextLabel) { advance() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 22)
        .frame(height: 60)
    }

    // MARK: Actions

    private func go(to next: OnboardingStep?) {
        guard let next else { return }
        withAnimation(.easeInOut(duration: 0.18)) { step = next }
    }

    private func advance() {
        switch step {
        case .server:
            draft.showProblems = true
            guard step.canContinue(with: draft) else { return }
            draft.showProblems = false
            go(to: step.next)
        case .folder:
            draft.showProblems = true
            guard step.canContinue(with: draft) else { return }
            do {
                try model.save(draft.config, password: draft.password)
                saveError = nil
                go(to: step.next)
            } catch {
                saveError = "Couldn’t save: \(error.localizedDescription)"
            }
        case .done:
            try? LaunchAtLogin.set(openAtLogin)
            onFinish()
        case .welcome, .connectionType:
            go(to: step.next)
        }
    }

    private func runTest() {
        draft.showProblems = true
        guard draft.isValid else { return }
        tester.test(draft, using: model.browser)
    }

    private func reloadFolders() {
        folders.load(RemotePath.normalizedDirectory(draft.remoteDirectory), draft: draft, using: model.browser)
    }
}
