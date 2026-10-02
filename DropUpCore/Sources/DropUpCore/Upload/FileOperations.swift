import Foundation

/// One item an operation could not finish, with a message that is fine to show.
public struct FileOperationFailure: Sendable, Equatable {
    public var name: String
    public var message: String

    public init(name: String, message: String) {
        self.name = name
        self.message = message
    }
}

/// How a move or delete went: the items done, and the ones that were refused.
public struct FileOperationResult: Sendable, Equatable {
    public var completed: Int
    public var failures: [FileOperationFailure]
    /// Links and special items inside copied folders that were left out.
    public var skipped: Int
    /// Files that took the place of a file with the same name. The old file is gone, so these can't be undone.
    public var replaced: Int
    /// Items that got a number added to their name because theirs was taken.
    public var renamed: Int
    /// Hidden files that hold what a replacement pushed aside but couldn't delete.
    public var leftOver: [String]
    /// What Undo needs to take this back, when something was done that can be taken back.
    public var change: BrowseChange?

    public init(
        completed: Int = 0,
        failures: [FileOperationFailure] = [],
        skipped: Int = 0,
        replaced: Int = 0,
        renamed: Int = 0,
        leftOver: [String] = [],
        change: BrowseChange? = nil
    ) {
        self.completed = completed
        self.failures = failures
        self.skipped = skipped
        self.replaced = replaced
        self.renamed = renamed
        self.leftOver = leftOver
        self.change = change
    }

    public var isComplete: Bool { failures.isEmpty }
}

public enum FileOperationError: Error, Equatable, Sendable {
    case invalidName
    case alreadyExists(String)
    /// The name is taken by something a file can't replace: a folder, or a file when a folder is moved.
    case cantReplace(String)
    case movedIntoItself
    case copiedIntoItself
    case cantCopyLink
    case isRoot
    case tooDeep
    case tooMany
    /// Something inside a folder could not be deleted. `path` is relative to the folder being deleted.
    case failedInside(path: String, reason: String)
}

extension FileOperationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidName:
            "That name can't be used. It can't be empty, contain a slash, or be “.” or “..”."
        case .alreadyExists(let name):
            "Something called “\(name)” is already there."
        case .cantReplace(let name):
            "“\(name)” is already there, and only a file can replace a file."
        case .movedIntoItself:
            "A folder can't be moved into itself."
        case .copiedIntoItself:
            "A folder can't be copied into itself."
        case .cantCopyLink:
            "A link can't be copied. Copy the file or folder it points to instead."
        case .isRoot:
            "The top folder of the server can't be changed."
        case .tooDeep:
            "The folders are nested too deeply to handle safely."
        case .tooMany:
            "There are too many items in this folder to handle at once."
        case .failedInside(let path, let reason):
            "“\(path)” couldn't be deleted. \(reason)"
        }
    }
}

extension RemoteFileName {
    /// The name with surrounding spaces and line breaks removed, or `FileOperationError.invalidName`
    /// if nothing is left or the server could not take it as one name.
    public static func validated(_ proposed: String) throws -> String {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != ".." else { throw FileOperationError.invalidName }
        // Check scalars, not Characters: "\r\n" is a single Character.
        let forbidden = name.unicodeScalars.contains { $0 == "/" || $0.properties.generalCategory == .control }
        guard !forbidden else { throw FileOperationError.invalidName }
        return name
    }

    /// `untitled folder`, or `untitled folder 2`, `untitled folder 3`, … when that is taken.
    public static func unusedName(_ base: String, among taken: some Collection<String>) -> String {
        let used = Set(taken)
        guard used.contains(base) else { return base }
        var index = 2
        while used.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }
}

/// Changes to a server's files and folders, built from the `ServerSession` commands so they behave the same over FTP and SFTP.
///
/// Every operation keeps to these rules: it replaces something that is already there only when the policy says so and
/// both are files, it never follows a symbolic link when deleting, and it tells the caller about each item it could not handle instead of stopping at the first.
public enum FileOperations {
    private static let deepestFolder = 64

    /// Makes the folder and says where it is.
    @discardableResult
    public static func makeFolder(named name: String, in folder: String, session: any ServerSession) async throws -> String {
        let name = try RemoteFileName.validated(name)
        let path = RemotePath.appending(name, to: folder)
        try await session.makeDirectory(atPath: path)
        return path
    }

    /// Renames the item and says what moved, or nil when the name was already right.
    @discardableResult
    public static func rename(
        _ entry: RemoteEntry,
        to newName: String,
        in folder: String,
        session: any ServerSession
    ) async throws -> ItemMove? {
        let newName = try RemoteFileName.validated(newName)
        guard newName != entry.name else { return nil }
        let siblings = try await session.listEntries(atPath: RemotePath.normalizedDirectory(folder))
        guard !siblings.contains(where: { $0.name == newName }) else { throw FileOperationError.alreadyExists(newName) }
        let move = ItemMove(from: RemotePath.appending(entry.name, to: folder), to: RemotePath.appending(newName, to: folder))
        try await session.rename(from: move.from, to: move.to)
        return move
    }

