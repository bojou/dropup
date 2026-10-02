import Foundation
import Testing
@testable import DropUpCore

struct UndoTests {
    private func file(_ name: String, size: Int64 = 3) -> RemoteEntry { RemoteEntry(name: name, kind: .file, size: size) }
    private func folder(_ name: String) -> RemoteEntry { RemoteEntry(name: name, kind: .folder) }

    // MARK: Titles and places

    @Test func titlesNameWhatWouldBeUndone() {
        #expect(BrowseChange.madeFolder("/a/new").title == "New Folder")
        #expect(BrowseChange.renamed(ItemMove(from: "/a/x", to: "/a/y")).title == "Rename")
        #expect(BrowseChange.moved([ItemMove(from: "/a/x", to: "/b/x")]).title == "Move “x”")
        #expect(BrowseChange.moved([ItemMove(from: "/a/x", to: "/b/x"), ItemMove(from: "/a/y", to: "/b/y")]).title == "Move 2 Items")
        let one = CopyRecord(sources: [file("x")], from: "/a", to: "/b", files: ["/b/x"], folders: [])
        #expect(BrowseChange.copied(one).title == "Copy “x”")
    }

    @Test func eachChangeKnowsWhichFolderShowsIt() {
        let moved = BrowseChange.moved([ItemMove(from: "/a/x", to: "/b/c/x")])
        #expect(moved.folderWhenDone == "/b/c" && moved.folderWhenUndone == "/a")
        let renamed = BrowseChange.renamed(ItemMove(from: "/a/x", to: "/a/y"))
        #expect(renamed.folderWhenDone == "/a" && renamed.folderWhenUndone == "/a")
        #expect(BrowseChange.madeFolder("/a/new").folderWhenUndone == "/a")
        #expect(BrowseChange.madeFolder("/new").folderWhenDone == "/")
    }

    // MARK: New folder

    @Test func undoingANewFolderRemovesItAndRedoMakesItAgain() async throws {
        let server = FakeFileSystem().addFolder("/drops")
        let made = try await FileOperations.makeFolder(named: "photos", in: "/drops", session: server)
        let change = BrowseChange.madeFolder(made)

        let undone = try await FileOperations.undo(change, session: server)
        #expect(undone.completed == 1 && undone.change == change)
        #expect(!server.exists("/drops/photos"))

        let redone = try await FileOperations.redo(change, session: server)
        #expect(redone.completed == 1 && redone.change == change)
        #expect(server.exists("/drops/photos"))
    }

    @Test func aNewFolderThatGotFilesIsNotRemoved() async throws {
        let server = FakeFileSystem().addFile("/drops/photos/a.jpg")

        let result = try await FileOperations.undo(.madeFolder("/drops/photos"), session: server)

        #expect(result.completed == 0 && result.change == nil)
        #expect(result.failures.map(\.name) == ["photos"])
        #expect(server.exists("/drops/photos/a.jpg"))
    }

    // MARK: Rename

    @Test func undoingARenameGivesTheOldNameBack() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt", data: Data("A".utf8))
        let move = try #require(try await FileOperations.rename(file("a.txt"), to: "b.txt", in: "/drops", session: server))
        let change = BrowseChange.renamed(move)

        let undone = try await FileOperations.undo(change, session: server)
        #expect(undone.change == change)
        #expect(server.data(at: "/drops/a.txt") == Data("A".utf8) && !server.exists("/drops/b.txt"))

