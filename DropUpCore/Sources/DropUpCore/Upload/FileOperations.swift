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

    public init(completed: Int = 0, failures: [FileOperationFailure] = []) {
        self.completed = completed
        self.failures = failures
    }

    public var isComplete: Bool { failures.isEmpty }
}

public enum FileOperationError: Error, Equatable, Sendable {
    case invalidName
    case alreadyExists(String)
    case movedIntoItself
    case isRoot
    case tooDeep
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
        case .movedIntoItself:
            "A folder can't be moved into itself."
        case .isRoot:
            "The top folder of the server can't be changed."
        case .tooDeep:
            "The folders are nested too deeply to delete safely."
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
/// Every operation keeps to these rules: it never replaces something that is already there, it never follows a
/// symbolic link when deleting, and it tells the caller about each item it could not handle instead of stopping at the first.
public enum FileOperations {
    private static let deepestFolder = 64

    public static func makeFolder(named name: String, in folder: String, session: any ServerSession) async throws {
        let name = try RemoteFileName.validated(name)
        try await session.makeDirectory(atPath: RemotePath.appending(name, to: folder))
    }

    public static func rename(
        _ entry: RemoteEntry,
        to newName: String,
        in folder: String,
        session: any ServerSession
    ) async throws {
        let newName = try RemoteFileName.validated(newName)
        guard newName != entry.name else { return }
        let siblings = try await session.listEntries(atPath: RemotePath.normalizedDirectory(folder))
        guard !siblings.contains(where: { $0.name == newName }) else { throw FileOperationError.alreadyExists(newName) }
        try await session.rename(
            from: RemotePath.appending(entry.name, to: folder),
            to: RemotePath.appending(newName, to: folder)
        )
    }

    /// Moves `entries` from `folder` into `destination`. Items whose name is already taken there are left where they are.
    public static func move(
        _ entries: [RemoteEntry],
        from folder: String,
        to destination: String,
        session: any ServerSession
    ) async throws -> FileOperationResult {
        let source = RemotePath.normalizedDirectory(folder)
        let target = RemotePath.normalizedDirectory(destination)
        guard source != target, !entries.isEmpty else { return FileOperationResult() }

        let taken = Set(try await session.listEntries(atPath: target).map(\.name))
        var result = FileOperationResult()
        for entry in entries {
            try Task.checkCancellation()
            let from = RemotePath.appending(entry.name, to: source)
            do {
                if entry.kind == .folder, target == from || target.hasPrefix(from + "/") {
                    throw FileOperationError.movedIntoItself
                }
                if taken.contains(entry.name) { throw FileOperationError.alreadyExists(entry.name) }
                try await session.rename(from: from, to: RemotePath.appending(entry.name, to: target))
                result.completed += 1
            } catch {
                result.failures.append(try failure(for: entry, error))
            }
        }
        return result
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
    private static func isRefusal(_ error: any Error) -> Bool {
        switch error {
        case is FileOperationError, UploaderError.serverRejected, UploaderError.invalidRemotePath:
            true
        default:
            false
        }
    }

    /// Turns a refusal into a failure to report. Anything else (cancel, lost connection) goes on up.
    private static func failure(for entry: RemoteEntry, _ error: any Error) throws -> FileOperationFailure {
        guard isRefusal(error) else { throw error }
        return FileOperationFailure(name: entry.name, message: UploadQueue.message(for: error))
    }
}
