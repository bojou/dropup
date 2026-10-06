import Foundation

public struct UploadProgress: Sendable, Equatable {
    public var bytesSent: Int64
    public var totalBytes: Int64

    public init(bytesSent: Int64, totalBytes: Int64) {
        self.bytesSent = bytesSent
        self.totalBytes = totalBytes
    }

    /// 0...1, or 0 for an empty file.
    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(bytesSent) / Double(totalBytes)))
    }
}

/// One logged-in connection to the server. Implementations: `FTPSession`, the SFTP session in
/// `DropUpTransport`, and fakes in tests.
///
/// A session is used by one caller at a time, except for the files of a folder transfer: up to
/// `concurrentTransfers` of those at once. After any error it should be closed and discarded.
public protocol ServerSession: Sendable {
    /// How many files of a folder this one session can send or fetch at the same time. The default is 1.
    var concurrentTransfers: Int { get }

    /// How many connections to the server, this one included, a folder transfer may use at the same time, for a
    /// session that moves one file at a time. The default is 1.
    var connectionsForFolders: Int { get }

    /// Whether a file (not a folder) exists at `path`.
    func fileExists(atPath path: String) async throws -> Bool

    /// The size in bytes of the file at `path`, or nil when there is no file there. Throws
    /// `UploaderError.cannotResume` when the server can't say, which tells a caller not to continue a partly sent file.
    func fileSize(atPath path: String) async throws -> Int64?

    /// Names of the folders directly inside `path`, without `.` and `..`.
    func listDirectories(atPath path: String) async throws -> [String]

    /// Everything directly inside the folder `path`, hidden items included, folders first.
    func listEntries(atPath path: String) async throws -> [RemoteEntry]

    /// Like `listEntries`, but a symbolic link is always reported as a link. Some FTP servers list a link to a folder as
    /// a folder, so walking a tree with `listEntries` could lead out of it. The default is `listEntries`.
    func listEntriesWithLinks(atPath path: String) async throws -> [RemoteEntry]

