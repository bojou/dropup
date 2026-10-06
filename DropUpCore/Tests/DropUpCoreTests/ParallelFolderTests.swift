import Foundation
import Testing
@testable import DropUpCore

/// A connection to a `FakeFileSystem` that moves several files of a folder at once, or one at a time on each of several
/// connections. It counts how many transfers run at the same time.
private final class ParallelSession: ServerSession, @unchecked Sendable {
    let server: FakeFileSystem
    let concurrentTransfers: Int
    let connectionsForFolders: Int
    private let counter: ParallelConnector

    init(_ server: FakeFileSystem, concurrent: Int, connections: Int, counter: ParallelConnector) {
        self.server = server
        concurrentTransfers = concurrent
        connectionsForFolders = connections
        self.counter = counter
    }

    func fileExists(atPath path: String) async throws -> Bool { try await server.fileExists(atPath: path) }
    func fileSize(atPath path: String) async throws -> Int64? {
        counter.looked(at: path)
        return try await server.fileSize(atPath: path)
    }
    func listDirectories(atPath path: String) async throws -> [String] { try await server.listDirectories(atPath: path) }
    func listEntries(atPath path: String) async throws -> [RemoteEntry] { try await server.listEntries(atPath: path) }
    func deleteFile(atPath remotePath: String) async throws { try await server.deleteFile(atPath: remotePath) }
    func makeDirectory(atPath path: String) async throws { try await server.makeDirectory(atPath: path) }
    func removeDirectory(atPath path: String) async throws { try await server.removeDirectory(atPath: path) }
    func rename(from oldPath: String, to newPath: String) async throws { try await server.rename(from: oldPath, to: newPath) }

    func upload(fileURL: URL, to remotePath: String, startingAt offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        counter.started(remotePath, offset: offset)
        defer { counter.ended() }
        try await server.upload(fileURL: fileURL, to: remotePath, startingAt: offset, progress: progress)
    }

    func download(remotePath: String, to fileURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        counter.started(remotePath, offset: 0)
        defer { counter.ended() }
        try await server.download(remotePath: remotePath, to: fileURL, progress: progress)
    }

    func close() async { counter.closed() }
}

/// Opens a new `ParallelSession` per connection, refusing any beyond `limit`.
private final class ParallelConnector: ServerConnector, ConnectorFactory, @unchecked Sendable {
    let server: FakeFileSystem
    private let concurrent: Int
    private let connections: Int
    private let limit: Int
    private let lock = NSLock()
    private var open = 0
    private var _attempts = 0
    private var _refused = 0
    private var _closes = 0
    private var running = 0
    private var _most = 0
    private var _transfers: [(path: String, offset: Int64)] = []
    private var _looks: [String] = []

    init(_ server: FakeFileSystem, concurrent: Int = 1, connections: Int = 1, limit: Int = .max) {
        self.server = server
        self.concurrent = concurrent
        self.connections = connections
        self.limit = limit
    }

    var attempts: Int { lock.withLock { _attempts } }
    var refused: Int { lock.withLock { _refused } }
    var closes: Int { lock.withLock { _closes } }
    /// The most transfers that ran at the same time.
    var mostAtOnce: Int { lock.withLock { _most } }
    var transfers: [(path: String, offset: Int64)] { lock.withLock { _transfers } }
    var looks: [String] { lock.withLock { _looks } }

    func connect(to config: ServerConfig, password: String) async throws -> any ServerSession {
        try lock.withLock {
            _attempts += 1
            guard open < limit else {
                _refused += 1
                throw UploaderError.serverRejected(code: 421, message: "Too many connections from this address.")
            }
            open += 1
        }
        return ParallelSession(server, concurrent: concurrent, connections: connections, counter: self)
    }

    func connector(for transferProtocol: TransferProtocol) -> any ServerConnector { self }

    func started(_ path: String, offset: Int64) {
        lock.withLock {
            running += 1
            _most = max(_most, running)
            _transfers.append((path, offset))
        }
    }

    func ended() { lock.withLock { running -= 1 } }
    func looked(at path: String) { lock.withLock { _looks.append(path) } }

    func closed() {
        lock.withLock {
            _closes += 1
            open -= 1
        }
    }
}

struct ParallelFolderTests {
    let config = ServerConfig(transferProtocol: .sftp, host: "example.com", username: "me", remoteDirectory: "/drops")

