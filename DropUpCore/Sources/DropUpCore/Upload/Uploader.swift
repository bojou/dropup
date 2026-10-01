import Foundation

/// One file to send to one server.
public struct UploadRequest: Sendable, Equatable {
    public var fileURL: URL
    public var remotePath: String
    public var config: ServerConfig
    public var password: String

    public init(fileURL: URL, remotePath: String, config: ServerConfig, password: String) {
        self.fileURL = fileURL
        self.remotePath = remotePath
        self.config = config
        self.password = password
    }
}

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

/// Sends a single file to a server. Implementations: `FTPUploader`, `SFTPUploader`, and fakes in tests.
public protocol Uploader: Sendable {
    func upload(
        _ request: UploadRequest,
        progress: @escaping @Sendable (UploadProgress) -> Void
    ) async throws
}

/// Picks the uploader for a protocol, so the queue never knows about concrete transports.
public protocol UploaderFactory: Sendable {
    func uploader(for transferProtocol: TransferProtocol) -> any Uploader
}

public struct DefaultUploaderFactory: UploaderFactory {
    public init() {}

    public func uploader(for transferProtocol: TransferProtocol) -> any Uploader {
        switch transferProtocol {
        case .ftp: FTPUploader()
        case .sftp: SFTPUploader()
        }
    }
}

public enum UploaderError: Error, Equatable, Sendable {
    case notImplemented(TransferProtocol)
    case connectionFailed(String)
    case authenticationFailed
    case serverRejected(code: Int, message: String)
}
