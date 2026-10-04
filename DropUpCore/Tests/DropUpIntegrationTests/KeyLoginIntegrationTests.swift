import DropUpCore
import DropUpTransport
import Foundation
import Testing

/// Signing in to the SFTP server with an SSH key, against the real server started by `scripts/test-servers.py`, which
/// takes keys as well as the password. The key files it made are in `DROPUP_IT_KEY_DIR`. They run only when it is set.
struct KeyLoginIntegrationTests {
    static let root = ProcessInfo.processInfo.environment["DROPUP_IT_ROOT"]
    static let keyDirectory = ProcessInfo.processInfo.environment["DROPUP_IT_KEY_DIR"]
    static let enabled = root != nil && keyDirectory != nil

    private static let passphrase = "key-secret"

    private func keyPath(_ name: String) -> String { Self.keyDirectory! + "/" + name }

    private func port(modern: Bool) -> Int {
        Int(ProcessInfo.processInfo.environment[modern ? "DROPUP_IT_SFTP_MODERN_PORT" : "DROPUP_IT_SFTP_PORT"] ?? "") ?? 0
    }

    private func config(key: String, directory: String = "/drops", modern: Bool = false, path: String? = nil) -> ServerConfig {
        ServerConfig(
            transferProtocol: .sftp, host: "127.0.0.1", port: port(modern: modern), username: "me",
            remoteDirectory: directory, loginMethod: .sshKey, keyFilePath: path ?? keyPath(key)
        )
    }

    private func passwordConfig(directory: String = "/drops") -> ServerConfig {
        ServerConfig(transferProtocol: .sftp, host: "127.0.0.1", port: port(modern: false), username: "me", remoteDirectory: directory)
    }

    private func connectors() -> any ConnectorFactory {
        BreakingConnectors(
            board: Switchboard(),
            ftp: FTPConnector(opener: makeByteStreamOpener()),
            sftp: SFTPConnector(hostKeys: InMemoryHostKeyStore())
        )
    }

    private func makeQueue(
        _ config: ServerConfig, secret: String?, board: Switchboard = Switchboard(),
        reconnect: ReconnectPolicy = ReconnectPolicy(delays: [], giveUpAfter: 30, noticeAfter: 5)
    ) -> UploadQueue {
        let passwords = secret.map { [config.credentialKey: $0] } ?? [:]
        return UploadQueue(
            settings: InMemorySettingsStore(config: config),
            credentials: InMemoryCredentialStore(passwords: passwords),
            connectors: BreakingConnectors(
                board: board,
                ftp: FTPConnector(opener: makeByteStreamOpener()),
                sftp: SFTPConnector(hostKeys: InMemoryHostKeyStore())
            ),
            progressInterval: 0,
            reconnect: reconnect
        )
    }

    private func finish(_ queue: UploadQueue) async -> [UploadEvent] {
        await queue.waitUntilIdle()
        await queue.finish()
        var events: [UploadEvent] = []
        for await event in queue.events { events.append(event) }
        return events
    }

    private func uniqueName(_ ext: String = "bin") -> String { "key-\(UUID().uuidString.prefix(8)).\(ext)" }

    private func serverFile(_ path: String) -> Data? { FileManager.default.contents(atPath: Self.root! + path) }

