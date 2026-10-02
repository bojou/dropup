import Foundation
import Observation
import DropUpCore

/// What the Browse window shows: one folder of the server at a time, reached through a connection that stays open.
/// It also carries out the changes the window offers (new folder, rename, move, delete) and refreshes the listing afterwards.
@MainActor
@Observable
final class BrowseModel {
    /// A change to the server that is running.
    struct Operation: Equatable {
        var title: String
        /// Items removed so far, for a delete.
        var count: Int?
        var canCancel: Bool
    }

    /// Items that were cut and wait for Paste. They stay where they are until pasted.
    struct Clipboard: Equatable {
        var folder: String
        var entries: [RemoteEntry]
    }

    /// The folder on screen. It only changes once a folder has loaded, so a folder that fails to open leaves the old one in view.
    private(set) var path: String
    private(set) var entries: [RemoteEntry] = []
    private(set) var isLoading = false
    /// Why the folder couldn't be listed.
    private(set) var error: String?
    /// Why a change couldn't be finished. Stays until dismissed or until the next change or folder.
    private(set) var problem: String?
    private(set) var history: FolderHistory
    private(set) var operation: Operation?
    private(set) var clipboard: Clipboard?
    /// Names the window should select once the folder on screen has loaded (the folder just made, the item just renamed).
    var selectionRequest: Set<String>?
    /// The server this window shows, and the login for it, kept so downloads go where the window is looking.
    let config: ServerConfig
    let password: String
    /// Names the server in the window title and the empty-folder text.
    let serverName: String
    /// Identifies the server this window was opened for, so a drop can tell if Settings pointed somewhere else since.
    let credentialKey: String

    @ObservationIgnored private let session: BrowseSession
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?

