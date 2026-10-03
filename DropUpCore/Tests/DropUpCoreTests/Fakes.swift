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
    private var _downloads: [String] = []
    private let files: [String: Data]
    private let downloadError: (any Error)?
    private let hangAfterWritingDownload: Bool
    private let error: (any Error)?
    private let hangUntilCancelled: Bool
    private let hangAfterCreatingFile: Bool
    private let deleteError: (any Error)?
    private let hangOnDelete: Bool
    private var _listDelayMilliseconds: UInt64
    private let uploadDelayMilliseconds: UInt64
    private let makeDirectoryDelayMilliseconds: UInt64
    private var _madeDirectories: [String] = []
    private var _sizes: [String: Int64]
    private var _offsets: [Int64] = []
    private var _drops: [Int64]
    private var _sizeFailure: (any Error)?
    private let refusesToResume: Bool
    private let stuckUntilClosed: Bool
    private var _closed = false
    let folders: [String: [String]]
    let entries: [String: [RemoteEntry]]

    /// - Parameters:
    ///   - entries: what `listEntries` returns for each folder path.
    ///   - files: what `download` serves for each remote path. A path not listed is refused with 550.
    ///   - downloadError: makes `download` fail after the server agreed to send.
    ///   - hangAfterWritingDownload: writes the first half of the file, then waits for cancellation.
    ///   - listFailures: errors for the first `listEntries` calls, one per call, before it starts answering.
    ///   - hangUntilCancelled: waits for cancellation before the server has created the file.
    ///   - hangAfterCreatingFile: creates the file, then waits for cancellation (a half-sent upload).
    ///   - deleteError: makes `deleteFile` fail.
    ///   - hangOnDelete: makes `deleteFile` wait until it is cancelled.
    ///   - listDelayMilliseconds: how long each `listEntries` call takes.
    ///   - uploadDelayMilliseconds: how long each upload takes once the file exists.
    ///   - makeDirectoryDelayMilliseconds: how long each `makeDirectory` takes. It does not notice a cancel, like a real server's reply.
    ///   - sizes: files the server already holds, with the number of bytes they have (a partly sent upload, say).
    ///   - drops: for each upload in turn, the number of bytes the server holds when the connection breaks, which makes
    ///     that upload fail with a lost connection. Uploads after the list is used up go through.
    ///   - refusesToResume: makes an upload that starts in the middle of a file fail with `cannotResume`.
    ///   - stuckUntilClosed: after creating the file the upload waits for `close()`, deaf to a cancel, like a transfer on a dead link.
    init(
        existing: Set<String> = [],
        folders: [String: [String]] = [:],
        entries: [String: [RemoteEntry]] = [:],
        listFailures: [any Error] = [],
        files: [String: Data] = [:],
        downloadError: (any Error)? = nil,
        hangAfterWritingDownload: Bool = false,
        error: (any Error)? = nil,
        hangUntilCancelled: Bool = false,
        hangAfterCreatingFile: Bool = false,
        deleteError: (any Error)? = nil,
        hangOnDelete: Bool = false,
        listDelayMilliseconds: UInt64 = 2,
        uploadDelayMilliseconds: UInt64 = 0,
        makeDirectoryDelayMilliseconds: UInt64 = 0,
        sizes: [String: Int64] = [:],
        drops: [Int64] = [],
        refusesToResume: Bool = false,
        stuckUntilClosed: Bool = false
    ) {
        _existing = existing.union(sizes.keys)
        _sizes = sizes
        _drops = drops
        self.refusesToResume = refusesToResume
        self.stuckUntilClosed = stuckUntilClosed
        self.folders = folders
        self.entries = entries
        self.files = files
        self.downloadError = downloadError
        self.hangAfterWritingDownload = hangAfterWritingDownload
        _listFailures = listFailures
        self.error = error
        self.hangUntilCancelled = hangUntilCancelled
        self.hangAfterCreatingFile = hangAfterCreatingFile
        self.deleteError = deleteError
        self.hangOnDelete = hangOnDelete
        _listDelayMilliseconds = listDelayMilliseconds
        self.uploadDelayMilliseconds = uploadDelayMilliseconds
        self.makeDirectoryDelayMilliseconds = makeDirectoryDelayMilliseconds
    }

    /// Changes how long each `listEntries` call takes from now on.
    func setListDelay(milliseconds: UInt64) { lock.withLock { _listDelayMilliseconds = milliseconds } }

    /// The offset each upload started at, in the order uploads started.
    var uploadOffsets: [Int64] { lock.withLock { _offsets } }
    /// How many bytes the server holds of `path`, or nil when there is no such file.
    func size(of path: String) -> Int64? { lock.withLock { _sizes[path] } }
    /// Makes `fileSize` fail with `error`.
    func failSizeChecks(with error: any Error) { lock.withLock { _sizeFailure = error } }
    /// Puts a file of `size` bytes on the server, as if an earlier upload had left it.
    func hold(_ path: String, size: Int64) {
        lock.withLock {
            _existing.insert(path)
            _sizes[path] = size
        }
    }

    /// Remote paths in the order uploads started.
    var uploads: [String] { lock.withLock { _uploads } }
    /// Remote paths in the order they were deleted.
    var deletions: [String] { lock.withLock { _deletions } }
    var closeCount: Int { lock.withLock { _closeCount } }
    /// Remote paths in the order downloads started.
    var downloads: [String] { lock.withLock { _downloads } }
    var listingCount: Int { lock.withLock { _listings } }
    /// Remote paths in the order folders were made.
    var madeDirectories: [String] { lock.withLock { _madeDirectories } }

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

    func fileSize(atPath path: String) async throws -> Int64? {
        if let failure = lock.withLock({ _sizeFailure }) { throw failure }
        if let error { throw error }
        return lock.withLock { _sizes[path] ?? (_existing.contains(path) ? 0 : nil) }
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
        try await Task.sleep(nanoseconds: lock.withLock { _listDelayMilliseconds } * 1_000_000)
        if let failure { throw failure }
        if let error { throw error }
        return entries[path] ?? []
    }

    func upload(fileURL: URL, to remotePath: String, startingAt offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let drop: Int64? = lock.withLock {
            _closed = false
            _uploads.append(remotePath)
            _offsets.append(offset)
            return _drops.isEmpty ? nil : _drops.removeFirst()
        }
        if let error { throw error }
        if offset > 0, refusesToResume { throw UploaderError.cannotResume }
        if hangUntilCancelled { try await Self.hang() }
        let size = Int64((try? Data(contentsOf: fileURL).count) ?? 0)
        lock.withLock {
            _existing.insert(remotePath)
            _sizes[remotePath] = offset
        }
        progress(offset)
        if stuckUntilClosed {
            // Deaf to a cancel: only closing the connection lets go.
            while !lock.withLock({ _closed }) { try? await Task.sleep(nanoseconds: 1_000_000) }
            throw UploaderError.connectionFailed("The connection was lost.")
        }
        if hangAfterCreatingFile { try await Self.hang() }
        if uploadDelayMilliseconds > 0 { try await Task.sleep(nanoseconds: uploadDelayMilliseconds * 1_000_000) }
        if let drop, drop < size {
            lock.withLock { _sizes[remotePath] = drop }
            progress(drop)
            throw UploaderError.connectionFailed("The connection was lost.")
        }
        progress(offset + (size - offset) / 2)
        lock.withLock { _sizes[remotePath] = size }
        progress(size)
    }

    func download(remotePath: String, to fileURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        lock.withLock { _downloads.append(remotePath) }
        guard let data = files[remotePath] else {
            throw UploaderError.serverRejected(code: 550, message: "No such file")
        }
        let half = data.count / 2
        try data.prefix(half).write(to: fileURL)
        progress(Int64(half))
        if hangAfterWritingDownload { try await Self.hang() }
        if let downloadError { throw downloadError }
        try data.write(to: fileURL)
        progress(Int64(data.count))
    }

    func deleteFile(atPath remotePath: String) async throws {
        if hangOnDelete { try await Self.hang() }
        if let deleteError { throw deleteError }
        lock.withLock {
            _existing.remove(remotePath)
            _sizes[remotePath] = nil
            _deletions.append(remotePath)
        }
    }

    func makeDirectory(atPath path: String) async throws {
        lock.withLock { _madeDirectories.append(path) }
        if makeDirectoryDelayMilliseconds > 0 {
            // Waits the whole time even when cancelled.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(makeDirectoryDelayMilliseconds))) {
                    continuation.resume()
                }
            }
        }
    }
    func removeDirectory(atPath path: String) async throws {}
    func rename(from oldPath: String, to newPath: String) async throws {}

    private static func hang() async throws {
        while true {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func close() async {
        lock.withLock {
            _closeCount += 1
            _closed = true
        }
    }
}

/// Hands out the same `FakeSession` and counts connections.
final class FakeConnector: ServerConnector, ConnectorFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var _connections: [(ServerConfig, String)] = []
    let session: FakeSession
    let connectError: (any Error)?
    /// How long the first connection takes (a cancel cuts the wait short), for a connection that is slow to come up.
    private let firstConnectMilliseconds: UInt64

    init(session: FakeSession = FakeSession(), connectError: (any Error)? = nil, firstConnectMilliseconds: UInt64 = 0) {
        self.session = session
        self.connectError = connectError
        self.firstConnectMilliseconds = firstConnectMilliseconds
    }

    var connectionCount: Int { lock.withLock { _connections.count } }
    var passwords: [String] { lock.withLock { _connections.map(\.1) } }
    var configs: [ServerConfig] { lock.withLock { _connections.map(\.0) } }

    func connect(to config: ServerConfig, password: String) async throws -> any ServerSession {
        let first = lock.withLock { () -> Bool in
            _connections.append((config, password))
            return _connections.count == 1
        }
        if first, firstConnectMilliseconds > 0 { try await Task.sleep(nanoseconds: firstConnectMilliseconds * 1_000_000) }
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


extension FileOperationResult {
    /// The result without the record Undo keeps, for tests that only look at the counts.
    var withoutChange: FileOperationResult {
        var copy = self
        copy.change = nil
        return copy
    }
}
