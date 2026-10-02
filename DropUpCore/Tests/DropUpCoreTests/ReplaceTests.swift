import Foundation
import Testing
@testable import DropUpCore

/// Moving and copying onto a name that is taken: keep both, or let a file replace a file.
struct MoveConflictTests {
    private func file(_ name: String) -> RemoteEntry { RemoteEntry(name: name, kind: .file, size: 3) }
    private func folder(_ name: String) -> RemoteEntry { RemoteEntry(name: name, kind: .folder) }

    private func hiddenFiles(_ server: FakeFileSystem) -> [String] {
        server.paths().filter { $0.split(separator: "/").last?.hasPrefix(".") == true }
    }

    @Test func keepingBothAddsTheFirstFreeNumber() async throws {
        let server = FakeFileSystem()
            .addFile("/drops/a.txt", data: Data("new".utf8))
            .addFile("/target/a.txt", data: Data("old".utf8))
            .addFile("/target/a-1.txt", data: Data("older".utf8))

        let result = try await FileOperations.move([file("a.txt")], from: "/drops", to: "/target", policy: .keepBoth, session: server)

        #expect(result.completed == 1 && result.renamed == 1 && result.replaced == 0 && result.failures.isEmpty)
        #expect(server.data(at: "/target/a-2.txt") == Data("new".utf8))
        #expect(server.data(at: "/target/a.txt") == Data("old".utf8))
        #expect(result.change == .moved([ItemMove(from: "/drops/a.txt", to: "/target/a-2.txt")]))
    }

    @Test(arguments: [false, true])
    func replacingPutsTheNewFileInPlaceOfTheOldOne(serverReplacesOnRename: Bool) async throws {
        // A strict server refuses a rename onto a name that exists, a lax one overwrites silently. Both must end the same.
        let server = FakeFileSystem()
            .addFile("/drops/a.txt", data: Data("new".utf8))
            .addFile("/drops/b.txt", data: Data("b".utf8))
            .addFile("/target/a.txt", data: Data("old".utf8))
        server.replacesOnRename = serverReplacesOnRename

        let result = try await FileOperations.move([file("a.txt"), file("b.txt")], from: "/drops", to: "/target", policy: .replace, session: server)

        #expect(result.completed == 2 && result.replaced == 1 && result.renamed == 0 && result.failures.isEmpty)
        #expect(server.data(at: "/target/a.txt") == Data("new".utf8))
        #expect(server.data(at: "/target/b.txt") == Data("b".utf8))
        #expect(server.paths() == ["/drops", "/target", "/target/a.txt", "/target/b.txt"])
        // Only the plain move can be taken back. The replaced file is gone for good.
        #expect(result.change == .moved([ItemMove(from: "/drops/b.txt", to: "/target/b.txt")]))
    }

    @Test func theOldFileIsOnlyDeletedOnceTheNewOneIsInPlace() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt").addFile("/target/a.txt")
        _ = try await FileOperations.move([file("a.txt")], from: "/drops", to: "/target", policy: .replace, session: server)

