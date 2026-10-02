import Foundation
import Observation
import DropUpCore

/// What the Browse window shows: one folder of the server at a time, reached through a connection that stays open.
/// It also carries out the changes the window offers (new folder, rename, move, copy, delete), refreshes the listing
/// afterwards, and remembers what can be undone.
@MainActor
@Observable
final class BrowseModel {
    /// A change to the server that is running.
    struct Operation: Equatable {
        var title: String
        /// A few words on how far it has got, like "12 removed" or the name of the item being copied.
        var detail: String?
        /// 0...1 when the change can say how far along it is.
        var fraction: Double?
        var canCancel: Bool
    }

    /// One of the folders above the one on screen, shown as a column in the Columns view.
    struct ParentColumn: Identifiable, Equatable {
        var path: String
        /// The folder inside it that leads down to the folder on screen.
        var childName: String
        /// Nil while the listing is on its way.
        var entries: [RemoteEntry]?
        var error: String?
        var id: String { path }
    }

    /// Items that were cut or copied and wait for Paste. They stay where they are until pasted.
    struct Clipboard: Equatable {
        enum Mode { case cut, copy }
        var mode: Mode
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
    /// The folders above the one on screen, outermost first. Only filled in while the Columns view is on.
    private(set) var parentColumns: [ParentColumn] = []
    private(set) var clipboard: Clipboard?
    /// Names the window should select once the folder on screen has loaded (the folder just made, the item just renamed).
    var selectionRequest: Set<String>?
    /// Changes Undo can take back, the latest last, and changes Redo can do again. They live as long as the window.
    private(set) var undoStack: [BrowseChange] = []
    private(set) var redoStack: [BrowseChange] = []
    /// The server this window shows, and the login for it, kept so downloads go where the window is looking.
    let config: ServerConfig
    let password: String
    /// Names the server in the window title and the empty-folder text.
    let serverName: String
    /// Identifies the server this window was opened for, so a drop can tell if Settings pointed somewhere else since.
    let credentialKey: String

    @ObservationIgnored private let session: BrowseSession
    /// What to do when a move or copy lands on a name that is taken. Read each time, so a change in Settings applies at once.
    @ObservationIgnored private let conflictPolicy: @MainActor () -> ConflictPolicy
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Listings of the folders above, kept so moving around doesn't list the same folders again and again.
    @ObservationIgnored private var parentListings: [String: [RemoteEntry]] = [:]
    @ObservationIgnored private var showsParents = false
    /// Bumped for each round of parent listings, so a round that was overtaken stops after its current listing.
    @ObservationIgnored private var parentRound = 0
    @ObservationIgnored private var operationTask: Task<Void, Never>?

    init(
        config: ServerConfig,
        password: String,
        session: BrowseSession,
        conflictPolicy: @escaping @MainActor () -> ConflictPolicy = { .keepBoth }
    ) {
        self.config = config
        self.password = password
        let start = RemotePath.normalizedDirectory(config.remoteDirectory)
        self.path = start
        // Back can climb out of the starting folder, one enclosing folder at a time.
        self.history = FolderHistory(start: start, includingParents: true)
        self.serverName = config.shownName ?? config.host
        self.credentialKey = config.credentialKey
        self.session = session
        self.conflictPolicy = conflictPolicy
    }

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }
    var isBusy: Bool { operation != nil }
    var canUndo: Bool { !undoStack.isEmpty && !isBusy }
    var canRedo: Bool { !redoStack.isEmpty && !isBusy }
    /// "Move “a.txt”", for the Undo button's tooltip.
    var undoTitle: String? { undoStack.last?.title }
    var redoTitle: String? { redoStack.last?.title }

    // MARK: Navigating

    /// Lists the starting folder. Call once when the window opens.
    func start() {
        load(path, as: .reload)
    }

