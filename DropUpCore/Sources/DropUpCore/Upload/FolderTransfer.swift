import Foundation

/// Why a folder transfer stopped, naming the item inside the folder it stopped at.
public struct FolderTransferError: Error, Equatable, Sendable, LocalizedError {
    /// The item's path relative to the folder being transferred.
    public var path: String
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }

    public var errorDescription: String? { "“\(path)”: \(reason)" }
}

/// Everything inside a folder on this Mac that a folder upload sends.
///
/// Symbolic links and other special items (sockets, devices) are left out and counted in `skipped`, so a link
/// can never lead the upload out of the folder or around in circles. `.DS_Store` files are left out too.
public struct LocalTree: Sendable, Equatable {
    public struct File: Sendable, Equatable {
        /// Path from the folder, with `/` between names.
        public var relativePath: String
        public var url: URL
        public var size: Int64
    }

    /// Every folder inside, empty ones included, with each folder listed before the folders inside it.
    public var directories: [String] = []
    public var files: [File] = []
    public var skipped = 0

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// The folders a file sits in, outermost first: `a/b/c.txt` is in `a` and `a/b`.
    static func folders(containing relativePath: String) -> [String] {
        let names = relativePath.split(separator: "/")
        guard names.count > 1 else { return [] }
        var folders: [String] = []
        var path = ""
        for name in names.dropLast() {
            path = path.isEmpty ? String(name) : path + "/" + name
            folders.append(path)
        }
        return folders
    }

    private static let deepest = 64
    private static let mostItems = 500_000

    public static func scan(_ root: URL, fileManager: FileManager = .default) throws -> LocalTree {
        var tree = LocalTree()
        try scan(root, relative: "", depth: 0, into: &tree, fileManager: fileManager)
        return tree
    }

    private static func scan(_ folder: URL, relative: String, depth: Int, into tree: inout LocalTree, fileManager: FileManager) throws {
        guard depth < deepest else { throw FileOperationError.tooDeep }
        // A big folder takes a while to read: a cancel has to be able to stop it between folders.
        try Task.checkCancellation()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let children = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = child.lastPathComponent
            guard name != ".DS_Store" else { continue }
            let values = try child.resourceValues(forKeys: Set(keys))
            let path = relative.isEmpty ? name : relative + "/" + name
            guard tree.files.count + tree.directories.count < mostItems else { throw FileOperationError.tooMany }
            if values.isSymbolicLink == true {
                tree.skipped += 1
            } else if values.isDirectory == true {
                tree.directories.append(path)
                try scan(child, relative: path, depth: depth + 1, into: &tree, fileManager: fileManager)
            } else if values.isRegularFile == true {
                tree.files.append(File(relativePath: path, url: child, size: Int64(values.fileSize ?? 0)))
            } else {
                tree.skipped += 1
            }
        }
    }
}

/// Everything inside a folder on the server that a folder download fetches.
///
/// Symbolic links are left out and counted in `skipped`. So are items whose names a server could use to
/// reach outside the folder (a name with a slash in it, or `..`), because the names become local file names.
public struct RemoteTree: Sendable, Equatable {
    public struct File: Sendable, Equatable {
        public var relativePath: String
        public var size: Int64?
    }

    /// Every folder inside, empty ones included, with each folder listed before the folders inside it.
    public var directories: [String] = []
    public var files: [File] = []
    public var skipped = 0

    public var totalBytes: Int64 { files.reduce(0) { $0 + ($1.size ?? 0) } }

    private static let deepest = 32
    private static let mostItems = 100_000

    public static func walk(_ root: String, session: any ServerSession) async throws -> RemoteTree {
        var tree = RemoteTree()
        try await walk(RemotePath.normalizedDirectory(root), relative: "", depth: 0, into: &tree, session: session)
        return tree
    }

    /// Whether a name from a listing is safe to use as one local file name.
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.unicodeScalars.contains { $0 == "/" || $0 == "\0" }
    }

    private static func walk(
        _ folder: String,
        relative: String,
        depth: Int,
        into tree: inout RemoteTree,
        session: any ServerSession
    ) async throws {
        guard depth < deepest else { throw FileOperationError.tooDeep }
        try Task.checkCancellation()
        let entries: [RemoteEntry]
        do {
            entries = try await session.listEntriesWithLinks(atPath: folder)
        } catch where relative.isEmpty == false && isRefusal(error) {
            throw FolderTransferError(path: relative, reason: UploadQueue.message(for: error))
        }
        for entry in entries {
            guard tree.files.count + tree.directories.count < mostItems else { throw FileOperationError.tooMany }
            guard isPlainName(entry.name) else {
                tree.skipped += 1
                continue
            }
            let path = relative.isEmpty ? entry.name : relative + "/" + entry.name
            switch entry.kind {
            case .link:
                tree.skipped += 1
            case .file:
                tree.files.append(File(relativePath: path, size: entry.size))
            case .folder:
                tree.directories.append(path)
                try await walk(folder + (folder == "/" ? "" : "/") + entry.name, relative: path, depth: depth + 1, into: &tree, session: session)
            }
        }
    }

    private static func isRefusal(_ error: any Error) -> Bool {
        switch error {
        case UploaderError.serverRejected, UploaderError.invalidRemotePath: true
        default: false
        }
    }
}

extension RemoteFileName {
    /// `photos`, then `photos-1`, `photos-2`…: a folder name has no extension to keep at the end.
    public static func numberedFolder(_ name: String, index: Int) -> String {
        "\(name)-\(index)"
    }
}
