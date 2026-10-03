import Foundation
import Testing
@testable import DropUpCore

/// Carrying on interrupted uploads: from what the server holds, over a lost connection, and after a relaunch.
struct ResumeUploadTests {
    let config = ServerConfig(transferProtocol: .sftp, host: "example.com", username: "me", remoteDirectory: "/drops")
    /// Waits are tiny so a test doesn't; what matters is the order of things.
    let quick = ReconnectPolicy(delays: [0.01, 0.01], giveUpAfter: 5, noticeAfter: 2)

    private func makeQueue(
        _ connector: FakeConnector,
        preferences: Preferences = Preferences(),
        reconnect: ReconnectPolicy? = nil,
        cancelGrace: TimeInterval = 1.5,
        password: String? = "secret"
    ) -> UploadQueue {
        let credentials = InMemoryCredentialStore()
        if let password { try? credentials.setPassword(password, for: config.credentialKey) }
        return UploadQueue(
            settings: InMemorySettingsStore(config: config, preferences: preferences),
            credentials: credentials,
            connectors: connector,
            progressInterval: 0,
            cleanupTimeout: 2,
            reconnect: reconnect ?? quick,
            cancelGrace: cancelGrace
        )
    }

    private func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// What an interrupted upload of `file` to `remote` left behind.
    private func point(_ file: URL, remote: String?, created: Bool = true, total: Int64, directory: String? = nil) -> ResumePoint {
        ResumePoint(
            sourcePath: file.path, isFolder: false, directory: directory, config: config, remotePath: remote,
            totalBytes: total, sourceModified: modified(file), created: created
        )
    }

    /// Runs `body` while the queue's events are collected, then returns them all.
    private func events(of queue: UploadQueue, _ body: () async throws -> Void) async throws -> [UploadEvent] {
        let log = EventLog()
        let collecting = log.collect(queue)
        try await body()
        await queue.waitUntilIdle()
        await queue.finish()
        await collecting.value
        return log.events
    }

    private func reasons(_ events: [UploadEvent]) -> [String] {
        events.compactMap { if case .restarted(_, let reason) = $0 { reason } else { nil } }
    }

    private func count(_ events: [UploadEvent], where match: (UploadEvent) -> Bool) -> Int {
        events.filter(match).count
    }

    // MARK: What is reported while it runs

