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

    public init(connectors: any ConnectorFactory, config: ServerConfig, password: String) {
        self.connectors = connectors
        self.config = config
        self.password = password
    }

    /// The items directly inside the folder `path`, folders first.
    public func entries(atPath path: String) async throws -> [RemoteEntry] {
        let folder = RemotePath.normalizedDirectory(path)
        return try await perform { try await $0.listEntries(atPath: folder) }
    }

    /// Creates a folder called `name` inside `folder`.
    public func makeFolder(named name: String, in folder: String) async throws {
        try await perform { try await FileOperations.makeFolder(named: name, in: folder, session: $0) }
    }

    public func rename(_ entry: RemoteEntry, to newName: String, in folder: String) async throws {
        try await perform { try await FileOperations.rename(entry, to: newName, in: folder, session: $0) }
    }

    /// Moves items into another folder. See `FileOperations.move`.
    public func move(_ entries: [RemoteEntry], from folder: String, to destination: String) async throws -> FileOperationResult {
        try await perform { try await FileOperations.move(entries, from: folder, to: destination, session: $0) }
    }

    /// Deletes items, folders with everything inside. See `FileOperations.delete`.
    public func delete(
        _ entries: [RemoteEntry],
        in folder: String,
        progress: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws -> FileOperationResult {
        try await perform { try await FileOperations.delete(entries, in: folder, session: $0, progress: progress) }
    }

    /// Runs `operation` on the open connection, one at a time. A connection the server dropped while idle is replaced and
    /// the operation tried once more; for a change to the server that is safe because the first try never got an answer.
    private func perform<T: Sendable>(_ operation: @Sendable (any ServerSession) async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        try Task.checkCancellation()

        if let session {
            do {
                return try await operation(session)
            } catch {
                guard await handle(error) == .retryOnFreshConnection else { throw error }
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
