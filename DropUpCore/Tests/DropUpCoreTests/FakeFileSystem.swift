import Foundation
@testable import DropUpCore

/// A small in-memory server with real folders, files and links, for tests of renaming, moving and deleting.
/// It answers like a Unix FTP or SFTP server: deleting a folder as a file is refused, removing a folder needs it empty,
/// and a rename onto something that exists is refused (or replaces a file, when `replacesOnRename` mimics a lax server).
final class FakeFileSystem: ServerSession, @unchecked Sendable {
    enum Node: Equatable {
        case folder
        case file(Int)
        case link(to: String)
    }

    private let lock = NSLock()
    private var nodes: [String: Node] = ["/": .folder]
    private var _log: [String] = []
    private var _failures: [String: any Error] = [:]
    private var _delayMilliseconds: UInt64 = 0
    private var _nextFailure: (any Error)?

    /// Lists a link to a folder as a plain folder, as some servers' machine-readable listings do.
    var reportsLinksAsFolders = false
    /// Lets a rename replace a file that is already at the new path.
    var replacesOnRename = false

    /// Every command in the order it arrived, like `DELE /a/b.txt`, `RMD /a`, `RENAME /a /b`, `LIST /a`.
    var log: [String] { lock.withLock { _log } }

    func clearLog() { lock.withLock { _log = [] } }

    /// Makes deleting, removing or renaming `path` fail with `error`.
    func fail(_ path: String, with error: any Error) { lock.withLock { _failures[path] = error } }

    /// Makes the next command of any kind fail with `error`, as when the server dropped an idle login.
    func failNextCommand(with error: any Error) { lock.withLock { _nextFailure = error } }

    /// Makes each command take this long, so a test can cancel one in flight.
    func slowDown(milliseconds: UInt64) { lock.withLock { _delayMilliseconds = milliseconds } }

    // MARK: Building a tree

    @discardableResult
    func addFolder(_ path: String) -> Self {
        lock.withLock { makeParents(of: path); nodes[path] = .folder }
        return self
    }

    @discardableResult
    func addFile(_ path: String, size: Int = 10) -> Self {
        lock.withLock { makeParents(of: path); nodes[path] = .file(size) }
        return self
    }

    @discardableResult
    func addLink(_ path: String, to target: String) -> Self {
        lock.withLock { makeParents(of: path); nodes[path] = .link(to: target) }
        return self
    }

    private func makeParents(of path: String) {
        var parent = Self.parent(of: path)
        while nodes[parent] == nil {
            nodes[parent] = .folder
            parent = Self.parent(of: parent)
        }
    }

    func exists(_ path: String) -> Bool { lock.withLock { nodes[path] != nil } }