        let log = server.log.filter { $0.hasPrefix("RENAME") || $0.hasPrefix("DELE") }
        #expect(log.count == 3)
        #expect(log[0].hasPrefix("RENAME /target/a.txt /target/.a.txt.replaced-"))
        #expect(log[1] == "RENAME /drops/a.txt /target/a.txt")
        #expect(log[2].hasPrefix("DELE /target/.a.txt.replaced-"))
    }

    @Test(arguments: [
        ("folder", "folder"),
        ("file", "folder"),
        ("folder", "file"),
    ])
    func replacingNeverTouchesAFolderOrPutsOneInTheWay(moving: String, there: String) async throws {
        let server = FakeFileSystem()
        if moving == "folder" { server.addFile("/drops/x/inside.txt", data: Data("1".utf8)) } else { server.addFile("/drops/x", data: Data("1".utf8)) }
        if there == "folder" { server.addFile("/target/x/other.txt", data: Data("2".utf8)) } else { server.addFile("/target/x", data: Data("2".utf8)) }
        let entry = moving == "folder" ? folder("x") : file("x")

        let result = try await FileOperations.move([entry], from: "/drops", to: "/target", policy: .replace, session: server)

        #expect(result.completed == 0 && result.replaced == 0)
        #expect(result.failures == [FileOperationFailure(name: "x", message: FileOperationError.cantReplace("x").errorDescription!)])
        #expect(server.exists("/drops/x"))
        #expect(!server.log.contains { $0.hasPrefix("RENAME") })
        #expect(result.change == nil)
    }

    @Test func aFailureAfterTheOldFileWasPushedAsidePutsItBack() async throws {
        let server = FakeFileSystem()
            .addFile("/drops/a.txt", data: Data("new".utf8))
            .addFile("/target/a.txt", data: Data("old".utf8))
        server.fail("/drops/a.txt", with: UploaderError.serverRejected(code: 550, message: "Permission denied"))

        let result = try await FileOperations.move([file("a.txt")], from: "/drops", to: "/target", policy: .replace, session: server)

        #expect(result.completed == 0 && result.replaced == 0)
        #expect(result.failures.first?.message.contains("Permission denied") == true)
        #expect(server.data(at: "/target/a.txt") == Data("old".utf8))
        #expect(server.data(at: "/drops/a.txt") == Data("new".utf8))
        #expect(hiddenFiles(server).isEmpty)
    }

    @Test func aCancelAfterTheOldFileWasPushedAsidePutsItBack() async throws {
        let server = FakeFileSystem()
            .addFile("/drops/a.txt", data: Data("new".utf8))
            .addFile("/target/a.txt", data: Data("old".utf8))
        server.fail("/drops/a.txt", with: CancellationError())

        await #expect(throws: CancellationError.self) {
            _ = try await FileOperations.move([file("a.txt")], from: "/drops", to: "/target", policy: .replace, session: server)
        }

        #expect(server.data(at: "/target/a.txt") == Data("old".utf8))
        #expect(hiddenFiles(server).isEmpty)
    }

    @Test func anOldFileThatCannotBeDeletedIsReportedNotHidden() async throws {
        let server = FakeFileSystem()
            .addFile("/drops/a.txt", data: Data("new".utf8))
            .addFile("/target/a.txt", data: Data("old".utf8))
        server.fail(pathsContaining: ".replaced-", with: UploaderError.serverRejected(code: 550, message: "Permission denied"))

        let result = try await FileOperations.move([file("a.txt")], from: "/drops", to: "/target", policy: .replace, session: server)

        #expect(result.completed == 1 && result.replaced == 1 && result.failures.isEmpty)
        #expect(server.data(at: "/target/a.txt") == Data("new".utf8))
        let left = try #require(result.leftOver.first)
        #expect(server.data(at: left) == Data("old".utf8))
        #expect(result.summary(verb: "moved")?.contains("still on the server") == true)
    }
}

struct CopyConflictTests {
    private let scratch: URL

