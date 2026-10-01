import Foundation
import Testing
@testable import DropUpCore

struct UploadQueueTests {
    let config = ServerConfig(transferProtocol: .sftp, host: "example.com", username: "me", remoteDirectory: "/drops")

    private func makeQueue(
        config: ServerConfig?,
        password: String? = "secret",
        uploader: FakeUploader = FakeUploader()
    ) -> UploadQueue {
        let credentials = InMemoryCredentialStore()
        if let config, let password {
            try? credentials.setPassword(password, for: config.credentialKey)
        }
        return UploadQueue(
            settings: InMemorySettingsStore(config: config),
            credentials: credentials,
            uploaderFactory: FakeUploaderFactory(uploader: uploader)
        )
    }

    /// Runs the queue to completion and returns every event it emitted.
    private func run(_ queue: UploadQueue, files: [URL]) async -> (ids: [UUID], events: [UploadEvent]) {
        let ids = await queue.enqueue(files)
        await queue.waitUntilIdle()
        await queue.finish()
        var events: [UploadEvent] = []
        for await event in queue.events {
            events.append(event)
        }
        return (ids, events)
    }

    @Test func uploadsFileToConfiguredDirectoryWithStoredPassword() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "photo.png")
        let uploader = FakeUploader()

        let (ids, events) = await run(makeQueue(config: config, uploader: uploader), files: [file])

        let id = try #require(ids.first)
        #expect(events == [
            .queued(id: id, fileName: "photo.png"),
            .started(id: id),
            .progress(id: id, UploadProgress(bytesSent: 50, totalBytes: 100)),
            .progress(id: id, UploadProgress(bytesSent: 100, totalBytes: 100)),
            .succeeded(id: id, remotePath: "/drops/photo.png"),
        ])
        #expect(uploader.requests == [
            UploadRequest(fileURL: file, remotePath: "/drops/photo.png", config: config, password: "secret"),
        ])
    }

    @Test func uploadsSeveralFilesInDropOrder() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let files = try ["a.txt", "b.txt", "c.txt"].map { try temp.file(named: $0) }
        let uploader = FakeUploader()

        let (ids, events) = await run(makeQueue(config: config, uploader: uploader), files: files)

        #expect(uploader.requests.map(\.remotePath) == ["/drops/a.txt", "/drops/b.txt", "/drops/c.txt"])
        let succeeded = events.compactMap { event -> UUID? in
            if case .succeeded(let id, _) = event { return id }
            return nil
        }
        #expect(succeeded == ids)
    }

    @Test func failsWithNotConfiguredWhenNoSettings() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "a.txt")
        let uploader = FakeUploader()

        let (ids, events) = await run(makeQueue(config: nil, uploader: uploader), files: [file])

        #expect(events.last == .failed(id: ids[0], .notConfigured))
        #expect(uploader.requests.isEmpty)
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

    @Test func reportsUploaderErrorsAndKeepsGoing() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let uploader = FakeUploader(error: UploaderError.authenticationFailed)
        let files = try ["a.txt", "b.txt"].map { try temp.file(named: $0) }

        let (ids, events) = await run(makeQueue(config: config, uploader: uploader), files: files)

        #expect(uploader.requests.count == 2)
        let failures = events.filter {
            if case .failed = $0 { return true }
            return false
        }
        #expect(failures.count == 2)
        #expect(events.contains(.failed(id: ids[1], .transfer(String(describing: UploaderError.authenticationFailed)))))
    }

    @Test func picksUpSettingsChangesBetweenUploads() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let settings = InMemorySettingsStore(config: config)
        let credentials = InMemoryCredentialStore()
        let moved = ServerConfig(transferProtocol: .sftp, host: "example.com", username: "me", remoteDirectory: "/elsewhere")
        try credentials.setPassword("secret", for: config.credentialKey)
        let uploader = FakeUploader()
        let queue = UploadQueue(settings: settings, credentials: credentials, uploaderFactory: FakeUploaderFactory(uploader: uploader))

        let first = try temp.file(named: "a.txt")
        let second = try temp.file(named: "b.txt")

        await queue.enqueue([first])
        await queue.waitUntilIdle()
        try settings.saveServerConfig(moved)
        await queue.enqueue([second])
        await queue.waitUntilIdle()

        #expect(uploader.requests.map(\.remotePath) == ["/drops/a.txt", "/elsewhere/b.txt"])
    }

    @Test func progressFractionIsClamped() {
        #expect(UploadProgress(bytesSent: 0, totalBytes: 0).fraction == 0)
        #expect(UploadProgress(bytesSent: 25, totalBytes: 100).fraction == 0.25)
        #expect(UploadProgress(bytesSent: 150, totalBytes: 100).fraction == 1)
    }
}
