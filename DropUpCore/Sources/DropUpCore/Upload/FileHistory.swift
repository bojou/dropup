import Foundation

extension FileOperations {
    /// Takes a change back. The result's `change` is what was actually taken back, which is what Redo should do again;
    /// it is nil when nothing could be taken back.
    ///
    /// Taking back never overwrites: an item whose old name has been taken since stays where it is and is reported.
    /// A folder that was made is removed only while it is empty, and a copy only removes what it created.
    public static func undo(_ change: BrowseChange, session: any ServerSession) async throws -> FileOperationResult {
        switch change {
        case .madeFolder(let path):
            return try await single(path) {
                try await session.removeDirectory(atPath: path)
                return change
            }
        case .renamed(let move):
            let done = try await relocate([move.flipped], session: session)
            return done.result(change: done.moves.isEmpty ? nil : change)
        case .moved(let moves):
            let done = try await relocate(moves.reversed().map(\.flipped), session: session)
            return done.result(change: done.moves.isEmpty ? nil : .moved(done.moves.map(\.flipped).reversed()))
        case .copied(let record):
            return try await removeCopy(record, session: session, change: change)
        }
    }

    /// Does a change again after it was taken back. A copy is made again with `copy` instead, because it needs a
    /// scratch folder on this Mac; here it is left alone.
    public static func redo(_ change: BrowseChange, session: any ServerSession) async throws -> FileOperationResult {
        switch change {
        case .madeFolder(let path):
            return try await single(path) {
                try await session.makeDirectory(atPath: path)
                return change
            }
        case .renamed(let move):
            let done = try await relocate([move], session: session)
            return done.result(change: done.moves.isEmpty ? nil : change)
        case .moved(let moves):
            let done = try await relocate(moves, session: session)
            return done.result(change: done.moves.isEmpty ? nil : .moved(done.moves))
        case .copied:
            return FileOperationResult()
        }
    }

    private static func single(_ path: String, _ body: () async throws -> BrowseChange) async throws -> FileOperationResult {
        do {
            return FileOperationResult(completed: 1, change: try await body())
        } catch {
            return FileOperationResult(failures: [try failure(named: RemotePath.lastComponent(of: path), error)])
        }
    }

    private struct Relocated {
        var moves: [ItemMove] = []
        var failures: [FileOperationFailure] = []

        func result(change: BrowseChange?) -> FileOperationResult {
            FileOperationResult(completed: moves.count, failures: failures, change: change)
        }
    }

    /// Moves each item from `from` to `to`, refusing to land on a name that is taken.
    private static func relocate(_ moves: [ItemMove], session: any ServerSession) async throws -> Relocated {
        var taken: [String: Set<String>] = [:]
        var done = Relocated()
        for move in moves {
            try Task.checkCancellation()
            let name = RemotePath.lastComponent(of: move.to)
            let folder = RemotePath.parent(of: move.to)
            do {
                if move.to.hasPrefix(move.from + "/") { throw FileOperationError.movedIntoItself }
                if taken[folder] == nil {
                    taken[folder] = Set(try await session.listEntries(atPath: folder).map(\.name))
                }
                guard taken[folder]?.contains(name) != true else { throw FileOperationError.alreadyExists(name) }
                try await session.rename(from: move.from, to: move.to)
                taken[folder]?.insert(name)
                done.moves.append(move)
            } catch {
                done.failures.append(try failure(named: name, error))
            }
        }
        return done
    }

    /// Deletes the files a copy made, then its folders from the inside out. Anything that was put in a copied folder
    /// since then keeps the folder in place, and the folder is reported.
    private static func removeCopy(_ record: CopyRecord, session: any ServerSession, change: BrowseChange) async throws -> FileOperationResult {
        var result = FileOperationResult()
        var removed = 0
        for path in record.files.reversed() {
            try Task.checkCancellation()
            do {
                try await session.deleteFile(atPath: path)
                removed += 1
            } catch {
                result.failures.append(try failure(named: RemotePath.lastComponent(of: path), error))
            }
        }
        for path in record.folders.reversed() {
            try Task.checkCancellation()
            do {
                try await session.removeDirectory(atPath: path)
                removed += 1
            } catch {
                result.failures.append(try failure(named: RemotePath.lastComponent(of: path), error))
            }
        }
        result.completed = removed
        result.change = result.failures.isEmpty ? change : nil
        return result
    }
}
