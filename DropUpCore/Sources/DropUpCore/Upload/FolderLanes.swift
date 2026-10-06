import Foundation

/// How a folder transfer moves several files at once. Each file of a folder costs a few round trips to open and close
/// besides its bytes, so a folder of many small files one at a time spends most of its time waiting on the server.
///
/// A session that can run several transfers (SFTP, over its one connection) gets that many lanes. A session that moves
/// one file at a time (FTP) gets a lane on each of a few more connections to the same server; one that can't be opened
/// (a server that takes only so many connections from one address) leaves its lane out, the others carry on, and the
/// next folder to that server doesn't try it again.
enum FolderLanes {
    /// Runs `lane` on each lane until all of them return; a lane takes files until there are none left. The first error
    /// from a lane stops the others and is thrown.
    /// - Parameters:
    ///   - main: the session the transfer already has. It is not closed here.
    ///   - files: how many files are left to move, so no more lanes are opened than there are files.
    ///   - connect: opens one more session to the same server.
    ///   - opened: told about each session opened here, so a stop can close it under a stuck transfer. They are all
    ///     closed before this returns.
    static func run(
        main: any ServerSession,
        files: Int,
        allowance: ConnectionAllowance,
        server: ServerConfig,
        connect: @escaping @Sendable () async throws -> any ServerSession,
        opened: @escaping @Sendable (any ServerSession) async -> Void,
        lane: @escaping @Sendable (any ServerSession) async throws -> Void
    ) async throws {
        let perSession = max(1, main.concurrentTransfers)
        let connections = allowance.connections(for: server, wanted: max(1, main.connectionsForFolders))
        let lanes = min(files, perSession * connections)
        guard lanes > 1 else {
            try await lane(main)
            return
        }
        let extra = ExtraSessions()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var left = lanes
                for _ in 0..<min(perSession, left) {
                    group.addTask { try await lane(main) }
                }
                left -= min(perSession, left)
                while left > 0 {
                    let count = min(perSession, left)
                    left -= count
                    group.addTask {
                        let session: any ServerSession
                        do {
                            session = try await connect()
                        } catch {
                            // Not a reason to stop the folder: the lanes that have a connection take its files.
                            if !Task.isCancelled { allowance.refused(by: server, working: extra.count + 1) }
                            return
                        }
                        extra.add(session)
                        await opened(session)
                        try await withThrowingTaskGroup(of: Void.self) { inner in
                            for _ in 0..<count {
                                inner.addTask { try await lane(session) }
                            }
                            try await inner.waitForAll()
                        }
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            await extra.closeAll()
            throw error
        }
        await extra.closeAll()
    }
}

/// How many connections each server took for a folder, once one was refused. Kept for as long as DropUp runs, so a
/// server that allows only one or two connections isn't asked for more on every folder.
final class ConnectionAllowance: @unchecked Sendable {
    private let lock = NSLock()
    private var limits: [String: Int] = [:]

    func connections(for server: ServerConfig, wanted: Int) -> Int {
        lock.withLock { min(wanted, limits[Self.key(server)] ?? wanted) }
    }

    /// A connection was refused while `working` were open.
    func refused(by server: ServerConfig, working: Int) {
        lock.withLock {
            let key = Self.key(server)
            limits[key] = max(1, min(limits[key] ?? .max, working))
        }
    }

    private static func key(_ server: ServerConfig) -> String {
        "\(server.transferProtocol)://\(server.username)@\(server.host):\(server.port)"
    }
}

/// The sessions a folder transfer opened besides its own.
private final class ExtraSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [any ServerSession] = []

    var count: Int { lock.withLock { sessions.count } }

    func add(_ session: any ServerSession) {
        lock.withLock { sessions.append(session) }
    }

    func closeAll() async {
        let all = lock.withLock {
            defer { sessions = [] }
            return sessions
        }
        for session in all {
            await session.close()
        }
    }
}

/// Hands out the files of a folder to the lanes, in order, and keeps the count of bytes moved across all of them.
final class FolderFiles: @unchecked Sendable {
    struct Moving {
        let index: Int
        /// Bytes of the file moved so far, counting what an earlier try left on the server.
        var bytes: Int64
        /// The server holds the file (or the Mac does, for a download), and it is this transfer's own.
        var created: Bool
        /// A note was made when it started, so it is noted again once the server holds it and when it is done.
        var noted: Bool
    }

