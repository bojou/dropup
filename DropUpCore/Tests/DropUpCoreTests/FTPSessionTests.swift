import Foundation
import Testing
@testable import DropUpCore

struct FTPSessionTests {
    let config = ServerConfig(transferProtocol: .ftp, host: "ftp.example.com", username: "me", remoteDirectory: "/drops")

    private func connect(_ server: FakeFTPServer, password: String = "secret") async throws -> any ServerSession {
        try await FTPConnector(opener: server, replyTimeout: 2).connect(to: config, password: password)
    }

    @Test func logsInAndUploadsInBinaryPassiveMode() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "photo.png", size: 600_000)
        let server = FakeFTPServer()
        let reported = Locked<[Int64]>([])

        let session = try await connect(server)
        try await session.upload(fileURL: file, to: "/drops/photo.png") { sent in reported.mutate { $0.append(sent) } }
        await session.close()

        let original = try Data(contentsOf: file)
        #expect(server.file("/drops/photo.png") == original)
        #expect(server.commandLog == [
            "USER me", "PASS ***", "OPTS UTF8 ON", "TYPE I", "EPSV", "STOR /drops/photo.png", "QUIT",
        ])
        // 0 once the server has accepted the file, then 600 KB in 256 KB chunks.
        #expect(reported.value == [0, 262_144, 524_288, 600_000])
        #expect(server.openedEndpoints == ["ftp.example.com:21", "ftp.example.com:5000"])
    }

    @Test func wrongPasswordIsAuthenticationFailure() async throws {
        let server = FakeFTPServer()
        await #expect(throws: UploaderError.authenticationFailed) {
            _ = try await connect(server, password: "nope")
        }
        #expect(server.commandLog.last == "QUIT")
    }

    @Test func fallsBackToPASVAndIgnoresItsAddress() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let server = FakeFTPServer()
        server.supportsEPSV = false

        let session = try await connect(server)
        try await session.upload(fileURL: try temp.file(named: "a.txt"), to: "/drops/a.txt") { _ in }
        try await session.upload(fileURL: try temp.file(named: "b.txt"), to: "/drops/b.txt") { _ in }

        #expect(server.file("/drops/b.txt") == Data("hello".utf8))
        // EPSV is tried once, then PASV is used directly.
        #expect(server.commandLog.filter { $0 == "EPSV" }.count == 1)
        #expect(server.commandLog.filter { $0 == "PASV" }.count == 2)
        #expect(server.openedEndpoints.allSatisfy { $0.hasPrefix("ftp.example.com:") })
    }

    @Test func refusedStoreIsReportedWithServerMessage() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let server = FakeFTPServer()
        server.readOnlyPaths = ["/drops/a.txt"]
        let reported = Locked<[Int64]>([])

        let session = try await connect(server)
        await #expect(throws: UploaderError.serverRejected(code: 553, message: "Permission denied")) {
            try await session.upload(fileURL: try temp.file(named: "a.txt"), to: "/drops/a.txt") { sent in
                reported.mutate { $0.append(sent) }
            }
        }
        // The server never took the file, so nothing was reported and nothing is the caller's to clean up.
        #expect(reported.value.isEmpty)
    }

    @Test func deletesAFile() async throws {
        let server = FakeFTPServer()
        server.seed("/drops/a.txt")
        let session = try await connect(server)

        try await session.deleteFile(atPath: "/drops/a.txt")

        #expect(server.file("/drops/a.txt") == nil)
        #expect(server.commandLog.contains("DELE /drops/a.txt"))
    }

    @Test func deletingAMissingFileIsRejected() async throws {
        let server = FakeFTPServer()
        let session = try await connect(server)
        await #expect(throws: UploaderError.serverRejected(code: 550, message: "No such file")) {
            try await session.deleteFile(atPath: "/drops/missing.txt")
        }
    }

    @Test func checksExistenceWithSIZEThenMDTM() async throws {
        let server = FakeFTPServer()
        server.seed("/drops/a.txt")
        let session = try await connect(server)
        #expect(try await session.fileExists(atPath: "/drops/a.txt"))
        #expect(try await session.fileExists(atPath: "/drops/b.txt") == false)

        let old = FakeFTPServer()
        old.supportsSIZE = false
        old.seed("/drops/a.txt")
        let oldSession = try await connect(old)
        #expect(try await oldSession.fileExists(atPath: "/drops/a.txt"))
        #expect(try await oldSession.fileExists(atPath: "/drops/b.txt") == false)
        #expect(old.commandLog.contains("MDTM /drops/a.txt"))
    }

    @Test func listsFoldersWithMLSD() async throws {
        let server = FakeFTPServer()
        let session = try await connect(server)
        #expect(try await session.listDirectories(atPath: "/drops") == ["archive", "My Photos"])
        #expect(server.commandLog.contains("MLSD /drops"))
    }

    @Test func listsFoldersWithLISTWhenMLSDIsMissing() async throws {
        let server = FakeFTPServer()
        server.supportsMLSD = false
        let session = try await connect(server)
        #expect(try await session.listDirectories(atPath: "/drops") == ["archive", "My Photos"])
        #expect(server.commandLog.contains("LIST /drops"))
    }

    @Test func listsEverythingInAFolderWithMLSD() async throws {
        let server = FakeFTPServer()
        let session = try await connect(server)

        let entries = try await session.listEntries(atPath: "/drops")

        // Hidden items are included (the app decides whether to show them); folders come first.
        #expect(Set(entries.map(\.name)) == ["archive", "My Photos", ".hidden", "notes.txt"])
        #expect(entries.prefix(3).allSatisfy { $0.kind == .folder })
        #expect(entries.last?.name == "notes.txt")
        #expect(entries.last?.size == 5)
        #expect(server.commandLog.contains("MLSD /drops"))
    }

    @Test func listsEverythingInAFolderWithLISTWhenMLSDIsMissing() async throws {
        let server = FakeFTPServer()
        server.supportsMLSD = false
        let session = try await connect(server)

        let entries = try await session.listEntries(atPath: "/drops")

        #expect(entries.map(\.name) == ["archive", "My Photos", "link", "notes.txt"])
        #expect(entries.map(\.kind) == [.folder, .folder, .link, .file])
        #expect(server.commandLog.contains("LIST /drops"))
    }

    @Test func downloadsAFileInBinaryPassiveMode() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let original = Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let server = FakeFTPServer()
        server.seed("/drops/photo.png", data: original)
        let reported = Locked<[Int64]>([])
        let target = temp.directory.appendingPathComponent("photo.png")

        let session = try await connect(server)
        try await session.download(remotePath: "/drops/photo.png", to: target) { received in reported.mutate { $0.append(received) } }
        await session.close()

        #expect(try Data(contentsOf: target) == original)
        #expect(server.commandLog == ["USER me", "PASS ***", "OPTS UTF8 ON", "TYPE I", "EPSV", "RETR /drops/photo.png", "QUIT"])
        #expect(reported.value == [262_144, 524_288, 600_000])
    }

    @Test func downloadingAMissingFileIsRejectedAndLeavesNothingBehind() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let server = FakeFTPServer()
        let target = temp.directory.appendingPathComponent("missing.txt")

        let session = try await connect(server)
        await #expect(throws: UploaderError.serverRejected(code: 550, message: "No such file")) {
            try await session.download(remotePath: "/drops/missing.txt", to: target) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func downloadStopsWhenCancelled() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let server = FakeFTPServer()
        server.seed("/drops/big.bin", data: Data(count: 2_000_000))
        let target = temp.directory.appendingPathComponent("big.bin")
        let session = try await connect(server)

        let task = Task {
            try await session.download(remotePath: "/drops/big.bin", to: target) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let written = (try? Data(contentsOf: target).count) ?? 0
        #expect(written < 2_000_000)
    }

    @Test func missingFolderIsRejected() async throws {
        let server = FakeFTPServer()
        let session = try await connect(server)
        await #expect(throws: UploaderError.serverRejected(code: 550, message: "No such folder")) {
            _ = try await session.listDirectories(atPath: "/nope")
        }
    }

    @Test func refusesLineBreaksInPaths() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let server = FakeFTPServer()
        let session = try await connect(server)
        await #expect(throws: UploaderError.invalidRemotePath) {
            try await session.upload(fileURL: try temp.file(named: "a.txt"), to: "/drops/a\r\nDELE x") { _ in }
        }
        await #expect(throws: UploaderError.invalidRemotePath) {
            try await session.deleteFile(atPath: "/drops/a\r\nDELE x")
        }
        await #expect(throws: UploaderError.invalidRemotePath) {
            try await session.download(remotePath: "/drops/a\r\nDELE x", to: temp.directory.appendingPathComponent("x")) { _ in }
        }
        #expect(!server.commandLog.contains { $0.hasPrefix("DELE") })
    }

    @Test func stopsWhenCancelled() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "big.bin", size: 2_000_000)
        let server = FakeFTPServer()
        let session = try await connect(server)

        let task = Task {
            try await session.upload(fileURL: file, to: "/drops/big.bin") { sent in
                // Cancel once data is flowing, not at the 0 that announces the file.
                if sent > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(server.file("/drops/big.bin").map { $0.count < 2_000_000 } ?? true)
    }
}

