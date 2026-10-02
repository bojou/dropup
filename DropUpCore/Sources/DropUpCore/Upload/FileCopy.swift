import Foundation

/// How far a copy has got. Each file counts twice, once for coming down from the server and once for going back up.
public struct CopyProgress: Sendable, Equatable {
    /// The item being copied.
    public var name: String
    public var done: Int64
    public var total: Int64

    public init(name: String, done: Int64, total: Int64) {
        self.name = name
        self.done = done
        self.total = total
    }

    /// 0...1, or 0 when nothing is known about the sizes.
    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(done) / Double(total)))
    }
}

extension RemoteFileName {
    /// `report.pdf` → `report copy.pdf`, then `report copy 2.pdf`, `report copy 3.pdf`… like Finder.
    /// Copying `report copy.pdf` gives `report copy 2.pdf` rather than `report copy copy.pdf`.
    /// A folder's name has no extension, so `photos.2026` → `photos.2026 copy`.
    public static func copyName(_ name: String, isFolder: Bool, among taken: some Collection<String>) -> String {
        let used = Set(taken)
        let (stem, ext) = isFolder ? (name, "") : split(name)
        var base = stem
        if let range = base.range(of: #" copy( [0-9]+)?$"#, options: .regularExpression), range.lowerBound != base.startIndex {
            base = String(base[..<range.lowerBound])
        }
        var candidate = "\(base) copy\(ext)"
        var index = 2
        while used.contains(candidate) {
            candidate = "\(base) copy \(index)\(ext)"
            index += 1
        }
        return candidate
    }
}

extension FileOperations {
    /// Copies `entries` from `folder` into `destination`, on the same server. Folders go with everything inside them.
    ///
    /// Neither FTP nor SFTP can copy on the server, so every file comes down to `scratch` on this Mac and goes back up.
    /// Nothing is replaced: a name that is taken in `destination` (which includes copying into the same folder) gets
    /// `copy` added, like Finder does. Links are not copied, and neither are links inside folders (they are counted
    /// in `skipped`), so a link can never lead the copy somewhere else.
    ///
    /// A copy that stops halfway leaves what was already copied, except for the file that was being uploaded, which
    /// `leftBehind` is asked to remove because the session that sent it can't be trusted to.
    ///
    /// - Parameters:
    ///   - scratch: an existing local folder to stage files in. Nothing stays in it.
    ///   - began: called just before the first change to the server. Nothing was changed before that, so the whole
    ///     copy can safely be started again on a new connection.
    ///   - leftBehind: asked to delete a half-sent file at a remote path.
    public static func copy(
        _ entries: [RemoteEntry],
        from folder: String,
        to destination: String,
        session: any ServerSession,
        scratch: URL,
        began: @Sendable () -> Void = {},
        leftBehind: @Sendable (String) async -> Void = { _ in },
        progress: @escaping @Sendable (CopyProgress) -> Void = { _ in }
    ) async throws -> FileOperationResult {
        guard !entries.isEmpty else { return FileOperationResult() }
        let source = RemotePath.normalizedDirectory(folder)
        let target = RemotePath.normalizedDirectory(destination)

        var taken = Set(try await session.listEntries(atPath: target).map(\.name))
        var result = FileOperationResult()
        for entry in entries {
            try Task.checkCancellation()
            let from = RemotePath.appending(entry.name, to: source)
            let isFolder = entry.kind == .folder
            let name = taken.contains(entry.name) ? RemoteFileName.copyName(entry.name, isFolder: isFolder, among: taken) : entry.name
            let to = RemotePath.appending(name, to: target)
            var started = false
            do {
                switch entry.kind {
                case .link:
                    throw FileOperationError.cantCopyLink
                case .file:
                    let size = entry.size ?? 0
                    try await copyFile(from: from, to: to, label: entry.name, offset: 0, total: size * 2, size: size, session: session, scratch: scratch, began: began, leftBehind: leftBehind, progress: progress)
                case .folder:
                    if target == from || target.hasPrefix(from + "/") { throw FileOperationError.copiedIntoItself }
                    let tree = try await RemoteTree.walk(from, session: session)
                    result.skipped += tree.skipped
                    let total = tree.totalBytes * 2
                    began()
                    try await session.makeDirectory(atPath: to)
                    started = true
                    for folder in tree.directories {
                        try Task.checkCancellation()
                        try await wrappedInside(folder) { try await session.makeDirectory(atPath: to + "/" + folder) }
                    }
                    var offset: Int64 = 0
                    progress(CopyProgress(name: entry.name, done: 0, total: total))
                    for file in tree.files {
                        try Task.checkCancellation()
                        let size = file.size ?? 0
                        try await wrappedInside(file.relativePath) {
                            try await copyFile(
                                from: from + "/" + file.relativePath,
                                to: to + "/" + file.relativePath,
                                label: entry.name,
                                offset: offset,
                                total: total,
                                size: size,
                                session: session,
                                scratch: scratch,
                                began: began,
                                leftBehind: leftBehind,
                                progress: progress
                            )
                        }
                        offset += size * 2
                    }
                }
                taken.insert(name)
                result.completed += 1
            } catch let stop as StopCopying {
                throw stop.error
            } catch {
                var item = try failure(for: entry, error)
                if started {
                    taken.insert(name)
                    item.message += " Part of it was copied before this stopped."
                }
                result.failures.append(item)
            }
        }
        return result
    }

    /// Brings one file down to `scratch` and sends it back up under the new name.
    private static func copyFile(
        from: String,
        to: String,
        label: String,
        offset: Int64,
        total: Int64,
        size: Int64,
        session: any ServerSession,
        scratch: URL,
        began: @Sendable () -> Void,
        leftBehind: @Sendable (String) async -> Void,
        progress: @escaping @Sendable (CopyProgress) -> Void
    ) async throws {
        let part = scratch.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: part) }
        try await session.download(remotePath: from, to: part) { received in
            progress(CopyProgress(name: label, done: offset + min(received, size), total: total))
        }
        try Task.checkCancellation()
        began()
        let created = Flag()
        do {
            try await session.upload(fileURL: part, to: to) { sent in
                created.set()
                progress(CopyProgress(name: label, done: offset + size + min(sent, size), total: total))
            }
        } catch {
            if created.isSet {
                await leftBehind(to)
                throw StopCopying(error: error)
            }
            throw error
        }
    }

    /// Names the file inside a folder where a refusal happened.
    private static func wrappedInside<T>(_ path: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as UploaderError where isRefusal(error) {
            throw FolderTransferError(path: path, reason: error.errorDescription ?? "\(error)")
        }
    }

    /// The upload of a file failed after the server created it. The connection can't be trusted, so the whole copy stops.
    private struct StopCopying: Error {
        let error: any Error
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}
