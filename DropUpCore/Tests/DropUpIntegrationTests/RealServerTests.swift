import DropUpCore
import DropUpTransport
import Foundation
import Testing

/// End-to-end tests against real FTP and SFTP servers started by `scripts/test-servers.py`.
/// They run only when `DROPUP_IT_ROOT` is set (the script prints the variables to export).
struct RealServerTests {
    static let root = ProcessInfo.processInfo.environment["DROPUP_IT_ROOT"]
    static let enabled = root != nil

    static func port(_ name: String) -> Int {
        Int(ProcessInfo.processInfo.environment[name] ?? "") ?? 0
    }

    func config(_ transferProtocol: TransferProtocol, directory: String = "/drops") -> ServerConfig {
        ServerConfig(
            transferProtocol: transferProtocol,
            host: "127.0.0.1",
            port: Self.port(transferProtocol == .ftp ? "DROPUP_IT_FTP_PORT" : "DROPUP_IT_SFTP_PORT"),
            username: "me",
            remoteDirectory: directory
        )
    }

    func connectors(hostKeys: any HostKeyStore = InMemoryHostKeyStore()) -> any ConnectorFactory {
        IntegrationConnectors(ftp: FTPConnector(opener: makeByteStreamOpener()), sftp: SFTPConnector(hostKeys: hostKeys))
    }

    func serverFile(_ path: String) -> Data? {
        FileManager.default.contents(atPath: Self.root! + path)
    }

    func uniqueName(_ ext: String = "bin") -> String { "it-\(UUID().uuidString.prefix(8)).\(ext)" }

    func makeQueue(_ config: ServerConfig, password: String = "secret", hostKeys: any HostKeyStore = InMemoryHostKeyStore()) -> UploadQueue {
        let credentials = InMemoryCredentialStore(passwords: [config.credentialKey: password])
        return UploadQueue(settings: InMemorySettingsStore(config: config), credentials: credentials, connectors: connectors(hostKeys: hostKeys), progressInterval: 0)
    }

