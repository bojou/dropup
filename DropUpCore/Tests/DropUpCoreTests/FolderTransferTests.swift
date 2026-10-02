import Foundation
import Testing
@testable import DropUpCore

/// A folder tree on this Mac, built from `relative path: contents` pairs. A path ending in `/` is an empty folder.
private func buildFolder(named name: String, in temp: TempFiles, _ items: [String: String]) throws -> URL {
    let root = temp.directory.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (path, contents) in items {
        let url = root.appendingPathComponent(path)
        if path.hasSuffix("/") {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
    }
    return root
}

struct LocalTreeTests {
    @Test func listsFilesAndEveryFolderParentsFirst() throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let root = try buildFolder(named: "photos", in: temp, [
            "a.txt": "12345", "sub/b.txt": "123", "sub/deeper/c.txt": "1", "empty/": "", ".hidden": "xx",
        ])

        let tree = try LocalTree.scan(root)

        #expect(tree.directories == ["empty", "sub", "sub/deeper"])
        #expect(tree.files.map(\.relativePath) == [".hidden", "a.txt", "sub/b.txt", "sub/deeper/c.txt"])
        #expect(tree.totalBytes == 11)
        #expect(tree.skipped == 0)
    }

    @Test func leavesOutLinksAndDSStoreFiles() throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let outside = try temp.file(named: "outside.txt")
        let root = try buildFolder(named: "photos", in: temp, ["a.txt": "1", ".DS_Store": "junk", "sub/.DS_Store": "junk"])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked folder"), withDestinationURL: temp.directory)

        let tree = try LocalTree.scan(root)

        #expect(tree.files.map(\.relativePath) == ["a.txt"])
        #expect(tree.directories == ["sub"])
        #expect(tree.skipped == 2)
    }
}

struct FolderUploadTests {
    let config = ServerConfig(transferProtocol: .sftp, host: "example.com", username: "me", remoteDirectory: "/drops")

    private func makeQueue(_ server: FakeFileSystem, preferences: Preferences = Preferences()) -> UploadQueue {
        let credentials = InMemoryCredentialStore()
        try? credentials.setPassword("secret", for: config.credentialKey)
        return UploadQueue(
            settings: InMemorySettingsStore(config: config, preferences: preferences),
            credentials: credentials,
            connectors: FakeFileSystemConnector(server),
            progressInterval: 0
        )
    }

    private func run(_ queue: UploadQueue, _ urls: [URL], into directory: String? = nil) async -> (ids: [UUID], events: [UploadEvent]) {
        let ids = await queue.enqueue(urls, toDirectory: directory)
        await queue.waitUntilIdle()
        await queue.finish()
        var events: [UploadEvent] = []
        for await event in queue.events { events.append(event) }
        return (ids, events)
    }

    @Test func sendsAFolderWithEverythingInItAsOneItem() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let root = try buildFolder(named: "photos", in: temp, ["a.txt": "12345", "sub/b.txt": "123", "sub/deeper/c.txt": "1", "empty/": ""])
        let server = FakeFileSystem().addFolder("/drops")

        let (ids, events) = await run(makeQueue(server), [root])