    /// Sends the file to `remotePath`, replacing anything already there. With an `offset` above zero it carries on
    /// instead: `remotePath` already holds the first `offset` bytes of this file (a partly sent copy), and only the rest
    /// is sent. Throws `UploaderError.cannotResume`, before changing anything, when the server can't do that.
    /// `progress` receives the number of bytes of the file the server holds so far. It is called first, as soon as
    /// the server has created or emptied `remotePath` (with 0, or with `offset`), before any data is sent, so a caller
    /// can tell that the file on the server is now this upload's to clean up. A session may carry on from a little
    /// before `offset`, to be sure nothing is missing in between, and then reports that smaller number first.
    /// Must stop promptly with `CancellationError` when the task is cancelled.
    func upload(
        fileURL: URL,
        to remotePath: String,
        startingAt offset: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws

    /// Deletes the file at `remotePath`. A symbolic link is removed itself, whatever it points to.
    /// A folder is refused, so a caller can use this to tell a link to a folder from a real folder.
    func deleteFile(atPath remotePath: String) async throws

    /// Creates the folder `path` inside an existing folder. Fails if something is already there.
    func makeDirectory(atPath path: String) async throws

    /// Removes the empty folder `path`.
    func removeDirectory(atPath path: String) async throws

    /// Renames or moves the file or folder at `oldPath` to `newPath`, on the same server.
    /// Some servers silently replace a file already at `newPath`, so callers check first.
    func rename(from oldPath: String, to newPath: String) async throws

    /// Copies the file at `remotePath` to `fileURL`, replacing anything already there.
    /// `progress` receives the total number of bytes received so far.
    /// The local file is only created once the server has agreed to send the file.
    /// Must stop promptly with `CancellationError` when the task is cancelled.
    func download(
        remotePath: String,
        to fileURL: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws

    /// Logs out and closes the connection. Never throws.
    func close() async
}

extension ServerSession {
    public var concurrentTransfers: Int { 1 }
    public var connectionsForFolders: Int { 1 }

    public func listEntriesWithLinks(atPath path: String) async throws -> [RemoteEntry] {
        try await listEntries(atPath: path)
    }

    /// Sends the whole file, replacing anything already at `remotePath`.
    public func upload(
        fileURL: URL,
        to remotePath: String,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try await upload(fileURL: fileURL, to: remotePath, startingAt: 0, progress: progress)
    }
}

/// Opens sessions for one transfer protocol.
public protocol ServerConnector: Sendable {
    func connect(to config: ServerConfig, password: String) async throws -> any ServerSession
}

/// Picks the connector for a protocol, so the queue never knows about concrete transports.
/// The app uses `StandardConnectorFactory` from `DropUpTransport`.
public protocol ConnectorFactory: Sendable {
    func connector(for transferProtocol: TransferProtocol) -> any ServerConnector
}

public enum UploaderError: Error, Equatable, Sendable {
    case connectionFailed(String)
    case authenticationFailed
    case serverRejected(code: Int, message: String)
    case timedOut
    /// The SFTP server presented a different host key than the one trusted earlier.
    case hostKeyChanged(fingerprint: String)
    /// The remote path contains characters the protocol cannot carry (such as line breaks).
    case invalidRemotePath
    /// The server can't carry on a partly sent file: it doesn't know how big the file is, or won't start in the middle.
    case cannotResume
    /// The SSH key file is missing or can't be read.
    case keyFileUnreadable
    /// The file isn't an OpenSSH private key DropUp can read.
    case keyFormatUnsupported
    /// A valid key of a kind DropUp can't sign in with. The name is how the kind is shown, such as `ECDSA`.
    case keyTypeUnsupported(String)
    /// The key is encrypted with a cipher DropUp can't open. The name is the cipher's, such as `aes256-gcm@openssh.com`.
    case keyCipherUnsupported(String)
    /// The key is protected by a passphrase and none is saved.
    case keyNeedsPassphrase
    /// The saved passphrase doesn't unlock the key.
    case keyPassphraseWrong
    /// The server didn't accept the key. `rsa` says it was an RSA key, which many servers no longer take.
    case keyRejected(rsa: Bool)
}

extension UploaderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason):
            "Couldn't connect to the server. \(reason)"
        case .authenticationFailed:
            "The server rejected the username or password."
        case .serverRejected(let code, let message):
            message.isEmpty ? "The server refused (\(code))." : "The server refused: \(message) (\(code))"
        case .timedOut:
            "The server stopped responding."
        case .hostKeyChanged(let fingerprint):
            "The server's identity changed (now \(fingerprint)). If you expected this, forget the old key in Settings."
        case .invalidRemotePath:
            "The file or folder name can't be used on the server."
        case .cannotResume:
            "The server can't carry on a partly sent file."
        case .keyFileUnreadable:
            "The SSH key file is missing or can't be read."
        case .keyFormatUnsupported:
            "DropUp can't read this key file. It has to be an OpenSSH private key, an ed25519 or RSA one."
        case .keyTypeUnsupported(let name):
            "DropUp can't use \(name) keys yet. Use an ed25519 or RSA key."
        case .keyCipherUnsupported(let name):
            "DropUp can't open this key's encryption (\(name)). Save it again with aes256-ctr: ssh-keygen -p -Z aes256-ctr -f <key>"
        case .keyNeedsPassphrase:
            "This SSH key needs a passphrase."
        case .keyPassphraseWrong:
            "The passphrase doesn't unlock this SSH key."
        case .keyRejected(let rsa):
            rsa
                ? "The server didn't accept this RSA key. Many servers no longer take RSA keys, and an ed25519 key is accepted more widely."
                : "The server didn't accept this SSH key."
        }
    }
}

/// Runs `operation`, throwing `UploaderError.timedOut` if it takes longer than `seconds`.
/// The operation is cancelled on timeout, so it must respond to cancellation.
public func withTimeout<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw UploaderError.timedOut
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw UploaderError.timedOut }
        return result
    }
}
