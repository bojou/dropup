import Foundation

/// The transfer protocol used to reach the server.
public enum TransferProtocol: String, Codable, CaseIterable, Sendable {
    case ftp
    case sftp

    public var defaultPort: Int {
        switch self {
        case .ftp: 21
        case .sftp: 22
        }
    }
}

/// Everything DropUp needs to know about the destination, except the password.
/// The password lives in the Keychain (see `CredentialStore`) and is looked up by `credentialKey`.
public struct ServerConfig: Codable, Equatable, Sendable {
    public var transferProtocol: TransferProtocol
    public var host: String
    public var port: Int
    public var username: String
    /// Directory on the server that dropped files are uploaded into, e.g. `/public_html/drops`.
    public var remoteDirectory: String

    public init(
        transferProtocol: TransferProtocol,
        host: String,
        port: Int? = nil,
        username: String,
        remoteDirectory: String
    ) {
        self.transferProtocol = transferProtocol
        self.host = host
        self.port = port ?? transferProtocol.defaultPort
        self.username = username
        self.remoteDirectory = remoteDirectory
    }

    /// Stable key used to store and fetch the password for this server.
    public var credentialKey: String {
        "\(transferProtocol.rawValue)://\(username)@\(host):\(port)"
    }

    /// Full remote path for an uploaded file, e.g. `/public_html/drops/photo.png`.
    public func remotePath(forFileNamed fileName: String) -> String {
        let directory = RemotePath.normalizedDirectory(remoteDirectory)
        return directory == "/" ? "/\(fileName)" : "\(directory)/\(fileName)"
    }
}

public enum ServerConfigError: Error, Equatable, Sendable {
    case emptyHost
    case invalidHost
    case invalidPort
    case emptyUsername
}

extension ServerConfig {
    /// Returns every problem with the config, so onboarding can show them all at once.
    public func validationErrors() -> [ServerConfigError] {
        var errors: [ServerConfigError] = []
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        if trimmedHost.isEmpty {
            errors.append(.emptyHost)
        } else if trimmedHost.contains(where: { $0.isWhitespace || $0 == "/" }) || trimmedHost.contains("://") {
            errors.append(.invalidHost)
        }
        if !(1...65535).contains(port) {
            errors.append(.invalidPort)
        }
        if username.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append(.emptyUsername)
        }
        return errors
    }

    public var isValid: Bool { validationErrors().isEmpty }

    /// The same server and login with another upload folder. The credential key doesn't include the folder,
    /// so the saved password still applies.
    public func withRemoteDirectory(_ directory: String) -> ServerConfig {
        var copy = self
        copy.remoteDirectory = RemotePath.normalizedDirectory(directory)
        return copy
    }
}

public enum RemotePath {
    /// Turns user input like `drops/`, `//drops//images/` or `` into `/drops`, `/drops/images` and `/`.
    public static func normalizedDirectory(_ input: String) -> String {
        let components = input
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return "/" + components.joined(separator: "/")
    }
}
