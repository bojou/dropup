import Foundation
@testable import DropUpCore

/// An in-memory server session. Records uploads, reports progress in two steps,
/// and can be scripted to fail or to hang until cancelled.
final class FakeSession: ServerSession, @unchecked Sendable {
    private let lock = NSLock()
    private var _existing: Set<String>
    private var _uploads: [String] = []
    private var _closeCount = 0
    private let error: (any Error)?
    private let hangUntilCancelled: Bool
    let folders: [String: [String]]

    init(
        existing: Set<String> = [],
        folders: [String: [String]] = [:],
        error: (any Error)? = nil,
        hangUntilCancelled: Bool = false
    ) {
        _existing = existing
        self.folders = folders
        self.error = error
        self.hangUntilCancelled = hangUntilCancelled
    }

    /// Remote paths in the order uploads started.
    var uploads: [String] { lock.withLock { _uploads } }
    var closeCount: Int { lock.withLock { _closeCount } }

    func fileExists(atPath path: String) async throws -> Bool {
        lock.withLock { _existing.contains(path) }
    }

    func listDirectories(atPath path: String) async throws -> [String] {
        if let error { throw error }
        return folders[path] ?? []
    }

    func upload(fileURL: URL, to remotePath: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        lock.withLock { _uploads.append(remotePath) }
        if let error { throw error }
        if hangUntilCancelled {
            while true {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        let size = Int64((try? Data(contentsOf: fileURL).count) ?? 0)
        progress(size / 2)
        progress(size)
        lock.withLock { _ = _existing.insert(remotePath) }
    }

    func close() async {
        lock.withLock { _closeCount += 1 }
    }
}

/// Hands out the same `FakeSession` and counts connections.
final class FakeConnector: ServerConnector, ConnectorFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var _connections: [(ServerConfig, String)] = []
    let session: FakeSession
    let connectError: (any Error)?

    init(session: FakeSession = FakeSession(), connectError: (any Error)? = nil) {
        self.session = session
        self.connectError = connectError
    }

    var connectionCount: Int { lock.withLock { _connections.count } }
    var passwords: [String] { lock.withLock { _connections.map(\.1) } }

    func connect(to config: ServerConfig, password: String) async throws -> any ServerSession {
        lock.withLock { _connections.append((config, password)) }
        if let connectError { throw connectError }
        return session
    }

    func connector(for transferProtocol: TransferProtocol) -> any ServerConnector { self }
}

/// Creates real temp files, because the queue checks that dropped items exist and are readable.
struct TempFiles {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DropUpCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func file(named name: String, contents: String = "hello") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func file(named name: String, size: Int) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: url)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Polls `condition` until it holds, failing after about two seconds.
func eventually(_ condition: @Sendable () async -> Bool) async throws {
    for _ in 0..<2000 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    struct Timeout: Error {}
    throw Timeout()
}