        let redone = try await FileOperations.redo(change, session: server)
        #expect(redone.change == change)
        #expect(server.data(at: "/drops/b.txt") == Data("A".utf8) && !server.exists("/drops/a.txt"))
    }

    @Test func undoingARenameNeverOverwritesAFileThatTookTheOldName() async throws {
        let server = FakeFileSystem().addFile("/drops/b.txt", data: Data("B".utf8)).addFile("/drops/a.txt", data: Data("newer".utf8))
        server.replacesOnRename = true

        let result = try await FileOperations.undo(.renamed(ItemMove(from: "/drops/a.txt", to: "/drops/b.txt")), session: server)

        #expect(result.completed == 0 && result.change == nil)
        #expect(result.failures == [FileOperationFailure(name: "a.txt", message: FileOperationError.alreadyExists("a.txt").errorDescription!)])
        #expect(server.data(at: "/drops/a.txt") == Data("newer".utf8))
        #expect(server.data(at: "/drops/b.txt") == Data("B".utf8))
    }

    // MARK: Move

    @Test func undoingAMoveBringsEveryItemBackAndRedoMovesThemAgain() async throws {
        let server = FakeFileSystem()
            .addFile("/drops/a.txt", data: Data("A".utf8))
            .addFile("/drops/sub/b.txt", data: Data("B".utf8))
            .addFolder("/target")
        let moved = try await FileOperations.move([file("a.txt"), folder("sub")], from: "/drops", to: "/target", session: server)
        let change = try #require(moved.change)

        let undone = try await FileOperations.undo(change, session: server)
        #expect(undone.completed == 2 && undone.failures.isEmpty && undone.change == change)
        #expect(server.paths() == ["/drops", "/drops/a.txt", "/drops/sub", "/drops/sub/b.txt", "/target"])

        let redone = try await FileOperations.redo(change, session: server)
        #expect(redone.completed == 2 && redone.change == change)
        #expect(server.paths() == ["/drops", "/target", "/target/a.txt", "/target/sub", "/target/sub/b.txt"])
        #expect(server.data(at: "/target/a.txt") == Data("A".utf8))
    }

    @Test func aNumberedMoveGoesBackToTheOriginalName() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt", data: Data("new".utf8)).addFile("/target/a.txt", data: Data("old".utf8))
        let moved = try await FileOperations.move([file("a.txt")], from: "/drops", to: "/target", session: server)

        _ = try await FileOperations.undo(try #require(moved.change), session: server)

        #expect(server.data(at: "/drops/a.txt") == Data("new".utf8))
        #expect(server.data(at: "/target/a.txt") == Data("old".utf8))
        #expect(!server.exists("/target/a-1.txt"))
    }

    @Test func itemsWhoseOldNameWasTakenStayPutAndTheRestGoBack() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt").addFile("/drops/b.txt").addFolder("/target")
        let moved = try await FileOperations.move([file("a.txt"), file("b.txt")], from: "/drops", to: "/target", session: server)
        let change = try #require(moved.change)
        server.addFile("/drops/a.txt", data: Data("someone else's".utf8))

        let undone = try await FileOperations.undo(change, session: server)

        #expect(undone.completed == 1)
        #expect(undone.failures.map(\.name) == ["a.txt"])
        #expect(server.exists("/target/a.txt") && server.exists("/drops/b.txt"))
        #expect(server.data(at: "/drops/a.txt") == Data("someone else's".utf8))
        // Redo only repeats what was actually taken back.
        #expect(undone.change == .moved([ItemMove(from: "/drops/b.txt", to: "/target/b.txt")]))
    }

    @Test func aFolderCannotBeUndoneIntoItself() async throws {
        let server = FakeFileSystem().addFolder("/a/b")

        let result = try await FileOperations.redo(.moved([ItemMove(from: "/a", to: "/a/b/a")]), session: server)

        #expect(result.completed == 0)
        #expect(result.failures.first?.message == FileOperationError.movedIntoItself.errorDescription)
        #expect(!server.log.contains { $0.hasPrefix("RENAME") })
    }

    @Test func aLostConnectionStopsAnUndoInsteadOfBeingReportedPerItem() async throws {
        let server = FakeFileSystem().addFile("/target/a.txt").addFolder("/drops")
        server.fail("/target/a.txt", with: UploaderError.connectionFailed("The connection was lost."))

        await #expect(throws: UploaderError.connectionFailed("The connection was lost.")) {
            _ = try await FileOperations.undo(.moved([ItemMove(from: "/drops/a.txt", to: "/target/a.txt")]), session: server)
        }
    }

    // MARK: Copy

    @Test func undoingACopyRemovesOnlyWhatTheCopyMade() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("DropUpUndoTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let server = FakeFileSystem()
            .addFile("/drops/a.txt", data: Data("A".utf8))
            .addFile("/drops/dir/b.txt", data: Data("B".utf8))
            .addFile("/drops/dir/deep/c.txt", data: Data("C".utf8))
        let copied = try await FileOperations.copy([file("a.txt", size: 1), folder("dir")], from: "/drops", to: "/drops", session: server, scratch: scratch)
        let change = try #require(copied.change)
        #expect(server.exists("/drops/dir copy/deep/c.txt"))

        let undone = try await FileOperations.undo(change, session: server)

        #expect(undone.completed == 5 && undone.failures.isEmpty && undone.change == change)
        #expect(server.paths() == ["/drops", "/drops/a.txt", "/drops/dir", "/drops/dir/b.txt", "/drops/dir/deep", "/drops/dir/deep/c.txt"])
    }

    @Test func aCopiedFolderThatGotNewFilesKeepsThemAndSaysSo() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("DropUpUndoTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let server = FakeFileSystem().addFile("/drops/dir/b.txt", data: Data("B".utf8)).addFolder("/other")
        let copied = try await FileOperations.copy([folder("dir")], from: "/drops", to: "/other", session: server, scratch: scratch)
        server.addFile("/other/dir/mine.txt", data: Data("M".utf8))

        let undone = try await FileOperations.undo(try #require(copied.change), session: server)

        #expect(undone.failures.map(\.name) == ["dir"])
        #expect(undone.change == nil)
        #expect(!server.exists("/other/dir/b.txt"))
        #expect(server.data(at: "/other/dir/mine.txt") == Data("M".utf8))
    }

    @Test func redoMakesTheCopyAgain() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("DropUpUndoTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let server = FakeFileSystem().addFile("/drops/a.txt", data: Data("A".utf8))
        let config = ServerConfig(transferProtocol: .sftp, host: "example.com", username: "me", remoteDirectory: "/drops")
        let browser = BrowseSession(connectors: FakeFileSystemConnector(server), config: config, password: "x", scratchParent: parent)

        let copied = try await browser.copy([file("a.txt", size: 1)], from: "/drops", to: "/drops")
        let change = try #require(copied.change)
        let undone = try await browser.undo(change)
        #expect(!server.exists("/drops/a copy.txt"))
        let redone = try await browser.redo(try #require(undone.change))

        #expect(redone.completed == 1)
        #expect(server.data(at: "/drops/a copy.txt") == Data("A".utf8))
        #expect(redone.change != nil)
    }

    @Test func aSessionHandsBackChangesForFoldersAndRenames() async throws {
        let server = FakeFileSystem().addFile("/drops/a.txt")
        let config = ServerConfig(transferProtocol: .sftp, host: "example.com", username: "me", remoteDirectory: "/drops")
        let browser = BrowseSession(connectors: FakeFileSystemConnector(server), config: config, password: "x")

        let made = try await browser.makeFolder(named: "new", in: "/drops")
        let renamed = try await browser.rename(file("a.txt"), to: "b.txt", in: "/drops")
        let unchanged = try await browser.rename(file("b.txt"), to: "b.txt", in: "/drops")

        #expect(made == .madeFolder("/drops/new"))
        #expect(renamed == .renamed(ItemMove(from: "/drops/a.txt", to: "/drops/b.txt")))
        #expect(unchanged == nil)
    }
}

struct ResultSummaryTests {
    @Test func saysNothingWhenAllWentThroughQuietly() {
        #expect(FileOperationResult(completed: 2).summary(verb: "moved") == nil)
    }

    @Test func listsRefusalsLikeBefore() {
        let result = FileOperationResult(completed: 1, failures: [FileOperationFailure(name: "a", message: "No.")])
        #expect(result.summary(verb: "moved") == "1 of 2 items couldn't be moved.\n“a”: No.")
        let single = FileOperationResult(failures: [FileOperationFailure(name: "a", message: "No.")])
        #expect(single.summary(verb: "copied") == "“a” couldn't be copied.\nNo.")
    }

    @Test func tellsAboutLeftOutLinks() {
        #expect(FileOperationResult(completed: 1, skipped: 1).summary(verb: "copied") == "Copied.\nA link inside the folders was left out.")
        #expect(FileOperationResult(completed: 1, skipped: 3).summary(verb: "copied") == "Copied.\n3 links inside the folders were left out.")
    }

    @Test func warnsThatAReplacementCannotBeUndone() {
        let summary = FileOperationResult(completed: 1, replaced: 1).summary(verb: "moved")
        #expect(summary == "Moved.\nReplaced a file that was already there. That can't be undone.")
    }

    @Test func mentionsNumbersThatWereAdded() {
        #expect(FileOperationResult(completed: 1, renamed: 1).summary(verb: "moved")?.contains("A number was added to 1 name") == true)
        #expect(FileOperationResult(completed: 2, renamed: 2).summary(verb: "moved")?.contains("2 names") == true)
    }

    @Test func refusalsComeFirstAndNotesFollowWithoutAnOpeningWord() {
        let result = FileOperationResult(completed: 1, failures: [FileOperationFailure(name: "a", message: "No.")], replaced: 1)
        let lines = result.summary(verb: "moved")?.split(separator: "\n").map(String.init)
        #expect(lines?.first == "1 of 2 items couldn't be moved.")
        #expect(lines?.contains("Moved.") == false)
        #expect(lines?.last == "Replaced a file that was already there. That can't be undone.")
    }
}
