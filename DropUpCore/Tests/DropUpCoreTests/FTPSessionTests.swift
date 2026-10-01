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
        // 600 KB in 256 KB chunks.
        #expect(reported.value == [262_144, 524_288, 600_000])
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

        let session = try await connect(server)
        await #expect(throws: UploaderError.serverRejected(code: 553, message: "Permission denied")) {
            try await session.upload(fileURL: try temp.file(named: "a.txt"), to: "/drops/a.txt") { _ in }
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
        #expect(!server.commandLog.contains { $0.hasPrefix("DELE") })
    }

    @Test func stopsWhenCancelled() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "big.bin", size: 2_000_000)
        let server = FakeFTPServer()
        let session = try await connect(server)

        let task = Task {
            try await session.upload(fileURL: file, to: "/drops/big.bin") { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(server.file("/drops/big.bin").map { $0.count < 2_000_000 } ?? true)
    }
}

struct FTPListingTests {
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
