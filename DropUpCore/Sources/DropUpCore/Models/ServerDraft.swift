import Foundation

/// The server form while it is being edited. Everything is a string so half-typed values (an empty port)
/// are allowed; `config` turns it into a real `ServerConfig`. Shared by onboarding and Settings.
public struct ServerDraft: Equatable, Sendable {
    public var transferProtocol: TransferProtocol = .sftp
    public var host = ""
    public var port = String(TransferProtocol.sftp.defaultPort)
    public var username = ""
    public var password = ""
    public var remoteDirectory = "/"
    /// Optional; empty means none.
    public var displayName = ""
    /// Problems are only shown after the first attempt to continue or save.
    public var showProblems = false

    public init() {}

    public init(config: ServerConfig, password: String) {
        transferProtocol = config.transferProtocol
        host = config.host
        port = String(config.port)
        username = config.username
        self.password = password
        remoteDirectory = config.remoteDirectory
        displayName = config.displayName ?? ""
    }

    /// What the form holds for one connection type.
    private struct Fields: Equatable, Sendable {
        var host = ""
        var port: String
        var username = ""
        var password = ""
        var remoteDirectory = "/"
        var displayName = ""

        init(for transferProtocol: TransferProtocol) {
            port = String(transferProtocol.defaultPort)
        }
    }

    /// What was typed for the types that aren't showing, so going back to one finds it as it was left. A type that
    /// has not been shown yet starts empty: SFTP and FTP are different logins, and nothing typed for one is
    /// carried over to the other (least of all a password, which plain FTP would send unencrypted).
    private var others: [TransferProtocol: Fields] = [:]

    private var fields: Fields {
        get {
            var current = Fields(for: transferProtocol)
            current.host = host
            current.port = port
            current.username = username
            current.password = password
            current.remoteDirectory = remoteDirectory
            current.displayName = displayName
            return current
        }
        set {
            host = newValue.host
            port = newValue.port
            username = newValue.username
            password = newValue.password
            remoteDirectory = newValue.remoteDirectory
            displayName = newValue.displayName
        }
    }

    /// Shows the form for another connection type, with the fields it had when it was last shown (empty the first
    /// time, with that type's usual port). What was typed for the type that was showing is kept for when it comes back.
    public mutating func selectProtocol(_ new: TransferProtocol) {
        guard new != transferProtocol else { return }
        others[transferProtocol] = fields
        fields = others.removeValue(forKey: new) ?? Fields(for: new)
        transferProtocol = new
        // An empty form isn't a mistake to point out yet.
        showProblems = false
    }

    public var config: ServerConfig {
        ServerConfig(
            transferProtocol: transferProtocol,
            host: host.trimmingCharacters(in: .whitespaces),
            port: Int(port.trimmingCharacters(in: .whitespaces)) ?? 0,
            username: username.trimmingCharacters(in: .whitespaces),
            remoteDirectory: RemotePath.normalizedDirectory(remoteDirectory),
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    public var isValid: Bool { config.isValid }

    public var problems: [String] {
        guard showProblems else { return [] }
        return config.validationErrors().map(\.displayMessage)
    }
}

extension ServerConfigError {
    public var displayMessage: String {
        switch self {
        case .emptyHost: "Enter the server address."
        case .invalidHost: "Enter just the server name, like ftp.example.com."
        case .invalidPort: "Port must be a number between 1 and 65535."
        case .emptyUsername: "Enter your username."
        }
    }
}

/// The five onboarding screens and what is needed to leave each one.
public enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome, connectionType, server, folder, done

    public var title: String {
        switch self {
        case .welcome: "Welcome"
        case .connectionType: "Connection type"
        case .server: "Server"
        case .folder: "Folder"
        case .done: "Done"
        }
    }

    public var nextLabel: String {
        switch self {
        case .welcome: "Get Started"
        case .done: "Done"
        case .connectionType, .server, .folder: "Continue"
        }
    }

    public var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    public var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
    public var showsBack: Bool { self != .welcome && self != .done }

    /// Whether the draft is complete enough to leave this step.
    public func canContinue(with draft: ServerDraft) -> Bool {
        switch self {
        case .welcome, .connectionType, .done: true
        case .server, .folder: draft.isValid
        }
    }

    /// `Step 2 of 5: Connection type`, read by VoiceOver for the progress dots.
    public var accessibilityLabel: String {
        "Step \(rawValue + 1) of \(Self.allCases.count): \(title)"
    }
}
