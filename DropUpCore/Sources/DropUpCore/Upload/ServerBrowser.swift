import Foundation

/// One-off server operations for onboarding and Settings: "Test Connection" and the folder browser.
/// Each call opens its own session and closes it, independent of the upload queue.
public struct ServerBrowser: Sendable {
    private let connectors: any ConnectorFactory

    public init(connectors: any ConnectorFactory) {
        self.connectors = connectors
    }

    public struct TestResult: Equatable, Sendable {
        /// Time to connect, log in and list the upload folder.
        public var duration: TimeInterval
        /// Folders inside the upload folder, as a bonus for the folder picker.
        public var folders: [String]
    }

    /// Connects, logs in and lists `config.remoteDirectory`, so a typo in the folder shows up now
    /// rather than on the first upload.
    public func testConnection(_ config: ServerConfig, password: String) async throws -> TestResult {
        let start = Date()
        let folders = try await listDirectories(config, password: password, path: config.remoteDirectory)
        return TestResult(duration: Date().timeIntervalSince(start), folders: folders)
    }

    public func listDirectories(_ config: ServerConfig, password: String, path: String) async throws -> [String] {
        let session = try await connectors.connector(for: config.transferProtocol).connect(to: config, password: password)
        do {
            let folders = try await session.listDirectories(atPath: RemotePath.normalizedDirectory(path))
            await session.close()
            return folders
        } catch {
            await session.close()
            throw error
        }
    }

    /// A human-readable message for any error these calls throw.
    public static func message(for error: any Error) -> String {
        UploadQueue.message(for: error)
    }
}

extension RemotePath {
    /// The parent of a normalized directory: `/a/b` → `/a`, `/a` → `/`, `/` → `/`.
    public static func parent(of directory: String) -> String {
        let normalized = normalizedDirectory(directory)
        guard let slash = normalized.lastIndex(of: "/"), slash != normalized.startIndex else { return "/" }
        return String(normalized[..<slash])
    }

    /// Appends a folder name: `/a` + `b` → `/a/b`.
    public static func appending(_ name: String, to directory: String) -> String {
        normalizedDirectory(normalizedDirectory(directory) + "/" + name)
    }
}