    /// Moves `entries` from `folder` into `destination`.
    ///
    /// When `destination` already has an item with a name, `policy` decides: `keepBoth` adds a number (`a-1.txt`),
    /// and `replace` lets a file take the place of a file (see `replaceFile`). A folder is never merged into or
    /// replaced, and nothing replaces a folder: those items stay where they are and are reported.
    public static func move(
        _ entries: [RemoteEntry],
        from folder: String,
        to destination: String,
        policy: ConflictPolicy = .keepBoth,
        session: any ServerSession
    ) async throws -> FileOperationResult {
        let source = RemotePath.normalizedDirectory(folder)
        let target = RemotePath.normalizedDirectory(destination)
        guard source != target, !entries.isEmpty else { return FileOperationResult() }

        var present = Dictionary(try await session.listEntries(atPath: target).map { ($0.name, $0.kind) }, uniquingKeysWith: { first, _ in first })
        var result = FileOperationResult()
        var moves: [ItemMove] = []
        for entry in entries {
            try Task.checkCancellation()
            let from = RemotePath.appending(entry.name, to: source)
            do {
                if entry.kind == .folder, target == from || target.hasPrefix(from + "/") {
                    throw FileOperationError.movedIntoItself
                }
                var name = entry.name
                var replacing = false
                if let existing = present[entry.name] {
                    switch policy {
                    case .replace:
                        guard entry.kind == .file, existing == .file else { throw FileOperationError.cantReplace(entry.name) }
                        replacing = true
                    case .keepBoth:
                        name = try numberedName(entry.name, among: present.keys)
                    }
                }
                let to = RemotePath.appending(name, to: target)
                if replacing {
                    do {
                        try await replaceFile(at: to, with: from, session: session)
                    } catch let left as LeftOldCopy {
                        result.leftOver.append(left.path)
                    }
                    result.replaced += 1
                } else {
                    try await session.rename(from: from, to: to)
                    if name != entry.name { result.renamed += 1 }
                    moves.append(ItemMove(from: from, to: to))
                }
                present[name] = entry.kind
                result.completed += 1
            } catch {
                result.failures.append(try failure(for: entry, error))
            }
        }
        result.change = moves.isEmpty ? nil : .moved(moves)
        return result
    }

    /// `a.txt` → `a-1.txt`, or `a-2.txt` … the first of those that isn't taken.
    static func numberedName(_ name: String, among taken: some Collection<String>) throws -> String {
        let used = Set(taken)
        for index in 1...1000 {
            let candidate = RemoteFileName.numbered(name, index: index)
            if !used.contains(candidate) { return candidate }
        }
        throw FileOperationError.tooMany
    }

    /// Puts the file at `new` where the file at `existing` is, and deletes the old one.
    ///
    /// The old file is renamed aside first and only deleted once the new one is in place, so a failure or a cancel in the
    /// middle puts it back instead of leaving the name empty. It never relies on the server refusing or allowing a
    /// rename onto an existing name, which FTP and SFTP servers disagree about.
    /// Throws `LeftOldCopy` when the replacement worked but the old file could not be deleted.
    static func replaceFile(at existing: String, with new: String, session: any ServerSession) async throws {
        let folder = RemotePath.parent(of: existing)
        let aside = RemotePath.appending(".\(RemotePath.lastComponent(of: existing)).replaced-\(UUID().uuidString.prefix(8))", to: folder)
        try await session.rename(from: existing, to: aside)
        do {
            try await session.rename(from: new, to: existing)
        } catch {
            // Even if this task was cancelled, the old file has to go back.
            await Task.detached { try? await session.rename(from: aside, to: existing) }.value
            throw error
        }
        do {
            try await session.deleteFile(atPath: aside)
        } catch {
            throw LeftOldCopy(path: aside)
        }
    }

    /// A replacement is done, but the file it pushed aside is still on the server under a hidden name.
    struct LeftOldCopy: Error {
        let path: String
    }

    /// Deletes `entries` from `folder`, folders with everything inside them.
    /// `progress` receives the number of files and folders removed so far.
    public static func delete(
        _ entries: [RemoteEntry],
        in folder: String,
        session: any ServerSession,
        progress: @Sendable (Int) -> Void = { _ in }
    ) async throws -> FileOperationResult {
        var removed = 0
        var result = FileOperationResult()
        for entry in entries {
            try Task.checkCancellation()
            let path = RemotePath.appending(entry.name, to: folder)
            do {
                guard path != "/" else { throw FileOperationError.isRoot }
                try await remove(entry, at: path, relativeName: entry.name, depth: 0, session: session, removed: &removed, progress: progress)
                result.completed += 1
            } catch {
                result.failures.append(try failure(for: entry, error))
            }
        }
        return result
    }

