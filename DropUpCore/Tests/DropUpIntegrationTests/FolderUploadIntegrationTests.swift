import DropUpCore
import DropUpTransport
import Foundation
import Testing

/// Folder uploads against the real FTP and SFTP servers started by `scripts/test-servers.py`.
/// They run only when `DROPUP_IT_ROOT` is set.
struct FolderUploadIntegrationTests {
    static let root = ProcessInfo.processInfo.environment["DROPUP_IT_ROOT"]
    static let enabled = root != nil

    private func config(_ transferProtocol: TransferProtocol) -> ServerConfig {
        let port = Int(ProcessInfo.processInfo.environment[transferProtocol == .ftp ? "DROPUP_IT_FTP_PORT" : "DROPUP_IT_SFTP_PORT"] ?? "") ?? 0
        return ServerConfig(transferProtocol: transferProtocol, host: "127.0.0.1", port: port, username: "me", remoteDirectory: "/drops")
    }

    private func makeQueue(_ config: ServerConfig) -> UploadQueue {
        UploadQueue(
            settings: InMemorySettingsStore(config: config),
            credentials: InMemoryCredentialStore(passwords: [config.credentialKey: "secret"]),
            connectors: FolderTestConnectors(
                ftp: FTPConnector(opener: makeByteStreamOpener()),
                sftp: SFTPConnector(hostKeys: InMemoryHostKeyStore())
            ),
            progressInterval: 0
        )
    }

    /// A folder on this Mac with `subfolders` folders, each holding one small file.
    private func makeFolder(subfolders: Int) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("it-folder-\(UUID().uuidString.prefix(8))")
        let data = Data(repeating: 7, count: 2048)
        for index in 0..<subfolders {
            let sub = folder.appendingPathComponent("d\(index)")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try data.write(to: sub.appendingPathComponent("f.bin"))
        }
        return folder
    }

    private func serverFolder(_ name: String) -> String { Self.root! + "/drops/" + name }

    private func subfolderCount(_ name: String) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: serverFolder(name))) ?? []).count
    }

    @Test(.enabled(if: FolderUploadIntegrationTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func aFolderArrivesWithEverythingInItIntact(_ transferProtocol: TransferProtocol) async throws {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("it-folder-\(UUID().uuidString.prefix(8))")
        let fm = FileManager.default
        try fm.createDirectory(at: local.appendingPathComponent("sub/deeper"), withIntermediateDirectories: true)
        try fm.createDirectory(at: local.appendingPathComponent("empty/inner"), withIntermediateDirectories: true)
        try Data("top".utf8).write(to: local.appendingPathComponent("a.txt"))
        try Data("middle".utf8).write(to: local.appendingPathComponent("sub/b.txt"))
        try Data("bottom".utf8).write(to: local.appendingPathComponent("sub/deeper/c.txt"))
        let name = local.lastPathComponent
        defer {
            try? fm.removeItem(at: local)
            try? fm.removeItem(atPath: serverFolder(name))
        }

        let queue = makeQueue(config(transferProtocol))
        let ids = await queue.enqueue([local])
        await queue.waitUntilIdle()
        await queue.finish()
        var events: [UploadEvent] = []
        for await event in queue.events { events.append(event) }

        #expect(events.last == .succeeded(id: ids[0], remotePath: "/drops/\(name)"))
        let base = serverFolder(name)
        #expect(fm.contents(atPath: base + "/a.txt") == Data("top".utf8))
        #expect(fm.contents(atPath: base + "/sub/b.txt") == Data("middle".utf8))
        #expect(fm.contents(atPath: base + "/sub/deeper/c.txt") == Data("bottom".utf8))
        var isDirectory: ObjCBool = false
        #expect(fm.fileExists(atPath: base + "/empty/inner", isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    /// A folder with a great many subfolders used to make every one of them before sending anything and to ignore
    /// a cancel until all were made, so the row sat at 0 % and Cancel did nothing.
    @Test(.enabled(if: FolderUploadIntegrationTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func cancellingAFolderWithManySubfoldersStopsPromptly(_ transferProtocol: TransferProtocol) async throws {
        let subfolders = 2000
        let local = try makeFolder(subfolders: subfolders)
        let name = local.lastPathComponent
        defer {
            try? FileManager.default.removeItem(at: local)
            try? FileManager.default.removeItem(atPath: serverFolder(name))
        }

        let queue = makeQueue(config(transferProtocol))
        let ids = await queue.enqueue([local])
        // Sending starts at once: the first subfolders appear while the rest are still to come.
        var made = 0
        for _ in 0..<2000 where made < 20 {
            try await Task.sleep(nanoseconds: 10_000_000)
            made = subfolderCount(name)
        }
        #expect(made >= 20)

        let started = Date()
        await queue.cancel(ids[0])
        await queue.waitUntilIdle()
        let took = Date().timeIntervalSince(started)
        await queue.finish()
        var events: [UploadEvent] = []
        for await event in queue.events { events.append(event) }

        #expect(events.contains(.cancelled(id: ids[0])))
        #expect(took < 5)
        #expect(subfolderCount(name) < subfolders)
    }
}

private struct FolderTestConnectors: ConnectorFactory {
    let ftp: FTPConnector
    let sftp: SFTPConnector

    func connector(for transferProtocol: TransferProtocol) -> any ServerConnector {
        switch transferProtocol {
        case .ftp: ftp
        case .sftp: sftp
        }
    }
}
