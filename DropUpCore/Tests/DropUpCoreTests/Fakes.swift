import Foundation
@testable import DropUpCore

/// An in-memory server session. Records uploads and deletions, reports progress in two steps,
/// and can be scripted to fail or to hang until cancelled.
/// Like a real session, it reports progress 0 once the remote file exists.
final class FakeSession: ServerSession, @unchecked Sendable {
    private let lock = NSLock()
    private var _existing: Set<String>
    private var _uploads: [String] = []
    private var _deletions: [String] = []
    private var _closeCount = 0
    private var _listings = 0
    private var _listingsRunning = 0
    private var _mostListingsAtOnce = 0
    private var _listFailures: [any Error]
    private let error: (any Error)?
    private let hangUntilCancelled: Bool
    private let hangAfterCreatingFile: Bool
    private let deleteError: (any Error)?
    private let hangOnDelete: Bool
    private let listDelayMilliseconds: UInt64
    private let uploadDelayMilliseconds: UInt64
    let folders: [String: [String]]
    let entries: [String: [RemoteEntry]]

    /// - Parameters:
    ///   - entries: what `listEntries` returns for each folder path.
    ///   - listFailures: errors for the first `listEntries` calls, one per call, before it starts answering.
    ///   - hangUntilCancelled: waits for cancellation before the server has created the file.
    ///   - hangAfterCreatingFile: creates the file, then waits for cancellation (a half-sent upload).
    ///   - deleteError: makes `deleteFile` fail.
    ///   - hangOnDelete: makes `deleteFile` wait until it is cancelled.
    ///   - listDelayMilliseconds: how long each `listEntries` call takes.
    ///   - uploadDelayMilliseconds: how long each upload takes once the file exists.
    init(
        existing: Set<String> = [],
        folders: [String: [String]] = [:],
        entries: [String: [RemoteEntry]] = [:],
        listFailures: [any Error] = [],
        error: (any Error)? = nil,
        hangUntilCancelled: Bool = false,
        hangAfterCreatingFile: Bool = false,
        deleteError: (any Error)? = nil,
        hangOnDelete: Bool = false,
        listDelayMilliseconds: UInt64 = 2,
        uploadDelayMilliseconds: UInt64 = 0
    ) {
        _existing = existing
        self.folders = folders
        self.entries = entries
        _listFailures = listFailures
        self.error = error
        self.hangUntilCancelled = hangUntilCancelled
        self.hangAfterCreatingFile = hangAfterCreatingFile
        self.deleteError = deleteError
        self.hangOnDelete = hangOnDelete
        self.listDelayMilliseconds = listDelayMilliseconds
        self.uploadDelayMilliseconds = uploadDelayMilliseconds
    }

    /// Remote paths in the order uploads started.
    var uploads: [String] { lock.withLock { _uploads } }
    /// Remote paths in the order they were deleted.
    var deletions: [String] { lock.withLock { _deletions } }
    var closeCount: Int { lock.withLock { _closeCount } }
    var listingCount: Int { lock.withLock { _listings } }

    /// Makes the next `listEntries` call fail with `error`.
    func failNextListing(with error: any Error) {
        lock.withLock { _listFailures.insert(error, at: 0) }
    }
    /// The most `listEntries` calls that were ever running at the same time.
    var mostListingsAtOnce: Int { lock.withLock { _mostListingsAtOnce } }

    func exists(_ path: String) -> Bool { lock.withLock { _existing.contains(path) } }

    func fileExists(atPath path: String) async throws -> Bool {
        lock.withLock { _existing.contains(path) }
    }

    func listDirectories(atPath path: String) async throws -> [String] {
        if let error { throw error }
        return folders[path] ?? []
    }

    func listEntries(atPath path: String) async throws -> [RemoteEntry] {
        let failure: (any Error)? = lock.withLock {
            _listings += 1
            _listingsRunning += 1
            _mostListingsAtOnce = max(_mostListingsAtOnce, _listingsRunning)
            return _listFailures.isEmpty ? nil : _listFailures.removeFirst()
        }
        defer { lock.withLock { _listingsRunning -= 1 } }
        try await Task.sleep(nanoseconds: listDelayMilliseconds * 1_000_000)
        if let failure { throw failure }
        if let error { throw error }
        return entries[path] ?? []
    }

    func upload(fileURL: URL, to remotePath: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        lock.withLock { _uploads.append(remotePath) }
        if let error { throw error }
        if hangUntilCancelled { try await Self.hang() }
        lock.withLock { _ = _existing.insert(remotePath) }
        progress(0)
        if hangAfterCreatingFile { try await Self.hang() }
        if uploadDelayMilliseconds > 0 { try await Task.sleep(nanoseconds: uploadDelayMilliseconds * 1_000_000) }
        let size = Int64((try? Data(contentsOf: fileURL).count) ?? 0)
        progress(size / 2)
        progress(size)
    }

    func deleteFile(atPath remotePath: String) async throws {
        if hangOnDelete { try await Self.hang() }
        if let deleteError { throw deleteError }
        lock.withLock {
            _existing.remove(remotePath)
            _deletions.append(remotePath)
        }
    }

    private static func hang() async throws {
        while true {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
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
    var configs: [ServerConfig] { lock.withLock { _connections.map(\.0) } }

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