    private let lock = NSLock()
    private let sizes: [Int64]
    /// Every file before it is done.
    private var low: Int
    /// The next file to hand out.
    private var next: Int
    /// Files at or past `low` that are done.
    private var doneAhead: Set<Int>
    private var moving: [Int: Moving] = [:]
    private var bytesDone: Int64
    private var lastNote = Uptime.now

    /// `done` lists files past `firstUndone` that are done already, from an earlier try.
    init(sizes: [Int64], firstUndone: Int, done: Set<Int> = []) {
        self.sizes = sizes
        low = firstUndone
        next = firstUndone
        doneAhead = done.filter { $0 >= firstUndone && $0 < sizes.count }
        bytesDone = sizes[..<firstUndone].reduce(0, +) + doneAhead.reduce(Int64(0)) { $0 + sizes[$1] }
        advanceLow()
        next = low
    }

    /// Files not handed out yet and not done.
    var remaining: Int {
        lock.withLock { (max(next, low)..<sizes.count).filter { !doneAhead.contains($0) }.count }
    }

    /// Bytes moved across the whole folder.
    var bytes: Int64 {
        lock.withLock { bytesDone + moving.values.reduce(Int64(0)) { $0 + $1.bytes } }
    }

    /// The next file for a lane, or nil when every file has been handed out. `noteIf` decides, from the file's size and
    /// the seconds since the last note, whether it is noted as it starts.
    func take(startingAt offset: (Int) -> Int64, noteIf: (Int64, TimeInterval) -> Bool) -> (index: Int, offset: Int64, noted: Bool)? {
        lock.withLock {
            // Files done in an earlier try are skipped; `low` may have passed them already.
            next = max(next, low)
            while next < sizes.count, doneAhead.contains(next) { next += 1 }
            guard next < sizes.count else { return nil }
            let index = next
            next += 1
            let from = offset(index)
            let noted = noteIf(sizes[index], Uptime.now - lastNote)
            moving[index] = Moving(index: index, bytes: from, created: from > 0, noted: noted)
            return (index, from, noted)
        }
    }

    /// `bytes` of the file have moved. Returns the bytes moved across the folder, and whether the file has just become
    /// one the server holds after a note named it. `progress` gets the total while the count is held still, so totals
    /// from several lanes are passed on in the order they were reached.
    func reported(_ index: Int, bytes: Int64, progress: (Int64) -> Void = { _ in }) -> (total: Int64, newlyHeld: Bool) {
        lock.withLock {
            var newlyHeld = false
            if var file = moving[index] {
                if !file.created {
                    file.created = true
                    newlyHeld = file.noted
                }
                file.bytes = bytes
                moving[index] = file
            }
            let total = bytesDone + moving.values.reduce(Int64(0)) { $0 + $1.bytes }
            progress(total)
            return (total, newlyHeld)
        }
    }

    /// The file is done. Returns whether it was noted as it started.
    @discardableResult
    func finished(_ index: Int) -> Bool {
        lock.withLock {
            let file = moving.removeValue(forKey: index)
            bytesDone += sizes[index]
            doneAhead.insert(index)
            advanceLow()
            return file?.noted ?? false
        }
    }

    /// Where the folder stands, for a note: every file before `finished` is done, every file from `started` on has not
    /// begun, and in between all are done except `sending`; of those, the server holds `held`.
    /// `due` decides from the seconds since the last note whether to note now; a note is then taken inside the same lock
    /// by `make`, so notes go out in the order the folder got there.
    func note(force: Bool = false, due: (TimeInterval) -> Bool = { _ in true }, _ make: (_ finished: Int, _ started: Int, _ sending: [Int], _ held: [Int]) -> Void) {
        lock.withLock {
            let now = Uptime.now
            guard force || due(now - lastNote) else { return }
            lastNote = now
            let sending = moving.keys.sorted()
            make(low, next, sending, sending.filter { moving[$0]?.created == true })
        }
    }

    private func advanceLow() {
        while doneAhead.contains(low) {
            doneAhead.remove(low)
            low += 1
        }
    }
}