    /// Every path under `folder`, sorted, not including the folder itself.
    func paths(under folder: String = "/") -> [String] {
        lock.withLock {
            let prefix = folder == "/" ? "/" : folder + "/"
            return nodes.keys.filter { $0.hasPrefix(prefix) && $0 != folder }.sorted()
        }
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    private static func name(of path: String) -> String {
        String(path[path.index(after: path.lastIndex(of: "/") ?? path.startIndex)...])
    }

    // MARK: ServerSession

    private func begin(_ command: String, failing path: String? = nil) async throws {
        let (delay, failure, dropped) = lock.withLock { () -> (UInt64, (any Error)?, (any Error)?) in
            _log.append(command)
            defer { _nextFailure = nil }
            return (_delayMilliseconds, path.flatMap { _failures[$0] }, _nextFailure)
        }
        if let dropped { throw dropped }
        if delay > 0 { try await Task.sleep(nanoseconds: delay * 1_000_000) }
        try Task.checkCancellation()
        if let failure { throw failure }
    }

    private static func refuse(_ message: String) -> UploaderError {
        .serverRejected(code: 550, message: message)
    }

    func fileExists(atPath path: String) async throws -> Bool {
        lock.withLock { if case .file = nodes[path] { true } else { false } }
    }

    func listDirectories(atPath path: String) async throws -> [String] {
        try await listEntries(atPath: path).filter { $0.kind == .folder }.map(\.name)
    }

    func listEntries(atPath path: String) async throws -> [RemoteEntry] {
        try await begin("LIST \(path)")
        return try lock.withLock { () throws -> [RemoteEntry] in
            var folder = path
            // Like a real server, listing a link to a folder lists what it points at.
            if case .link(let target)? = nodes[folder] { folder = target }
            guard nodes[folder] == .folder else { throw Self.refuse("No such folder") }
            let prefix = folder == "/" ? "/" : folder + "/"
            let children = nodes.filter { $0.key != folder && $0.key.hasPrefix(prefix) && !$0.key.dropFirst(prefix.count).contains("/") }
            let entries = children.map { path, node -> RemoteEntry in
                switch node {
                case .folder:
                    return RemoteEntry(name: Self.name(of: path), kind: .folder)
                case .file(let size):
                    return RemoteEntry(name: Self.name(of: path), kind: .file, size: Int64(size))
                case .link(let target):
                    let pointsAtFolder = nodes[target] == .folder
                    return RemoteEntry(name: Self.name(of: path), kind: reportsLinksAsFolders && pointsAtFolder ? .folder : .link, size: 0)
                }
            }
            return RemoteEntry.sorted(entries)
        }
    }

    func upload(fileURL: URL, to remotePath: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await begin("STOR \(remotePath)")
        lock.withLock { nodes[remotePath] = .file(0) }
        progress(0)
    }

    func download(remotePath: String, to fileURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await begin("RETR \(remotePath)")
        guard case .file? = lock.withLock({ nodes[remotePath] }) else { throw Self.refuse("No such file") }
        try Data().write(to: fileURL)
    }

    func deleteFile(atPath remotePath: String) async throws {
        try await begin("DELE \(remotePath)", failing: remotePath)
        try lock.withLock {
            switch nodes[remotePath] {
            case nil: throw Self.refuse("No such file")
            case .folder?: throw Self.refuse("Is a directory")
            case .file?, .link?: nodes[remotePath] = nil
            }
        }
    }

    func makeDirectory(atPath path: String) async throws {
        try await begin("MKD \(path)", failing: path)
        try lock.withLock {
            guard nodes[Self.parent(of: path)] == .folder else { throw Self.refuse("No such folder") }
            guard nodes[path] == nil else { throw Self.refuse("File exists") }
            nodes[path] = .folder
        }
    }

    func removeDirectory(atPath path: String) async throws {
        try await begin("RMD \(path)", failing: path)
        try lock.withLock {
            guard nodes[path] == .folder else { throw Self.refuse(nodes[path] == nil ? "No such folder" : "Not a directory") }
            guard !nodes.keys.contains(where: { $0.hasPrefix(path + "/") }) else { throw Self.refuse("Directory not empty") }
            nodes[path] = nil
        }
    }

    func rename(from oldPath: String, to newPath: String) async throws {
        try await begin("RENAME \(oldPath) \(newPath)", failing: oldPath)
        try lock.withLock {
            guard let node = nodes[oldPath] else { throw Self.refuse("No such file or folder") }
            guard nodes[Self.parent(of: newPath)] == .folder else { throw Self.refuse("No such folder") }
            if let existing = nodes[newPath] {
                guard replacesOnRename, case .file = existing, case .file = node else { throw Self.refuse("File exists") }
            }
            let moved = nodes.filter { $0.key == oldPath || $0.key.hasPrefix(oldPath + "/") }
            for (path, _) in moved { nodes[path] = nil }
            for (path, node) in moved { nodes[newPath + path.dropFirst(oldPath.count)] = node }
        }
    }

    func close() async {
        lock.withLock { _log.append("QUIT") }
    }
}

/// Hands out one `FakeFileSystem` and counts connections.
final class FakeFileSystemConnector: ServerConnector, ConnectorFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var _connections = 0
    let fileSystem: FakeFileSystem

    init(_ fileSystem: FakeFileSystem) { self.fileSystem = fileSystem }

    var connectionCount: Int { lock.withLock { _connections } }

    func connect(to config: ServerConfig, password: String) async throws -> any ServerSession {
        lock.withLock { _connections += 1 }
        return fileSystem
    }

    func connector(for transferProtocol: TransferProtocol) -> any ServerConnector { self }
}
