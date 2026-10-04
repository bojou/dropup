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

/// How DropUp signs in to the server. Only SFTP has a choice; FTP always uses the password.
public enum LoginMethod: String, Codable, CaseIterable, Sendable {
    case password
    /// A private key file on this Mac, with an optional passphrase.
    case sshKey
}

/// Everything DropUp needs to know about the destination, except the secret.
/// The secret (the password, or an SSH key's passphrase) lives in the Keychain (see `CredentialStore`) and is looked up
/// by `credentialKey`. The key itself is never copied: only the path of its file is kept here.
public struct ServerConfig: Codable, Equatable, Sendable {
    public var transferProtocol: TransferProtocol
    public var host: String
    public var port: Int
    public var username: String
    /// How to sign in. Settings saved before SSH keys existed have no such field and are `.password`.
    public var loginMethod: LoginMethod
    /// The private key file, for `.sshKey`. Nil for a password login.
    public var keyFilePath: String?
    /// Directory on the server that dropped files are uploaded into, e.g. `/public_html/drops`.
    public var remoteDirectory: String
    /// An optional name to show instead of the protocol and host, such as `My website`. Settings saved before
    /// this existed have none.
    public var displayName: String?

    public init(
        transferProtocol: TransferProtocol,
        host: String,
        port: Int? = nil,
        username: String,
        remoteDirectory: String,
        displayName: String? = nil,
        loginMethod: LoginMethod = .password,
        keyFilePath: String? = nil
    ) {
        self.transferProtocol = transferProtocol
        self.host = host
        self.port = port ?? transferProtocol.defaultPort
        self.username = username
        self.remoteDirectory = remoteDirectory
        self.displayName = displayName
        self.loginMethod = loginMethod
        self.keyFilePath = keyFilePath
    }

    private enum CodingKeys: String, CodingKey {
        case transferProtocol, host, port, username, remoteDirectory, displayName, loginMethod, keyFilePath
    }

    /// Reads settings from every version: those from before SSH keys have no `loginMethod` and are password logins.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        transferProtocol = try values.decode(TransferProtocol.self, forKey: .transferProtocol)
        host = try values.decode(String.self, forKey: .host)
        port = try values.decode(Int.self, forKey: .port)
        username = try values.decode(String.self, forKey: .username)
        remoteDirectory = try values.decode(String.self, forKey: .remoteDirectory)
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
        loginMethod = try values.decodeIfPresent(LoginMethod.self, forKey: .loginMethod) ?? .password
        keyFilePath = try values.decodeIfPresent(String.self, forKey: .keyFilePath)
    }

    /// Whether this signs in with a key file. Plain FTP never does, whatever else is stored.
    public var usesKey: Bool { transferProtocol == .sftp && loginMethod == .sshKey }

    /// Stable key used to store and fetch the secret for this server: the password, or an SSH key's passphrase.
    ///
    /// A password login keeps the key it always had, so passwords saved by earlier versions are found as they were.
    /// A key login has a key of its own, which names the key file by a short stamp (never the path, which would end
    /// up wherever the key is shown, such as in a drag), so a password and a passphrase for the same host and user
    /// are two items and never overwrite each other.
    public var credentialKey: String {
        let base = "\(transferProtocol.rawValue)://\(username)@\(host):\(port)"
        guard usesKey else { return base }
        return "\(transferProtocol.rawValue)+key://\(username)@\(host):\(port)#\(KeyFileStamp.of(keyFilePath ?? ""))"
    }

    /// The display name without surrounding spaces, or nil when there is none worth showing.
    public var shownName: String? {
        guard let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }

    /// The line under "DropUp" in the popover: `My website · /public_html/drops`, or without a display name
    /// `SFTP · files.example.com:/public_html/drops`.
    public var serverSummary: String {
        if let name = shownName { return "\(name) · \(remoteDirectory)" }
        return "\(transferProtocol.rawValue.uppercased()) · \(host):\(remoteDirectory)"
    }

    /// The shorter line on the drop panel: `My website · /public_html/drops`, or `SFTP · /public_html/drops`.
    public var destinationSummary: String {
        "\(shownName ?? transferProtocol.rawValue.uppercased()) · \(remoteDirectory)"
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
    /// An SSH key login with no key file chosen.
    case emptyKeyFile
}

/// A short, stable stamp of a key file's path (FNV-1a, 64 bits, in hex): enough to tell two keys apart in a Keychain
/// account name without putting the path there. It is not a secret and not a security measure.
enum KeyFileStamp {
    static func of(_ path: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let digits = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
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
        if usesKey, (keyFilePath ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append(.emptyKeyFile)
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
