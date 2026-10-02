import Foundation
import Testing
@testable import DropUpCore

struct FileOperationsTests {
    private func file(_ name: String) -> RemoteEntry { RemoteEntry(name: name, kind: .file, size: 10) }
    private func folder(_ name: String) -> RemoteEntry { RemoteEntry(name: name, kind: .folder) }

    // MARK: Names

    @Test func acceptsOrdinaryNamesAndTrimsTheEnds() throws {
        #expect(try RemoteFileName.validated("report.pdf") == "report.pdf")
        #expect(try RemoteFileName.validated("  my folder \n") == "my folder")
        #expect(try RemoteFileName.validated(".htaccess") == ".htaccess")
    }

    @Test(arguments: ["", "   ", ".", "..", "a/b", "/", "line\nbreak", "tab\there", "nul\0byte", "a\r\nb"])
    func refusesNamesTheServerCouldNotTakeAsOne(_ name: String) {
        #expect(throws: FileOperationError.invalidName) { try RemoteFileName.validated(name) }
    }

    @Test func picksTheFirstUnusedFolderName() {
        #expect(RemoteFileName.unusedName("untitled folder", among: ["a", "b"]) == "untitled folder")
        #expect(RemoteFileName.unusedName("untitled folder", among: ["untitled folder"]) == "untitled folder 2")
        #expect(RemoteFileName.unusedName("untitled folder", among: ["untitled folder", "untitled folder 2"]) == "untitled folder 3")
    }

    // MARK: New folder

    @Test func createsAFolder() async throws {
        let server = FakeFileSystem().addFolder("/drops")
        try await FileOperations.makeFolder(named: "  photos ", in: "/drops/", session: server)
        #expect(server.exists("/drops/photos"))
    }