    init() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("DropUpReplaceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    private func file(_ name: String, size: Int64 = 3) -> RemoteEntry { RemoteEntry(name: name, kind: .file, size: size) }
    private func folder(_ name: String) -> RemoteEntry { RemoteEntry(name: name, kind: .folder) }

    private func copy(_ entries: [RemoteEntry], from: String, to: String, policy: ConflictPolicy, on server: FakeFileSystem) async throws -> FileOperationResult {
        try await FileOperations.copy(entries, from: from, to: to, policy: policy, session: server, scratch: scratch)
    }

    private func hiddenFiles(_ server: FakeFileSystem) -> [String] {
        server.paths().filter { $0.split(separator: "/").last?.hasPrefix(".") == true }
    }

    @Test(arguments: [false, true])
    func replacingSendsTheCopyNextToTheOldFileThenSwapsThem(serverReplacesOnRename: Bool) async throws {
        let server = FakeFileSystem()
            .addFile("/drops/a.txt", data: Data("new".utf8))
            .addFile("/target/a.txt", data: Data("old".utf8))
        server.replacesOnRename = serverReplacesOnRename

        let result = try await copy([file("a.txt")], from: "/drops", to: "/target", policy: .replace, on: server)

        #expect(result.completed == 1 && result.replaced == 1 && result.failures.isEmpty)
        #expect(server.data(at: "/target/a.txt") == Data("new".utf8))
        #expect(server.data(at: "/drops/a.txt") == Data("new".utf8))
        #expect(hiddenFiles(server).isEmpty)
        // The upload never touched the old file's name.
        #expect(server.uploads.count == 1)
        #expect(server.uploads[0].hasPrefix("/target/.a.txt.copying-"))
    }

    @Test func aFailedUploadLeavesTheOldFileWhole() async throws {
        let server = FakeFileSystem()
            .addFile("/drops/a.txt", data: Data("new".utf8))
            .addFile("/target/a.txt", data: Data("old".utf8))
        server.fail(pathsContaining: ".copying-", with: UploaderError.serverRejected(code: 552, message: "Disk full"))

        let result = try await copy([file("a.txt")], from: "/drops", to: "/target", policy: .replace, on: server)

        #expect(result.completed == 0 && result.replaced == 0)
        #expect(result.failures.first?.message.contains("Disk full") == true)
        #expect(server.data(at: "/target/a.txt") == Data("old".utf8))
        #expect(hiddenFiles(server).isEmpty)
    }

    @Test func aSwapThatFailsRemovesTheHiddenUploadAndKeepsTheOldFile() async throws {
        let server = FakeFileSystem()
            .addFile("/drops/a.txt", data: Data("new".utf8))
            .addFile("/target/a.txt", data: Data("old".utf8))
        // The upload and the first rename go through; moving the hidden upload into place is refused.
        server.fail(pathsContaining: ".copying-", during: "RENAME", with: UploaderError.serverRejected(code: 550, message: "Permission denied"))

        let result = try await copy([file("a.txt")], from: "/drops", to: "/target", policy: .replace, on: server)

        #expect(result.completed == 0 && result.replaced == 0)
        #expect(result.failures.first?.message.contains("Permission denied") == true)
        #expect(server.data(at: "/target/a.txt") == Data("old".utf8))
        #expect(hiddenFiles(server).isEmpty)
    }

    @Test func copyingIntoTheSameFolderStillMakesACopyEvenWhenReplacing() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt", data: Data("A".utf8))

        let result = try await copy([file("a.txt")], from: "/drops", to: "/drops", policy: .replace, on: server)

        #expect(result.completed == 1 && result.replaced == 0)
        #expect(server.data(at: "/drops/a copy.txt") == Data("A".utf8))
        #expect(server.data(at: "/drops/a.txt") == Data("A".utf8))
    }

    @Test func aFolderIsNeverReplacedByACopyEvenWhenReplacing() async throws {
        let server = FakeFileSystem()
            .addFile("/drops/x/one.txt", data: Data("1".utf8))
            .addFile("/target/x/two.txt", data: Data("2".utf8))

        let result = try await copy([folder("x")], from: "/drops", to: "/target", policy: .replace, on: server)

        #expect(result.completed == 1 && result.replaced == 0)
        #expect(server.data(at: "/target/x/two.txt") == Data("2".utf8))
        #expect(server.data(at: "/target/x copy/one.txt") == Data("1".utf8))
    }

    @Test func keepingBothMakesACopyEvenInAnotherFolder() async throws {
        let server = FakeFileSystem()
            .addFile("/drops/a.txt", data: Data("new".utf8))
            .addFile("/target/a.txt", data: Data("old".utf8))

        let result = try await copy([file("a.txt")], from: "/drops", to: "/target", policy: .keepBoth, on: server)

        #expect(result.replaced == 0)
        #expect(server.data(at: "/target/a.txt") == Data("old".utf8))
        #expect(server.data(at: "/target/a copy.txt") == Data("new".utf8))
    }
}
