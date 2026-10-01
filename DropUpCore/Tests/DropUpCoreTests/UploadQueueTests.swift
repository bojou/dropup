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

    @Test func rejectsFoldersAndMissingFiles() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let missing = temp.directory.appendingPathComponent("gone.txt")

        let (ids, events) = await run(makeQueue(config: config), files: [temp.directory, missing])

        #expect(events.contains(.failed(id: ids[0], .unsupportedItem)))
        #expect(events.contains(.failed(id: ids[1], .unsupportedItem)))
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
