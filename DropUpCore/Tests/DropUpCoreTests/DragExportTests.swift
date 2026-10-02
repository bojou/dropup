import Foundation
import Testing
@testable import DropUpCore

struct DragExportTests {
    let config = ServerConfig(transferProtocol: .sftp, host: "example.com", username: "me", remoteDirectory: "/drops")
    private let parent: URL

    init() throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("DropUpDragTests-\(UUID().uuidString)")
    }

    private func makeExport(_ server: FakeFileSystem) -> DragExport {
        DragExport(connectors: FakeFileSystemConnector(server), parent: parent)
    }

    private func contents(of url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    @Test func fetchesAFileUnderItsOwnNameAndReportsProgress() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt", data: Data("0123456789".utf8))
        let export = makeExport(server)
        let seen = Seen()

        let url = try await export.fetch(RemoteDownload(remotePath: "/drops/a.txt", size: 10), from: config, password: "secret") { seen.add($0) }

        #expect(url.lastPathComponent == "a.txt")
        #expect(url.path.hasPrefix(parent.path))
        #expect(try Data(contentsOf: url) == Data("0123456789".utf8))
        #expect(seen.values.last == UploadProgress(bytesSent: 10, totalBytes: 10))
        #expect(contents(of: url.deletingLastPathComponent()) == ["a.txt"])
    }

    @Test func fetchesAFolderAsAFolderWithoutItsLinks() async throws {
        let server = FakeFileSystem()
            .addFile("/drops/photos/a.jpg", data: Data("A".utf8))
            .addFile("/drops/photos/sub/b.jpg", data: Data("B".utf8))
            .addLink("/drops/photos/shortcut", to: "/secret")
            .addFile("/secret/passwords.txt", data: Data("no".utf8))
        let export = makeExport(server)

        let url = try await export.fetch(RemoteDownload(remotePath: "/drops/photos", isFolder: true), from: config, password: "secret")

        #expect(url.lastPathComponent == "photos")
        #expect(contents(of: url) == ["a.jpg", "sub"])
        #expect(try Data(contentsOf: url.appendingPathComponent("sub/b.jpg")) == Data("B".utf8))
    }

    @Test func eachFetchGetsAFolderOfItsOwn() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt", data: Data("1".utf8))
        let export = makeExport(server)

        let first = try await export.fetch(RemoteDownload(remotePath: "/drops/a.txt"), from: config, password: "secret")
        let second = try await export.fetch(RemoteDownload(remotePath: "/drops/a.txt"), from: config, password: "secret")

        #expect(first != second)
        #expect(first.lastPathComponent == "a.txt" && second.lastPathComponent == "a.txt")
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test func aRefusedFetchSaysWhyAndLeavesNothingBehind() async throws {
        let server = FakeFileSystem()
        let export = makeExport(server)

        let error = try await #require(throws: DragExportError.self) {
            _ = try await export.fetch(RemoteDownload(remotePath: "/drops/missing.txt"), from: config, password: "secret")
        }

        #expect(error.message.contains("No such file"))
        #expect(contents(of: parent) == [])
    }

    @Test func cancellingStopsTheFetchAndLeavesNothingBehind() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt", data: Data("0123456789".utf8))
        server.slowDown(milliseconds: 200)
        let export = makeExport(server)

        let task = Task {
            try await export.fetch(RemoteDownload(remotePath: "/drops/a.txt", size: 10), from: config, password: "secret")
        }
        try await eventually { server.log.contains("RETR /drops/a.txt") }
        task.cancel()

        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(contents(of: parent) == [])
    }

    @Test func removingFetchedFilesClearsTheLot() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt", data: Data("1".utf8))
        let export = makeExport(server)
        _ = try await export.fetch(RemoteDownload(remotePath: "/drops/a.txt"), from: config, password: "secret")
        #expect(FileManager.default.fileExists(atPath: parent.path))

        await export.removeFetchedFiles()

        #expect(!FileManager.default.fileExists(atPath: parent.path))
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [UploadProgress] = []
    var values: [UploadProgress] { lock.withLock { _values } }
    func add(_ progress: UploadProgress) { lock.withLock { _values.append(progress) } }
}
