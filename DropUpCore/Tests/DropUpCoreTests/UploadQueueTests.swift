import Foundation
import Testing
@testable import DropUpCore

struct UploadQueueTests {
    let config = ServerConfig(transferProtocol: .sftp, host: "example.com", username: "me", remoteDirectory: "/drops")

    private func makeQueue(
        config: ServerConfig?,
        password: String? = "secret",
        preferences: Preferences = Preferences(),
        connector: FakeConnector = FakeConnector()
    ) -> UploadQueue {
        let credentials = InMemoryCredentialStore()
        if let config, let password {
            try? credentials.setPassword(password, for: config.credentialKey)
        }
        return UploadQueue(
            settings: InMemorySettingsStore(config: config, preferences: preferences),
            credentials: credentials,
            connectors: connector,
            progressInterval: 0
        )
    }

    /// Runs the queue to completion and returns every event it emitted.
    private func run(_ queue: UploadQueue, files: [URL]) async -> (ids: [UUID], events: [UploadEvent]) {
        let ids = await queue.enqueue(files)
        await queue.waitUntilIdle()
        return (ids, await collect(queue))
    }

    private func collect(_ queue: UploadQueue) async -> [UploadEvent] {
        await queue.finish()
        var events: [UploadEvent] = []
        for await event in queue.events {
            events.append(event)
        }
        return events
    }

