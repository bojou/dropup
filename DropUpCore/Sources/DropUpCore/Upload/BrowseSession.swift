import Foundation

/// A server connection kept open while someone browses, so each folder they open doesn't log in again.
///
/// Listings run one at a time. If the connection has gone stale (servers drop idle logins) the listing
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
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        let folder = RemotePath.normalizedDirectory(path)

        if let session {
            do {
                return try await session.listEntries(atPath: folder)
            } catch {
                guard await handle(error) == .retryOnFreshConnection else { throw error }
                try Task.checkCancellation()
            }
        }
        let fresh = try await connectors.connector(for: config.transferProtocol).connect(to: config, password: password)
        session = fresh
        do {
            return try await fresh.listEntries(atPath: folder)
        } catch {
            _ = await handle(error)
            throw error
        }
    }

    /// Closes the connection. A later call to `entries` connects again.
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
        case UploaderError.serverRejected, UploaderError.invalidRemotePath:
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
