import Foundation
import Testing
@testable import DropUpCore

struct CopyNameTests {
    @Test func addsCopyBeforeTheExtension() {
        #expect(RemoteFileName.copyName("report.pdf", isFolder: false, among: ["report.pdf"]) == "report copy.pdf")
        #expect(RemoteFileName.copyName("archive.tar.gz", isFolder: false, among: ["archive.tar.gz"]) == "archive copy.tar.gz")
        #expect(RemoteFileName.copyName("README", isFolder: false, among: ["README"]) == "README copy")
        #expect(RemoteFileName.copyName(".env", isFolder: false, among: [".env"]) == ".env copy")
    }

    @Test func numbersTheNextCopyLikeFinder() {
        let taken = ["report.pdf", "report copy.pdf"]
        #expect(RemoteFileName.copyName("report.pdf", isFolder: false, among: taken) == "report copy 2.pdf")
        #expect(RemoteFileName.copyName("report.pdf", isFolder: false, among: taken + ["report copy 2.pdf"]) == "report copy 3.pdf")
    }

    @Test func copyingACopyDoesNotStackTheWord() {
        #expect(RemoteFileName.copyName("report copy.pdf", isFolder: false, among: ["report.pdf", "report copy.pdf"]) == "report copy 2.pdf")
        #expect(RemoteFileName.copyName("report copy 2.pdf", isFolder: false, among: ["report.pdf", "report copy.pdf", "report copy 2.pdf"]) == "report copy 3.pdf")
        // A name that is only the word keeps it.
        #expect(RemoteFileName.copyName(" copy", isFolder: false, among: [" copy"]) == " copy copy")
    }

    @Test func aFolderNameHasNoExtensionToKeep() {
        #expect(RemoteFileName.copyName("photos.2026", isFolder: true, among: ["photos.2026"]) == "photos.2026 copy")
        #expect(RemoteFileName.copyName("photos", isFolder: true, among: ["photos", "photos copy"]) == "photos copy 2")
    }
}

struct FileCopyTests {
    private let scratch: URL

    init() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("DropUpCopyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    private func file(_ name: String, size: Int64 = 4) -> RemoteEntry { RemoteEntry(name: name, kind: .file, size: size) }
    private func folder(_ name: String) -> RemoteEntry { RemoteEntry(name: name, kind: .folder) }

    private func copy(
        _ entries: [RemoteEntry],
        from: String,
        to: String,
        on server: FakeFileSystem,
        leftBehind: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> FileOperationResult {
        try await FileOperations.copy(entries, from: from, to: to, session: server, scratch: scratch, leftBehind: leftBehind)
    }

    private var scratchIsEmpty: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? ["?"]).isEmpty
    }

    @Test func duplicatesAFileInTheSameFolderUnderANewName() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt", data: Data("hello".utf8))

        let result = try await copy([file("a.txt", size: 5)], from: "/drops", to: "/drops", on: server)

