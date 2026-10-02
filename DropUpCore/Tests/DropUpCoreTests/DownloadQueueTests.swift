import Foundation
import Testing
@testable import DropUpCore

struct DownloadQueueTests {
    let config = ServerConfig(transferProtocol: .sftp, host: "example.com", username: "me", remoteDirectory: "/drops")

    private func makeQueue(_ connector: FakeConnector) -> DownloadQueue {
        DownloadQueue(connectors: connector, progressInterval: 0)
    }

    private func collect(_ queue: DownloadQueue) async -> [DownloadEvent] {
        await queue.finish()
        var events: [DownloadEvent] = []
        for await event in queue.events { events.append(event) }
        return events
    }

    private func names(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    @Test func downloadsFilesIntoTheFolderAndReportsProgress() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let connector = FakeConnector(session: FakeSession(files: ["/drops/a.txt": Data("0123456789".utf8)]))
        let queue = makeQueue(connector)

        let ids = await queue.enqueue([RemoteDownload(remotePath: "/drops/a.txt", size: 10)], from: config, password: "secret", into: temp.directory)
        await queue.waitUntilIdle()
        let events = await collect(queue)

        let id = try #require(ids.first)
        let saved = temp.directory.appendingPathComponent("a.txt")
        #expect(events == [
            .queued(id: id, fileName: "a.txt", totalBytes: 10),
            .started(id: id),
            .progress(id: id, UploadProgress(bytesSent: 5, totalBytes: 10)),
            .progress(id: id, UploadProgress(bytesSent: 10, totalBytes: 10)),
            .succeeded(id: id, localURL: saved),
        ])
        #expect(try Data(contentsOf: saved) == Data("0123456789".utf8))
        #expect(names(in: temp.directory) == ["a.txt"])
        #expect(connector.passwords == ["secret"])
    }

    @Test func aTakenNameGetsANumberInsteadOfBeingOverwritten() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        _ = try temp.file(named: "a.txt", contents: "mine")
        _ = try temp.file(named: "a-1.txt", contents: "also mine")
        let connector = FakeConnector(session: FakeSession(files: ["/drops/a.txt": Data("server".utf8)]))
        let queue = makeQueue(connector)

        await queue.enqueue([RemoteDownload(remotePath: "/drops/a.txt")], from: config, password: "secret", into: temp.directory)
        await queue.waitUntilIdle()

        #expect(names(in: temp.directory) == ["a-1.txt", "a-2.txt", "a.txt"])
        #expect(try String(contentsOf: temp.directory.appendingPathComponent("a.txt"), encoding: .utf8) == "mine")
        #expect(try String(contentsOf: temp.directory.appendingPathComponent("a-2.txt"), encoding: .utf8) == "server")
    }

    @Test func severalFilesShareOneConnectionAndAFailureDoesNotStopTheRest() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let connector = FakeConnector(session: FakeSession(files: ["/drops/a.txt": Data("a".utf8), "/drops/c.txt": Data("c".utf8)]))
        let queue = makeQueue(connector)

        let ids = await queue.enqueue(
            ["/drops/a.txt", "/drops/gone.txt", "/drops/c.txt"].map { RemoteDownload(remotePath: $0) },
            from: config, password: "secret", into: temp.directory
        )
        await queue.waitUntilIdle()
        let events = await collect(queue)

        #expect(names(in: temp.directory) == ["a.txt", "c.txt"])
        #expect(events.contains(.failed(id: ids[1], message: "The server refused: No such file (550)")))
        #expect(events.contains(.succeeded(id: ids[2], localURL: temp.directory.appendingPathComponent("c.txt"))))
        // The refusal is an ordinary answer, but a failure ends the session as uploads do, so the next file reconnects.
        #expect(connector.connectionCount == 2)
    }

    @Test func aFailedDownloadLeavesNoTemporaryFileBehind() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let session = FakeSession(files: ["/drops/a.txt": Data("0123456789".utf8)], downloadError: UploaderError.timedOut)
        let queue = makeQueue(FakeConnector(session: session))

        let ids = await queue.enqueue([RemoteDownload(remotePath: "/drops/a.txt")], from: config, password: "secret", into: temp.directory)
        await queue.waitUntilIdle()
        let events = await collect(queue)

        #expect(events.contains(.failed(id: ids[0], message: "The server stopped responding.")))
        #expect(names(in: temp.directory).isEmpty)
    }

    @Test func cancellingARunningDownloadRemovesItsPartialFile() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let session = FakeSession(files: ["/drops/big.bin": Data(count: 100)], hangAfterWritingDownload: true)
        let connector = FakeConnector(session: session)
        let queue = makeQueue(connector)

        let ids = await queue.enqueue([RemoteDownload(remotePath: "/drops/big.bin", size: 100)], from: config, password: "secret", into: temp.directory)
        // Wait until part of the file is on disk, then cancel.
        try await eventually { !names(in: temp.directory).isEmpty }
        await queue.cancel(ids[0])
        await queue.waitUntilIdle()
        let events = await collect(queue)

        #expect(events.contains(.cancelled(id: ids[0])))
        #expect(!events.contains { if case .succeeded = $0 { true } else { false } })
        #expect(names(in: temp.directory).isEmpty)
        #expect(session.closeCount == 1)
    }

    @Test func cancellingAWaitingDownloadNeverStartsIt() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let session = FakeSession(files: ["/drops/a.txt": Data("a".utf8), "/drops/b.txt": Data("b".utf8)], hangAfterWritingDownload: true)
        let queue = makeQueue(FakeConnector(session: session))

        let ids = await queue.enqueue(
            ["/drops/a.txt", "/drops/b.txt"].map { RemoteDownload(remotePath: $0) },
            from: config, password: "secret", into: temp.directory
        )
        try await eventually { session.downloads.count == 1 }
        await queue.cancelAll()
        await queue.waitUntilIdle()
        let events = await collect(queue)

        #expect(Set(events.compactMap { if case .cancelled(let id) = $0 { id } else { nil } }) == Set(ids))
        #expect(session.downloads == ["/drops/a.txt"])
        #expect(names(in: temp.directory).isEmpty)
    }

    @Test func theFileNameIsTheLastPathComponent() {
        #expect(RemoteDownload(remotePath: "/a/b/My Photo.png").fileName == "My Photo.png")
        #expect(RemoteDownload(remotePath: "/top.txt").fileName == "top.txt")
    }
}