    private static func remove(
        _ entry: RemoteEntry,
        at path: String,
        relativeName: String,
        depth: Int,
        session: any ServerSession,
        removed: inout Int,
        progress: @Sendable (Int) -> Void
    ) async throws {
        try Task.checkCancellation()
        switch entry.kind {
        case .file, .link:
            try await wrapped(relativeName, depth: depth) { try await session.deleteFile(atPath: path) }
            removed += 1
            progress(removed)
        case .folder:
            // A symbolic link to a folder can be listed as a folder, and walking into it would delete what it points at.
            // Deleting it as a file removes only the link, and is refused for a real folder.
            do {
                try await session.deleteFile(atPath: path)
                removed += 1
                progress(removed)
                return
            } catch where isRefusal(error) {
                // A real folder: empty it, then remove it.
            }
            guard depth < deepestFolder else { throw FileOperationError.tooDeep }
            let children = try await wrapped(relativeName, depth: depth) { try await session.listEntries(atPath: path) }
            for child in children {
                try await remove(
                    child,
                    at: RemotePath.appending(child.name, to: path),
                    relativeName: relativeName + "/" + child.name,
                    depth: depth + 1,
                    session: session,
                    removed: &removed,
                    progress: progress
                )
            }
            try await wrapped(relativeName, depth: depth) { try await session.removeDirectory(atPath: path) }
            removed += 1
            progress(removed)
        }
    }

    /// Reports a refusal inside a folder together with where it happened. Top-level failures keep their own message.
    private static func wrapped<T>(_ relativeName: String, depth: Int, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch where depth > 0 && isRefusal(error) {
            throw FileOperationError.failedInside(path: relativeName, reason: UploadQueue.message(for: error))
        }
    }

    /// An answer from the server that says "no" to this item, as opposed to a broken connection or a cancel.
    static func isRefusal(_ error: any Error) -> Bool {
        switch error {
        case is FileOperationError, is FolderTransferError, UploaderError.serverRejected, UploaderError.invalidRemotePath:
            true
        default:
            false
        }
    }

    /// Turns a refusal into a failure to report. Anything else (cancel, lost connection) goes on up.
    static func failure(for entry: RemoteEntry, _ error: any Error) throws -> FileOperationFailure {
        try failure(named: entry.name, error)
    }

    static func failure(named name: String, _ error: any Error) throws -> FileOperationFailure {
        guard isRefusal(error) else { throw error }
        return FileOperationFailure(name: name, message: UploadQueue.message(for: error))
    }
}

extension FileOperationResult {
    /// What to tell the person afterwards: the first few refusals, one per line, then anything else worth knowing about
    /// what was done. `verb` is the past tense of the operation ("moved", "copied"). Nil when it all went through quietly.
    public func summary(verb: String) -> String? {
        var lines: [String] = []
        if !failures.isEmpty {
            let total = completed + failures.count
            lines.append(
                total == 1
                    ? "“\(failures[0].name)” couldn't be \(verb)."
                    : "\(failures.count) of \(total) items couldn't be \(verb)."
            )
            for failure in failures.prefix(3) {
                lines.append(total == 1 ? failure.message : "“\(failure.name)”: \(failure.message)")
            }
            if failures.count > 3 { lines.append("and \(failures.count - 3) more.") }
        }
        var notes: [String] = []
        if skipped > 0 {
            notes.append(skipped == 1 ? "A link inside the folders was left out." : "\(skipped) links inside the folders were left out.")
        }
        if replaced > 0 {
            notes.append(
                replaced == 1
                    ? "Replaced a file that was already there. That can't be undone."
                    : "Replaced \(replaced) files that were already there. That can't be undone."
            )
        }
        if renamed > 0 {
            notes.append(
                renamed == 1
                    ? "A number was added to 1 name because it was taken."
                    : "A number was added to \(renamed) names because they were taken."
            )
        }
        if !leftOver.isEmpty {
            let names = leftOver.prefix(3).map { "“\(RemotePath.lastComponent(of: $0))”" }.joined(separator: ", ")
            notes.append("The old \(leftOver.count == 1 ? "file" : "files") couldn't be deleted and \(leftOver.count == 1 ? "is" : "are") still on the server, hidden, as \(names).")
        }
        if !notes.isEmpty, failures.isEmpty, completed > 0 {
            lines.append(verb.prefix(1).uppercased() + verb.dropFirst() + ".")
        }
        lines.append(contentsOf: notes)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