    @Test func aNewUploadReportsWhatItTakesToCarryItOn() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "big.bin", size: 1000)
        let queue = makeQueue(FakeConnector())

        var id = UUID()
        let all = try await events(of: queue) { id = await queue.enqueue([file])[0] }

        let points = all.compactMap { event -> ResumePoint? in
            if case .resumable(let eventID, let point) = event, eventID == id { point } else { nil }
        }
        // Waiting, then the name the server will hold, then the server holding it.
        #expect(points.count == 3)
        #expect(points[0].remotePath == nil && !points[0].created)
        #expect(points[1].remotePath == "/drops/big.bin" && !points[1].created)
        #expect(points[2].remotePath == "/drops/big.bin" && points[2].created)
        #expect(points[2].config == config)
        #expect(points[2].totalBytes == 1000)
        #expect(points[2].sourcePath == file.path)
        #expect(points[2].sourceModified != nil)
        // Waiting comes before the upload starts, so a quit while it waits loses nothing.
        let queued = try #require(all.firstIndex(of: .queued(id: id, fileName: "big.bin", totalBytes: 1000)))
        #expect(all[queued + 1] == .resumable(id: id, points[0]))
    }

    // MARK: Carrying on a file

    @Test func carriesOnTheSameFileFromWhatTheServerHolds() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "big.bin", size: 1000)
        let session = FakeSession(sizes: ["/drops/big.bin": 400])
        let queue = makeQueue(FakeConnector(session: session))
        let id = UUID()

        let all = try await events(of: queue) {
            await queue.resume(id, from: point(file, remote: "/drops/big.bin", total: 1000))
        }

        // The same name, even though Keep both would number a name that is taken.
        #expect(session.uploads == ["/drops/big.bin"])
        #expect(session.uploadOffsets == [400])
        #expect(all.contains(.progress(id: id, UploadProgress(bytesSent: 400, totalBytes: 1000))))
        #expect(all.last == .succeeded(id: id, remotePath: "/drops/big.bin"))
        #expect(reasons(all).isEmpty)
        #expect(session.deletions.isEmpty)
    }

    @Test func aFileThatIsAllThereAlreadyIsDoneWithoutSendingAnything() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "big.bin", size: 1000)
        let session = FakeSession(sizes: ["/drops/big.bin": 1000])
        let queue = makeQueue(FakeConnector(session: session))
        let id = UUID()

        let all = try await events(of: queue) {
            await queue.resume(id, from: point(file, remote: "/drops/big.bin", total: 1000))
        }

        #expect(session.uploads.isEmpty)
        #expect(all.last == .succeeded(id: id, remotePath: "/drops/big.bin"))
    }

    @Test func aFileThatChangedStartsOverAndSaysWhy() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "big.bin", size: 1200)
        let session = FakeSession(sizes: ["/drops/big.bin": 400])
        let queue = makeQueue(FakeConnector(session: session))
        let id = UUID()

        // It had 1000 bytes when the upload began; it has 1200 now.
        let all = try await events(of: queue) {
            await queue.resume(id, from: point(file, remote: "/drops/big.bin", total: 1000))
        }

        #expect(session.uploadOffsets == [0])
        #expect(session.uploads == ["/drops/big.bin"])
        #expect(reasons(all) == ["The file changed, so it starts over."])
        #expect(all.last == .succeeded(id: id, remotePath: "/drops/big.bin"))
    }

    @Test func aFileEditedInPlaceToTheSameSizeStartsOverToo() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "big.bin", size: 1000)
        let session = FakeSession(sizes: ["/drops/big.bin": 400])
        let queue = makeQueue(FakeConnector(session: session))
        var earlier = point(file, remote: "/drops/big.bin", total: 1000)
        earlier.sourceModified = Date().addingTimeInterval(-3600)

        let all = try await events(of: queue) { await queue.resume(UUID(), from: earlier) }

        #expect(session.uploadOffsets == [0])
        #expect(reasons(all) == ["The file changed, so it starts over."])
    }

    @Test func aPartThatIsGoneStartsOverAndSaysWhy() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "big.bin", size: 1000)
        let session = FakeSession()
        let queue = makeQueue(FakeConnector(session: session))

        let all = try await events(of: queue) {
            await queue.resume(UUID(), from: point(file, remote: "/drops/big.bin", total: 1000))
        }

        #expect(session.uploadOffsets == [0])
        #expect(reasons(all) == ["The partly sent file was gone, so it starts over."])
        #expect(session.size(of: "/drops/big.bin") == 1000)
    }

    @Test func aPartLargerThanTheFileStartsOver() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "big.bin", size: 1000)
        let session = FakeSession(sizes: ["/drops/big.bin": 5000])
        let queue = makeQueue(FakeConnector(session: session))

        let all = try await events(of: queue) {
            await queue.resume(UUID(), from: point(file, remote: "/drops/big.bin", total: 1000))
        }

        #expect(session.uploadOffsets == [0])
        #expect(reasons(all) == ["The file on the server was bigger than this one, so it starts over."])
    }

    @Test func aServerThatCantSayHowMuchItHasStartsOver() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "big.bin", size: 1000)
        let session = FakeSession(sizes: ["/drops/big.bin": 400])
        session.failSizeChecks(with: UploaderError.cannotResume)
        let queue = makeQueue(FakeConnector(session: session))

        let all = try await events(of: queue) {
            await queue.resume(UUID(), from: point(file, remote: "/drops/big.bin", total: 1000))
        }

        #expect(session.uploadOffsets == [0])
        #expect(reasons(all) == ["The server can't say how much it has, so it starts over."])
    }

    @Test func aServerThatWontStartInTheMiddleGetsTheWholeFile() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "big.bin", size: 1000)
        let session = FakeSession(sizes: ["/drops/big.bin": 400], refusesToResume: true)
        let queue = makeQueue(FakeConnector(session: session))
        let id = UUID()

        let all = try await events(of: queue) {
            await queue.resume(id, from: point(file, remote: "/drops/big.bin", total: 1000))
        }

        // It tried to carry on, was told no, and sent everything over the same name.
        #expect(session.uploadOffsets == [400, 0])
        #expect(session.uploads == ["/drops/big.bin", "/drops/big.bin"])
        #expect(reasons(all) == ["The server can't carry on a partly sent file, so it starts over."])
        #expect(all.last == .succeeded(id: id, remotePath: "/drops/big.bin"))
    }

    @Test func aPartThatTheServerDidntKeepIsNotTrustedAsOne() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "report.pdf", size: 1000)
        // Replacing is on, and this is a file the user already had: the upload had not made it its own before it stopped.
        let session = FakeSession(sizes: ["/drops/report.pdf": 400])
        let queue = makeQueue(FakeConnector(session: session), preferences: Preferences(conflictPolicy: .replace))

        _ = try await events(of: queue) {
            await queue.resume(UUID(), from: point(file, remote: "/drops/report.pdf", created: false, total: 1000))
        }

        // Nothing is added to their file: it is replaced, as an upload with that setting does.
        #expect(session.uploadOffsets == [0])
    }

    @Test func anUploadThatNeverStartedIsSentLikeANewOne() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "a.txt")
        let session = FakeSession(existing: ["/drops/a.txt"])
        let queue = makeQueue(FakeConnector(session: session))
        let id = UUID()
        let fresh = ResumePoint(sourcePath: file.path, isFolder: false, totalBytes: 5)

        let all = try await events(of: queue) { await queue.resume(id, from: fresh) }

        // Keep both: the name is taken, so it gets a number, as it would have then.
        #expect(all.last == .succeeded(id: id, remotePath: "/drops/a-1.txt"))
    }

    @Test func aFileThatMovedCantCarryOn() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let gone = temp.directory.appendingPathComponent("gone.bin")
        let session = FakeSession(sizes: ["/drops/gone.bin": 400])
        let queue = makeQueue(FakeConnector(session: session))
        let id = UUID()

        let all = try await events(of: queue) {
            await queue.resume(id, from: ResumePoint(sourcePath: gone.path, isFolder: false, config: config, remotePath: "/drops/gone.bin", totalBytes: 1000, created: true))
        }

        #expect(session.uploads.isEmpty)
        #expect(all.last == .failed(id: id, .transfer("The file is no longer where it was, so it can't carry on.")))
    }

    @Test func aResumeOfAFileFromAnotherServerGoesToThatServer() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "big.bin", size: 1000)
        let session = FakeSession(sizes: ["/drops/big.bin": 400])
        let connector = FakeConnector(session: session)
        // The saved server is another one now; the upload was going to the old one, and its password is still there.
        let other = ServerConfig(transferProtocol: .sftp, host: "other.example.com", username: "me", remoteDirectory: "/elsewhere")
        let credentials = InMemoryCredentialStore()
        try credentials.setPassword("old-secret", for: config.credentialKey)
        let queue = UploadQueue(
            settings: InMemorySettingsStore(config: other), credentials: credentials, connectors: connector,
            progressInterval: 0, reconnect: quick
        )

        _ = try await events(of: queue) {
            await queue.resume(UUID(), from: point(file, remote: "/drops/big.bin", total: 1000))
        }

        #expect(connector.configs == [config])
        #expect(connector.passwords == ["old-secret"])
        #expect(session.uploadOffsets == [400])
    }

    // MARK: A lost connection

    @Test func aLostConnectionIsTriedAgainAndCarriesOnFromWhatArrived() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "big.bin", size: 1000)
        // The connection breaks when the server holds 400 bytes.
        let session = FakeSession(drops: [400])
        let connector = FakeConnector(session: session)
        let queue = makeQueue(connector)
        var id = UUID()

        let all = try await events(of: queue) { id = await queue.enqueue([file])[0] }

        #expect(all.contains(.waitingForConnection(id: id)))
        #expect(session.uploads == ["/drops/big.bin", "/drops/big.bin"])
        #expect(session.uploadOffsets == [0, 400])
        #expect(connector.connectionCount == 2)
        #expect(all.last == .succeeded(id: id, remotePath: "/drops/big.bin"))
        // It was a pause, not a failure: nothing was deleted and nothing was reported as failed.
        #expect(session.deletions.isEmpty)
        #expect(!all.contains { if case .failed = $0 { true } else { false } })
    }

    @Test func itGivesUpWhenTheConnectionStaysLostAndLeavesTheFileForResuming() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "big.bin", size: 1000)
        let session = FakeSession(drops: [400, 400, 400, 400])
        let queue = makeQueue(FakeConnector(session: session))
        var id = UUID()

        let all = try await events(of: queue) { id = await queue.enqueue([file])[0] }

        // The first try plus one after each wait, then it is over.
        #expect(session.uploads.count == 3)
        #expect(count(all) { $0 == .waitingForConnection(id: id) } == 2)
        guard case .failed(_, let failure)? = all.last(where: { if case .failed = $0 { true } else { false } }) else {
            Issue.record("expected a failure")
            return
        }
        #expect(failure.isInterruption)
        // What was sent stays where it is, and the last report says it is the upload's own.
        #expect(session.deletions.isEmpty)
        #expect(session.size(of: "/drops/big.bin") == 400)
        let last = all.compactMap { event -> ResumePoint? in
            if case .resumable(_, let point) = event { point } else { nil }
        }.last
        #expect(last?.created == true && last?.remotePath == "/drops/big.bin")
        #expect(!all.contains { if case .cancelled = $0 { true } else { false } })
    }

    @Test func theWaitsGrowAndAreUsedUp() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "big.bin", size: 1000)
        let session = FakeSession(drops: [400, 400, 400, 400, 400, 400])
        let policy = ReconnectPolicy(delays: [0.05, 0.1, 0.15], giveUpAfter: 5, noticeAfter: 2)
        let queue = makeQueue(FakeConnector(session: session), reconnect: policy)

        let started = Date()
        _ = try await events(of: queue) { await queue.enqueue([file]) }

        // Four tries (the first and one after each wait), and at least the waits in between.
        #expect(session.uploads.count == 4)
        #expect(Date().timeIntervalSince(started) >= 0.3)
    }

    @Test func theTimeAllowedIsCountedFromTheLastSignOfLife() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "big.bin", size: 1000)
        let session = FakeSession(drops: [400, 400, 400, 400])
        // The first wait fits in the time allowed, the second doesn't.
        let policy = ReconnectPolicy(delays: [0.05, 30, 30], giveUpAfter: 1, noticeAfter: 0.5)
        let queue = makeQueue(FakeConnector(session: session), reconnect: policy)

        let started = Date()
        let all = try await events(of: queue) { await queue.enqueue([file]) }

        #expect(session.uploads.count == 2)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(all.contains { if case .failed(_, let failure) = $0 { failure.isInterruption } else { false } })
    }

    @Test func aServerThatNeverAnsweredIsNotWaitedFor() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "a.txt")
        let connector = FakeConnector(connectError: UploaderError.connectionFailed("The server refused the connection."))
        let queue = makeQueue(connector)
        var id = UUID()

        let all = try await events(of: queue) { id = await queue.enqueue([file])[0] }

        // As it always was: a server that can't be reached fails at once, most likely a mistake in the settings.
        #expect(connector.connectionCount == 1)
        #expect(!all.contains(.waitingForConnection(id: id)))
        #expect(all.last == .failed(id: id, .transfer("Couldn't connect to the server. The server refused the connection.")))
    }

    @Test func aResumeThatCantConnectStaysAnInterruptedUpload() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "big.bin", size: 1000)
        let connector = FakeConnector(connectError: UploaderError.connectionFailed("The server refused the connection."))
        let queue = makeQueue(connector)
        let id = UUID()

        let all = try await events(of: queue) {
            await queue.resume(id, from: point(file, remote: "/drops/big.bin", total: 1000))
        }

        #expect(connector.connectionCount == 1)
        #expect(all.last == .failed(id: id, .connectionLost("Couldn't connect to the server. The server refused the connection.")))
    }

    @Test func aRefusalIsNotAConnectionProblem() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "a.txt")
        let session = FakeSession(error: UploaderError.serverRejected(code: 552, message: "Disk full"))
        let queue = makeQueue(FakeConnector(session: session))
        var id = UUID()

        let all = try await events(of: queue) { id = await queue.enqueue([file])[0] }

        #expect(!all.contains(.waitingForConnection(id: id)))
        #expect(session.uploads.count == 1)
        #expect(UploadQueue.isConnectionLoss(UploaderError.serverRejected(code: 421, message: "Timeout")))
        #expect(!UploadQueue.isConnectionLoss(UploaderError.serverRejected(code: 550, message: "No")))
        #expect(!UploadQueue.isConnectionLoss(UploaderError.authenticationFailed))
        #expect(!UploadQueue.isConnectionLoss(CancellationError()))
    }

    // MARK: A connection that goes quiet

    @Test func aStalledUploadSaysItIsWaitingAndGivesUpInsideTheWindow() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "big.bin", size: 1000)
        // The server holds the file and then nothing moves, with no error: a connection that went quiet.
        let session = FakeSession(hangAfterCreatingFile: true)
        let policy = ReconnectPolicy(delays: [0.01], giveUpAfter: 0.4, noticeAfter: 0.1)
        let queue = makeQueue(FakeConnector(session: session), reconnect: policy)
        var id = UUID()

        let started = Date()
        let all = try await events(of: queue) { id = await queue.enqueue([file])[0] }

        #expect(all.contains(.waitingForConnection(id: id)))
        #expect(Date().timeIntervalSince(started) < 4)
        #expect(all.last == .failed(id: id, .connectionLost("The server stopped responding.")))
        #expect(session.deletions.isEmpty)
        #expect(session.uploads.count == 1)
    }

    @Test func aTransferThatCantSeeACancelIsClosedUnder() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "big.bin", size: 1000)
        let session = FakeSession(stuckUntilClosed: true)
        let policy = ReconnectPolicy(delays: [0.01], giveUpAfter: 0.3, noticeAfter: 0.1)
        let queue = makeQueue(FakeConnector(session: session), reconnect: policy, cancelGrace: 0.05)
        var id = UUID()

        let started = Date()
        let all = try await events(of: queue) { id = await queue.enqueue([file])[0] }

        // The stall was noticed, the transfer ignored the cancel, and closing the connection ended it.
        #expect(Date().timeIntervalSince(started) < 4)
        #expect(all.last == .failed(id: id, .connectionLost("The server stopped responding.")))
        #expect(session.closeCount >= 1)
    }

    @Test func aUserCancelOnAStuckTransferStillEnds() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "big.bin", size: 1000)
        let session = FakeSession(stuckUntilClosed: true)
        let queue = makeQueue(FakeConnector(session: session), cancelGrace: 0.05)
        var id = UUID()

        let started = Date()
        let all = try await events(of: queue) {
            id = await queue.enqueue([file])[0]
            try await eventually { session.size(of: "/drops/big.bin") != nil }
            await queue.cancel(id)
        }

        #expect(Date().timeIntervalSince(started) < 4)
        #expect(all.contains(.cancelled(id: id)))
        // A cancel is the one thing that takes the half-sent file away.
        #expect(session.deletions == ["/drops/big.bin"])
    }

    // MARK: Cancel and discard

    @Test func cancellingWhileItWaitsToTryAgainTakesTheHalfSentFileAway() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "big.bin", size: 1000)
        let session = FakeSession(drops: [400])
        let policy = ReconnectPolicy(delays: [30], giveUpAfter: 100, noticeAfter: 50)
        let queue = makeQueue(FakeConnector(session: session), reconnect: policy)
        let log = EventLog()
        let collecting = log.collect(queue)

        let id = await queue.enqueue([file])[0]
        try await eventually { log.events.contains(.waitingForConnection(id: id)) }
        await queue.cancel(id)
        await queue.waitUntilIdle()
        await queue.finish()
        await collecting.value

        #expect(log.events.contains(.cancelled(id: id)))
        #expect(session.deletions == ["/drops/big.bin"])
    }

    @Test func cancellingAnUploadWaitingItsTurnToResumeTakesItsPartAway() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let busy = try temp.file(named: "busy.bin", size: 100)
        let file = try temp.file(named: "big.bin", size: 1000)
        // The first upload hangs, so the resumed one is still waiting its turn.
        let session = FakeSession(hangAfterCreatingFile: true, sizes: ["/drops/big.bin": 400])
        let queue = makeQueue(FakeConnector(session: session))
        let log = EventLog()
        let collecting = log.collect(queue)

        let first = await queue.enqueue([busy])[0]
        try await eventually { session.uploads.count == 1 }
        let waiting = UUID()
        await queue.resume(waiting, from: point(file, remote: "/drops/big.bin", total: 1000))
        await queue.cancel(waiting)
        try await eventually { session.deletions == ["/drops/big.bin"] }
        await queue.cancel(first)
        await queue.waitUntilIdle()
        await queue.finish()
        await collecting.value

        #expect(log.events.contains(.cancelled(id: waiting)))
    }

    @Test func pressingResumeTwiceStartsItOnce() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "big.bin", size: 1000)
        let session = FakeSession(sizes: ["/drops/big.bin": 400])
        let queue = makeQueue(FakeConnector(session: session))
        let id = UUID()

        let all = try await events(of: queue) {
            let earlier = point(file, remote: "/drops/big.bin", total: 1000)
            await queue.resume(id, from: earlier)
            await queue.resume(id, from: earlier)
        }

        #expect(count(all) { if case .queued = $0 { true } else { false } } == 1)
        #expect(session.uploads == ["/drops/big.bin"])
        #expect(all.last == .succeeded(id: id, remotePath: "/drops/big.bin"))
    }

    @Test func discardTakesTheHalfSentFileOffTheServer() async throws {
        let session = FakeSession(sizes: ["/drops/big.bin": 400])
        let connector = FakeConnector(session: session)
        let queue = makeQueue(connector)
        let held = ResumePoint(sourcePath: "/tmp/big.bin", isFolder: false, config: config, remotePath: "/drops/big.bin", totalBytes: 1000, created: true)

        let problem = await queue.discard(held)

        #expect(problem == nil)
        #expect(session.deletions == ["/drops/big.bin"])
        // A connection of its own, closed again.
        #expect(connector.connectionCount == 1)
        #expect(session.closeCount == 1)
    }

    @Test func discardLeavesAFileThatIsNotTheUploadsOwn() async throws {
        let session = FakeSession(sizes: ["/drops/report.pdf": 400])
        let connector = FakeConnector(session: session)
        let queue = makeQueue(connector)
        // The upload never made the file (replace was on and the name was the user's own).
        let notYet = ResumePoint(sourcePath: "/tmp/report.pdf", isFolder: false, config: config, remotePath: "/drops/report.pdf", totalBytes: 1000, created: false)

        let problem = await queue.discard(notYet)

        #expect(problem == nil)
        #expect(session.deletions.isEmpty)
        #expect(connector.connectionCount == 0)
    }

    @Test func discardOfAFolderTakesOnlyTheFileItWasIn() async throws {
        let session = FakeSession(sizes: ["/drops/photos/a.txt": 100, "/drops/photos/b/big.bin": 400])
        let queue = makeQueue(FakeConnector(session: session))
        var mid = ResumePoint(sourcePath: "/tmp/photos", isFolder: true, config: config, remotePath: "/drops/photos", totalBytes: 1500, created: true, finishedFiles: 1, currentFile: "b/big.bin")

        let problem = await queue.discard(mid)

        #expect(problem == nil)
        // The finished file and the folders stay.
        #expect(session.deletions == ["/drops/photos/b/big.bin"])
        #expect(session.exists("/drops/photos/a.txt"))

        // Between two files there is nothing half sent.
        mid.currentFile = nil
        mid.created = false
        #expect(mid.partialPath == nil)
        #expect(await queue.discard(mid) == nil)
        #expect(session.deletions.count == 1)
    }

    @Test func discardSaysWhyWhenTheServerCantBeReached() async throws {
        let session = FakeSession(sizes: ["/drops/big.bin": 400])
        let connector = FakeConnector(session: session, connectError: UploaderError.connectionFailed("The server refused the connection."))
        let queue = makeQueue(connector)
        let held = ResumePoint(sourcePath: "/tmp/big.bin", isFolder: false, config: config, remotePath: "/drops/big.bin", totalBytes: 1000, created: true)

        let problem = await queue.discard(held)

        #expect(problem == "Couldn't connect to the server. The server refused the connection.")
        #expect(session.deletions.isEmpty)
    }

    @Test func discardWithoutAPasswordSaysSo() async throws {
        let queue = makeQueue(FakeConnector(), password: nil)
        let held = ResumePoint(sourcePath: "/tmp/big.bin", isFolder: false, config: config, remotePath: "/drops/big.bin", totalBytes: 1000, created: true)

        #expect(await queue.discard(held) == UploadFailure.missingPassword.displayMessage)
    }

    @Test func discardSaysWhenTheServerRefusesToDelete() async throws {
        let session = FakeSession(deleteError: UploaderError.serverRejected(code: 550, message: "Permission denied"), sizes: ["/drops/big.bin": 400])
        let queue = makeQueue(FakeConnector(session: session))
        let held = ResumePoint(sourcePath: "/tmp/big.bin", isFolder: false, config: config, remotePath: "/drops/big.bin", totalBytes: 1000, created: true)

        #expect(await queue.discard(held) == "The server refused: Permission denied (550)")
        #expect(session.exists("/drops/big.bin"))
    }

    // MARK: Folders

    private func makeFolder(_ temp: TempFiles, named name: String = "photos") throws -> URL {
        let folder = temp.directory.appendingPathComponent(name)
        let fm = FileManager.default
        try fm.createDirectory(at: folder.appendingPathComponent("b"), withIntermediateDirectories: true)
        try Data(count: 100).write(to: folder.appendingPathComponent("a.txt"))
        try Data(count: 1000).write(to: folder.appendingPathComponent("b/big.bin"))
        try Data(count: 50).write(to: folder.appendingPathComponent("c.txt"))
        return folder
    }

    private func folderPoint(_ folder: URL, finished: Int, current: String?, created: Bool, fingerprint: String? = nil) throws -> ResumePoint {
        let tree = try LocalTree.scan(folder)
        return ResumePoint(
            sourcePath: folder.path, isFolder: true, config: config, remotePath: "/drops/photos",
            totalBytes: tree.totalBytes, created: created, finishedFiles: finished,
            fingerprint: fingerprint ?? tree.fingerprint, currentFile: current
        )
    }

    @Test func aResumedFolderSkipsWhatIsDoneAndCarriesOnTheHalfSentFile() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let folder = try makeFolder(temp)
        let session = FakeSession(sizes: ["/drops/photos/a.txt": 100, "/drops/photos/b/big.bin": 400])
        let queue = makeQueue(FakeConnector(session: session))
        let id = UUID()

        let all = try await events(of: queue) {
            await queue.resume(id, from: try folderPoint(folder, finished: 1, current: "b/big.bin", created: true))
        }

        // a.txt is done and left alone; big.bin goes on from 400; c.txt is sent whole.
        #expect(session.uploads == ["/drops/photos/b/big.bin", "/drops/photos/c.txt"])
        #expect(session.uploadOffsets == [400, 0])
        #expect(reasons(all).isEmpty)
        #expect(all.last == .succeeded(id: id, remotePath: "/drops/photos"))
        // One bar for the whole folder, starting where it stood: 100 done, 400 of the big file there.
        #expect(all.contains(.progress(id: id, UploadProgress(bytesSent: 500, totalBytes: 1150))))
        #expect(session.deletions.isEmpty)
    }

    @Test func filesThatFinishedAfterTheLastNoteAreFoundAndSkipped() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let folder = try makeFolder(temp)
        // The last note says nothing was done yet, but the server has a.txt and the whole of big.bin.
        let session = FakeSession(sizes: ["/drops/photos/a.txt": 100, "/drops/photos/b/big.bin": 1000])
        let queue = makeQueue(FakeConnector(session: session))

        _ = try await events(of: queue) {
            await queue.resume(UUID(), from: try folderPoint(folder, finished: 0, current: nil, created: false))
        }

        #expect(session.uploads == ["/drops/photos/c.txt"])
    }

    @Test func aPartTheNoteDoesntNameIsRewrittenNotContinued() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let folder = try makeFolder(temp)
        // The server holds part of big.bin, but the last note was about an earlier file: not known to be the upload's own.
        let session = FakeSession(sizes: ["/drops/photos/a.txt": 100, "/drops/photos/b/big.bin": 400])
        let queue = makeQueue(FakeConnector(session: session))

        _ = try await events(of: queue) {
            await queue.resume(UUID(), from: try folderPoint(folder, finished: 0, current: nil, created: false))
        }

        #expect(session.uploadOffsets == [0, 0])
        #expect(session.uploads == ["/drops/photos/b/big.bin", "/drops/photos/c.txt"])
    }

    @Test func aFolderThatChangedStartsOverIntoTheSameFolder() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let folder = try makeFolder(temp)
        let session = FakeSession(sizes: ["/drops/photos/a.txt": 100, "/drops/photos/b/big.bin": 400])
        let queue = makeQueue(FakeConnector(session: session))

        let all = try await events(of: queue) {
            await queue.resume(UUID(), from: try folderPoint(folder, finished: 1, current: "b/big.bin", created: true, fingerprint: "somethingelse"))
        }

        #expect(reasons(all) == ["The folder changed, so it starts over."])
        #expect(session.uploads == ["/drops/photos/a.txt", "/drops/photos/b/big.bin", "/drops/photos/c.txt"])
        #expect(session.uploadOffsets == [0, 0, 0])
    }

    @Test func aResumedFolderDoesntMakeTheFoldersOfFinishedFilesAgain() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let folder = try makeFolder(temp)
        let session = FakeSession(sizes: ["/drops/photos/a.txt": 100, "/drops/photos/b/big.bin": 1000])
        let queue = makeQueue(FakeConnector(session: session))

        _ = try await events(of: queue) {
            await queue.resume(UUID(), from: try folderPoint(folder, finished: 2, current: nil, created: false))
        }

        // Only the folder itself is made (accepting that it is there); "b" holds a finished file, so it is not touched.
        #expect(!session.madeDirectories.contains("/drops/photos/b"))
        #expect(session.uploads == ["/drops/photos/c.txt"])
    }

    @Test func aFolderNotesTheFileItIsSendingWhenItIsBigAndWhenItIsDone() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let folder = temp.directory.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 10).write(to: folder.appendingPathComponent("a.txt"))
        try Data(count: 1_100_000).write(to: folder.appendingPathComponent("b.bin"))
        let queue = makeQueue(FakeConnector())
        var id = UUID()

        let all = try await events(of: queue) { id = await queue.enqueue([folder])[0] }

        let points = all.compactMap { event -> ResumePoint? in
            if case .resumable(let eventID, let point) = event, eventID == id { point } else { nil }
        }
        // Waiting, then the folder is made, then the big file starts (not on the server yet), is on it, and is done.
        let big = points.filter { $0.currentFile == "b.bin" }
        #expect(big.map(\.created) == [false, true])
        #expect(big.allSatisfy { $0.remotePath == "/drops/photos" && $0.finishedFiles == 1 })
        let done = try #require(points.last)
        #expect(done.finishedFiles == 2 && done.currentFile == nil && !done.created)
        #expect(done.fingerprint == (try LocalTree.scan(folder)).fingerprint)
    }
}

/// Collects a queue's events from another task, so a test can look at them while the queue is still running.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [UploadEvent] = []

    var events: [UploadEvent] { lock.withLock { all } }

    func collect(_ queue: UploadQueue) -> Task<Void, Never> {
        Task {
            for await event in queue.events {
                lock.withLock { all.append(event) }
            }
        }
    }
}