    @Test func aFolderThatExistsIsRefusedByTheServer() async throws {
        let server = FakeFileSystem().addFolder("/drops/photos")
        await #expect(throws: UploaderError.serverRejected(code: 550, message: "File exists")) {
            try await FileOperations.makeFolder(named: "photos", in: "/drops", session: server)
        }
    }

    @Test func aBadFolderNameNeverReachesTheServer() async throws {
        let server = FakeFileSystem().addFolder("/drops")
        await #expect(throws: FileOperationError.invalidName) {
            try await FileOperations.makeFolder(named: "../etc", in: "/drops", session: server)
        }
        #expect(server.log.isEmpty)
    }

    // MARK: Rename

    @Test func renamesAFile() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt")
        try await FileOperations.rename(file("a.txt"), to: "b.txt", in: "/drops", session: server)
        #expect(server.exists("/drops/b.txt"))
        #expect(!server.exists("/drops/a.txt"))
    }

    @Test func renamingAFolderKeepsWhatIsInside() async throws {
        let server = FakeFileSystem().addFile("/drops/old/one.txt").addFile("/drops/old/deep/two.txt")
        try await FileOperations.rename(folder("old"), to: "new", in: "/drops", session: server)
        #expect(server.paths(under: "/drops") == ["/drops/new", "/drops/new/deep", "/drops/new/deep/two.txt", "/drops/new/one.txt"])
    }

    @Test func renamingToTheSameNameDoesNothing() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt")
        try await FileOperations.rename(file("a.txt"), to: " a.txt ", in: "/drops", session: server)
        #expect(server.log.isEmpty)
    }

    @Test func renamingOntoAnotherItemIsRefusedBeforeAnythingIsSent() async throws {
        // A lax server would replace the file, so the check has to come from us.
        let server = FakeFileSystem().addFile("/drops/a.txt").addFile("/drops/b.txt")
        server.replacesOnRename = true
        await #expect(throws: FileOperationError.alreadyExists("b.txt")) {
            try await FileOperations.rename(file("a.txt"), to: "b.txt", in: "/drops", session: server)
        }
        #expect(server.exists("/drops/a.txt") && server.exists("/drops/b.txt"))
        #expect(!server.log.contains { $0.hasPrefix("RENAME") })
    }

    @Test func aBadNameIsRefusedWithoutAskingTheServer() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt")
        await #expect(throws: FileOperationError.invalidName) {
            try await FileOperations.rename(file("a.txt"), to: "x/y", in: "/drops", session: server)
        }
        #expect(server.log.isEmpty)
    }

    // MARK: Move

    @Test func movesSeveralItemsIntoAFolder() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt").addFile("/drops/sub/b.txt").addFolder("/drops/target")
        let result = try await FileOperations.move([file("a.txt"), folder("sub")], from: "/drops", to: "/drops/target", session: server)

        #expect(result.withoutChange == FileOperationResult(completed: 2, failures: []))
        #expect(server.paths(under: "/drops") == ["/drops/target", "/drops/target/a.txt", "/drops/target/sub", "/drops/target/sub/b.txt"])
    }

    @Test func movingToTheFolderItIsInDoesNothing() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt")
        let result = try await FileOperations.move([file("a.txt")], from: "/drops", to: "/drops/", session: server)
        #expect(result == FileOperationResult())
        #expect(server.log.isEmpty)
    }

    @Test func aTakenNameGetsANumberWhenKeepingBothAndTheRestStillMove() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt").addFile("/drops/b.txt").addFile("/target/a.txt")
        server.replacesOnRename = true
        let result = try await FileOperations.move([file("a.txt"), file("b.txt")], from: "/drops", to: "/target", session: server)

        #expect(result.completed == 2 && result.failures.isEmpty && result.renamed == 1)
        #expect(server.paths(under: "/target") == ["/target/a-1.txt", "/target/a.txt", "/target/b.txt"])
        #expect(!server.exists("/drops/a.txt"))
    }

    @Test func aFolderCannotGoIntoItselfOrBelowItself() async throws {
        let server = FakeFileSystem().addFolder("/drops/a/b")
        let into = try await FileOperations.move([folder("a")], from: "/drops", to: "/drops/a", session: server)
        let below = try await FileOperations.move([folder("a")], from: "/drops", to: "/drops/a/b", session: server)

        #expect(into.failures.map(\.name) == ["a"])
        #expect(below.failures.map(\.name) == ["a"])
        #expect(into.failures.first?.message == FileOperationError.movedIntoItself.errorDescription)
        #expect(server.exists("/drops/a/b"))
        #expect(!server.log.contains { $0.hasPrefix("RENAME") })
    }

    @Test func aFolderMayGoNextToOneWithTheSamePrefix() async throws {
        let server = FakeFileSystem().addFolder("/drops/a").addFolder("/drops/ab")
        let result = try await FileOperations.move([folder("a")], from: "/drops", to: "/drops/ab", session: server)
        #expect(result.withoutChange == FileOperationResult(completed: 1, failures: []))
        #expect(server.exists("/drops/ab/a"))
    }

    @Test func aRefusalFromTheServerIsReportedAndTheRestContinue() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt").addFile("/drops/b.txt").addFolder("/target")
        server.fail("/drops/a.txt", with: UploaderError.serverRejected(code: 550, message: "Permission denied"))
        let result = try await FileOperations.move([file("a.txt"), file("b.txt")], from: "/drops", to: "/target", session: server)

        #expect(result.completed == 1)
        #expect(result.failures.map(\.name) == ["a.txt"])
        #expect(result.failures.first?.message.contains("Permission denied") == true)
        #expect(server.exists("/target/b.txt"))
    }

    @Test func aLostConnectionStopsTheMoveInsteadOfBeingReportedPerItem() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt").addFolder("/target")
        server.fail("/drops/a.txt", with: UploaderError.connectionFailed("The connection was lost."))
        await #expect(throws: UploaderError.connectionFailed("The connection was lost.")) {
            _ = try await FileOperations.move([file("a.txt")], from: "/drops", to: "/target", session: server)
        }
    }

    // MARK: Delete

    @Test func deletesAFile() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt").addFile("/drops/keep.txt")
        let result = try await FileOperations.delete([file("a.txt")], in: "/drops", session: server)
        #expect(result == FileOperationResult(completed: 1, failures: []))
        #expect(server.paths(under: "/drops") == ["/drops/keep.txt"])
    }

    @Test func deletesAFolderWithEverythingInsideItBottomUp() async throws {
        let server = FakeFileSystem()
            .addFile("/drops/old/one.txt")
            .addFile("/drops/old/deep/two.txt")
            .addFolder("/drops/old/empty")
            .addFile("/drops/keep.txt")
        let counts = Counter()
        let result = try await FileOperations.delete([folder("old")], in: "/drops", session: server) { counts.add($0) }

        #expect(result == FileOperationResult(completed: 1, failures: []))
        #expect(server.paths(under: "/drops") == ["/drops/keep.txt"])
        // Every folder is removed after what was inside it.
        let log = server.log
        let removals = log.filter { $0.hasPrefix("RMD") }
        #expect(removals.last == "RMD /drops/old")
        let deleted = try #require(log.firstIndex(of: "DELE /drops/old/deep/two.txt"))
        let removed = try #require(log.firstIndex(of: "RMD /drops/old/deep"))
        #expect(deleted < removed)
        // one.txt, two.txt, deep, empty and old itself.
        #expect(counts.values.last == 5)
    }

    @Test func deletingSeveralItemsReportsEachRefusalAndKeepsGoing() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt").addFile("/drops/b.txt").addFile("/drops/c.txt")
        server.fail("/drops/b.txt", with: UploaderError.serverRejected(code: 550, message: "Permission denied"))
        let result = try await FileOperations.delete([file("a.txt"), file("b.txt"), file("c.txt")], in: "/drops", session: server)

        #expect(result.completed == 2)
        #expect(result.failures.map(\.name) == ["b.txt"])
        #expect(server.paths(under: "/drops") == ["/drops/b.txt"])
    }

    @Test func aRefusalInsideAFolderNamesTheItemAndLeavesTheFolderInPlace() async throws {
        let server = FakeFileSystem().addFile("/drops/old/one.txt").addFile("/drops/old/deep/two.txt")
        server.fail("/drops/old/deep/two.txt", with: UploaderError.serverRejected(code: 550, message: "Permission denied"))
        let result = try await FileOperations.delete([folder("old")], in: "/drops", session: server)

        #expect(result.completed == 0)
        #expect(result.failures.count == 1)
        let message = try #require(result.failures.first?.message)
        #expect(message.contains("old/deep/two.txt"))
        #expect(message.contains("Permission denied"))
        #expect(server.exists("/drops/old"))
    }

    @Test func aLinkIsRemovedAndNeverFollowed() async throws {
        let server = FakeFileSystem()
            .addFile("/other/precious.txt")
            .addLink("/drops/shortcut", to: "/other")
            .addLink("/drops/filelink", to: "/other/precious.txt")
        let result = try await FileOperations.delete(
            [RemoteEntry(name: "shortcut", kind: .link), RemoteEntry(name: "filelink", kind: .link)],
            in: "/drops", session: server
        )

        #expect(result == FileOperationResult(completed: 2, failures: []))
        #expect(server.exists("/other/precious.txt"))
        #expect(!server.log.contains { $0.hasPrefix("LIST") })
    }

    @Test func aLinkListedAsAFolderIsStillOnlyUnlinked() async throws {
        // Some servers list a link to a folder as a folder. Walking into it would delete the folder it points at.
        let server = FakeFileSystem()
            .addFile("/other/precious.txt")
            .addFile("/drops/real/inside.txt")
            .addLink("/drops/real/shortcut", to: "/other")
        server.reportsLinksAsFolders = true

        let listed = try await server.listEntries(atPath: "/drops/real")
        #expect(listed.first { $0.name == "shortcut" }?.kind == .folder)

        let result = try await FileOperations.delete([folder("real")], in: "/drops", session: server)

        #expect(result == FileOperationResult(completed: 1, failures: []))
        #expect(server.exists("/other/precious.txt"))
        #expect(!server.exists("/drops/real"))
        #expect(!server.log.contains("LIST /drops/real/shortcut"))
    }

    @Test func theTopFolderOfTheServerCannotBeDeleted() async throws {
        let server = FakeFileSystem().addFile("/a.txt")
        let result = try await FileOperations.delete([folder("")], in: "/", session: server)
        #expect(result.failures.map(\.message) == [FileOperationError.isRoot.errorDescription])
        #expect(server.exists("/a.txt"))
        #expect(server.log.isEmpty)
    }

    @Test func foldersNestedTooDeeplyAreRefusedRatherThanWalkedForever() async throws {
        let server = FakeFileSystem()
        server.addFolder("/drops/" + (0..<70).map { "d\($0)" }.joined(separator: "/"))
        let result = try await FileOperations.delete([folder("d0")], in: "/drops", session: server)
        #expect(result.failures.map(\.message) == [FileOperationError.tooDeep.errorDescription])
    }

    @Test func aCancelStopsDeletingAndIsNotReportedAsAFailure() async throws {
        let server = FakeFileSystem()
        for index in 0..<20 { server.addFile("/drops/f\(index).txt") }
        server.slowDown(milliseconds: 5)
        let entries = (0..<20).map { file("f\($0).txt") }

        let task = Task { try await FileOperations.delete(entries, in: "/drops", session: server) }
        try await eventually { server.log.count >= 3 }
        task.cancel()

        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(server.paths(under: "/drops").count > 0)
    }

    // MARK: Through the browse connection

    private let config = ServerConfig(transferProtocol: .sftp, host: "example.com", username: "me", remoteDirectory: "/drops")

    private func makeBrowser(_ server: FakeFileSystem) -> (BrowseSession, FakeFileSystemConnector) {
        let connector = FakeFileSystemConnector(server)
        return (BrowseSession(connectors: connector, config: config, password: "secret"), connector)
    }

    @Test func changesShareTheListingConnection() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt")
        let (browser, connector) = makeBrowser(server)

        _ = try await browser.entries(atPath: "/drops")
        try await browser.makeFolder(named: "new", in: "/drops")
        try await browser.rename(file("a.txt"), to: "b.txt", in: "/drops")
        let moved = try await browser.move([file("b.txt")], from: "/drops", to: "/drops/new")
        let deleted = try await browser.delete([folder("new")], in: "/drops")

        #expect(moved.isComplete && deleted.isComplete)
        #expect(server.paths(under: "/drops").isEmpty)
        #expect(connector.connectionCount == 1)
    }

    @Test func aServerRefusalKeepsTheConnectionOpen() async throws {
        let server = FakeFileSystem().addFolder("/drops/new")
        let (browser, connector) = makeBrowser(server)
        _ = try await browser.entries(atPath: "/drops")

        await #expect(throws: UploaderError.serverRejected(code: 550, message: "File exists")) {
            try await browser.makeFolder(named: "new", in: "/drops")
        }
        await #expect(throws: FileOperationError.invalidName) {
            try await browser.makeFolder(named: "", in: "/drops")
        }
        _ = try await browser.entries(atPath: "/drops")

        #expect(connector.connectionCount == 1)
        #expect(!server.log.contains("QUIT"))
    }

    @Test func aChangeOnAStaleLoginIsTriedOnceOnAFreshConnection() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt")
        let (browser, connector) = makeBrowser(server)
        _ = try await browser.entries(atPath: "/drops")

        server.failNextCommand(with: UploaderError.connectionFailed("The server closed the connection."))
        try await browser.rename(file("a.txt"), to: "b.txt", in: "/drops")

        #expect(server.exists("/drops/b.txt"))
        #expect(connector.connectionCount == 2)
    }

    @Test func aFreshConnectionThatDropsIsNotTriedAgain() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt")
        let (browser, connector) = makeBrowser(server)

        server.failNextCommand(with: UploaderError.connectionFailed("The server closed the connection."))
        await #expect(throws: UploaderError.connectionFailed("The server closed the connection.")) {
            try await browser.makeFolder(named: "new", in: "/drops")
        }
        #expect(connector.connectionCount == 1)
        #expect(!server.exists("/drops/new"))
    }

    @Test func cancellingADeleteClosesTheConnectionBecauseItStoppedMidCommand() async throws {
        let server = FakeFileSystem()
        for index in 0..<30 { server.addFile("/drops/f\(index).txt") }
        server.slowDown(milliseconds: 5)
        let (browser, _) = makeBrowser(server)
        let entries = (0..<30).map { file("f\($0).txt") }

        let task = Task { try await browser.delete(entries, in: "/drops") }
        try await eventually { server.log.count >= 3 }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }

        #expect(server.log.last == "QUIT")
    }
}

/// Collects progress numbers from a `@Sendable` callback.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int] = []
    func add(_ value: Int) { lock.withLock { _values.append(value) } }
    var values: [Int] { lock.withLock { _values } }
}