        let id = try #require(ids.first)
        #expect(events.first == .queued(id: id, fileName: "photos/", totalBytes: 9))
        #expect(events.last == .succeeded(id: id, remotePath: "/drops/photos"))
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
        #expect(server.paths(under: "/drops") == [
            "/drops/photos", "/drops/photos/a.txt", "/drops/photos/empty", "/drops/photos/sub",
            "/drops/photos/sub/b.txt", "/drops/photos/sub/deeper", "/drops/photos/sub/deeper/c.txt",
        ])
        #expect(server.data(at: "/drops/photos/sub/b.txt") == Data("123".utf8))
        // Progress counts bytes across all the files, and never goes backwards.
        let sent = events.compactMap { event -> Int64? in
            if case .progress(_, let progress) = event { progress.bytesSent } else { nil }
        }
        #expect(sent == sent.sorted())
        #expect(sent.last == 9)
        // A folder is made before anything goes into it.
        let log = server.log
        let folderMade = try #require(log.firstIndex(of: "MKD /drops/photos/sub/deeper"))
        let fileSent = try #require(log.firstIndex(of: "STOR /drops/photos/sub/deeper/c.txt"))
        #expect(folderMade < fileSent)
    }

    @Test func aTakenFolderNameGetsANumberInsteadOfBeingMergedInto() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let root = try buildFolder(named: "photos", in: temp, ["a.txt": "new"])
        let server = FakeFileSystem().addFile("/drops/photos/a.txt", data: Data("old".utf8)).addFolder("/drops/photos-1")

        let (ids, events) = await run(makeQueue(server), [root])

        #expect(events.last == .succeeded(id: try #require(ids.first), remotePath: "/drops/photos-2"))
        #expect(server.data(at: "/drops/photos/a.txt") == Data("old".utf8))
        #expect(server.data(at: "/drops/photos-2/a.txt") == Data("new".utf8))
    }

    @Test func replaceMergesIntoTheExistingFolderAndOverwritesSameNames() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let root = try buildFolder(named: "photos", in: temp, ["a.txt": "new", "sub/b.txt": "new b"])
        let server = FakeFileSystem()
            .addFile("/drops/photos/a.txt", data: Data("old".utf8))
            .addFile("/drops/photos/keep.txt", data: Data("kept".utf8))
            .addFolder("/drops/photos/sub")

        let (ids, events) = await run(makeQueue(server, preferences: Preferences(conflictPolicy: .replace)), [root])

        #expect(events.last == .succeeded(id: try #require(ids.first), remotePath: "/drops/photos"))
        #expect(server.data(at: "/drops/photos/a.txt") == Data("new".utf8))
        #expect(server.data(at: "/drops/photos/sub/b.txt") == Data("new b".utf8))
        #expect(server.data(at: "/drops/photos/keep.txt") == Data("kept".utf8))
    }

    @Test func goesIntoAnotherFolderAndLeavesLinksOut() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let outside = try temp.file(named: "outside.txt")
        let root = try buildFolder(named: "photos", in: temp, ["a.txt": "1", ".DS_Store": "junk"])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: outside)
        let server = FakeFileSystem().addFolder("/drops").addFolder("/elsewhere")

        let (ids, events) = await run(makeQueue(server), [root], into: "/elsewhere")

        #expect(events.last == .succeeded(id: try #require(ids.first), remotePath: "/elsewhere/photos"))
        #expect(server.paths(under: "/elsewhere") == ["/elsewhere/photos", "/elsewhere/photos/a.txt"])
    }

    @Test func aRefusalInsideTheFolderNamesTheFileAndStops() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let root = try buildFolder(named: "photos", in: temp, ["a.txt": "1", "sub/b.txt": "2", "z.txt": "3"])
        let server = FakeFileSystem().addFolder("/drops")
        server.fail("/drops/photos/sub/b.txt", with: UploaderError.serverRejected(code: 550, message: "Permission denied"))

        let (ids, events) = await run(makeQueue(server), [root])

        let id = try #require(ids.first)
        #expect(events.last == .failed(id: id, .transfer("“sub/b.txt”: The server refused: Permission denied (550)")))
        #expect(server.exists("/drops/photos/a.txt"))
        #expect(!server.exists("/drops/photos/z.txt"))
    }

    @Test func cancellingRemovesOnlyTheHalfSentFile() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let root = try buildFolder(named: "photos", in: temp, ["a.txt": "1", "b.txt": "2", "c.txt": "3"])
        let server = FakeFileSystem().addFolder("/drops")
        server.hangUpload(of: "/drops/photos/b.txt")
        let queue = makeQueue(server)

        let ids = await queue.enqueue([root])
        try await eventually { server.exists("/drops/photos/b.txt") }
        await queue.cancel(ids[0])
        await queue.waitUntilIdle()
        await queue.finish()
        var events: [UploadEvent] = []
        for await event in queue.events { events.append(event) }

        #expect(events.last == .cancelled(id: ids[0]))
        #expect(server.exists("/drops/photos/a.txt"))
        #expect(!server.exists("/drops/photos/b.txt"))
        #expect(!server.exists("/drops/photos/c.txt"))
    }

    @Test func anEmptyFolderIsStillCreated() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let root = try buildFolder(named: "nothing", in: temp, [:])
        let server = FakeFileSystem().addFolder("/drops")

        let (ids, events) = await run(makeQueue(server), [root])

        #expect(events.last == .succeeded(id: try #require(ids.first), remotePath: "/drops/nothing"))
        #expect(server.exists("/drops/nothing"))
    }

    @Test func aFolderAndAFileDroppedTogetherBothGo() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let root = try buildFolder(named: "photos", in: temp, ["a.txt": "1"])
        let file = try temp.file(named: "note.txt")
        let server = FakeFileSystem().addFolder("/drops")

        let (_, events) = await run(makeQueue(server), [root, file])

        #expect(server.exists("/drops/photos/a.txt"))
        #expect(server.exists("/drops/note.txt"))
        #expect(events.filter { if case .succeeded = $0 { true } else { false } }.count == 2)
    }
}