        #expect(result.withoutChange == FileOperationResult(completed: 1))
        #expect(server.data(at: "/drops/a.txt") == Data("hello".utf8))
        #expect(server.data(at: "/drops/a copy.txt") == Data("hello".utf8))
        #expect(scratchIsEmpty)
    }

    @Test func aSecondDuplicateGetsTheNextNumber() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt", data: Data("x".utf8))

        _ = try await copy([file("a.txt", size: 1)], from: "/drops", to: "/drops", on: server)
        _ = try await copy([file("a.txt", size: 1)], from: "/drops", to: "/drops", on: server)

        #expect(server.paths(under: "/drops") == ["/drops/a copy 2.txt", "/drops/a copy.txt", "/drops/a.txt"])
    }

    @Test func copiesToAnotherFolderWithTheSameNameAndNeverReplaces() async throws {
        let server = FakeFileSystem()
            .addFile("/drops/a.txt", data: Data("new".utf8))
            .addFile("/drops/b.txt", data: Data("bee".utf8))
            .addFile("/other/a.txt", data: Data("old".utf8))

        let result = try await copy([file("a.txt", size: 3), file("b.txt", size: 3)], from: "/drops", to: "/other", on: server)

        #expect(result.completed == 2)
        #expect(server.data(at: "/other/a.txt") == Data("old".utf8))
        #expect(server.data(at: "/other/a copy.txt") == Data("new".utf8))
        #expect(server.data(at: "/other/b.txt") == Data("bee".utf8))
        #expect(server.data(at: "/drops/a.txt") == Data("new".utf8))
    }

    @Test func copiesAFolderWithEverythingInsideAndLeavesLinksOut() async throws {
        let server = FakeFileSystem()
            .addFile("/drops/photos/a.jpg", data: Data("A".utf8))
            .addFile("/drops/photos/sub/deep/b.jpg", data: Data("BB".utf8))
            .addFolder("/drops/photos/empty")
            .addLink("/drops/photos/shortcut", to: "/secret")
            .addFile("/secret/passwords.txt", data: Data("no".utf8))

        let result = try await copy([folder("photos")], from: "/drops", to: "/drops", on: server)

        #expect(result.withoutChange == FileOperationResult(completed: 1, skipped: 1))
        #expect(server.data(at: "/drops/photos copy/a.jpg") == Data("A".utf8))
        #expect(server.data(at: "/drops/photos copy/sub/deep/b.jpg") == Data("BB".utf8))
        #expect(server.exists("/drops/photos copy/empty"))
        #expect(!server.exists("/drops/photos copy/shortcut"))
        #expect(server.paths(under: "/drops/photos").contains("/drops/photos/shortcut"))
        #expect(scratchIsEmpty)
    }

    @Test func aFolderCantBeCopiedIntoItselfOrBelowItself() async throws {
        let server = FakeFileSystem().addFile("/drops/photos/a.jpg", data: Data("A".utf8)).addFolder("/drops/photos/sub")
        let before = server.paths()

        let into = try await copy([folder("photos")], from: "/drops", to: "/drops/photos", on: server)
        let below = try await copy([folder("photos")], from: "/drops", to: "/drops/photos/sub", on: server)

        let message = FileOperationError.copiedIntoItself.errorDescription
        #expect(into.failures == [FileOperationFailure(name: "photos", message: message!)])
        #expect(below.failures == [FileOperationFailure(name: "photos", message: message!)])
        #expect(server.paths() == before)
    }

    @Test func aLinkIsNotCopied() async throws {
        let server = FakeFileSystem().addLink("/drops/shortcut", to: "/elsewhere").addFile("/drops/a.txt", data: Data("A".utf8))

        let result = try await copy([RemoteEntry(name: "shortcut", kind: .link), file("a.txt", size: 1)], from: "/drops", to: "/drops", on: server)

        #expect(result.completed == 1)
        #expect(result.failures == [FileOperationFailure(name: "shortcut", message: FileOperationError.cantCopyLink.errorDescription!)])
        #expect(!server.exists("/drops/shortcut copy"))
        #expect(server.exists("/drops/a copy.txt"))
    }

    @Test func aFileTheServerWontGiveUpIsReportedAndTheRestGoOn() async throws {
        let server = FakeFileSystem()
            .addFile("/drops/locked.txt", data: Data("L".utf8))
            .addFile("/drops/ok.txt", data: Data("O".utf8))
        server.fail("/drops/locked.txt", with: UploaderError.serverRejected(code: 550, message: "Permission denied"))

        let result = try await copy([file("locked.txt", size: 1), file("ok.txt", size: 1)], from: "/drops", to: "/drops", on: server)

        #expect(result.completed == 1)
        #expect(result.failures.map(\.name) == ["locked.txt"])
        #expect(result.failures[0].message.contains("Permission denied"))
        #expect(server.exists("/drops/ok copy.txt"))
        #expect(!server.exists("/drops/locked copy.txt"))
    }

    @Test func aFileInsideAFolderThatCantBeReadStopsThatFolderAndSaysSo() async throws {
        let server = FakeFileSystem()
            .addFile("/drops/box/a.txt", data: Data("A".utf8))
            .addFile("/drops/box/b.txt", data: Data("B".utf8))
            .addFile("/drops/ok.txt", data: Data("O".utf8))
        server.fail("/drops/box/b.txt", with: UploaderError.serverRejected(code: 550, message: "Permission denied"))

        let result = try await copy([folder("box"), file("ok.txt", size: 1)], from: "/drops", to: "/drops", on: server)

        #expect(result.completed == 1)
        #expect(result.failures.count == 1)
        #expect(result.failures[0].name == "box")
        #expect(result.failures[0].message.contains("b.txt"))
        #expect(result.failures[0].message.contains("Part of it was copied"))
        #expect(server.exists("/drops/ok copy.txt"))
    }

    @Test func aLostConnectionStopsTheWholeCopy() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt", data: Data("A".utf8)).addFile("/drops/b.txt", data: Data("B".utf8))
        server.fail("/drops/a.txt", with: UploaderError.connectionFailed("gone"))

        await #expect(throws: UploaderError.connectionFailed("gone")) {
            _ = try await copy([file("a.txt", size: 1), file("b.txt", size: 1)], from: "/drops", to: "/drops", on: server)
        }
        #expect(!server.exists("/drops/b copy.txt"))
    }

    @Test func cancellingMidUploadAsksForTheHalfSentFileToBeRemoved() async throws {
        let server = FakeFileSystem().addFile("/drops/big.bin", data: Data("data".utf8))
        server.hangUpload(of: "/drops/big copy.bin")
        let leftovers = Leftovers()

        let task = Task {
            try await copy([file("big.bin", size: 4)], from: "/drops", to: "/drops", on: server) { await leftovers.add($0) }
        }
        try await eventually { server.uploads == ["/drops/big copy.bin"] }
        task.cancel()

        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await leftovers.paths == ["/drops/big copy.bin"])
        #expect(scratchIsEmpty)
    }

    @Test func aServerRefusalAfterTheFileWasCreatedStopsEverythingAndCleansUp() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt", data: Data("A".utf8)).addFile("/drops/b.txt", data: Data("B".utf8))
        server.failUpload(of: "/drops/a copy.txt", with: UploaderError.serverRejected(code: 552, message: "Quota exceeded"))
        let leftovers = Leftovers()

        await #expect(throws: UploaderError.serverRejected(code: 552, message: "Quota exceeded")) {
            _ = try await copy([file("a.txt", size: 1), file("b.txt", size: 1)], from: "/drops", to: "/drops", on: server) { await leftovers.add($0) }
        }
        #expect(await leftovers.paths == ["/drops/a copy.txt"])
        #expect(server.uploads == ["/drops/a copy.txt"])
    }

    @Test func reportsProgressThatReachesTheEnd() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt", data: Data("abcd".utf8))
        let seen = Seen()

        _ = try await FileOperations.copy([file("a.txt", size: 4)], from: "/drops", to: "/drops", session: server, scratch: scratch, progress: { seen.add($0) })

        let all = seen.values
        #expect(all.allSatisfy { $0.name == "a.txt" && $0.total == 8 })
        #expect(all.map(\.done) == all.map(\.done).sorted())
        #expect(all.last?.fraction == 1)
    }
}