    private func makeQueue(_ connector: ParallelConnector) -> UploadQueue {
        let credentials = InMemoryCredentialStore()
        try? credentials.setPassword("secret", for: config.credentialKey)
        return UploadQueue(
            settings: InMemorySettingsStore(config: config),
            credentials: credentials,
            connectors: connector,
            progressInterval: 0,
            cleanupTimeout: 2
        )
    }

    /// A folder `photos` with `count` files `f00.txt`… of `size` bytes, each holding its own name.
    private func makeFolder(_ temp: TempFiles, count: Int, named name: String = "photos") throws -> URL {
        let folder = temp.directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for index in 0..<count {
            let path = index % 2 == 0 ? String(format: "f%02d.txt", index) : String(format: "sub/f%02d.txt", index)
            try Data(path.utf8).write(to: folder.appendingPathComponent(path))
        }
        return folder
    }

    /// `a.txt`, `b.bin`, `c.bin`, `d.txt`, sent in that order.
    private func makeMixedFolder(_ temp: TempFiles) throws -> URL {
        let folder = temp.directory.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 100).write(to: folder.appendingPathComponent("a.txt"))
        try Data(count: 1000).write(to: folder.appendingPathComponent("b.bin"))
        try Data(count: 2000).write(to: folder.appendingPathComponent("c.bin"))
        try Data(count: 50).write(to: folder.appendingPathComponent("d.txt"))
        return folder
    }

    private func events(of queue: UploadQueue, _ body: () async throws -> Void) async throws -> [UploadEvent] {
        let log = EventLog()
        let collecting = log.collect(queue)
        try await body()
        await queue.waitUntilIdle()
        await queue.finish()
        await collecting.value
        return log.events
    }

    private func lastPoint(_ events: [UploadEvent]) -> ResumePoint? {
        events.compactMap { if case .resumable(_, let point) = $0 { point } else { nil } }.last
    }

    private func progress(_ events: [UploadEvent]) -> [Int64] {
        events.compactMap { if case .progress(_, let progress) = $0 { progress.bytesSent } else { nil } }
    }

    // MARK: Several at once

    @Test func aSessionThatCanSendSeveralFilesGetsThatManyAtOnce() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let folder = try makeFolder(temp, count: 12)
        let server = FakeFileSystem().addFolder("/drops")
        server.slowDown(milliseconds: 15)
        let connector = ParallelConnector(server, concurrent: 4)
        let queue = makeQueue(connector)

        let events = try await events(of: queue) { _ = await queue.enqueue([folder]) }

        #expect(events.last.map { if case .succeeded = $0 { true } else { false } } == true)
        for index in 0..<12 {
            let path = index % 2 == 0 ? String(format: "f%02d.txt", index) : String(format: "sub/f%02d.txt", index)
            #expect(server.data(at: "/drops/photos/" + path) == Data(path.utf8), "\(path)")
        }
        #expect(connector.mostAtOnce == 4)
        #expect(connector.attempts == 1)
        // Progress counts the bytes of all the files, never goes backwards, and ends at the folder's size.
        let sent = progress(events)
        let total = Int64(try LocalTree.scan(folder).totalBytes)
        #expect(sent == sent.sorted())
        #expect(sent.last == total)
        // The folder a file goes into is made once, before the file, however many files want it at the same time.
        #expect(server.log.filter { $0 == "MKD /drops/photos/sub" }.count == 1)
    }

    @Test func aSessionThatSendsOneFileAtATimeGetsMoreConnections() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let folder = try makeFolder(temp, count: 10)
        let server = FakeFileSystem().addFolder("/drops")
        server.slowDown(milliseconds: 15)
        let connector = ParallelConnector(server, connections: 4)
        let queue = makeQueue(connector)

        let events = try await events(of: queue) { _ = await queue.enqueue([folder]) }

        #expect(events.last.map { if case .succeeded = $0 { true } else { false } } == true)
        #expect(server.paths(under: "/drops/photos").filter { $0.hasSuffix(".txt") }.count == 10)
        #expect(connector.attempts == 4)
        #expect(connector.mostAtOnce == 4)
        // The three it opened for the folder, and the queue's own once it ran dry.
        #expect(connector.closes == 4)
    }

    @Test func aServerThatTakesFewerConnectionsGetsFewerAndIsNotAskedAgain() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let first = try makeFolder(temp, count: 10, named: "one")
        let second = try makeFolder(temp, count: 10, named: "two")
        let server = FakeFileSystem().addFolder("/drops")
        server.slowDown(milliseconds: 10)
        let connector = ParallelConnector(server, connections: 4, limit: 2)
        let queue = makeQueue(connector)

        let events = try await events(of: queue) {
            _ = await queue.enqueue([first])
            await queue.waitUntilIdle()
            #expect(connector.refused >= 1)
            let refusedBefore = connector.refused
            let attemptsBefore = connector.attempts
            _ = await queue.enqueue([second])
            await queue.waitUntilIdle()
            // The second folder asks for no more than the server took.
            #expect(connector.refused == refusedBefore)
            #expect(connector.attempts - attemptsBefore == 2)
        }

        #expect(events.filter { if case .succeeded = $0 { true } else { false } }.count == 2)
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
        #expect(server.paths(under: "/drops/one").filter { $0.hasSuffix(".txt") }.count == 10)
        #expect(server.paths(under: "/drops/two").filter { $0.hasSuffix(".txt") }.count == 10)
        #expect(connector.mostAtOnce == 2)
    }

    // MARK: Stopping with several files half sent

    @Test func aPausedFolderNotesEveryFileItWasInTheMiddleOfAndCarriesThemOn() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let folder = try makeMixedFolder(temp)
        let server = FakeFileSystem().addFolder("/drops")
        server.hangUpload(of: "/drops/photos/b.bin")
        server.hangUpload(of: "/drops/photos/c.bin")
        let connector = ParallelConnector(server, concurrent: 3)
        let queue = makeQueue(connector)

        let paused = try await events(of: queue) {
            let id = await queue.enqueue([folder])[0]
            try await eventually { server.data(at: "/drops/photos/d.txt")?.count == 50 && server.data(at: "/drops/photos/a.txt")?.count == 100 }
            try await eventually { server.exists("/drops/photos/b.bin") && server.exists("/drops/photos/c.bin") }
            await queue.pause(id)
        }

        #expect(paused.last.map { if case .paused = $0 { true } else { false } } == true)
        let point = try #require(lastPoint(paused))
        #expect(point.finishedFiles == 1)
        #expect(point.startedFiles == 4)
        #expect(point.sendingFiles == ["b.bin", "c.bin"])
        #expect(point.partialFiles == ["b.bin", "c.bin"])
        #expect(point.currentFile == "b.bin" && point.created)
        #expect(point.partialPaths == ["/drops/photos/b.bin", "/drops/photos/c.bin"])
        // Survives being written down, as the Recent list does.
        let saved = try JSONDecoder().decode(ResumePoint.self, from: JSONEncoder().encode(point))
        #expect(saved == point)

        // The server holds part of each.
        server.stopHanging()
        server.addFile("/drops/photos/b.bin", size: 400)
        server.addFile("/drops/photos/c.bin", size: 700)
        let carried = ParallelConnector(server, concurrent: 3)
        let second = makeQueue(carried)
        let events = try await events(of: second) { await second.resume(UUID(), from: saved) }

        #expect(events.last.map { if case .succeeded = $0 { true } else { false } } == true)
        // Only the two half-sent files go again, each from what the server holds; the finished ones aren't even looked at.
        let sent = carried.transfers.sorted { $0.path < $1.path }
        #expect(sent.map(\.path) == ["/drops/photos/b.bin", "/drops/photos/c.bin"])
        #expect(sent.map(\.offset) == [400, 700])
        #expect(!carried.looks.contains("/drops/photos/d.txt"))
        #expect(server.data(at: "/drops/photos/c.bin")?.count == 2000)
    }

    @Test func cancellingAFolderTakesAwayEveryHalfSentFileAndKeepsTheRest() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let folder = try makeMixedFolder(temp)
        let server = FakeFileSystem().addFolder("/drops")
        server.hangUpload(of: "/drops/photos/b.bin")
        server.hangUpload(of: "/drops/photos/c.bin")
        let connector = ParallelConnector(server, concurrent: 3)
        let queue = makeQueue(connector)

        let events = try await events(of: queue) {
            let id = await queue.enqueue([folder])[0]
            try await eventually { server.data(at: "/drops/photos/d.txt")?.count == 50 && server.data(at: "/drops/photos/a.txt")?.count == 100 }
            try await eventually { server.exists("/drops/photos/b.bin") && server.exists("/drops/photos/c.bin") }
            await queue.cancel(id)
        }

        #expect(events.contains { if case .cancelled = $0 { true } else { false } })
        #expect(!server.exists("/drops/photos/b.bin"))
        #expect(!server.exists("/drops/photos/c.bin"))
        #expect(server.exists("/drops/photos/a.txt"))
        #expect(server.exists("/drops/photos/d.txt"))
        #expect(server.exists("/drops/photos"))
    }

    @Test func discardingAPausedFolderTakesAwayEveryHalfSentFile() async throws {
        let server = FakeFileSystem()
            .addFile("/drops/photos/a.txt", size: 100)
            .addFile("/drops/photos/b.bin", size: 400)
            .addFile("/drops/photos/c.bin", size: 700)
        let queue = makeQueue(ParallelConnector(server, concurrent: 3))
        let point = ResumePoint(
            sourcePath: "/tmp/photos", isFolder: true, config: config, remotePath: "/drops/photos", totalBytes: 3150,
            created: true, finishedFiles: 1, currentFile: "b.bin", startedFiles: 4, sendingFiles: ["b.bin", "c.bin"],
            partialFiles: ["b.bin", "c.bin"]
        )

        #expect(await queue.discard(point) == nil)
        #expect(server.paths(under: "/drops/photos") == ["/drops/photos/a.txt"])
    }

    @Test func aFileThatWasBeingSentButNotYetCreatedGoesAgainFromTheStart() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let folder = try makeMixedFolder(temp)
        let tree = try LocalTree.scan(folder)
        // b.bin had started, but the server didn't hold it yet: whatever is there may be someone else's.
        let server = FakeFileSystem()
            .addFile("/drops/photos/a.txt", size: 100)
            .addFile("/drops/photos/b.bin", size: 300)
            .addFile("/drops/photos/c.bin", size: 700)
            .addFile("/drops/photos/d.txt", size: 50)
        let point = ResumePoint(
            sourcePath: folder.path, isFolder: true, config: config, remotePath: "/drops/photos", totalBytes: tree.totalBytes,
            created: false, finishedFiles: 1, fingerprint: tree.fingerprint, currentFile: "b.bin", startedFiles: 4,
            sendingFiles: ["b.bin", "c.bin"], partialFiles: ["c.bin"]
        )
        let connector = ParallelConnector(server, concurrent: 3)
        let queue = makeQueue(connector)

        let events = try await events(of: queue) { await queue.resume(UUID(), from: point) }

        #expect(events.last.map { if case .succeeded = $0 { true } else { false } } == true)
        let sent = connector.transfers.sorted { $0.path < $1.path }
        #expect(sent.map(\.path) == ["/drops/photos/b.bin", "/drops/photos/c.bin"])
        #expect(sent.map(\.offset) == [0, 700])
    }

    // MARK: Downloads

    @Test func aFolderDownloadFetchesSeveralFilesAtOnce() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let server = FakeFileSystem()
        for index in 0..<9 {
            server.addFile(String(format: "/drops/photos/sub/f%02d.txt", index), data: Data("file \(index)".utf8))
        }
        server.slowDown(milliseconds: 15)
        let connector = ParallelConnector(server, concurrent: 3)
        let queue = DownloadQueue(connectors: connector, progressInterval: 0)
        let destination = temp.directory.appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        await queue.enqueue([RemoteDownload(remotePath: "/drops/photos", isFolder: true)], from: config, password: "secret", into: destination)
        await queue.waitUntilIdle()
        await queue.finish()
        var events: [DownloadEvent] = []
        for await event in queue.events { events.append(event) }

        #expect(events.last.map { if case .succeeded = $0 { true } else { false } } == true)
        for index in 0..<9 {
            let url = destination.appendingPathComponent(String(format: "photos/sub/f%02d.txt", index))
            #expect(try Data(contentsOf: url) == Data("file \(index)".utf8))
        }
        #expect(connector.mostAtOnce == 3)
        let received = events.compactMap { if case .progress(_, let progress) = $0 { progress.bytesSent } else { nil } }
        #expect(received == received.sorted())
        #expect(received.last == (0..<9).reduce(Int64(0)) { $0 + Int64("file \($1)".utf8.count) })
    }
}
