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
        #expect(events == [
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
        let connector = FakeConnector(session: FakeSession(error: UploaderError.timedOut))
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