    @Test func uploadsFileToConfiguredDirectoryWithStoredPassword() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "photo.png", contents: "0123456789")
        let connector = FakeConnector()

        let (ids, events) = await run(makeQueue(config: config, connector: connector), files: [file])

        let id = try #require(ids.first)
        // What it takes to resume is reported along the way too; ResumeTests looks at that.
        #expect(events.filter { if case .resumable = $0 { false } else { true } } == [
            .queued(id: id, fileName: "photo.png", totalBytes: 10),
            .started(id: id),
            .progress(id: id, UploadProgress(bytesSent: 5, totalBytes: 10)),
            .progress(id: id, UploadProgress(bytesSent: 10, totalBytes: 10)),
            .succeeded(id: id, remotePath: "/drops/photo.png"),
        ])
        #expect(connector.session.uploads == ["/drops/photo.png"])
        #expect(connector.passwords == ["secret"])
    }

    @Test func uploadsSeveralFilesInDropOrderOverOneConnection() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let files = try ["a.txt", "b.txt", "c.txt"].map { try temp.file(named: $0) }
        let connector = FakeConnector()

        let (ids, events) = await run(makeQueue(config: config, connector: connector), files: files)

        #expect(connector.session.uploads == ["/drops/a.txt", "/drops/b.txt", "/drops/c.txt"])
        #expect(connector.connectionCount == 1)
        #expect(connector.session.closeCount == 1)
        let succeeded = events.compactMap { event -> UUID? in
            if case .succeeded(let id, _) = event { return id }
            return nil
        }
        #expect(succeeded == ids)
    }

    @Test func keepBothPicksTheNextFreeNumberedName() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "photo.png")
        let connector = FakeConnector(session: FakeSession(existing: ["/drops/photo.png", "/drops/photo-1.png"]))

        let (ids, events) = await run(makeQueue(config: config, connector: connector), files: [file])

        #expect(events.last == .succeeded(id: ids[0], remotePath: "/drops/photo-2.png"))
    }

    @Test func replaceOverwritesTheExistingName() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "photo.png")
        let connector = FakeConnector(session: FakeSession(existing: ["/drops/photo.png"]))
        let queue = makeQueue(config: config, preferences: Preferences(conflictPolicy: .replace), connector: connector)

        let (ids, events) = await run(queue, files: [file])

        #expect(events.last == .succeeded(id: ids[0], remotePath: "/drops/photo.png"))
    }

    @Test func droppingTheSameFileTwiceKeepsBoth() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "a.txt")
        let connector = FakeConnector()

        _ = await run(makeQueue(config: config, connector: connector), files: [file, file])

        #expect(connector.session.uploads == ["/drops/a.txt", "/drops/a-1.txt"])
    }

    @Test func failsWithNotConfiguredWhenNoSettings() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "a.txt")
        let connector = FakeConnector()

        let (ids, events) = await run(makeQueue(config: nil, connector: connector), files: [file])

        #expect(events.last == .failed(id: ids[0], .notConfigured))
        #expect(connector.connectionCount == 0)
    }

    @Test func failsWithMissingPasswordWhenKeychainIsEmpty() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "a.txt")

        let (ids, events) = await run(makeQueue(config: config, password: nil), files: [file])

        #expect(events.last == .failed(id: ids[0], .missingPassword))
    }

    @Test func rejectsMissingItems() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let missing = temp.directory.appendingPathComponent("gone.txt")

        let (ids, events) = await run(makeQueue(config: config), files: [missing])

        #expect(events.contains(.failed(id: ids[0], .unsupportedItem)))
    }

    @Test func reportsReadableErrorsAndKeepsGoing() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let connector = FakeConnector(connectError: UploaderError.authenticationFailed)
        let files = try ["a.txt", "b.txt"].map { try temp.file(named: $0) }

        let (ids, events) = await run(makeQueue(config: config, connector: connector), files: files)

        #expect(connector.connectionCount == 2)
        let message = "The server rejected the username or password."
        #expect(events.contains(.failed(id: ids[0], .transfer(message))))
        #expect(events.contains(.failed(id: ids[1], .transfer(message))))
    }

    @Test func reconnectsAfterATransferError() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        // A refusal is not a lost connection, so nothing waits and tries again: the next file just gets a fresh session.
        let connector = FakeConnector(session: FakeSession(error: UploaderError.serverRejected(code: 552, message: "Disk full")))
        let files = try ["a.txt", "b.txt"].map { try temp.file(named: $0) }

        _ = await run(makeQueue(config: config, connector: connector), files: files)

        #expect(connector.connectionCount == 2)
        #expect(connector.session.closeCount == 2)
    }

    @Test func picksUpSettingsChangesBetweenUploads() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let settings = InMemorySettingsStore(config: config)
        let credentials = InMemoryCredentialStore()
        let moved = ServerConfig(transferProtocol: .sftp, host: "example.com", username: "me", remoteDirectory: "/elsewhere")
        try credentials.setPassword("secret", for: config.credentialKey)
        let connector = FakeConnector()
        let queue = UploadQueue(settings: settings, credentials: credentials, connectors: connector, progressInterval: 0)

        await queue.enqueue([try temp.file(named: "a.txt")])
        await queue.waitUntilIdle()
        try settings.saveServerConfig(moved)
        try credentials.setPassword("new", for: moved.credentialKey)
        await queue.enqueue([try temp.file(named: "b.txt")])
        await queue.waitUntilIdle()

        #expect(connector.session.uploads == ["/drops/a.txt", "/elsewhere/b.txt"])
        #expect(connector.passwords == ["secret", "new"])
    }

    /// Drops two files for `config`, saves `replacement` in Settings while the first one is running and the second waits,
    /// then lets both go through. Returns what the connector saw.
    private func dropTwoThenSave(_ replacement: ServerConfig, temp: TempFiles) async throws -> FakeConnector {
        let settings = InMemorySettingsStore(config: config)
        let credentials = InMemoryCredentialStore()
        try credentials.setPassword("secret", for: config.credentialKey)
        try credentials.setPassword("replacement-secret", for: replacement.credentialKey)
        let connector = FakeConnector(session: FakeSession(hangUntilCancelled: true))
        let queue = UploadQueue(settings: settings, credentials: credentials, connectors: connector, progressInterval: 0)

        let ids = await queue.enqueue(try ["a.txt", "b.txt"].map { try temp.file(named: $0) })
        try await eventually { connector.session.uploads.count == 1 }
        try settings.saveServerConfig(replacement)
        // The first upload ends; the second one's turn comes after the save.
        await queue.cancel(ids[0])
        try await eventually { connector.session.uploads.count == 2 }
        await queue.cancel(ids[1])
        await queue.waitUntilIdle()
        return connector
    }

    @Test func aWaitingUploadKeepsTheServerItWasDroppedFor() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let other = ServerConfig(transferProtocol: .ftp, host: "other.example.com", username: "you", remoteDirectory: "/other")

        let connector = try await dropTwoThenSave(other, temp: temp)

        #expect(connector.session.uploads == ["/drops/a.txt", "/drops/b.txt"])
        #expect(connector.configs.allSatisfy { $0 == config })
        #expect(connector.passwords.allSatisfy { $0 == "secret" })
    }

    @Test func aWaitingUploadKeepsItsFolderWhenOnlyTheFolderIsChanged() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }

        let connector = try await dropTwoThenSave(config.withRemoteDirectory("/new"), temp: temp)

        #expect(connector.session.uploads == ["/drops/a.txt", "/drops/b.txt"])
    }

    @Test func anUploadForAnEarlierServerGoesThereWhateverIsSavedNow() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let earlier = ServerConfig(transferProtocol: .ftp, host: "old.example.com", username: "me", remoteDirectory: "/old")
        let credentials = InMemoryCredentialStore()
        try credentials.setPassword("secret", for: config.credentialKey)
        try credentials.setPassword("old-secret", for: earlier.credentialKey)
        let connector = FakeConnector()
        let queue = UploadQueue(settings: InMemorySettingsStore(config: config), credentials: credentials, connectors: connector, progressInterval: 0)

        let ids = await queue.enqueue([try temp.file(named: "a.txt")], config: earlier)
        await queue.waitUntilIdle()
        let events = await collect(queue)

        #expect(connector.session.uploads == ["/old/a.txt"])
        #expect(connector.configs == [earlier])
        #expect(connector.passwords == ["old-secret"])
        #expect(events.contains { if case .succeeded(let id, _) = $0 { id == ids[0] } else { false } })
    }

    @Test func aNewUploadReportsTheServerItWasDroppedForAtOnce() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let queue = makeQueue(config: config, connector: FakeConnector())

        let ids = await queue.enqueue([try temp.file(named: "a.txt")], toDirectory: "/chosen")
        await queue.waitUntilIdle()
        let events = await collect(queue)

        // Before it has connected, so a switch right now, or a quit, still leaves it knowing where it was going.
        let first = events.compactMap { event -> ResumePoint? in
            if case .resumable(let id, let point) = event, id == ids[0] { point } else { nil }
        }.first
        #expect(first?.config == config)
        #expect(first?.directory == "/chosen")
    }

    @Test func cancelsWaitingAndRunningUploads() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let connector = FakeConnector(session: FakeSession(hangUntilCancelled: true))
        let queue = makeQueue(config: config, connector: connector)
        let files = try ["a.txt", "b.txt"].map { try temp.file(named: $0) }

        let ids = await queue.enqueue(files)
        try await eventually { connector.session.uploads.count == 1 }
        await queue.cancel(ids[1])
        await queue.cancel(ids[0])
        await queue.waitUntilIdle()
        let events = await collect(queue)

        #expect(events.contains(.cancelled(id: ids[0])))
        #expect(events.contains(.cancelled(id: ids[1])))
        #expect(!events.contains { if case .succeeded = $0 { true } else { false } })
        #expect(connector.session.uploads == ["/drops/a.txt"])
        #expect(connector.session.closeCount == 1)
    }

    @Test func uploadsIntoAChosenFolderAndKeepsTheConnection() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let connector = FakeConnector(session: FakeSession(uploadDelayMilliseconds: 50))
        let queue = makeQueue(config: config, connector: connector)

        // The second file is queued while the first is still uploading, so both belong to one run of the queue.
        await queue.enqueue([try temp.file(named: "a.txt")], toDirectory: "/other/place/")
        await queue.enqueue([try temp.file(named: "b.txt")])
        await queue.waitUntilIdle()

        #expect(connector.session.uploads == ["/other/place/a.txt", "/drops/b.txt"])
        #expect(connector.connectionCount == 1)
    }

    @Test func numbersAFileInAChosenFolderByThatFoldersContents() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let connector = FakeConnector(session: FakeSession(existing: ["/other/a.txt"]))
        let queue = makeQueue(config: config, connector: connector)

        await queue.enqueue([try temp.file(named: "a.txt")], toDirectory: "/other")
        await queue.waitUntilIdle()

        #expect(connector.session.uploads == ["/other/a-1.txt"])
    }

    @Test func cancelDeletesTheHalfSentFileFromTheServer() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let session = FakeSession(hangAfterCreatingFile: true)
        let connector = FakeConnector(session: session)
        let queue = makeQueue(config: config, connector: connector)

        let ids = await queue.enqueue([try temp.file(named: "big.bin")])
        try await eventually { session.exists("/drops/big.bin") }
        await queue.cancel(ids[0])
        await queue.waitUntilIdle()
        let events = await collect(queue)

        #expect(events.contains(.cancelled(id: ids[0])))
        #expect(session.deletions == ["/drops/big.bin"])
        #expect(!session.exists("/drops/big.bin"))
        // The interrupted connection is dropped and a fresh one does the cleanup.
        #expect(connector.connectionCount == 2)
    }

    @Test func cancelBeforeTheServerCreatesTheFileLeavesTheExistingOneAlone() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        // Replacing is on, so the path holds the user's own file until the server starts the new upload.
        let session = FakeSession(existing: ["/drops/report.pdf"], hangUntilCancelled: true)
        let connector = FakeConnector(session: session)
        let queue = makeQueue(config: config, preferences: Preferences(conflictPolicy: .replace), connector: connector)

        let ids = await queue.enqueue([try temp.file(named: "report.pdf")])
        try await eventually { session.uploads.count == 1 }
        await queue.cancel(ids[0])
        await queue.waitUntilIdle()
        let events = await collect(queue)

        #expect(events.contains(.cancelled(id: ids[0])))
        #expect(session.deletions.isEmpty)
        #expect(session.exists("/drops/report.pdf"))
    }

    @Test func cleanupGoesToTheServerTheUploadUsed() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let settings = InMemorySettingsStore(config: config)
        let credentials = InMemoryCredentialStore()
        try credentials.setPassword("secret", for: config.credentialKey)
        let session = FakeSession(hangAfterCreatingFile: true)
        let connector = FakeConnector(session: session)
        let queue = UploadQueue(settings: settings, credentials: credentials, connectors: connector, progressInterval: 0)

        let ids = await queue.enqueue([try temp.file(named: "big.bin")])
        try await eventually { session.exists("/drops/big.bin") }
        // The user points DropUp at another server while the upload is running.
        let other = ServerConfig(transferProtocol: .sftp, host: "other.example.com", username: "me", remoteDirectory: "/elsewhere")
        try settings.saveServerConfig(other)
        try credentials.setPassword("other-secret", for: other.credentialKey)
        await queue.cancel(ids[0])
        await queue.waitUntilIdle()

        #expect(connector.configs == [config, config])
        #expect(connector.passwords == ["secret", "secret"])
        #expect(session.deletions == ["/drops/big.bin"])
    }

    @Test func aCancelStaysCancelledWhenTheCleanupFails() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let session = FakeSession(hangAfterCreatingFile: true, deleteError: UploaderError.serverRejected(code: 550, message: "Nope"))
        let connector = FakeConnector(session: session)
        let queue = makeQueue(config: config, connector: connector)

        let ids = await queue.enqueue([try temp.file(named: "big.bin")])
        try await eventually { session.exists("/drops/big.bin") }
        await queue.cancel(ids[0])
        await queue.waitUntilIdle()
        let events = await collect(queue)

        #expect(events.contains(.cancelled(id: ids[0])))
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
        #expect(session.exists("/drops/big.bin"))
    }

    @Test func aStuckCleanupDoesNotBlockTheQueueForever() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let session = FakeSession(hangAfterCreatingFile: true, hangOnDelete: true)
        let connector = FakeConnector(session: session)
        let queue = UploadQueue(
            settings: InMemorySettingsStore(config: config),
            credentials: {
                let credentials = InMemoryCredentialStore()
                try? credentials.setPassword("secret", for: config.credentialKey)
                return credentials
            }(),
            connectors: connector,
            progressInterval: 0,
            cleanupTimeout: 0.05
        )

        let ids = await queue.enqueue([try temp.file(named: "big.bin")])
        try await eventually { session.exists("/drops/big.bin") }
        await queue.cancel(ids[0])
        await queue.waitUntilIdle()
        let events = await collect(queue)

        #expect(events.contains(.cancelled(id: ids[0])))
    }

    @Test func cancelAllEmptiesTheQueue() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let connector = FakeConnector(session: FakeSession(hangUntilCancelled: true))
        let queue = makeQueue(config: config, connector: connector)
        let files = try ["a.txt", "b.txt", "c.txt"].map { try temp.file(named: $0) }

        let ids = await queue.enqueue(files)
        try await eventually { connector.session.uploads.count == 1 }
        await queue.cancelAll()
        await queue.waitUntilIdle()
        let events = await collect(queue)

        #expect(Set(events.compactMap { if case .cancelled(let id) = $0 { id } else { nil } }) == Set(ids))
    }

    @Test func throttleAlwaysLetsTheLastByteThrough() {
        let throttle = ProgressThrottle(interval: 10, total: 100)
        let now = Date()
        #expect(throttle.shouldReport(10, now: now))
        #expect(!throttle.shouldReport(20, now: now.addingTimeInterval(1)))
        #expect(throttle.shouldReport(100, now: now.addingTimeInterval(2)))
        #expect(throttle.shouldReport(30, now: now.addingTimeInterval(13)))
    }

    @Test func progressFractionIsClamped() {
        #expect(UploadProgress(bytesSent: 0, totalBytes: 0).fraction == 0)
        #expect(UploadProgress(bytesSent: 25, totalBytes: 100).fraction == 0.25)
        #expect(UploadProgress(bytesSent: 150, totalBytes: 100).fraction == 1)
    }
}
