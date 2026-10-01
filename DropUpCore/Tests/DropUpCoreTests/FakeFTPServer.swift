import Foundation
@testable import DropUpCore

/// A scripted FTP server behind fake byte streams, enough to drive `FTPSession` through
/// login, passive mode, uploads and listings without a socket.
final class FakeFTPServer: ByteStreamOpener, @unchecked Sendable {
    static let controlPort = 21
    static let dataPort = 5000

    private let lock = NSLock()
    var users = ["me": "secret"]
    var supportsEPSV = true
    var supportsMLSD = true
    var supportsSIZE = true
    /// Paths that STOR refuses with 553.
    var readOnlyPaths: Set<String> = []
    /// Folder path → subfolder names.
    var folders: [String: [String]] = ["/": ["drops"], "/drops": ["My Photos", "archive"]]

    private(set) var files: [String: Data] = [:]
    private(set) var commands: [String] = []
    private(set) var openedEndpoints: [String] = []

    private var outbox = Data()
    private var user: String?
    private var dataStream: FakeDataStream?
    private var storingPath: String?

    // MARK: ByteStreamOpener

    func open(host: String, port: Int) async throws -> any ByteStream {
        try lock.withLock { () throws -> any ByteStream in
            openedEndpoints.append("\(host):\(port)")
            if port == Self.controlPort {
                outbox.append(Data("220 Fake FTP ready\r\n".utf8))
                return FakeControlStream(server: self)
            }
            guard port == Self.dataPort, let dataStream else {
                throw UploaderError.connectionFailed("fake: nothing listening on \(port)")
            }
            return dataStream
        }
    }

    func seed(_ path: String, _ contents: String = "x") {
        lock.withLock { files[path] = Data(contents.utf8) }
    }

    func file(_ path: String) -> Data? {
        lock.withLock { files[path] }
    }

    var commandLog: [String] { lock.withLock { commands } }

    // MARK: Control channel

    fileprivate func receiveFromServer(maxLength: Int) throws -> Data {
        try lock.withLock { () throws -> Data in
            guard !outbox.isEmpty else {
                // A real server would block here; failing makes a protocol bug show up as a test failure.
                throw UploaderError.connectionFailed("fake: client waited for a reply that was never sent")
            }
            let chunk = outbox.prefix(maxLength)
            outbox.removeFirst(chunk.count)
            return Data(chunk)
        }
    }

    fileprivate func receiveFromClient(_ data: Data) {
        lock.withLock {
            let text = String(decoding: data, as: UTF8.self)
            for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
                commands.append(line.hasPrefix("PASS ") ? "PASS ***" : line)
                reply(handle(line))
            }
        }
    }

    fileprivate func dataStreamClosed(_ stream: FakeDataStream) {
        lock.withLock {
            guard stream === dataStream else { return }
            dataStream = nil
            if let path = storingPath {
                files[path] = stream.received
                storingPath = nil
                reply("226 Transfer complete")
            }
        }
    }

    private func reply(_ line: String) {
        outbox.append(Data((line + "\r\n").utf8))
    }

    private func handle(_ line: String) -> String {
        let verb = line.prefix(while: { $0 != " " }).uppercased()
        let argument = line.contains(" ") ? String(line[line.index(after: line.firstIndex(of: " ")!)...]) : ""
        switch verb {
        case "USER":
            user = argument
            return "331 Password required"
        case "PASS":
            guard let user, users[user] == argument else { return "530 Login incorrect" }
            return "230 Logged in"
        case "OPTS":
            return "200 OK"
        case "TYPE":
            return argument == "I" ? "200 Binary" : "504 Unsupported type"
        case "EPSV":
            guard supportsEPSV else { return "500 EPSV not understood" }
            dataStream = FakeDataStream(server: self)
            return "229 Entering Extended Passive Mode (|||\(Self.dataPort)|)"
        case "PASV":
            dataStream = FakeDataStream(server: self)
            // Advertises a private address the client should ignore.
            return "227 Entering Passive Mode (10,0,0,1,\(Self.dataPort / 256),\(Self.dataPort % 256))"
        case "SIZE":
            guard supportsSIZE else { return "502 SIZE not implemented" }
            if let file = files[argument] { return "213 \(file.count)" }
            return "550 No such file"
        case "MDTM":
            return files[argument] != nil ? "213 20260101120000" : "550 No such file"
        case "STOR":
            guard dataStream != nil else { return "425 Use PASV first" }
            if readOnlyPaths.contains(argument) { return "553 Permission denied" }
            storingPath = argument
            return "150 Opening data connection"
        case "MLSD", "LIST":
            if verb == "MLSD", !supportsMLSD { return "500 MLSD not understood" }
            guard let dataStream else { return "425 Use PASV first" }
            guard let subfolders = folders[argument] else { return "550 No such folder" }
            dataStream.toSend = Data(listing(subfolders, machineReadable: verb == "MLSD").utf8)
            reply("150 Here comes the listing")
            return "226 Listing sent"
        case "QUIT":
            return "221 Bye"
        default:
            return "502 Not implemented"
        }
    }

    private func listing(_ subfolders: [String], machineReadable: Bool) -> String {
        if machineReadable {
            let entries = ["type=cdir;perm=el; .", "type=pdir;perm=el; ..", "type=file;size=5; notes.txt", "type=dir;perm=el; .hidden"]
                + subfolders.map { "type=dir;modify=20260101120000;perm=flcdmpe; \($0)" }
            return entries.joined(separator: "\r\n") + "\r\n"
        }
        let entries = ["-rw-r--r--    1 me  staff     5 Sep 10 12:00 notes.txt", "lrwxr-xr-x    1 me  staff     5 Sep 10 12:00 link -> elsewhere"]
            + subfolders.map { "drwxr-xr-x    2 me  staff  4096 Sep 10 12:00 \($0)" }
        return entries.joined(separator: "\r\n") + "\r\n"
    }
}

private final class FakeControlStream: ByteStream, @unchecked Sendable {
    let server: FakeFTPServer
    init(server: FakeFTPServer) { self.server = server }

    func send(_ data: Data) async throws { server.receiveFromClient(data) }
    func receive(maxLength: Int) async throws -> Data { try server.receiveFromServer(maxLength: maxLength) }
    func close() async {}
}

final class FakeDataStream: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private weak var server: FakeFTPServer?
    private var _received = Data()
    private var _toSend = Data()

    init(server: FakeFTPServer) { self.server = server }

    var received: Data { lock.withLock { _received } }
    var toSend: Data {
        get { lock.withLock { _toSend } }
        set { lock.withLock { _toSend = newValue } }
    }

    func send(_ data: Data) async throws {
        lock.withLock { _received.append(data) }
    }

    func receive(maxLength: Int) async throws -> Data {
        lock.withLock { () -> Data in
            let chunk = _toSend.prefix(maxLength)
            _toSend.removeFirst(chunk.count)
            return Data(chunk)
        }
    }

    func close() async {
        server?.dataStreamClosed(self)
    }
}