struct FTPListingTests {
    @Test func mlsdEntriesCarryTypeSizeAndUTCModifiedTime() {
        let text = [
            "type=cdir;modify=20260101000000; .",
            "type=pdir; ..",
            "type=dir;modify=20260102030405; My Photos",
            "Type=File;Size=1234;Modify=20260910120000.250; report final.pdf",
            "type=OS.unix=slink:/var/www;size=11; www",
            "type=OS.unix=socket; run.sock",
            "type=file; no-facts.txt",
        ].joined(separator: "\r\n")

        let entries = FTPListing.entriesFromMLSD(text)

        #expect(entries.map(\.name) == ["My Photos", "report final.pdf", "www", "no-facts.txt"])
        #expect(entries.map(\.kind) == [.folder, .file, .link, .file])
        #expect(entries[0].size == nil)
        #expect(entries[1].size == 1234)
        #expect(entries[3].size == nil)
        #expect(entries[0].modified == Date(timeIntervalSince1970: 1_767_323_045)) // 2026-01-02 03:04:05 UTC
        #expect(entries[1].modified == Date(timeIntervalSince1970: 1_789_041_600)) // 2026-09-10 12:00:00 UTC
        #expect(entries[3].modified == nil)
    }

    @Test func listEntriesCarryTypeSizeAndDate() {
        let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21
        let text = [
            "total 12",
            "drwxr-xr-x    2 me  staff  4096 Sep 10 12:00 My Photos",
            "-rw-r--r--    1 me  staff  1234 Sep 10 12:00 report final.pdf",
            "-rw-r--r--    1 me  staff    99 Dec 25 08:30 from-last-year.txt",
            "-rw-r--r--    1 me  staff     7 Mar  3  2019 old.txt",
            "lrwxr-xr-x    1 me  staff    11 Sep 10 12:00 www -> public_html",
            "srwxr-xr-x    1 me  staff     0 Sep 10 12:00 run.sock",
        ].joined(separator: "\n")

        let entries = FTPListing.entriesFromLIST(text, now: now)

        #expect(entries.map(\.name) == ["My Photos", "report final.pdf", "from-last-year.txt", "old.txt", "www"])
        #expect(entries.map(\.kind) == [.folder, .file, .file, .file, .link])
        #expect(entries[1].size == 1234)
        #expect(entries[0].size == nil)
        #expect(entries[1].modified == Date(timeIntervalSince1970: 1_789_041_600)) // 2026-09-10 12:00 UTC
        #expect(entries[2].modified == Date(timeIntervalSince1970: 1_766_651_400)) // a future-looking December is last year: 2025-12-25 08:30 UTC
        #expect(entries[3].modified == Date(timeIntervalSince1970: 1_551_571_200)) // 2019-03-03 00:00 UTC
    }

    @Test func parsesMLSDFacts() {
        let text = "type=dir;modify=20260101; images\r\nType=Dir; Mixed Case\r\ntype=file;size=3; a.txt\r\ntype=cdir; .\r\n"
        #expect(FTPListing.directoriesFromMLSD(text) == ["images", "Mixed Case"])
    }

    @Test func parsesUnixLIST() {
        let text = """
        total 8
        drwxr-xr-x   2 user  group  4096 Sep 10 12:00 images
        drwxr-xr-x   2 user  group  4096 Sep 10  2025 two  spaces
        -rw-r--r--   1 user  group     3 Sep 10 12:00 a.txt
        drwxr-xr-x   2 user  group  4096 Sep 10 12:00 .git

        """
        #expect(FTPListing.directoriesFromLIST(text) == ["images", "two  spaces"])
    }
}

/// A tiny lock-protected box for collecting values from `@Sendable` callbacks.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value { lock.withLock { _value } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&_value) } }
}
