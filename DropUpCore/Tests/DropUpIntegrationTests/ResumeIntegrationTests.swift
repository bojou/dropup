import DropUpCore
import DropUpTransport
import Foundation
import Testing

/// Interrupted uploads against the real FTP and SFTP servers started by `scripts/test-servers.py`: a real upload is cut
/// off part of the way, so the server really holds a half-sent file, and the next try has to carry on from it.
/// They run only when `DROPUP_IT_ROOT` is set.
struct ResumeIntegrationTests {
    static let root = ProcessInfo.processInfo.environment["DROPUP_IT_ROOT"]
    static let enabled = root != nil

    private let giveUpAtOnce = ReconnectPolicy(delays: [], giveUpAfter: 30, noticeAfter: 5)

    private func config(_ transferProtocol: TransferProtocol) -> ServerConfig {
        let port = Int(ProcessInfo.processInfo.environment[transferProtocol == .ftp ? "DROPUP_IT_FTP_PORT" : "DROPUP_IT_SFTP_PORT"] ?? "") ?? 0
        return ServerConfig(transferProtocol: transferProtocol, host: "127.0.0.1", port: port, username: "me", remoteDirectory: "/ops")
    }

    private func makeQueue(
        _ config: ServerConfig,
        _ board: Switchboard,
        reconnect: ReconnectPolicy,
        preferences: Preferences = Preferences()
    ) -> UploadQueue {
        UploadQueue(
            settings: InMemorySettingsStore(config: config, preferences: preferences),
            credentials: InMemoryCredentialStore(passwords: [config.credentialKey: "secret"]),
            connectors: BreakingConnectors(
                board: board,
                ftp: FTPConnector(opener: makeByteStreamOpener()),
                sftp: SFTPConnector(hostKeys: InMemoryHostKeyStore())
            ),
            progressInterval: 0,
            reconnect: reconnect
        )
    }

    /// Random-looking bytes that are cheap to make: one random block of an odd length, repeated. A chunk that is dropped,
    /// repeated or moved by anything but exactly that length changes the content, which is what the comparisons look for.
    private func randomData(_ count: Int) -> Data {
        let blockSize = min(count, 1_000_003)
        var block = Data(count: blockSize)
        block.withUnsafeMutableBytes { buffer in
            var generator = SystemRandomNumberGenerator()
            for offset in stride(from: 0, to: blockSize - 7, by: 8) {
                buffer.storeBytes(of: UInt64.random(in: .min ... .max, using: &generator), toByteOffset: offset, as: UInt64.self)
            }
        }
        var data = Data(capacity: count)
        while data.count < count { data.append(block.prefix(count - data.count)) }
        return data
    }

    private func uniqueName(_ ext: String = "bin") -> String { "it-\(UUID().uuidString.prefix(8)).\(ext)" }

    private func serverPath(_ path: String) -> String { Self.root! + path }

    private func serverFile(_ path: String) -> Data? { FileManager.default.contents(atPath: serverPath(path)) }