    init(config: ServerConfig, password: String, session: BrowseSession) {
        self.config = config
        self.password = password
        let start = RemotePath.normalizedDirectory(config.remoteDirectory)
        self.path = start
        self.history = FolderHistory(start: start)
        self.serverName = config.shownName ?? config.host
        self.credentialKey = config.credentialKey
        self.session = session
    }

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }
    var isBusy: Bool { operation != nil }

    // MARK: Navigating

    /// Lists the starting folder. Call once when the window opens.
    func start() {
        load(path, as: .reload)
    }

    func reload() {
        load(path, as: .reload)
    }

    func goBack() {
        guard let previous = history.previous else { return }
        load(previous, as: .back)
    }

    func goForward() {
        guard let next = history.next else { return }
        load(next, as: .forward)
    }

    /// The enclosing folder.
    func goUp() {
        guard path != "/" else { return }
        load(RemotePath.parent(of: path), as: .visit)
    }

    func enter(folderNamed name: String) {
        load(RemotePath.appending(name, to: path), as: .visit)
    }

    func go(to path: String) {
        load(path, as: .visit)
    }

    /// Shows a problem that isn't about listing, such as a drop that can't be accepted.
    func report(_ message: String) {
        problem = message
    }

    func dismissProblem() {
        problem = nil
    }

    /// Stops any listing or change in flight and drops the connection. Call when the window closes.
    func close() {
        task?.cancel()
        task = nil
        operationTask?.cancel()
        operationTask = nil
        let session = session
        Task { await session.close() }
    }

    /// The folders inside `folder`, for the Move To… chooser. Separate from the listing on screen.
    func folders(in folder: String) async throws -> [RemoteEntry] {
        try await session.entries(atPath: folder).filter { $0.kind == .folder && !$0.isHidden }
    }

    private enum Step { case visit, back, forward, reload }

    private func load(_ target: String, as step: Step) {
        let target = RemotePath.normalizedDirectory(target)
        task?.cancel()
        isLoading = true
        error = nil
        if step != .reload { problem = nil }
        task = Task {
            do {
                let listing = try await session.entries(atPath: target)
                guard !Task.isCancelled else { return }
                switch step {
                case .visit: history.visit(target)
                case .back: history.goBack()
                case .forward: history.goForward()
                case .reload: break
                }
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

    // MARK: Changing things

    /// `untitled folder`, or the first `untitled folder 2`, 3… not yet taken in the folder on screen.
    var suggestedFolderName: String {
        RemoteFileName.unusedName("untitled folder", among: entries.map(\.name))
    }

    func makeFolder(named name: String) {
        let folder = path
        run("Creating folder…", selecting: name.trimmingCharacters(in: .whitespacesAndNewlines)) { session in
            try await session.makeFolder(named: name, in: folder)
            return nil
        }
    }

    func rename(_ entry: RemoteEntry, to newName: String) {
        let folder = path
        run("Renaming…", selecting: newName.trimmingCharacters(in: .whitespacesAndNewlines)) { session in
            try await session.rename(entry, to: newName, in: folder)
            return nil
        }
    }

    /// Moves items out of the folder on screen into `destination`.
    func move(_ items: [RemoteEntry], to destination: String) {
        move(items, from: path, to: destination)
    }

    func move(_ items: [RemoteEntry], from folder: String, to destination: String) {
        guard !items.isEmpty else { return }
        run("Moving \(Self.count(items))…") { session in
            let result = try await session.move(items, from: folder, to: destination)
            return ("moved", result)
        }
    }

    func delete(_ items: [RemoteEntry]) {
        guard !items.isEmpty else { return }
        let folder = path
        run("Deleting \(Self.count(items))…", canCancel: true) { [weak self] session in
            let result = try await session.delete(items, in: folder) { removed in
                Task { @MainActor in self?.operation?.count = removed }
            }
            return ("deleted", result)
        }
    }

    func cancelOperation() {
        operationTask?.cancel()
    }

    // MARK: Cut and paste

    func cut(_ items: [RemoteEntry]) {
        clipboard = items.isEmpty ? nil : Clipboard(folder: path, entries: items)
    }

    /// Moves the cut items into the folder on screen, or into one of its folders.
    func paste(into folderName: String? = nil) {
        guard let clipboard else { return }
        move(clipboard.entries, from: clipboard.folder, to: folderName.map { RemotePath.appending($0, to: path) } ?? path)
    }

    // MARK: Running a change

    /// Runs one change at a time, then reloads the folder on screen whatever happened, so the window shows the truth.
    private func run(
        _ title: String,
        selecting name: String? = nil,
        canCancel: Bool = false,
        _ work: @escaping (BrowseSession) async throws -> (verb: String, result: FileOperationResult)?
    ) {
        guard operation == nil else { return }
        problem = nil
        operation = Operation(title: title, count: nil, canCancel: canCancel)
        let folder = path
        operationTask = Task {
            var shouldSelect = name
            do {
                if let outcome = try await work(session) {
                    problem = Self.describe(outcome.result, verb: outcome.verb)
                    if outcome.result.completed == 0 { shouldSelect = nil }
                    if outcome.result.isComplete, clipboard != nil { clipboard = nil }
                }
            } catch is CancellationError {
                shouldSelect = nil
            } catch {
                problem = ServerBrowser.message(for: error)
                shouldSelect = nil
            }
            operation = nil
            operationTask = nil
            if let shouldSelect, path == folder { selectionRequest = [shouldSelect] }
            reload()
        }
    }

    private static func count(_ items: [RemoteEntry]) -> String {
        items.count == 1 ? "“\(items[0].name)”" : "\(items.count) items"
    }

    /// Nil when everything went through. Otherwise the first few refusals, one per line.
    static func describe(_ result: FileOperationResult, verb: String) -> String? {
        guard !result.failures.isEmpty else { return nil }
        let total = result.completed + result.failures.count
        let head = total == 1
            ? "“\(result.failures[0].name)” couldn't be \(verb)."
            : "\(result.failures.count) of \(total) items couldn't be \(verb)."
        var lines = [head]
        for failure in result.failures.prefix(3) {
            lines.append(total == 1 ? failure.message : "“\(failure.name)”: \(failure.message)")
        }
        if result.failures.count > 3 { lines.append("and \(result.failures.count - 3) more.") }
        return lines.joined(separator: "\n")
    }
}