    func upload(_ file: URL, config: ServerConfig, password: String = "secret", hostKeys: any HostKeyStore = InMemoryHostKeyStore()) async -> [UploadEvent] {
        let queue = makeQueue(config, password: password, hostKeys: hostKeys)
        await queue.enqueue([file])
        await queue.waitUntilIdle()
        await queue.finish()
        var events: [UploadEvent] = []
        for await event in queue.events { events.append(event) }
        return events
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func uploadsALargeFileIntact(_ transferProtocol: TransferProtocol) async throws {
        let name = uniqueName()
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        // 3.5 MB of non-repeating-looking bytes, so a dropped or reordered chunk changes the content.
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<3_500_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try data.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        let events = await upload(local, config: config(transferProtocol))

        #expect(events.contains { if case .succeeded(_, let path) = $0 { path == "/drops/\(name)" } else { false } })
        #expect(serverFile("/drops/\(name)") == data)
        let fractions = events.compactMap { event -> Double? in
            if case .progress(_, let progress) = event { progress.fraction } else { nil }
        }
        #expect(fractions == fractions.sorted())
        #expect(fractions.last == 1)
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func cancellingRemovesTheHalfSentFile(_ transferProtocol: TransferProtocol) async throws {
        let name = uniqueName()
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        // A sparse 512 MB file: too big to finish before the cancel, cheap to create and read.
        #expect(FileManager.default.createFile(atPath: local.path, contents: nil))
        let handle = try FileHandle(forWritingTo: local)
        try handle.truncate(atOffset: 512 * 1024 * 1024)
        try handle.close()
        defer { try? FileManager.default.removeItem(at: local) }

        let queue = makeQueue(config(transferProtocol))
        let ids = await queue.enqueue([local])
        // Wait until the server really holds part of the file, then cancel.
        var partialSize = 0
        for _ in 0..<2000 where partialSize == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
            let attributes = try? FileManager.default.attributesOfItem(atPath: Self.root! + "/drops/\(name)")
            partialSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        }
        #expect(partialSize > 0)
        await queue.cancel(ids[0])
        await queue.waitUntilIdle()
        await queue.finish()
        var events: [UploadEvent] = []
        for await event in queue.events { events.append(event) }

        #expect(events.contains(.cancelled(id: ids[0])))
        #expect(serverFile("/drops/\(name)") == nil)
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func browsingShowsFoldersAndFilesWithSizesAndDates(_ transferProtocol: TransferProtocol) async throws {
        let name = uniqueName("txt")
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try Data("twelve bytes".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        _ = await upload(local, config: config(transferProtocol))
        let server = config(transferProtocol)
        let browse = BrowseSession(connectors: connectors(), config: server, password: "secret")

        let drops = try await browse.entries(atPath: "/drops")
        let root = try await browse.entries(atPath: "/")
        await browse.close()

        #expect(drops.contains { $0.name == "archive" && $0.kind == .folder })
        let file = try #require(drops.first { $0.name == name })
        #expect(file.kind == .file)
        #expect(file.size == 12)
        let age = Date().timeIntervalSince(try #require(file.modified))
        #expect(age > -120 && age < 300)
        // Folders come first, and the root lists the folder we uploaded into.
        #expect(drops.firstIndex { $0.name == "archive" }! < drops.firstIndex { $0.name == name }!)
        #expect(root.contains { $0.name == "drops" && $0.kind == .folder })
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func uploadingIntoAnotherFolderPutsTheFileThere(_ transferProtocol: TransferProtocol) async throws {
        let name = uniqueName("txt")
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try Data("deep".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        let queue = makeQueue(config(transferProtocol))
        await queue.enqueue([local], toDirectory: "/drops/archive")
        await queue.waitUntilIdle()
        await queue.finish()

        #expect(serverFile("/drops/archive/\(name)") == Data("deep".utf8))
        #expect(serverFile("/drops/\(name)") == nil)
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func downloadsFilesIntact(_ transferProtocol: TransferProtocol) async throws {
        // A multi-chunk random file, an empty file and a name with spaces and unicode, put on the server directly.
        var generator = SystemRandomNumberGenerator()
        let big = Data((0..<3_500_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let names = [uniqueName(), uniqueName("txt"), "Bericht – Größe \(UUID().uuidString.prefix(6)).txt"]
        let contents = [big, Data(), Data("hej".utf8)]
        for (name, data) in zip(names, contents) {
            try data.write(to: URL(fileURLWithPath: Self.root! + "/ops/\(name)"))
        }
        defer { for name in names { try? FileManager.default.removeItem(atPath: Self.root! + "/ops/\(name)") } }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let queue = DownloadQueue(connectors: connectors(), progressInterval: 0)
        await queue.enqueue(
            zip(names, contents).map { RemoteDownload(remotePath: "/ops/\($0)", size: Int64($1.count)) },
            from: config(transferProtocol), password: "secret", into: destination
        )
        await queue.waitUntilIdle()
        await queue.finish()
        var events: [DownloadEvent] = []
        for await event in queue.events { events.append(event) }

        #expect(!events.contains { if case .failed = $0 { true } else { false } })
        for (name, data) in zip(names, contents) {
            #expect(FileManager.default.contents(atPath: destination.appendingPathComponent(name).path) == data)
        }
        let fractions = events.compactMap { event -> Double? in
            if case .progress(_, let progress) = event, progress.totalBytes == Int64(big.count) { progress.fraction } else { nil }
        }
        #expect(fractions == fractions.sorted())
        #expect(fractions.last == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).count == 3)
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func downloadingAMissingFileFailsPlainly(_ transferProtocol: TransferProtocol) async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let queue = DownloadQueue(connectors: connectors(), progressInterval: 0)
        await queue.enqueue([RemoteDownload(remotePath: "/drops/none-\(UUID().uuidString.prefix(6)).txt")], from: config(transferProtocol), password: "secret", into: destination)
        await queue.waitUntilIdle()
        await queue.finish()
        var events: [DownloadEvent] = []
        for await event in queue.events { events.append(event) }

        #expect(events.contains { if case .failed = $0 { true } else { false } })
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func cancellingADownloadRemovesThePartialFile(_ transferProtocol: TransferProtocol) async throws {
        // A sparse 512 MB file on the server: too big to finish before the cancel, cheap to create and read.
        let name = uniqueName()
        let remote = Self.root! + "/ops/\(name)"
        #expect(FileManager.default.createFile(atPath: remote, contents: nil))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: remote))
        try handle.truncate(atOffset: 512 * 1024 * 1024)
        try handle.close()
        defer { try? FileManager.default.removeItem(atPath: remote) }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let queue = DownloadQueue(connectors: connectors(), progressInterval: 0)
        let ids = await queue.enqueue([RemoteDownload(remotePath: "/ops/\(name)", size: 512 * 1024 * 1024)], from: config(transferProtocol), password: "secret", into: destination)
        // Wait until part of the file is on disk, then cancel.
        var partial = 0
        for _ in 0..<2000 where partial == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
            for file in (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? [] {
                let attributes = try? FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent(file).path)
                partial = max(partial, (attributes?[.size] as? NSNumber)?.intValue ?? 0)
            }
        }
        #expect(partial > 0)
        await queue.cancel(ids[0])
        await queue.waitUntilIdle()
        await queue.finish()
        var events: [DownloadEvent] = []
        for await event in queue.events { events.append(event) }

        #expect(events.contains(.cancelled(id: ids[0])))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func emptyFileUploads(_ transferProtocol: TransferProtocol) async throws {
        let name = uniqueName("txt")
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try Data().write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        let events = await upload(local, config: config(transferProtocol))

        #expect(events.contains { if case .succeeded = $0 { true } else { false } })
        #expect(serverFile("/drops/\(name)") == Data())
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func secondDropOfTheSameNameIsNumbered(_ transferProtocol: TransferProtocol) async throws {
        let stem = "dup-\(UUID().uuidString.prefix(8))"
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("\(stem).txt")
        try Data("one".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        let first = await upload(local, config: config(transferProtocol))
        let second = await upload(local, config: config(transferProtocol))

        #expect(first.contains { if case .succeeded(_, let path) = $0 { path == "/drops/\(stem).txt" } else { false } })
        #expect(second.contains { if case .succeeded(_, let path) = $0 { path == "/drops/\(stem)-1.txt" } else { false } })
        #expect(serverFile("/drops/\(stem)-1.txt") == Data("one".utf8))
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func namesWithSpacesAndUnicodeSurvive(_ transferProtocol: TransferProtocol) async throws {
        let name = "Bericht – Größe \(UUID().uuidString.prefix(6)).txt"
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try Data("hej".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        let events = await upload(local, config: config(transferProtocol))

        #expect(events.contains { if case .succeeded = $0 { true } else { false } })
        #expect(serverFile("/drops/\(name)") == Data("hej".utf8))
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func wrongPasswordIsReportedPlainly(_ transferProtocol: TransferProtocol) async throws {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(uniqueName("txt"))
        try Data("x".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        let events = await upload(local, config: config(transferProtocol), password: "wrong")

        #expect(events.contains(.failed(id: queuedID(events), .transfer("The server rejected the username or password."))))
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func missingFolderIsReported(_ transferProtocol: TransferProtocol) async throws {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(uniqueName("txt"))
        try Data("x".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        let events = await upload(local, config: config(transferProtocol, directory: "/no/such/folder"))

        let failed = events.contains { if case .failed = $0 { true } else { false } }
        #expect(failed)
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func testConnectionListsFolders(_ transferProtocol: TransferProtocol) async throws {
        let browser = ServerBrowser(connectors: connectors())

        let result = try await browser.testConnection(config(transferProtocol), password: "secret")
        let root = try await browser.listDirectories(config(transferProtocol), password: "secret", path: "/")

        #expect(result.folders.contains("archive"))
        #expect(root.contains("drops"))
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func unreachablePortFailsFast(_ transferProtocol: TransferProtocol) async throws {
        var unreachable = config(transferProtocol)
        unreachable.port = 1
        let browser = ServerBrowser(connectors: connectors())

        let started = Date()
        await #expect(throws: UploaderError.self) {
            _ = try await browser.testConnection(unreachable, password: "secret")
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test(.enabled(if: RealServerTests.enabled))
    func sftpTrustsFirstHostKeyThenRejectsAChangedOne() async throws {
        let hostKeys = InMemoryHostKeyStore()
        let sftp = config(.sftp)
        let browser = ServerBrowser(connectors: connectors(hostKeys: hostKeys))

        _ = try await browser.testConnection(sftp, password: "secret")
        let remembered = try #require(hostKeys.trustedKey(for: sftp.hostKeyID))
        #expect(remembered.hasPrefix("ssh-ed25519 "))
        _ = try await browser.testConnection(sftp, password: "secret")

        // Pretend the server's key was different when we first saw it.
        hostKeys.trust("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f", for: sftp.hostKeyID)
        do {
            _ = try await browser.testConnection(sftp, password: "secret")
            Issue.record("Expected the changed host key to be rejected")
        } catch let error as UploaderError {
            guard case .hostKeyChanged(let fingerprint) = error else {
                Issue.record("Wrong error: \(error)")
                return
            }
            #expect(fingerprint.hasPrefix("SHA256:"))
        }
    }

    // MARK: Changing files and folders

    /// A fresh folder that the test owns, created on the server's disk and removed afterwards.
    /// It lives under `/ops`, not `/drops`: other tests list `/drops` while these run, and a server that finds an
    /// entry gone halfway through a listing (asyncssh does) fails the whole listing.
    private func scratchFolder() throws -> (name: String, path: String, disk: String) {
        let name = "ops-\(UUID().uuidString.prefix(8))"
        let disk = Self.root! + "/ops/" + name
        try FileManager.default.createDirectory(atPath: disk, withIntermediateDirectories: true)
        return (name, "/ops/" + name, disk)
    }

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func createsRenamesAndMovesThings(_ transferProtocol: TransferProtocol) async throws {
        let scratch = try scratchFolder()
        defer { try? FileManager.default.removeItem(atPath: scratch.disk) }
        try write("hello", to: scratch.disk + "/note.txt")
        try write("deep", to: scratch.disk + "/Älbum 1/inside.txt")
        let browse = BrowseSession(connectors: connectors(), config: config(transferProtocol), password: "secret")
        defer { Task { await browse.close() } }

        try await browse.makeFolder(named: "Neuer Ordner", in: scratch.path)
        var listing = try await browse.entries(atPath: scratch.path)
        #expect(listing.contains { $0.name == "Neuer Ordner" && $0.kind == .folder })

        let note = try #require(listing.first { $0.name == "note.txt" })
        try await browse.rename(note, to: "renamed note.txt", in: scratch.path)
        #expect(serverFile("/ops/\(scratch.name)/renamed note.txt") == Data("hello".utf8))
        #expect(serverFile("/ops/\(scratch.name)/note.txt") == nil)

        listing = try await browse.entries(atPath: scratch.path)
        let moving = listing.filter { $0.name == "renamed note.txt" || $0.name == "Älbum 1" }
        #expect(moving.count == 2)
        let result = try await browse.move(moving, from: scratch.path, to: scratch.path + "/Neuer Ordner")
        #expect(result == FileOperationResult(completed: 2, failures: []))
        #expect(serverFile("/ops/\(scratch.name)/Neuer Ordner/renamed note.txt") == Data("hello".utf8))
        #expect(serverFile("/ops/\(scratch.name)/Neuer Ordner/Älbum 1/inside.txt") == Data("deep".utf8))
        let rest = try await browse.entries(atPath: scratch.path)
        #expect(rest.map(\.name) == ["Neuer Ordner"])
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func neverReplacesAnItemWhenRenamingOrMoving(_ transferProtocol: TransferProtocol) async throws {
        let scratch = try scratchFolder()
        defer { try? FileManager.default.removeItem(atPath: scratch.disk) }
        try write("mine", to: scratch.disk + "/a.txt")
        try write("theirs", to: scratch.disk + "/b.txt")
        try write("elsewhere", to: scratch.disk + "/target/a.txt")
        let browse = BrowseSession(connectors: connectors(), config: config(transferProtocol), password: "secret")
        defer { Task { await browse.close() } }
        let listing = try await browse.entries(atPath: scratch.path)
        let a = try #require(listing.first { $0.name == "a.txt" })

        await #expect(throws: FileOperationError.alreadyExists("b.txt")) {
            try await browse.rename(a, to: "b.txt", in: scratch.path)
        }
        let result = try await browse.move([a], from: scratch.path, to: scratch.path + "/target")

        #expect(result.completed == 0 && result.failures.map(\.name) == ["a.txt"])
        #expect(serverFile("/ops/\(scratch.name)/a.txt") == Data("mine".utf8))
        #expect(serverFile("/ops/\(scratch.name)/b.txt") == Data("theirs".utf8))
        #expect(serverFile("/ops/\(scratch.name)/target/a.txt") == Data("elsewhere".utf8))
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func deletesFoldersWithEverythingInside(_ transferProtocol: TransferProtocol) async throws {
        let scratch = try scratchFolder()
        defer { try? FileManager.default.removeItem(atPath: scratch.disk) }
        try write("1", to: scratch.disk + "/tree/one.txt")
        try write("2", to: scratch.disk + "/tree/a/two.txt")
        try write("3", to: scratch.disk + "/tree/a/b/c/three.txt")
        try FileManager.default.createDirectory(atPath: scratch.disk + "/tree/empty", withIntermediateDirectories: true)
        try write(".", to: scratch.disk + "/tree/.hidden")
        try write("keep", to: scratch.disk + "/keep.txt")
        let browse = BrowseSession(connectors: connectors(), config: config(transferProtocol), password: "secret")
        defer { Task { await browse.close() } }
        let listing = try await browse.entries(atPath: scratch.path)
        let tree = try #require(listing.first { $0.name == "tree" })
        let removed = ProgressLog()

        let result = try await browse.delete([tree], in: scratch.path) { removed.add($0) }

        #expect(result == FileOperationResult(completed: 1, failures: []))
        #expect(!FileManager.default.fileExists(atPath: scratch.disk + "/tree"))
        #expect(serverFile("/ops/\(scratch.name)/keep.txt") == Data("keep".utf8))
        // Files one, two, three and .hidden; folders a, b, c, empty and tree.
        #expect(removed.values.last == 9)
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func deletingNeverFollowsALinkOutOfTheFolder(_ transferProtocol: TransferProtocol) async throws {
        let scratch = try scratchFolder()
        defer { try? FileManager.default.removeItem(atPath: scratch.disk) }
        try write("precious", to: scratch.disk + "/outside/precious.txt")
        try write("1", to: scratch.disk + "/doomed/one.txt")
        try FileManager.default.createSymbolicLink(atPath: scratch.disk + "/doomed/shortcut", withDestinationPath: scratch.disk + "/outside")
        try FileManager.default.createSymbolicLink(atPath: scratch.disk + "/doomed/filelink", withDestinationPath: scratch.disk + "/outside/precious.txt")
        let browse = BrowseSession(connectors: connectors(), config: config(transferProtocol), password: "secret")
        defer { Task { await browse.close() } }
        let listing = try await browse.entries(atPath: scratch.path)
        let doomed = try #require(listing.first { $0.name == "doomed" })

        let result = try await browse.delete([doomed], in: scratch.path)

        #expect(result == FileOperationResult(completed: 1, failures: []))
        #expect(!FileManager.default.fileExists(atPath: scratch.disk + "/doomed"))
        #expect(serverFile("/ops/\(scratch.name)/outside/precious.txt") == Data("precious".utf8))
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func changesThatTheServerRefusesAreReportedPlainly(_ transferProtocol: TransferProtocol) async throws {
        let scratch = try scratchFolder()
        defer { try? FileManager.default.removeItem(atPath: scratch.disk) }
        try write("x", to: scratch.disk + "/exists/file.txt")
        let browse = BrowseSession(connectors: connectors(), config: config(transferProtocol), password: "secret")
        defer { Task { await browse.close() } }

        await #expect(throws: UploaderError.self) { try await browse.makeFolder(named: "exists", in: scratch.path) }
        await #expect(throws: UploaderError.self) { try await browse.makeFolder(named: "x", in: scratch.path + "/missing") }
        let ghost = RemoteEntry(name: "ghost.txt", kind: .file)
        let result = try await browse.delete([ghost], in: scratch.path)
        #expect(result.completed == 0 && result.failures.map(\.name) == ["ghost.txt"])

        // The connection is still good afterwards.
        let listing = try await browse.entries(atPath: scratch.path)
        #expect(listing.map(\.name) == ["exists"])
    }

    private func queuedID(_ events: [UploadEvent]) -> UUID {
        for case .queued(let id, _, _) in events { return id }
        return UUID()
    }
}

private struct IntegrationConnectors: ConnectorFactory {
    let ftp: FTPConnector
    let sftp: SFTPConnector

    func connector(for transferProtocol: TransferProtocol) -> any ServerConnector {
        switch transferProtocol {
        case .ftp: ftp
        case .sftp: sftp
        }
    }
}

/// Collects the numbers a `@Sendable` progress callback reports.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int] = []
    func add(_ value: Int) { lock.withLock { _values.append(value) } }
    var values: [Int] { lock.withLock { _values } }
}