private actor Leftovers {
    var paths: [String] = []
    func add(_ path: String) { paths.append(path) }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [CopyProgress] = []
    var values: [CopyProgress] { lock.withLock { _values } }
    func add(_ progress: CopyProgress) { lock.withLock { _values.append(progress) } }
}

struct BrowseSessionCopyTests {
    let config = ServerConfig(transferProtocol: .sftp, host: "example.com", username: "me", remoteDirectory: "/drops")
    private let scratchParent: URL

    init() throws {
        scratchParent = FileManager.default.temporaryDirectory.appendingPathComponent("DropUpBrowseCopyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchParent, withIntermediateDirectories: true)
    }

    private func makeBrowser(_ server: FakeFileSystem) -> (BrowseSession, FakeFileSystemConnector) {
        let connector = FakeFileSystemConnector(server)
        return (BrowseSession(connectors: connector, config: config, password: "secret", scratchParent: scratchParent), connector)
    }

    private var scratchIsEmpty: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: scratchParent.path)) ?? ["?"]).isEmpty
    }

    @Test func copiesAndCleansUpItsScratchFolder() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt", data: Data("A".utf8))
        let (browser, _) = makeBrowser(server)

        let result = try await browser.copy([RemoteEntry(name: "a.txt", kind: .file, size: 1)], from: "/drops", to: "/drops")

        #expect(result.completed == 1)
        #expect(server.data(at: "/drops/a copy.txt") == Data("A".utf8))
        #expect(scratchIsEmpty)
    }

    @Test func aStaleLoginBeforeAnythingChangedIsRetriedOnce() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt", data: Data("A".utf8))
        let (browser, connector) = makeBrowser(server)
        _ = try await browser.entries(atPath: "/drops")
        server.failNextCommand(with: UploaderError.connectionFailed("The server closed the connection."))

        let result = try await browser.copy([RemoteEntry(name: "a.txt", kind: .file, size: 1)], from: "/drops", to: "/drops")

        #expect(result.completed == 1)
        #expect(connector.connectionCount == 2)
        #expect(server.paths(under: "/drops") == ["/drops/a copy.txt", "/drops/a.txt"])
    }

    @Test func aConnectionThatDiesAfterTheCopyStartedIsNotStartedOver() async throws {
        let server = FakeFileSystem()
            .addFile("/drops/a.txt", data: Data("A".utf8))
            .addFile("/drops/b.txt", data: Data("B".utf8))
        server.fail("/drops/b.txt", with: UploaderError.connectionFailed("gone"))
        let (browser, connector) = makeBrowser(server)
        // A login that is already open is the one a failure would be retried on.
        _ = try await browser.entries(atPath: "/drops")
        let entries = [RemoteEntry(name: "a.txt", kind: .file, size: 1), RemoteEntry(name: "b.txt", kind: .file, size: 1)]

        await #expect(throws: UploaderError.connectionFailed("gone")) {
            _ = try await browser.copy(entries, from: "/drops", to: "/drops")
        }

        // a.txt was copied once; starting over would have made "a copy 2.txt" too.
        #expect(server.paths(under: "/drops") == ["/drops/a copy.txt", "/drops/a.txt", "/drops/b.txt"])
        #expect(connector.connectionCount == 1)
        #expect(scratchIsEmpty)
    }

    @Test func cancellingMidUploadRemovesTheHalfSentFileOverANewConnection() async throws {
        let server = FakeFileSystem().addFile("/drops/big.bin", data: Data("data".utf8))
        server.hangUpload(of: "/drops/big copy.bin")
        let (browser, connector) = makeBrowser(server)

        let task = Task {
            try await browser.copy([RemoteEntry(name: "big.bin", kind: .file, size: 4)], from: "/drops", to: "/drops")
        }
        try await eventually { server.uploads == ["/drops/big copy.bin"] }
        task.cancel()

        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!server.exists("/drops/big copy.bin"))
        #expect(server.exists("/drops/big.bin"))
        #expect(connector.connectionCount == 2)
        #expect(scratchIsEmpty)
    }
}