    func reload() {
        parentListings.removeAll()
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
        showsParents = false
        parentRound += 1
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
                refreshParents()
            } catch is CancellationError {
                // A newer listing replaced this one, and it owns the loading state.
            } catch {
                guard !Task.isCancelled else { return }
                isLoading = false
                self.error = ServerBrowser.message(for: error)
            }
        }
    }

    // MARK: Parent folders (Columns view)

    /// Turns the parent columns on or off. While on, they follow the folder on screen.
    func setShowsParents(_ shown: Bool) {
        guard shown != showsParents else { return }
        showsParents = shown
        refreshParents()
    }

    /// Lays out one column for each folder above the one on screen, using what is already known, and lists the rest
    /// from the nearest folder outwards. The folder on screen is listed first, so these never hold it up for long.
    private func refreshParents() {
        parentRound += 1
        guard showsParents else {
            parentColumns = []
            return
        }
        let trail = RemotePath.trail(to: path)
        let before = parentColumns
        // A column that is being listed again keeps showing its old listing meanwhile, so it doesn't flicker.
        parentColumns = trail.dropLast().enumerated().map { index, step in
            let shown = parentListings[step.path] ?? before.first(where: { $0.path == step.path })?.entries
            return ParentColumn(path: step.path, childName: trail[index + 1].name, entries: shown, error: nil)
        }
        let missing = parentColumns.map(\.path).filter { parentListings[$0] == nil }.reversed()
        guard !missing.isEmpty else { return }
        let round = parentRound
        let session = session
        Task {
            for target in missing {
                // Not cancelled, just abandoned: cancelling a listing in flight would drop the shared connection.
                guard round == parentRound else { return }
                do {
                    let listing = try await session.entries(atPath: target)
                    guard round == parentRound else { return }
                    parentListings[target] = listing
                    updateParent(target) { $0.entries = listing }
                } catch {
                    guard round == parentRound else { return }
                    updateParent(target) { $0.error = ServerBrowser.message(for: error) }
                }
            }
        }
    }

    private func updateParent(_ path: String, _ change: (inout ParentColumn) -> Void) {
        guard let index = parentColumns.firstIndex(where: { $0.path == path }) else { return }
        change(&parentColumns[index])
    }

    // MARK: Changing things

    /// `untitled folder`, or the first `untitled folder 2`, 3… not yet taken in the folder on screen.
    var suggestedFolderName: String {
        RemoteFileName.unusedName("untitled folder", among: entries.map(\.name))
    }

    func makeFolder(named name: String) {
        let folder = path
        run("Creating folder…", selecting: name.trimmingCharacters(in: .whitespacesAndNewlines)) { session in
            let change = try await session.makeFolder(named: name, in: folder)
            return ("created", FileOperationResult(completed: 1, change: change))
        }
    }

    func rename(_ entry: RemoteEntry, to newName: String) {
        let folder = path
        run("Renaming…", selecting: newName.trimmingCharacters(in: .whitespacesAndNewlines)) { session in
            let change = try await session.rename(entry, to: newName, in: folder)
            return ("renamed", FileOperationResult(completed: change == nil ? 0 : 1, change: change))
        }
    }

    /// Moves items out of the folder on screen into `destination`.
    func move(_ items: [RemoteEntry], to destination: String) {
        move(items, from: path, to: destination)
    }

    func move(_ items: [RemoteEntry], from folder: String, to destination: String) {
        guard !items.isEmpty else { return }
        let policy = conflictPolicy()
        run("Moving \(Self.count(items))…") { session in
            let result = try await session.move(items, from: folder, to: destination, policy: policy)
            return ("moved", result)
        }
    }

    func delete(_ items: [RemoteEntry]) {
        guard !items.isEmpty else { return }
        let folder = path
        run("Deleting \(Self.count(items))…", canCancel: true) { [weak self] session in
            let result = try await session.delete(items, in: folder) { removed in
                Task { @MainActor in self?.operation?.detail = "\(removed) removed" }
            }
            return ("deleted", result)
        }
    }

    func cancelOperation() {
        operationTask?.cancel()
    }

    // MARK: Cut, copy and paste

    func cut(_ items: [RemoteEntry]) {
        clipboard = items.isEmpty ? nil : Clipboard(mode: .cut, folder: path, entries: items)
    }

    func copyToClipboard(_ items: [RemoteEntry]) {
        clipboard = items.isEmpty ? nil : Clipboard(mode: .copy, folder: path, entries: items)
    }

    func clearClipboard() {
        clipboard = nil
    }

    /// Moves the cut items, or copies the copied ones, into the folder on screen or into one of its folders.
    func paste(into folderName: String? = nil) {
        guard let clipboard else { return }
        let destination = folderName.map { RemotePath.appending($0, to: path) } ?? path
        switch clipboard.mode {
        case .cut: move(clipboard.entries, from: clipboard.folder, to: destination)
        case .copy: copy(clipboard.entries, from: clipboard.folder, to: destination)
        }
    }

    /// Makes a copy of each item next to it, called "name copy".
    func duplicate(_ items: [RemoteEntry]) {
        copy(items, from: path, to: path)
    }

    private func copy(_ items: [RemoteEntry], from folder: String, to destination: String) {
        guard !items.isEmpty else { return }
        let policy = conflictPolicy()
        let report = copyReporter()
        run("Copying \(Self.count(items))…", canCancel: true) { session in
            let result = try await session.copy(items, from: folder, to: destination, policy: policy, progress: report)
            return ("copied", result)
        }
    }

    // MARK: Undo and redo

    /// Takes back the latest change. Deleting can't be taken back, so it isn't in the list.
    func undo() {
        guard canUndo, let change = undoStack.last else { return }
        run("Undoing \(change.title)…", canCancel: Self.isCopy(change), role: .undoing) { session in
            let result = try await session.undo(change)
            return ("undone", result)
        }
    }

    /// Does the change that Undo took back again.
    func redo() {
        guard canRedo, let change = redoStack.last else { return }
        let policy = conflictPolicy()
        let report = copyReporter()
        run("Redoing \(change.title)…", canCancel: Self.isCopy(change), role: .redoing) { session in
            let result = try await session.redo(change, policy: policy, progress: report)
            return ("redone", result)
        }
    }

    private static func isCopy(_ change: BrowseChange) -> Bool {
        if case .copied = change { return true }
        return false
    }

    private static let undoLimit = 50

    /// Only the latest changes are kept. A new change ends whatever Redo could have repeated, as in any editor.
    private func record(_ change: BrowseChange) {
        undoStack.append(change)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
        redoStack.removeAll()
    }

    /// A replaced file can't be brought back, so changes made before it could no longer be undone in order.
    private func forgetHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Updates the progress strip as a copy goes on.
    private func copyReporter() -> @Sendable (CopyProgress) -> Void {
        { [weak self] progress in
            Task { @MainActor in
                self?.operation?.detail = progress.name
                self?.operation?.fraction = progress.total > 0 ? progress.fraction : nil
            }
        }
    }

    // MARK: Running a change

    private enum HistoryRole { case fresh, undoing, redoing }

    /// Runs one change at a time, then reloads the folder on screen whatever happened, so the window shows the truth.
    /// `role` says how the change fits the undo list: a new change is added to it, while undoing or redoing moves
    /// the latest entry across.
    private func run(
        _ title: String,
        selecting name: String? = nil,
        canCancel: Bool = false,
        role: HistoryRole = .fresh,
        _ work: @escaping (BrowseSession) async throws -> (verb: String, result: FileOperationResult)?
    ) {
        guard operation == nil else { return }
        problem = nil
        operation = Operation(title: title, detail: nil, fraction: nil, canCancel: canCancel)
        let folder = path
        operationTask = Task {
            var shouldSelect = name
            var showFolder: String?
            do {
                if let outcome = try await work(session) {
                    let result = outcome.result
                    problem = result.summary(verb: outcome.verb)
                    if result.completed == 0 { shouldSelect = nil }
                    // Cut items have left where they were once they are moved or deleted. Copied ones can be pasted again.
                    if ["moved", "deleted"].contains(outcome.verb), result.isComplete, clipboard?.mode == .cut { clipboard = nil }
                    switch role {
                    case .fresh:
                        if result.replaced > 0 {
                            forgetHistory()
                        } else if let change = result.change {
                            record(change)
                        }
                    case .undoing:
                        // Whatever happened, this entry has had its turn. What was taken back can be done again.
                        if !undoStack.isEmpty { undoStack.removeLast() }
                        if let undone = result.change {
                            redoStack.append(undone)
                            showFolder = undone.folderWhenUndone
                        }
                    case .redoing:
                        if !redoStack.isEmpty { redoStack.removeLast() }
                        if result.replaced > 0 {
                            forgetHistory()
                        } else if let redone = result.change {
                            undoStack.append(redone)
                            showFolder = redone.folderWhenDone
                        }
                    }
                }
            } catch is CancellationError {
                shouldSelect = nil
            } catch {
                problem = ServerBrowser.message(for: error)
                shouldSelect = nil
            }
            operation = nil
            operationTask = nil
            parentListings.removeAll()
            if let shouldSelect, path == folder { selectionRequest = [shouldSelect] }
            // Show where an undo or redo happened, so the person sees what it did. Opening a folder clears the
            // message, so when there is one to read the window stays where it is.
            if let showFolder, showFolder != path, problem == nil {
                go(to: showFolder)
            } else {
                reload()
            }
        }
    }

    private static func count(_ items: [RemoteEntry]) -> String {
        items.count == 1 ? "“\(items[0].name)”" : "\(items.count) items"
    }
}