struct FolderDownloadTests {
    let config = ServerConfig(transferProtocol: .sftp, host: "example.com", username: "me", remoteDirectory: "/drops")

    private func run(_ server: FakeFileSystem, _ downloads: [RemoteDownload], into directory: URL, cancelWhen: (@Sendable () -> Bool)? = nil) async throws -> (ids: [UUID], events: [DownloadEvent]) {
        let queue = DownloadQueue(connectors: FakeFileSystemConnector(server), progressInterval: 0)
        let ids = await queue.enqueue(downloads, from: config, password: "secret", into: directory)
        if let cancelWhen {
            try await eventually { cancelWhen() }
            await queue.cancel(ids[0])
        }
        await queue.waitUntilIdle()
        await queue.finish()
        var events: [DownloadEvent] = []
        for await event in queue.events { events.append(event) }
        return (ids, events)
    }

    private func savedURL(_ event: DownloadEvent?) -> URL? {
        if case .succeeded(_, let url)? = event { url } else { nil }
    }

    private func relativeFiles(in folder: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: folder.path)
        return ((enumerator?.allObjects as? [String]) ?? []).sorted()
    }

    @Test func fetchesAFolderWithEverythingInItIntoANewLocalFolder() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let server = FakeFileSystem()
            .addFile("/drops/photos/a.txt", data: Data("12345".utf8))
            .addFile("/drops/photos/sub/b.txt", data: Data("123".utf8))
            .addFolder("/drops/photos/empty")
        let destination = temp.directory.appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let (ids, events) = try await run(server, [RemoteDownload(remotePath: "/drops/photos", isFolder: true)], into: destination)

        let id = try #require(ids.first)
        let saved = destination.appendingPathComponent("photos")
        #expect(events.first == .queued(id: id, fileName: "photos/", totalBytes: 0))
        #expect(savedURL(events.last)?.path == saved.path)
        #expect(relativeFiles(in: saved) == ["a.txt", "empty", "sub", "sub/b.txt"])
        #expect(try Data(contentsOf: saved.appendingPathComponent("sub/b.txt")) == Data("123".utf8))
        // Once the folder has been looked through, progress carries its size and then counts bytes across the files.
        let progress = events.compactMap { event -> UploadProgress? in
            if case .progress(_, let p) = event { p } else { nil }
        }
        #expect(progress.first == UploadProgress(bytesSent: 0, totalBytes: 8))
        #expect(progress.last == UploadProgress(bytesSent: 8, totalBytes: 8))
    }

    @Test func aTakenLocalNameGetsANumber() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let destination = temp.directory
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("photos"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: destination.appendingPathComponent("photos/mine.txt"))
        let server = FakeFileSystem().addFile("/drops/photos/a.txt", data: Data("1".utf8))

        let (ids, events) = try await run(server, [RemoteDownload(remotePath: "/drops/photos", isFolder: true)], into: destination)

        #expect(savedURL(events.last)?.path == destination.appendingPathComponent("photos-1").path)
        #expect(relativeFiles(in: destination.appendingPathComponent("photos")) == ["mine.txt"])
        #expect(relativeFiles(in: destination.appendingPathComponent("photos-1")) == ["a.txt"])
    }

    @Test func linksAreLeftOut() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let server = FakeFileSystem()
            .addFile("/drops/photos/a.txt", data: Data("1".utf8))
            .addFile("/other/secret.txt", data: Data("s".utf8))
            .addLink("/drops/photos/shortcut", to: "/other")
        let destination = temp.directory.appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        _ = try await run(server, [RemoteDownload(remotePath: "/drops/photos", isFolder: true)], into: destination)

        #expect(relativeFiles(in: destination.appendingPathComponent("photos")) == ["a.txt"])
    }

    @Test func aFailureInsideRemovesTheWholeLocalFolderAndNamesTheFile() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let server = FakeFileSystem()
            .addFile("/drops/photos/a.txt", data: Data("1".utf8))
            .addFile("/drops/photos/sub/b.txt", data: Data("2".utf8))
        server.fail("/drops/photos/sub/b.txt", with: UploaderError.serverRejected(code: 550, message: "Permission denied"))
        let destination = temp.directory.appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let (ids, events) = try await run(server, [RemoteDownload(remotePath: "/drops/photos", isFolder: true)], into: destination)

        #expect(events.last == .failed(id: ids[0], message: "“sub/b.txt”: The server refused: Permission denied (550)"))
        #expect(relativeFiles(in: destination).isEmpty)
    }

    @Test func cancellingRemovesTheWholeLocalFolder() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let server = FakeFileSystem()
        for index in 0..<30 { server.addFile("/drops/photos/f\(index).txt", data: Data("x".utf8)) }
        server.slowDown(milliseconds: 5)
        let destination = temp.directory.appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let (ids, events) = try await run(
            server, [RemoteDownload(remotePath: "/drops/photos", isFolder: true)], into: destination,
            cancelWhen: { server.log.filter { $0.hasPrefix("RETR") }.count >= 2 }
        )

        #expect(events.last == .cancelled(id: ids[0]))
        #expect(relativeFiles(in: destination).isEmpty)
    }

    @Test func namesThatCouldReachOutsideTheFolderAreNeverFollowed() async throws {
        let session = FakeSession(entries: [
            "/x": [
                RemoteEntry(name: "ok.txt", kind: .file, size: 1),
                RemoteEntry(name: "../evil.txt", kind: .file, size: 1),
                RemoteEntry(name: "a/b", kind: .file, size: 1),
                RemoteEntry(name: "..", kind: .folder),
                RemoteEntry(name: "bad\0name", kind: .file, size: 1),
            ],
        ])

        let tree = try await RemoteTree.walk("/x", session: session)

        #expect(tree.files.map(\.relativePath) == ["ok.txt"])
        #expect(tree.skipped == 4)
    }

    @Test func foldersNestedTooDeeplyAreRefused() async throws {
        let server = FakeFileSystem()
        server.addFolder("/x/" + (0..<40).map { "d\($0)" }.joined(separator: "/"))
        await #expect(throws: FileOperationError.tooDeep) {
            _ = try await RemoteTree.walk("/x", session: server)
        }
    }

    @Test func foldersWithAbsurdlyManyItemsAreRefused() async throws {
        let session = FakeSession(entries: [
            "/x": (0..<100_001).map { RemoteEntry(name: "f\($0)", kind: .file, size: 1) },
        ])
        await #expect(throws: FileOperationError.tooMany) {
            _ = try await RemoteTree.walk("/x", session: session)
        }
        #expect(FileOperationError.tooMany.errorDescription == "There are too many items in this folder to handle at once.")
    }
}
