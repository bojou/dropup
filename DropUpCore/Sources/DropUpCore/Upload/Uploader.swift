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
/// A session is used by one caller at a time. After any error it should be closed and discarded.
public protocol ServerSession: Sendable {
    /// Whether a file (not a folder) exists at `path`.
    func fileExists(atPath path: String) async throws -> Bool

    /// Names of the folders directly inside `path`, without `.` and `..`.
    func listDirectories(atPath path: String) async throws -> [String]

    /// Everything directly inside the folder `path`, hidden items included, folders first.
    func listEntries(atPath path: String) async throws -> [RemoteEntry]

    /// Sends the file to `remotePath`, replacing anything already there.
    /// `progress` receives the total number of bytes sent so far. It is called with 0 as soon as the
    /// server has created or emptied `remotePath`, before any data is sent, so a caller can tell
    /// that the file on the server is now this upload's to clean up.
    /// Must stop promptly with `CancellationError` when the task is cancelled.
    func upload(
        fileURL: URL,
        to remotePath: String,
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
