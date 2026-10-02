import Foundation
import Observation
import DropUpCore

/// What the Browse window shows: one folder of the server at a time, reached through a connection that stays open.
@MainActor
@Observable
final class BrowseModel {
    /// The folder on screen. It only changes once a folder has loaded, so a folder that fails to open leaves the old one in view.
    private(set) var path: String
    private(set) var entries: [RemoteEntry] = []
    private(set) var isLoading = false
    private(set) var error: String?
    /// Names the server in the window title and the empty-folder text.
    let serverName: String
    /// Identifies the server this window was opened for, so a drop can tell if Settings pointed somewhere else since.
    let credentialKey: String

    @ObservationIgnored private let session: BrowseSession
    @ObservationIgnored private var task: Task<Void, Never>?

    init(config: ServerConfig, session: BrowseSession) {
        self.path = RemotePath.normalizedDirectory(config.remoteDirectory)
        self.serverName = config.shownName ?? config.host
        self.credentialKey = config.credentialKey
        self.session = session
    }

    /// Lists the starting folder. Call once when the window opens.
    func start() {
        load(path)
    }

    func reload() {
        load(path)
    }

    func goUp() {
        load(RemotePath.parent(of: path))
    }

    func enter(folderNamed name: String) {
        load(RemotePath.appending(name, to: path))
    }

    func go(to path: String) {
        load(path)
    }

    /// Shows a problem that isn't about listing, such as a drop that can't be accepted.
    func report(_ message: String) {
        error = message
    }

    /// Stops any listing in flight and drops the connection. Call when the window closes.
    func close() {
        task?.cancel()
        task = nil
        let session = session
        Task { await session.close() }
    }

    private func load(_ target: String) {
        let target = RemotePath.normalizedDirectory(target)
        task?.cancel()
        isLoading = true
        error = nil
        task = Task {
            do {
                let listing = try await session.entries(atPath: target)
                guard !Task.isCancelled else { return }
                path = target
                entries = listing
                isLoading = false
            } catch is CancellationError {
                // A newer listing replaced this one, and it owns the loading state.
            } catch {
                guard !Task.isCancelled else { return }
                isLoading = false
                self.error = ServerBrowser.message(for: error)
            }
        }
    }
}
