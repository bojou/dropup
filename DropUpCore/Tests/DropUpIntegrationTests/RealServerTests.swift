import DropUpCore
import DropUpTransport
import Foundation
import Testing

/// End-to-end tests against real FTP and SFTP servers started by `scripts/test-servers.py`.
/// They run only when `DROPUP_IT_ROOT` is set (the script prints the variables to export).
struct RealServerTests {
    static let root = ProcessInfo.processInfo.environment["DROPUP_IT_ROOT"]
    static let enabled = root != nil

    static func port(_ name: String) -> Int {
        Int(ProcessInfo.processInfo.environment[name] ?? "") ?? 0
    }

    func config(_ transferProtocol: TransferProtocol, directory: String = "/drops") -> ServerConfig {
        ServerConfig(
            transferProtocol: transferProtocol,
            host: "127.0.0.1",
            port: Self.port(transferProtocol == .ftp ? "DROPUP_IT_FTP_PORT" : "DROPUP_IT_SFTP_PORT"),
            username: "me",
            remoteDirectory: directory
        )
    }

    func connectors(hostKeys: any HostKeyStore = InMemoryHostKeyStore()) -> any ConnectorFactory {
        IntegrationConnectors(ftp: FTPConnector(opener: makeByteStreamOpener()), sftp: SFTPConnector(hostKeys: hostKeys))
    }

    func serverFile(_ path: String) -> Data? {
        FileManager.default.contents(atPath: Self.root! + path)
    }

    func uniqueName(_ ext: String = "bin") -> String { "it-\(UUID().uuidString.prefix(8)).\(ext)" }

    func makeQueue(_ config: ServerConfig, password: String = "secret", hostKeys: any HostKeyStore = InMemoryHostKeyStore()) -> UploadQueue {
        let credentials = InMemoryCredentialStore(passwords: [config.credentialKey: password])
        return UploadQueue(settings: InMemorySettingsStore(config: config), credentials: credentials, connectors: connectors(hostKeys: hostKeys), progressInterval: 0)
    }

    func upload(_ file: URL, config: ServerConfig, password: String = "secret", hostKeys: any HostKeyStore = InMemoryHostKeyStore()) async -> [UploadEvent] {
        let queue = makeQueue(config, password: password, hostKeys: hostKeys)
        await queue.enqueue([file])
        await queue.waitUntilIdle()
        await queue.finish()
        var events: [UploadEvent] = []
        for await event in queue.events { events.append(event) }
        return events
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func uploadsALargeFileIntact(_ transferProtocol: TransferProtocol) async throws {
        let name = uniqueName()
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        // 3.5 MB of non-repeating-looking bytes, so a dropped or reordered chunk changes the content.
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<3_500_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try data.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        let events = await upload(local, config: config(transferProtocol))

        #expect(events.contains { if case .succeeded(_, let path) = $0 { path == "/drops/\(name)" } else { false } })
        #expect(serverFile("/drops/\(name)") == data)
        let fractions = events.compactMap { event -> Double? in
            if case .progress(_, let progress) = event { progress.fraction } else { nil }
        }
        #expect(fractions == fractions.sorted())
        #expect(fractions.last == 1)
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func emptyFileUploads(_ transferProtocol: TransferProtocol) async throws {
        let name = uniqueName("txt")
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try Data().write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        let events = await upload(local, config: config(transferProtocol))

        #expect(events.contains { if case .succeeded = $0 { true } else { false } })
        #expect(serverFile("/drops/\(name)") == Data())
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func secondDropOfTheSameNameIsNumbered(_ transferProtocol: TransferProtocol) async throws {
        let stem = "dup-\(UUID().uuidString.prefix(8))"
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("\(stem).txt")
        try Data("one".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        let first = await upload(local, config: config(transferProtocol))
        let second = await upload(local, config: config(transferProtocol))

        #expect(first.contains { if case .succeeded(_, let path) = $0 { path == "/drops/\(stem).txt" } else { false } })
        #expect(second.contains { if case .succeeded(_, let path) = $0 { path == "/drops/\(stem)-1.txt" } else { false } })
        #expect(serverFile("/drops/\(stem)-1.txt") == Data("one".utf8))
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func namesWithSpacesAndUnicodeSurvive(_ transferProtocol: TransferProtocol) async throws {
        let name = "Bericht – Größe \(UUID().uuidString.prefix(6)).txt"
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try Data("hej".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        let events = await upload(local, config: config(transferProtocol))

        #expect(events.contains { if case .succeeded = $0 { true } else { false } })
        #expect(serverFile("/drops/\(name)") == Data("hej".utf8))
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func wrongPasswordIsReportedPlainly(_ transferProtocol: TransferProtocol) async throws {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(uniqueName("txt"))
        try Data("x".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        let events = await upload(local, config: config(transferProtocol), password: "wrong")

        #expect(events.contains(.failed(id: queuedID(events), .transfer("The server rejected the username or password."))))
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func missingFolderIsReported(_ transferProtocol: TransferProtocol) async throws {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(uniqueName("txt"))
        try Data("x".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        let events = await upload(local, config: config(transferProtocol, directory: "/no/such/folder"))

        let failed = events.contains { if case .failed = $0 { true } else { false } }
        #expect(failed)
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func testConnectionListsFolders(_ transferProtocol: TransferProtocol) async throws {
        let browser = ServerBrowser(connectors: connectors())

        let result = try await browser.testConnection(config(transferProtocol), password: "secret")
        let root = try await browser.listDirectories(config(transferProtocol), password: "secret", path: "/")

        #expect(result.folders.contains("archive"))
        #expect(root.contains("drops"))
    }

    @Test(.enabled(if: RealServerTests.enabled), arguments: [TransferProtocol.ftp, .sftp])
    func unreachablePortFailsFast(_ transferProtocol: TransferProtocol) async throws {
        var unreachable = config(transferProtocol)
        unreachable.port = 1
        let browser = ServerBrowser(connectors: connectors())

        let started = Date()
        await #expect(throws: UploaderError.self) {
            _ = try await browser.testConnection(unreachable, password: "secret")
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test(.enabled(if: RealServerTests.enabled))
    func sftpTrustsFirstHostKeyThenRejectsAChangedOne() async throws {
        let hostKeys = InMemoryHostKeyStore()
        let sftp = config(.sftp)
        let browser = ServerBrowser(connectors: connectors(hostKeys: hostKeys))

        _ = try await browser.testConnection(sftp, password: "secret")
        let remembered = try #require(hostKeys.trustedKey(for: sftp.hostKeyID))
        #expect(remembered.hasPrefix("ssh-ed25519 "))
        _ = try await browser.testConnection(sftp, password: "secret")

        // Pretend the server's key was different when we first saw it.
        hostKeys.trust("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f", for: sftp.hostKeyID)
        do {
            _ = try await browser.testConnection(sftp, password: "secret")
            Issue.record("Expected the changed host key to be rejected")
        } catch let error as UploaderError {
            guard case .hostKeyChanged(let fingerprint) = error else {
                Issue.record("Wrong error: \(error)")
                return
            }
            #expect(fingerprint.hasPrefix("SHA256:"))
        }
    }

    private func queuedID(_ events: [UploadEvent]) -> UUID {
        for case .queued(let id, _, _) in events { return id }
        return UUID()
    }
}

private struct IntegrationConnectors: ConnectorFactory {
    let ftp: FTPConnector
    let sftp: SFTPConnector

    func connector(for transferProtocol: TransferProtocol) -> any ServerConnector {
        switch transferProtocol {
        case .ftp: ftp
        case .sftp: sftp
        }
    }
}