    private func serverSize(_ path: String) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: serverPath(path))
        return (attributes?[.size] as? NSNumber)?.intValue
    }

    /// The size of a file on the server once nothing more is arriving: a cut-off upload can still have bytes in flight.
    private func settledSize(_ path: String) async throws -> Int? {
        var last = serverSize(path)
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            let now = serverSize(path)
            if now == last { return now }
            last = now
        }
        return last
    }

    private func removeFromServer(_ names: [String]) {
        for name in names { try? FileManager.default.removeItem(atPath: serverPath("/ops/" + name)) }
    }

    /// Everything the queue reported, once it has nothing left to do.
    private func finish(_ queue: UploadQueue) async -> [UploadEvent] {
        await queue.waitUntilIdle()
        await queue.finish()
        var events: [UploadEvent] = []
        for await event in queue.events { events.append(event) }
        return events
    }

    private func lastPoint(_ events: [UploadEvent], of id: UUID) -> ResumePoint? {
        events.reversed().compactMap { event -> ResumePoint? in
            if case .resumable(let eventID, let point) = event, eventID == id { point } else { nil }
        }.first
    }

    private func isConnectionLost(_ events: [UploadEvent], _ id: UUID) -> Bool {
        events.contains { event in
            if case .failed(let eventID, .connectionLost) = event { eventID == id } else { false }
        }
    }

    private func restarts(_ events: [UploadEvent]) -> [String] {
        events.compactMap { if case .restarted(_, let reason) = $0 { reason } else { nil } }
    }

    private func roundTrip(_ point: ResumePoint) throws -> ResumePoint {
        try JSONDecoder().decode(ResumePoint.self, from: JSONEncoder().encode(point))
    }

    /// A file that was cut off part of the way, with the connection gone and nobody retrying: what is left after a
    /// connection that did not come back, or after DropUp quit.
    private struct Interrupted {
        let name: String
        let local: URL
        let data: Data
        let id: UUID
        let point: ResumePoint
        let partialSize: Int
    }

    private func interrupt(_ transferProtocol: TransferProtocol, size: Int = 6_000_000, cutAfter: Int64 = 2_000_000) async throws -> Interrupted {
        let name = uniqueName()
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let data = randomData(size)
        try data.write(to: local)

        let board = Switchboard()
        board.cut(path: name, after: cutAfter)
        let queue = makeQueue(config(transferProtocol), board, reconnect: giveUpAtOnce)
        let id = await queue.enqueue([local])[0]
        let events = await finish(queue)

        #expect(isConnectionLost(events, id))
        let point = try #require(lastPoint(events, of: id))
        let settled = try await settledSize("/ops/" + name)
        let partial = try #require(settled)
        return Interrupted(name: name, local: local, data: data, id: id, point: try roundTrip(point), partialSize: partial)
    }

    // MARK: Carrying on a file

    @Test(.enabled(if: ResumeIntegrationTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func aCutOffUploadCarriesOnByItselfFromWhatTheServerHolds(_ transferProtocol: TransferProtocol) async throws {
        let name = uniqueName()
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let data = randomData(6_000_000)
        try data.write(to: local)
        defer {
            try? FileManager.default.removeItem(at: local)
            removeFromServer([name, name.replacingOccurrences(of: ".bin", with: "-1.bin")])
        }

        let board = Switchboard()
        board.cut(path: name, after: 2_000_000)
        let queue = makeQueue(config(transferProtocol), board, reconnect: ReconnectPolicy(delays: [0.1, 0.1, 0.1], giveUpAfter: 30, noticeAfter: 5))
        let id = await queue.enqueue([local])[0]
        let events = await finish(queue)

        #expect(events.contains(.succeeded(id: id, remotePath: "/ops/\(name)")))
        #expect(events.contains(.waitingForConnection(id: id)))
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
        #expect(serverFile("/ops/" + name) == data)
        // The second try went on from what the server held instead of starting over, and under the same name.
        let offsets = board.offsets
        #expect(offsets.count == 2)
        #expect(offsets.first == 0)
        #expect((offsets.last ?? 0) > 0)
        #expect(serverSize("/ops/" + name.replacingOccurrences(of: ".bin", with: "-1.bin")) == nil)
    }

    @Test(.enabled(if: ResumeIntegrationTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func anUploadThatGaveUpResumesAfterARelaunch(_ transferProtocol: TransferProtocol) async throws {
        let cut = try await interrupt(transferProtocol)
        defer {
            try? FileManager.default.removeItem(at: cut.local)
            removeFromServer([cut.name, cut.name.replacingOccurrences(of: ".bin", with: "-1.bin")])
        }
        // Part of it is on the server, and only part.
        #expect(cut.partialSize > 0 && cut.partialSize < cut.data.count)
        #expect(cut.point.created && cut.point.remotePath == "/ops/\(cut.name)")

        // A new queue, as after a relaunch, knowing only what was written down.
        let board = Switchboard()
        let queue = makeQueue(config(transferProtocol), board, reconnect: giveUpAtOnce)
        await queue.resume(cut.id, from: cut.point)
        let events = await finish(queue)

        #expect(events.last == .succeeded(id: cut.id, remotePath: "/ops/\(cut.name)"))
        #expect(serverFile("/ops/" + cut.name) == cut.data)
        #expect(restarts(events).isEmpty)
        // It asked the server how much it had, and sent only the rest (SFTP starts a little early, to be sure).
        let offset = try #require(board.offsets.first)
        #expect(offset > 0 && offset <= Int64(cut.partialSize))
        let first = events.compactMap { event -> Int64? in
            if case .progress(_, let progress) = event, progress.bytesSent > 0 { progress.bytesSent } else { nil }
        }.first
        #expect((first ?? 0) >= offset - 524_288)
        // Never a numbered copy next to it, whatever the setting for names that are taken.
        #expect(serverSize("/ops/" + cut.name.replacingOccurrences(of: ".bin", with: "-1.bin")) == nil)
    }

    @Test(.enabled(if: ResumeIntegrationTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func aFileThatChangedStartsOverAndSaysWhy(_ transferProtocol: TransferProtocol) async throws {
        let cut = try await interrupt(transferProtocol)
        defer {
            try? FileManager.default.removeItem(at: cut.local)
            removeFromServer([cut.name, cut.name.replacingOccurrences(of: ".bin", with: "-1.bin")])
        }
        var changed = cut.data
        changed.append(randomData(4096))
        try changed.write(to: cut.local)

        let board = Switchboard()
        let queue = makeQueue(config(transferProtocol), board, reconnect: giveUpAtOnce)
        await queue.resume(cut.id, from: cut.point)
        let events = await finish(queue)

        #expect(events.last == .succeeded(id: cut.id, remotePath: "/ops/\(cut.name)"))
        #expect(restarts(events).count == 1)
        #expect(restarts(events).first?.contains("changed") == true)
        #expect(serverFile("/ops/" + cut.name) == changed)
        #expect(board.offsets == [0])
    }

    @Test(.enabled(if: ResumeIntegrationTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func aPartialFileThatIsGoneStartsOverAndSaysWhy(_ transferProtocol: TransferProtocol) async throws {
        let cut = try await interrupt(transferProtocol)
        defer {
            try? FileManager.default.removeItem(at: cut.local)
            removeFromServer([cut.name, cut.name.replacingOccurrences(of: ".bin", with: "-1.bin")])
        }
        try FileManager.default.removeItem(atPath: serverPath("/ops/" + cut.name))

        let board = Switchboard()
        let queue = makeQueue(config(transferProtocol), board, reconnect: giveUpAtOnce)
        await queue.resume(cut.id, from: cut.point)
        let events = await finish(queue)

        #expect(events.last == .succeeded(id: cut.id, remotePath: "/ops/\(cut.name)"))
        #expect(restarts(events).first?.contains("gone") == true)
        #expect(serverFile("/ops/" + cut.name) == cut.data)
        #expect(board.offsets == [0])
    }

    // MARK: Cancelling and removing

    @Test(.enabled(if: ResumeIntegrationTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func removingAnInterruptedUploadTakesItsPartialFileOffTheServer(_ transferProtocol: TransferProtocol) async throws {
        let cut = try await interrupt(transferProtocol)
        defer {
            try? FileManager.default.removeItem(at: cut.local)
            removeFromServer([cut.name])
        }
        let bystander = uniqueName("txt")
        try Data("not ours".utf8).write(to: URL(fileURLWithPath: serverPath("/ops/" + bystander)))
        defer { removeFromServer([bystander]) }
        #expect(serverSize("/ops/" + cut.name) != nil)

        let queue = makeQueue(config(transferProtocol), Switchboard(), reconnect: giveUpAtOnce)
        let problem = await queue.discard(cut.point)
        _ = await finish(queue)

        #expect(problem == nil)
        #expect(serverSize("/ops/" + cut.name) == nil)
        #expect(serverFile("/ops/" + bystander) == Data("not ours".utf8))
    }

    @Test(.enabled(if: ResumeIntegrationTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func cancellingACarriedOnUploadRemovesItsPartialFileToo(_ transferProtocol: TransferProtocol) async throws {
        // A sparse 512 MB file: too big to finish before the cancel, cheap to create and read.
        let name = uniqueName()
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        #expect(FileManager.default.createFile(atPath: local.path, contents: nil))
        let handle = try FileHandle(forWritingTo: local)
        try handle.truncate(atOffset: 512 * 1024 * 1024)
        try handle.close()
        defer {
            try? FileManager.default.removeItem(at: local)
            removeFromServer([name])
        }
        let board = Switchboard()
        board.cut(path: name, after: 20_000_000)
        let first = makeQueue(config(transferProtocol), board, reconnect: giveUpAtOnce)
        let id = await first.enqueue([local])[0]
        let earlier = await finish(first)
        let point = try roundTrip(#require(lastPoint(earlier, of: id)))
        let settledBefore = try await settledSize("/ops/" + name)
        let before = try #require(settledBefore)
        #expect(before > 0)

        let queue = makeQueue(config(transferProtocol), Switchboard(), reconnect: giveUpAtOnce)
        await queue.resume(id, from: point)
        // Wait until the carried-on upload has added to what was there, then cancel it.
        var size = before
        for _ in 0..<2000 where size <= before {
            try await Task.sleep(nanoseconds: 5_000_000)
            size = serverSize("/ops/" + name) ?? 0
        }
        #expect(size > before)
        await queue.cancel(id)
        let events = await finish(queue)

        #expect(events.contains(.cancelled(id: id)))
        #expect(serverSize("/ops/" + name) == nil)
    }

    // MARK: The connection

    @Test(.enabled(if: ResumeIntegrationTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func anOutageThatEndsInsideTheWindowIsRiddenOut(_ transferProtocol: TransferProtocol) async throws {
        let name = uniqueName()
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let data = randomData(6_000_000)
        try data.write(to: local)
        defer {
            try? FileManager.default.removeItem(at: local)
            removeFromServer([name])
        }
        let board = Switchboard()
        board.cut(path: name, after: 2_000_000, thenDownFor: 0.6)
        let queue = makeQueue(config(transferProtocol), board, reconnect: ReconnectPolicy(delays: [0.2, 0.2, 0.2, 0.2, 0.2, 0.2], giveUpAfter: 30, noticeAfter: 5))
        let id = await queue.enqueue([local])[0]
        let events = await finish(queue)

        #expect(events.last == .succeeded(id: id, remotePath: "/ops/\(name)"))
        #expect(serverFile("/ops/" + name) == data)
        #expect(board.refusedConnections > 0)
    }

    @Test(.enabled(if: ResumeIntegrationTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func anOutageThatOutlastsTheTriesFailsAndCanBeResumedWhenTheNetworkIsBack(_ transferProtocol: TransferProtocol) async throws {
        let name = uniqueName()
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let data = randomData(6_000_000)
        try data.write(to: local)
        defer {
            try? FileManager.default.removeItem(at: local)
            removeFromServer([name, name.replacingOccurrences(of: ".bin", with: "-1.bin")])
        }
        let board = Switchboard()
        board.cut(path: name, after: 2_000_000, thenDownFor: 3600)
        let queue = makeQueue(config(transferProtocol), board, reconnect: ReconnectPolicy(delays: [0.1, 0.1], giveUpAfter: 30, noticeAfter: 5))
        let id = await queue.enqueue([local])[0]
        let events = await finish(queue)

        #expect(events.contains(.waitingForConnection(id: id)))
        #expect(isConnectionLost(events, id))
        #expect(!events.contains(.succeeded(id: id, remotePath: "/ops/\(name)")))
        // What was sent stays on the server, for the user to resume.
        let settled = try await settledSize("/ops/" + name)
        let partial = try #require(settled)
        #expect(partial > 0 && partial < data.count)

        let point = try roundTrip(#require(lastPoint(events, of: id)))
        board.networkIsBack()
        let again = makeQueue(config(transferProtocol), board, reconnect: giveUpAtOnce)
        await again.resume(id, from: point)
        let resumed = await finish(again)

        #expect(resumed.last == .succeeded(id: id, remotePath: "/ops/\(name)"))
        #expect(serverFile("/ops/" + name) == data)
    }

    @Test(.enabled(if: ResumeIntegrationTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func theTriesStopWhenTheWindowIsUsedUp(_ transferProtocol: TransferProtocol) async throws {
        let name = uniqueName()
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try randomData(6_000_000).write(to: local)
        defer {
            try? FileManager.default.removeItem(at: local)
            removeFromServer([name])
        }
        let board = Switchboard()
        board.cut(path: name, after: 2_000_000, thenDownFor: 3600)
        // Plenty of tries, but only a few seconds to use them in (counted from the last byte).
        let queue = makeQueue(config(transferProtocol), board, reconnect: ReconnectPolicy(delays: Array(repeating: 0.5, count: 50), giveUpAfter: 6, noticeAfter: 3))
        let id = await queue.enqueue([local])[0]
        let started = Date()
        let events = await finish(queue)

        #expect(isConnectionLost(events, id))
        #expect(Date().timeIntervalSince(started) < 60)
        #expect(board.refusedConnections >= 3 && board.refusedConnections < 40)
    }

    @Test(.enabled(if: ResumeIntegrationTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func aServerThatCantBeReachedAtAllFailsAtOnceAsItAlwaysDid(_ transferProtocol: TransferProtocol) async throws {
        let name = uniqueName()
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try randomData(1000).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let board = Switchboard()
        board.networkIsDown()
        let queue = makeQueue(config(transferProtocol), board, reconnect: ReconnectPolicy(delays: [0.1, 0.1], giveUpAfter: 30, noticeAfter: 5))
        let id = await queue.enqueue([local])[0]
        let events = await finish(queue)

        #expect(events.contains { if case .failed(let eventID, .transfer) = $0 { eventID == id } else { false } })
        #expect(!events.contains(.waitingForConnection(id: id)))
        #expect(board.refusedConnections == 1)
    }

    // MARK: Folders

    @Test(.enabled(if: ResumeIntegrationTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func aFolderCarriesOnWithTheFilesItHasntDone(_ transferProtocol: TransferProtocol) async throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("it-folder-\(UUID().uuidString.prefix(8))")
        let name = folder.lastPathComponent
        try fm.createDirectory(at: folder.appendingPathComponent("b/deeper"), withIntermediateDirectories: true)
        let files: [(path: String, data: Data)] = [
            ("a.txt", Data("first".utf8)),
            ("b/big.bin", randomData(6_000_000)),
            ("b/deeper/c.txt", Data("third".utf8)),
            ("d.txt", Data("fourth".utf8)),
        ]
        for file in files { try file.data.write(to: folder.appendingPathComponent(file.path)) }
        defer {
            try? fm.removeItem(at: folder)
            removeFromServer([name, name + "-1"])
        }

        let board = Switchboard()
        board.cut(path: "big.bin", after: 2_000_000)
        let first = makeQueue(config(transferProtocol), board, reconnect: giveUpAtOnce)
        let id = await first.enqueue([folder])[0]
        let cutOff = await finish(first)

        #expect(isConnectionLost(cutOff, id))
        let point = try roundTrip(#require(lastPoint(cutOff, of: id)))
        #expect(point.isFolder && point.created)
        #expect(point.remotePath == "/ops/\(name)")
        #expect(point.finishedFiles == 1)
        #expect(point.currentFile == "b/big.bin")
        #expect(serverFile("/ops/\(name)/a.txt") == Data("first".utf8))
        let settled = try await settledSize("/ops/\(name)/b/big.bin")
        let partial = try #require(settled)
        #expect(partial > 0 && partial < 6_000_000)

        let carried = Switchboard()
        let second = makeQueue(config(transferProtocol), carried, reconnect: giveUpAtOnce)
        await second.resume(id, from: point)
        let events = await finish(second)

        #expect(events.last == .succeeded(id: id, remotePath: "/ops/\(name)"))
        for file in files { #expect(serverFile("/ops/\(name)/\(file.path)") == file.data, "\(file.path)") }
        // The folder is the same folder, not a numbered one, and the finished file was not sent again.
        #expect(serverSize("/ops/\(name)-1") == nil)
        #expect(!carried.uploaded.contains { $0.hasSuffix("/a.txt") })
        #expect(carried.uploaded.first?.hasSuffix("/b/big.bin") == true)
        #expect(carried.uploaded.contains { $0.hasSuffix("/d.txt") })
        let offset = try #require(carried.offsets.first)
        #expect(offset > 0)
    }

    // MARK: Pausing

    private func isPaused(_ events: [UploadEvent], _ id: UUID) -> Bool { events.contains(.paused(id: id)) }

    private func waitForServer(_ path: String, toHold bytes: Int) async throws {
        for _ in 0..<1000 where (serverSize(path) ?? 0) < bytes {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect((serverSize(path) ?? 0) >= bytes)
    }

    @Test(.enabled(if: ResumeIntegrationTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func pausingKeepsThePartialFileAndLetsTheNextUploadThrough(_ transferProtocol: TransferProtocol) async throws {
        let big = uniqueName()
        let small = uniqueName("txt")
        let fm = FileManager.default
        let bigLocal = fm.temporaryDirectory.appendingPathComponent(big)
        let smallLocal = fm.temporaryDirectory.appendingPathComponent(small)
        try randomData(6_000_000).write(to: bigLocal)
        try Data("small".utf8).write(to: smallLocal)
        defer {
            try? fm.removeItem(at: bigLocal)
            try? fm.removeItem(at: smallLocal)
            removeFromServer([big, small])
        }

        let board = Switchboard()
        board.hold(path: big, after: 2_000_000)
        let queue = makeQueue(config(transferProtocol), board, reconnect: giveUpAtOnce)
        let ids = await queue.enqueue([bigLocal, smallLocal])
        try await waitForServer("/ops/" + big, toHold: 1_000_000)
        await queue.pause(ids[0])
        let events = await finish(queue)

        #expect(isPaused(events, ids[0]))
        #expect(events.contains(.succeeded(id: ids[1], remotePath: "/ops/\(small)")))
        #expect(serverFile("/ops/" + small) == Data("small".utf8))
        // A pause is no failure, and it takes nothing off the server.
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
        #expect(!events.contains(.cancelled(id: ids[0])))
        let partial = try #require(try await settledSize("/ops/" + big))
        #expect(partial > 0 && partial < 6_000_000)
        let point = try #require(lastPoint(events, of: ids[0]))
        #expect(point.created && point.remotePath == "/ops/\(big)")
    }

    @Test(.enabled(if: ResumeIntegrationTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func aPausedUploadResumesAfterARelaunchFromWhatTheServerHolds(_ transferProtocol: TransferProtocol) async throws {
        let name = uniqueName()
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let data = randomData(6_000_000)
        try data.write(to: local)
        defer {
            try? FileManager.default.removeItem(at: local)
            removeFromServer([name, name.replacingOccurrences(of: ".bin", with: "-1.bin")])
        }

        let board = Switchboard()
        board.hold(path: name, after: 2_000_000)
        let first = makeQueue(config(transferProtocol), board, reconnect: giveUpAtOnce)
        let id = await first.enqueue([local])[0]
        try await waitForServer("/ops/" + name, toHold: 1_000_000)
        await first.pause(id)
        let paused = await finish(first)
        #expect(isPaused(paused, id))
        let point = try roundTrip(#require(lastPoint(paused, of: id)))
        let partial = try #require(try await settledSize("/ops/" + name))
        #expect(partial > 0 && partial < data.count)

        // A new queue, as after a relaunch, knowing only what was written down.
        let carried = Switchboard()
        let second = makeQueue(config(transferProtocol), carried, reconnect: giveUpAtOnce)
        await second.resume(id, from: point)
        let events = await finish(second)

        #expect(events.last == .succeeded(id: id, remotePath: "/ops/\(name)"))
        #expect(serverFile("/ops/" + name) == data)
        #expect(restarts(events).isEmpty)
        let offset = try #require(carried.offsets.first)
        #expect(offset > 0 && offset <= Int64(partial))
        #expect(serverSize("/ops/" + name.replacingOccurrences(of: ".bin", with: "-1.bin")) == nil)
    }

    @Test(.enabled(if: ResumeIntegrationTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func cancellingAPausedUploadTakesItsPartialFileOffTheServer(_ transferProtocol: TransferProtocol) async throws {
        let name = uniqueName()
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try randomData(6_000_000).write(to: local)
        defer {
            try? FileManager.default.removeItem(at: local)
            removeFromServer([name])
        }

        let board = Switchboard()
        board.hold(path: name, after: 2_000_000)
        let queue = makeQueue(config(transferProtocol), board, reconnect: giveUpAtOnce)
        let id = await queue.enqueue([local])[0]
        try await waitForServer("/ops/" + name, toHold: 1_000_000)
        await queue.pause(id)
        let events = await finish(queue)
        let point = try roundTrip(#require(lastPoint(events, of: id)))
        #expect(try await settledSize("/ops/" + name) != nil)

        // The cross on a paused row is a cancel.
        let problem = await makeQueue(config(transferProtocol), Switchboard(), reconnect: giveUpAtOnce).discard(point)
        #expect(problem == nil)
        #expect(serverSize("/ops/" + name) == nil)
    }

    @Test(.enabled(if: ResumeIntegrationTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func aPausedFolderCarriesOnWithTheFilesItHasntDone(_ transferProtocol: TransferProtocol) async throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("it-folder-\(UUID().uuidString.prefix(8))")
        let name = folder.lastPathComponent
        try fm.createDirectory(at: folder.appendingPathComponent("b"), withIntermediateDirectories: true)
        let files: [(path: String, data: Data)] = [
            ("a.txt", Data("first".utf8)),
            ("b/big.bin", randomData(6_000_000)),
            ("c.txt", Data("third".utf8)),
        ]
        for file in files { try file.data.write(to: folder.appendingPathComponent(file.path)) }
        defer {
            try? fm.removeItem(at: folder)
            removeFromServer([name, name + "-1"])
        }

        let board = Switchboard()
        board.hold(path: "big.bin", after: 2_000_000)
        let first = makeQueue(config(transferProtocol), board, reconnect: giveUpAtOnce)
        let id = await first.enqueue([folder])[0]
        try await waitForServer("/ops/\(name)/b/big.bin", toHold: 1_000_000)
        await first.pause(id)
        let paused = await finish(first)

        #expect(isPaused(paused, id))
        let point = try roundTrip(#require(lastPoint(paused, of: id)))
        #expect(point.isFolder && point.created)
        #expect(point.finishedFiles == 1 && point.currentFile == "b/big.bin")
        // The folder stays as it is: the finished file is there, and so is the half-sent one.
        #expect(serverFile("/ops/\(name)/a.txt") == Data("first".utf8))
        let partial = try #require(try await settledSize("/ops/\(name)/b/big.bin"))
        #expect(partial > 0 && partial < 6_000_000)

        let carried = Switchboard()
        let second = makeQueue(config(transferProtocol), carried, reconnect: giveUpAtOnce)
        await second.resume(id, from: point)
        let events = await finish(second)

        #expect(events.last == .succeeded(id: id, remotePath: "/ops/\(name)"))
        for file in files { #expect(serverFile("/ops/\(name)/\(file.path)") == file.data, "\(file.path)") }
        #expect(serverSize("/ops/\(name)-1") == nil)
        #expect(!carried.uploaded.contains { $0.hasSuffix("/a.txt") })
        #expect(carried.uploaded.first?.hasSuffix("/b/big.bin") == true)
        #expect(try #require(carried.offsets.first) > 0)
    }
}

// MARK: Cutting connections

/// What the tests do to the connections: cut an upload off after some bytes, and keep the network down for a while.
final class Switchboard: @unchecked Sendable {
    private let lock = NSLock()
    private var cuts: [(path: String, after: Int64, down: TimeInterval, holds: Bool)] = []
    private var downUntil: Date?
    private var recordedOffsets: [Int64] = []
    private var recordedUploads: [String] = []
    private var refused = 0

    /// The next upload whose path ends with `path` is cut off once the server holds `after` bytes, and then no
    /// connection can be made for `thenDownFor` seconds.
    func cut(path: String, after: Int64, thenDownFor down: TimeInterval = 0) {
        lock.withLock { cuts.append((path, after, down, false)) }
    }

    /// Like `cut`, but the connection is not lost: the real transfer stops once the server holds `after` bytes and the
    /// upload then waits, as one that is being paused does, until the queue lets go of it.
    func hold(path: String, after: Int64) {
        lock.withLock { cuts.append((path, after, 0, true)) }
    }

    func networkIsDown() { lock.withLock { downUntil = .distantFuture } }
    func networkIsBack() { lock.withLock { downUntil = nil } }

    var offsets: [Int64] { lock.withLock { recordedOffsets } }
    var uploaded: [String] { lock.withLock { recordedUploads } }
    var refusedConnections: Int { lock.withLock { refused } }

    func connect() throws {
        try lock.withLock {
            if let downUntil, Date() < downUntil {
                refused += 1
                throw UploaderError.connectionFailed("The network is down.")
            }
        }
    }

    func startUpload(to path: String, offset: Int64) -> (limit: Int64, holds: Bool)? {
        lock.withLock {
            recordedUploads.append(path)
            recordedOffsets.append(offset)
            guard let index = cuts.firstIndex(where: { path.hasSuffix($0.path) }) else { return nil }
            return (cuts[index].after, cuts[index].holds)
        }
    }

    func cutHappened(on path: String) {
        lock.withLock {
            guard let index = cuts.firstIndex(where: { path.hasSuffix($0.path) }) else { return }
            let cut = cuts.remove(at: index)
            if cut.down > 0 { downUntil = Date().addingTimeInterval(cut.down) }
        }
    }
}

struct BreakingConnectors: ConnectorFactory {
    let board: Switchboard
    let ftp: FTPConnector
    let sftp: SFTPConnector

    func connector(for transferProtocol: TransferProtocol) -> any ServerConnector {
        BreakingConnector(board: board, inner: transferProtocol == .ftp ? ftp : sftp)
    }
}

private struct BreakingConnector: ServerConnector {
    let board: Switchboard
    let inner: any ServerConnector

    func connect(to config: ServerConfig, password: String) async throws -> any ServerSession {
        try board.connect()
        return BreakingSession(board: board, inner: try await inner.connect(to: config, password: password))
    }
}

/// A real session whose uploads can be cut off part of the way: the real transfer runs until the server holds enough,
/// then it is stopped under the queue's feet and the connection fails the way a lost one does.
private final class BreakingSession: ServerSession, @unchecked Sendable {
    let board: Switchboard
    let inner: any ServerSession
    private let lock = NSLock()
    private var closed = false

    init(board: Switchboard, inner: any ServerSession) {
        self.board = board
        self.inner = inner
    }

    func fileExists(atPath path: String) async throws -> Bool { try await inner.fileExists(atPath: path) }
    func fileSize(atPath path: String) async throws -> Int64? { try await inner.fileSize(atPath: path) }
    func listDirectories(atPath path: String) async throws -> [String] { try await inner.listDirectories(atPath: path) }
    func listEntries(atPath path: String) async throws -> [RemoteEntry] { try await inner.listEntries(atPath: path) }
    func listEntriesWithLinks(atPath path: String) async throws -> [RemoteEntry] { try await inner.listEntriesWithLinks(atPath: path) }
    func deleteFile(atPath remotePath: String) async throws { try await inner.deleteFile(atPath: remotePath) }
    func makeDirectory(atPath path: String) async throws { try await inner.makeDirectory(atPath: path) }
    func removeDirectory(atPath path: String) async throws { try await inner.removeDirectory(atPath: path) }
    func rename(from oldPath: String, to newPath: String) async throws { try await inner.rename(from: oldPath, to: newPath) }

    func download(remotePath: String, to fileURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await inner.download(remotePath: remotePath, to: fileURL, progress: progress)
    }

    func close() async {
        let first = lock.withLock {
            defer { closed = true }
            return !closed
        }
        if first { await inner.close() }
    }

    func upload(fileURL: URL, to remotePath: String, startingAt offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard let (limit, holds) = board.startUpload(to: remotePath, offset: offset) else {
            try await inner.upload(fileURL: fileURL, to: remotePath, startingAt: offset, progress: progress)
            return
        }
        let trip = Trip()
        let task = Task {
            try await inner.upload(fileURL: fileURL, to: remotePath, startingAt: offset) { sent in
                progress(sent)
                if sent >= limit { trip.fire() }
            }
        }
        trip.attach(task)
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            guard trip.fired else { throw error }
            await close()
            board.cutHappened(on: remotePath)
            if holds {
                // Nothing is lost here: the upload stands still until a pause or a cancel ends it, which stops the sleep.
                try await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
            throw UploaderError.connectionFailed("The connection was lost.")
        }
    }
}

/// Stops the real transfer from inside its own progress callback.
private final class Trip: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, any Error>?
    private var isFired = false

    var fired: Bool { lock.withLock { isFired } }

    func attach(_ task: Task<Void, any Error>) {
        let cancelNow = lock.withLock {
            self.task = task
            return isFired
        }
        if cancelNow { task.cancel() }
    }

    func fire() {
        let task = lock.withLock {
            isFired = true
            return self.task
        }
        task?.cancel()
    }
}
