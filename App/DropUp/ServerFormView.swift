import SwiftUI
import DropUpCore

/// The host / credentials / path form, shared by onboarding and Settings.
struct ServerFormView: View {
    @Binding var draft: ServerDraft

    var body: some View {
        Form {
            Picker("Protocol", selection: $draft.transferProtocol) {
                Text("FTP").tag(TransferProtocol.ftp)
                Text("SFTP").tag(TransferProtocol.sftp)
            }
            .pickerStyle(.segmented)
            .onChange(of: draft.transferProtocol) { old, new in
                if draft.port == String(old.defaultPort) { draft.port = String(new.defaultPort) }
            }
            TextField("Server", text: $draft.host, prompt: Text("ftp.example.com"))
            TextField("Port", text: $draft.port)
            TextField("Username", text: $draft.username)
            SecureField("Password", text: $draft.password)
            TextField("Upload folder", text: $draft.remoteDirectory, prompt: Text("/public_html/drops"))

            ForEach(draft.problems, id: \.self) { problem in
                Text(problem).foregroundStyle(.red).font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}

/// Editable form state. Kept as strings so half-typed values (like an empty port) are allowed.
struct ServerDraft: Equatable {
    var transferProtocol: TransferProtocol = .ftp
    var host = ""
    var port = String(TransferProtocol.ftp.defaultPort)
    var username = ""
    var password = ""
    var remoteDirectory = "/"
    var showProblems = false

    init() {}

    init(config: ServerConfig, password: String) {
        transferProtocol = config.transferProtocol
        host = config.host
        port = String(config.port)
        username = config.username
        self.password = password
        remoteDirectory = config.remoteDirectory
    }

    var config: ServerConfig {
        ServerConfig(
            transferProtocol: transferProtocol,
            host: host.trimmingCharacters(in: .whitespaces),
            port: Int(port) ?? 0,
            username: username.trimmingCharacters(in: .whitespaces),
            remoteDirectory: RemotePath.normalizedDirectory(remoteDirectory)
        )
    }

    var problems: [String] {
        guard showProblems else { return [] }
        return config.validationErrors().map {
            switch $0 {
            case .emptyHost: "Enter the server address."
            case .invalidHost: "Enter just the server name, like ftp.example.com."
            case .invalidPort: "Port must be a number between 1 and 65535."
            case .emptyUsername: "Enter your username."
            }
        }
    }
}