    private func temporaryFile(_ data: Data, named name: String? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name ?? uniqueName())
        try data.write(to: url)
        return url
    }

    private func randomData(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    /// What testing the connection says when it fails, as the settings screen shows it.
    private func testConnectionError(_ config: ServerConfig, secret: String) async -> UploaderError? {
        do {
            _ = try await ServerBrowser(connectors: connectors()).testConnection(config, password: secret)
            return nil
        } catch let error as UploaderError {
            return error
        } catch {
            Issue.record("Not an UploaderError: \(error)")
            return nil
        }
    }

    // MARK: Signing in

    /// Every kind of key that works: with and without a passphrase, and with both ciphers `ssh-keygen` has used.
    static let working: [(key: String, passphrase: String)] = [
        ("ed25519", ""), ("ed25519-pass", passphrase), ("ed25519-aes128", passphrase),
        ("rsa", ""), ("rsa-pass", passphrase),
    ]

    @Test(.enabled(if: KeyLoginIntegrationTests.enabled), arguments: KeyLoginIntegrationTests.working.map { "\($0.key)|\($0.passphrase)" })
    func aKeyLogsInAndUploadsAFileIntact(_ pair: String) async throws {
        let parts = pair.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let (key, secret) = (parts[0], parts[1])
        let name = uniqueName()
        let data = randomData(2_500_000)
        let local = try temporaryFile(data, named: name)
        defer { try? FileManager.default.removeItem(at: local) }
        let server = config(key: key)

        let result = try await ServerBrowser(connectors: connectors()).testConnection(server, password: secret)
        #expect(result.folders.contains("archive"))

        let queue = makeQueue(server, secret: secret.isEmpty ? nil : secret)
        let ids = await queue.enqueue([local])
        let events = await finish(queue)

        #expect(events.contains(.succeeded(id: ids[0], remotePath: "/drops/\(name)")))
        #expect(serverFile("/drops/\(name)") == data)
        try? FileManager.default.removeItem(atPath: Self.root! + "/drops/\(name)")
    }

    @Test(.enabled(if: KeyLoginIntegrationTests.enabled))
    func aKeyWithNoPassphraseIgnoresOneThatIsStillSaved() async throws {
        let result = try await ServerBrowser(connectors: connectors()).testConnection(config(key: "ed25519"), password: "left over")
        #expect(result.folders.contains("archive"))
    }

    @Test(.enabled(if: KeyLoginIntegrationTests.enabled))
    func aFolderUploadsWithAKey() async throws {
        let fm = FileManager.default
        let local = fm.temporaryDirectory.appendingPathComponent("key-folder-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: local.appendingPathComponent("sub/deeper"), withIntermediateDirectories: true)
        try Data("top".utf8).write(to: local.appendingPathComponent("a.txt"))
        let big = randomData(1_200_000)
        try big.write(to: local.appendingPathComponent("sub/big.bin"))
        try Data("bottom".utf8).write(to: local.appendingPathComponent("sub/deeper/c.txt"))
        let name = local.lastPathComponent
        defer {
            try? fm.removeItem(at: local)
            try? fm.removeItem(atPath: Self.root! + "/drops/" + name)
        }

        let queue = makeQueue(config(key: "ed25519-pass"), secret: Self.passphrase)
        let ids = await queue.enqueue([local])
        let events = await finish(queue)

        #expect(events.last == .succeeded(id: ids[0], remotePath: "/drops/\(name)"))
        #expect(serverFile("/drops/\(name)/a.txt") == Data("top".utf8))
        #expect(serverFile("/drops/\(name)/sub/big.bin") == big)
        #expect(serverFile("/drops/\(name)/sub/deeper/c.txt") == Data("bottom".utf8))
    }

    @Test(.enabled(if: KeyLoginIntegrationTests.enabled))
    func browsingAndDownloadingWorkWithAKey() async throws {
        let name = uniqueName()
        let data = randomData(1_500_000)
        try data.write(to: URL(fileURLWithPath: Self.root! + "/ops/\(name)"))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: Self.root! + "/ops/\(name)")
            try? FileManager.default.removeItem(at: destination)
        }
        let server = config(key: "rsa-pass", directory: "/ops")

        let browse = BrowseSession(connectors: connectors(), config: server, password: Self.passphrase)
        let listing = try await browse.entries(atPath: "/ops")
        try await browse.makeFolder(named: "made-with-key-\(name)", in: "/ops")
        await browse.close()
        #expect(listing.contains { $0.name == name && $0.size == Int64(data.count) })
        #expect(FileManager.default.fileExists(atPath: Self.root! + "/ops/made-with-key-\(name)"))
        try? FileManager.default.removeItem(atPath: Self.root! + "/ops/made-with-key-\(name)")

        let queue = DownloadQueue(connectors: connectors(), progressInterval: 0)
        await queue.enqueue(
            [RemoteDownload(remotePath: "/ops/\(name)", size: Int64(data.count))],
            from: server, password: Self.passphrase, into: destination
        )
        await queue.waitUntilIdle()
        await queue.finish()
        var events: [DownloadEvent] = []
        for await event in queue.events { events.append(event) }
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
        #expect(FileManager.default.contents(atPath: destination.appendingPathComponent(name).path) == data)
    }

    @Test(.enabled(if: KeyLoginIntegrationTests.enabled))
    func thePasswordStillWorksOnTheSameServer() async throws {
        let name = uniqueName("txt")
        let local = try temporaryFile(Data("password".utf8), named: name)
        defer {
            try? FileManager.default.removeItem(at: local)
            try? FileManager.default.removeItem(atPath: Self.root! + "/drops/\(name)")
        }
        let server = passwordConfig()
        #expect(!server.usesKey)

        let queue = makeQueue(server, secret: "secret")
        let ids = await queue.enqueue([local])
        let events = await finish(queue)

        #expect(events.contains(.succeeded(id: ids[0], remotePath: "/drops/\(name)")))
        #expect(serverFile("/drops/\(name)") == Data("password".utf8))
        // And a wrong one is still a wrong password, not a key problem.
        #expect(await testConnectionError(server, secret: "wrong") == .authenticationFailed)
    }

    // MARK: What goes wrong

    @Test(.enabled(if: KeyLoginIntegrationTests.enabled))
    func aKeyThatNeedsAPassphraseSaysSo() async {
        #expect(await testConnectionError(config(key: "ed25519-pass"), secret: "") == .keyNeedsPassphrase)
        #expect(await testConnectionError(config(key: "rsa-pass"), secret: "") == .keyNeedsPassphrase)
    }

    @Test(.enabled(if: KeyLoginIntegrationTests.enabled))
    func aWrongPassphraseSaysSo() async {
        #expect(await testConnectionError(config(key: "ed25519-pass"), secret: "not it") == .keyPassphraseWrong)
        #expect(await testConnectionError(config(key: "rsa-pass"), secret: "not it") == .keyPassphraseWrong)
    }

    @Test(.enabled(if: KeyLoginIntegrationTests.enabled), arguments: ["ed25519-unknown", "rsa-unknown"])
    func aKeyTheServerDoesNotKnowIsRefusedAsAKey(_ key: String) async {
        let error = await testConnectionError(config(key: key), secret: "")
        #expect(error == .keyRejected(rsa: key.hasPrefix("rsa")))
        #expect(error != .authenticationFailed)
    }

    @Test(.enabled(if: KeyLoginIntegrationTests.enabled))
    func aKeyFileThatIsNotThereSaysSo() async {
        let missing = keyPath("no-such-key")
        let error = await testConnectionError(config(key: "x", path: missing), secret: "")
        #expect(error == .keyFileUnreadable)
        #expect(error?.errorDescription?.contains(missing) == false)
        #expect(await testConnectionError(config(key: "x", path: Self.keyDirectory!), secret: "") == .keyFileUnreadable)
    }

    @Test(.enabled(if: KeyLoginIntegrationTests.enabled), arguments: ["not-a-key.txt", "rsa-pem", "ed25519.pub", "ed25519-truncated"])
    func aFileThatIsNotAnOpenSSHKeyIsNotRead(_ file: String) async {
        #expect(await testConnectionError(config(key: file), secret: "") == .keyFormatUnsupported)
    }

    @Test(.enabled(if: KeyLoginIntegrationTests.enabled), arguments: ["ecdsa-p256", "ecdsa-p384", "ecdsa-p521"])
    func anEcdsaKeyIsSaidToBeUnsupported(_ file: String) async {
        let error = await testConnectionError(config(key: file), secret: "")
        #expect(error == .keyTypeUnsupported("ECDSA"))
        #expect(error?.errorDescription?.contains("ECDSA") == true)
    }

    @Test(.enabled(if: KeyLoginIntegrationTests.enabled))
    func aKeyEncryptedWithACipherThatCannotBeOpenedIsNotCalledAWrongPassphrase() async {
        let error = await testConnectionError(config(key: "ed25519-gcm"), secret: Self.passphrase)
        #expect(error == .keyCipherUnsupported("aes256-gcm@openssh.com"))
    }

    @Test(.enabled(if: KeyLoginIntegrationTests.enabled))
    func aCurrentServerTakesEd25519ButRefusesTheOldRSASignature() async throws {
        let ok = try await ServerBrowser(connectors: connectors()).testConnection(config(key: "ed25519", modern: true), password: "")
        #expect(ok.folders.contains("archive"))
        // The server knows this key; the SSH library can only sign RSA with SHA-1, which a current OpenSSH refuses.
        let error = await testConnectionError(config(key: "rsa", modern: true), secret: "")
        #expect(error == .keyRejected(rsa: true))
        #expect(error?.errorDescription?.contains("ed25519") == true)
    }

    @Test(.enabled(if: KeyLoginIntegrationTests.enabled))
    func aKeyProblemShowsAsAFailedUploadWithTheSameWords() async throws {
        let local = try temporaryFile(Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: local) }

        let queue = makeQueue(config(key: "ed25519-pass"), secret: "not it")
        let ids = await queue.enqueue([local])
        let events = await finish(queue)

        #expect(events.contains(.failed(id: ids[0], .transfer("The passphrase doesn't unlock this SSH key."))))
    }

    // MARK: Carrying on

    @Test(.enabled(if: KeyLoginIntegrationTests.enabled))
    func aCutOffUploadWithAKeyResumesAfterARelaunchFromWhatWasWrittenDown() async throws {
        let name = uniqueName()
        let data = randomData(6_000_000)
        let local = try temporaryFile(data, named: name)
        defer {
            try? FileManager.default.removeItem(at: local)
            try? FileManager.default.removeItem(atPath: Self.root! + "/ops/\(name)")
        }
        let server = config(key: "ed25519-pass", directory: "/ops")

        let board = Switchboard()
        board.cut(path: name, after: 2_000_000)
        let first = makeQueue(server, secret: Self.passphrase, board: board)
        let id = await first.enqueue([local])[0]
        let firstEvents = await finish(first)
        let written = try #require(firstEvents.reversed().compactMap { event -> ResumePoint? in
            if case .resumable(let eventID, let point) = event, eventID == id { point } else { nil }
        }.first)
        // What survives a quit is the JSON, and it holds the way in: the key's file and no secret.
        let encoded = try JSONEncoder().encode(written)
        let point = try JSONDecoder().decode(ResumePoint.self, from: encoded)
        #expect(point.config?.loginMethod == .sshKey)
        #expect(point.config?.keyFilePath == keyPath("ed25519-pass"))
        #expect(!String(decoding: encoded, as: UTF8.self).contains(Self.passphrase))
        let partial = try #require(FileManager.default.attributesOfItem(atPath: Self.root! + "/ops/\(name)")[.size] as? NSNumber)
        #expect(partial.intValue > 0 && partial.intValue < data.count)

        let carried = Switchboard()
        let second = makeQueue(server, secret: Self.passphrase, board: carried)
        await second.resume(id, from: point)
        let events = await finish(second)

        #expect(events.last == .succeeded(id: id, remotePath: "/ops/\(name)"))
        #expect(serverFile("/ops/\(name)") == data)
        #expect(try #require(carried.offsets.first) > 0)
        #expect(!FileManager.default.fileExists(atPath: Self.root! + "/ops/" + name.replacingOccurrences(of: ".bin", with: "-1.bin")))
    }

    @Test(.enabled(if: KeyLoginIntegrationTests.enabled))
    func aKeyFileThatWasMovedFailsClearlyAndTheUploadResumesOnceItIsBack() async throws {
        let name = uniqueName()
        let data = randomData(5_000_000)
        let local = try temporaryFile(data, named: name)
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("key-copy-\(UUID().uuidString.prefix(8))")
        try FileManager.default.copyItem(atPath: keyPath("ed25519"), toPath: kept.path)
        let hidden = kept.appendingPathExtension("away")
        defer {
            try? FileManager.default.removeItem(at: local)
            try? FileManager.default.removeItem(at: kept)
            try? FileManager.default.removeItem(at: hidden)
            try? FileManager.default.removeItem(atPath: Self.root! + "/ops/\(name)")
        }
        let server = config(key: "ed25519", directory: "/ops", path: kept.path)

        let board = Switchboard()
        board.cut(path: name, after: 1_500_000)
        let first = makeQueue(server, secret: nil, board: board)
        let id = await first.enqueue([local])[0]
        let firstEvents = await finish(first)
        var point = try #require(firstEvents.reversed().compactMap { event -> ResumePoint? in
            if case .resumable(let eventID, let point) = event, eventID == id { point } else { nil }
        }.first)

        // The key goes missing while the upload waits.
        try FileManager.default.moveItem(at: kept, to: hidden)
        let missing = makeQueue(server, secret: nil)
        await missing.resume(id, from: point)
        let missingEvents = await finish(missing)
        #expect(missingEvents.contains(.failed(id: id, .transfer("The SSH key file is missing or can't be read."))))
        #expect(!missingEvents.contains { if case .succeeded = $0 { true } else { false } })
        // The half-sent file is still there to carry on from.
        #expect(FileManager.default.fileExists(atPath: Self.root! + "/ops/\(name)"))
        point = missingEvents.reversed().compactMap { event -> ResumePoint? in
            if case .resumable(let eventID, let point) = event, eventID == id { point } else { nil }
        }.first ?? point

        try FileManager.default.moveItem(at: hidden, to: kept)
        let back = makeQueue(server, secret: nil)
        await back.resume(id, from: point)
        let events = await finish(back)

        #expect(events.last == .succeeded(id: id, remotePath: "/ops/\(name)"))
        #expect(serverFile("/ops/\(name)") == data)
    }
}
