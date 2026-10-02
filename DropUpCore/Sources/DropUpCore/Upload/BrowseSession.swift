import Foundation

/// A server connection kept open while someone browses, so each folder they open doesn't log in again.
///
/// Listings and changes run one at a time. If the connection has gone stale (servers drop idle logins) the call
/// is retried once on a fresh connection.
public actor BrowseSession {
    private let connectors: any ConnectorFactory
    private let config: ServerConfig
    private let password: String
    private var session: (any ServerSession)?
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let scratchParent: URL
    private let cleanupTimeout: Double

    /// - Parameters:
    ///   - scratchParent: a local folder to stage copies in. Each copy makes a folder of its own inside and removes it again.
    ///   - cleanupTimeout: seconds to spend deleting the half-sent file of a failed or cancelled copy before giving up.
    public init(
        connectors: any ConnectorFactory,
        config: ServerConfig,
        password: String,
        scratchParent: URL = FileManager.default.temporaryDirectory,
        cleanupTimeout: Double = 15
    ) {
        self.connectors = connectors
        self.config = config
        self.password = password
        self.scratchParent = scratchParent
        self.cleanupTimeout = cleanupTimeout
    }

    /// The items directly inside the folder `path`, folders first.
    public func entries(atPath path: String) async throws -> [RemoteEntry] {
        let folder = RemotePath.normalizedDirectory(path)
        return try await perform { try await $0.listEntries(atPath: folder) }
    }

    /// Creates a folder called `name` inside `folder`, and says how to take that back.
    @discardableResult
    public func makeFolder(named name: String, in folder: String) async throws -> BrowseChange {
        let path = try await perform { try await FileOperations.makeFolder(named: name, in: folder, session: $0) }
        return .madeFolder(path)
    }

    /// Renames an item, and says how to take that back. Nil when the name was already right.
    @discardableResult
    public func rename(_ entry: RemoteEntry, to newName: String, in folder: String) async throws -> BrowseChange? {
        let move = try await perform { try await FileOperations.rename(entry, to: newName, in: folder, session: $0) }
        return move.map { .renamed($0) }
    }

    /// Moves items into another folder. See `FileOperations.move`.
    public func move(
        _ entries: [RemoteEntry],
        from folder: String,
        to destination: String,
        policy: ConflictPolicy = .keepBoth
    ) async throws -> FileOperationResult {
        try await perform { try await FileOperations.move(entries, from: folder, to: destination, policy: policy, session: $0) }
    }

    /// Takes a change back. See `FileOperations.undo`.
    public func undo(_ change: BrowseChange) async throws -> FileOperationResult {
        try await perform { try await FileOperations.undo(change, session: $0) }
    }

    /// Does a change again after `undo`. A copy is made again, which takes as long as it did the first time.
    public func redo(
        _ change: BrowseChange,
        policy: ConflictPolicy = .keepBoth,
        progress: @escaping @Sendable (CopyProgress) -> Void = { _ in }
    ) async throws -> FileOperationResult {
        if case .copied(let record) = change {
            return try await copy(record.sources, from: record.from, to: record.to, policy: policy, progress: progress)
        }
        return try await perform { try await FileOperations.redo(change, session: $0) }
    }

    /// Deletes items, folders with everything inside. See `FileOperations.delete`.
    public func delete(
        _ entries: [RemoteEntry],
        in folder: String,
        progress: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> FileOperationResult {
        try await perform { try await FileOperations.delete(entries, in: folder, session: $0, progress: progress) }
    }

    /// Copies items into another folder, or the same one. See `FileOperations.copy`.
    /// Files travel through this Mac, so `progress` follows the whole trip.
    public func copy(
        _ entries: [RemoteEntry],
        from folder: String,
        to destination: String,
        policy: ConflictPolicy = .keepBoth,
        progress: @escaping @Sendable (CopyProgress) -> Void = { _ in }
    ) async throws -> FileOperationResult {
        let scratch = scratchParent.appendingPathComponent("DropUp-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Once the server has been changed, starting over on a new connection would copy the same items a second time.
        let changed = ChangeFlag()
        // A few updates a second are plenty for a progress bar. The last one always goes through.
        let throttle = ProgressThrottle(interval: 0.1, total: 1)
        let report: @Sendable (CopyProgress) -> Void = { update in
            if throttle.shouldReport(update.done >= update.total ? 1 : 0) { progress(update) }
        }
        return try await perform(mayRetry: { !changed.isSet }) { session in
            try await FileOperations.copy(
                entries,
                from: folder,
                to: destination,
                policy: policy,
                session: session,
                scratch: scratch,
                began: { changed.set() },
                leftBehind: { await self.removeLeftover(at: $0) },
                progress: report
            )
        }
    }

    /// Deletes the half-sent file of a copy that stopped, over a new connection because the one that sent it can't be trusted.
    /// Best effort: if the server can't be reached or refuses, the file stays and the copy still reports why it stopped.
    private func removeLeftover(at path: String) async {
        await close()
        let (connectors, config, password, timeout) = (connectors, config, password, cleanupTimeout)
        // Its own task, so that cancelling the copy doesn't also cancel the cleanup.
        await Task.detached {
            do {
                try await withTimeout(seconds: timeout) {
                    let session = try await connectors.connector(for: config.transferProtocol).connect(to: config, password: password)
                    do {
                        try await session.deleteFile(atPath: path)
                    } catch {
                        await session.close()
                        throw error
                    }
                    await session.close()
                }
            } catch {
                // The file stays. Nothing more can be done from here.
            }
        }.value
    }

    private final class ChangeFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    /// Runs `operation` on the open connection, one at a time. A connection the server dropped while idle is replaced and
    /// the operation tried once more; for a change to the server that is safe because the first try never got an answer.
    /// `mayRetry` can say no when the operation had already changed something before the connection failed.
    private func perform<T: Sendable>(
        mayRetry: @Sendable () -> Bool = { true },
        _ operation: @Sendable (any ServerSession) async throws -> T
    ) async throws -> T {
        await acquire()
        defer { release() }
        try Task.checkCancellation()

        if let session {
            do {
                return try await operation(session)
            } catch {
                guard await handle(error) == .retryOnFreshConnection, mayRetry() else { throw error }
                try Task.checkCancellation()
            }
        }
        let fresh = try await connectors.connector(for: config.transferProtocol).connect(to: config, password: password)
        session = fresh
        do {
            return try await operation(fresh)
        } catch {
            _ = await handle(error)
            throw error
        }
    }

    /// Closes the connection. A later call connects again.
    public func close() async {
        guard let session else { return }
        self.session = nil
        await session.close()
    }

    private enum Verdict { case keepConnection, retryOnFreshConnection, giveUp }

    /// Closes the connection unless the error shows it is still fine, and says whether a fresh one is worth a try.
    private func handle(_ error: any Error) async -> Verdict {
        switch error {
        case is CancellationError:
            // Stopped mid-command, so the connection's state is unknown.
            await close()
            return .giveUp
        case UploaderError.serverRejected, UploaderError.invalidRemotePath, is FileOperationError:
            // The server answered normally (no such folder, say), so the login is still good.
            return .keepConnection
        default:
            // Probably an idle login that the server dropped.
            await close()
            return .retryOnFreshConnection
        }
    }

    // MARK: One listing at a time

    private func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            isBusy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
