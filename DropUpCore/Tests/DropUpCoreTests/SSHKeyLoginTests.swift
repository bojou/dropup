import Foundation
import Testing
@testable import DropUpCore

/// Signing in to an SFTP server with an SSH key, and above all that nothing changes for a password login.
struct SSHKeyLoginTests {
    let password = ServerConfig(transferProtocol: .sftp, host: "example.com", username: "me", remoteDirectory: "/drops")
    let key = ServerConfig(
        transferProtocol: .sftp, host: "example.com", username: "me", remoteDirectory: "/drops",
        loginMethod: .sshKey, keyFilePath: "/Users/me/.ssh/id_ed25519"
    )

    // MARK: Settings and rows saved before SSH keys existed

    @Test func settingsSavedByAnEarlierVersionAreAPasswordLogin() throws {
        let saved = #"{"transferProtocol":"sftp","host":"example.com","port":2222,"username":"me","remoteDirectory":"/drops"}"#
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(saved.utf8))

        #expect(config.loginMethod == .password)
        #expect(config.keyFilePath == nil)
        #expect(!config.usesKey)
        #expect(config == ServerConfig(transferProtocol: .sftp, host: "example.com", port: 2222, username: "me", remoteDirectory: "/drops"))
        // The Keychain item the password was saved under is found by the same key as before.
        #expect(config.credentialKey == "sftp://me@example.com:2222")
    }

    @Test func aFtpServerAndADisplayNameFromAnEarlierVersionDecodeToo() throws {
        let saved = #"{"transferProtocol":"ftp","host":"ftp.example.com","port":21,"username":"u","remoteDirectory":"/","displayName":"Site"}"#
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(saved.utf8))

        #expect(config == ServerConfig(transferProtocol: .ftp, host: "ftp.example.com", username: "u", remoteDirectory: "/", displayName: "Site"))
        #expect(config.credentialKey == "ftp://u@ftp.example.com:21")
    }

    @Test func aResumePointFromAnEarlierVersionGoesOnWithThePassword() throws {
        let saved = """
        {"sourcePath":"/tmp/big.bin","isFolder":false,"config":{"transferProtocol":"sftp","host":"example.com","port":22,\
        "username":"me","remoteDirectory":"/drops"},"remotePath":"/drops/big.bin","totalBytes":1000,"created":true,\
        "finishedFiles":0}
        """
        let point = try JSONDecoder().decode(ResumePoint.self, from: Data(saved.utf8))

        #expect(point.config == password)
        #expect(point.config?.usesKey == false)
        #expect(point.partialPath == "/drops/big.bin")
    }

    @Test func aStoredUploadFromAnEarlierVersionDecodesAsAPasswordLogin() throws {
        let saved = """
        {"fileName":"big.bin","totalBytes":1000,"outcome":"interrupted","detail":"","finishedAt":0,\
        "resume":{"sourcePath":"/tmp/big.bin","isFolder":false,"config":{"transferProtocol":"sftp","host":"example.com","port":22,\
        "username":"me","remoteDirectory":"/drops"},"remotePath":"/drops/big.bin","totalBytes":1000,"created":true,"finishedFiles":0}}
        """
        let stored = try JSONDecoder().decode(StoredUpload.self, from: Data(saved.utf8))

        #expect(stored.resume?.config == password)
    }

    @Test func aPasswordLoginKeepsTheKeychainKeyItAlwaysHad() {
        #expect(password.credentialKey == "sftp://me@example.com:22")
        #expect(ServerConfig(transferProtocol: .ftp, host: "h", username: "u", remoteDirectory: "/").credentialKey == "ftp://u@h:21")
    }

    @Test func aKeyLoginRoundTripsThroughTheSavedFormat() throws {
        let decoded = try JSONDecoder().decode(ServerConfig.self, from: JSONEncoder().encode(key))
        #expect(decoded == key)
        #expect(decoded.usesKey)
        #expect(decoded.keyFilePath == "/Users/me/.ssh/id_ed25519")
    }

    @Test func aPasswordLoginSavesNoKeyFile() throws {
        let text = String(decoding: try JSONEncoder().encode(password), as: UTF8.self)
        #expect(!text.contains("keyFilePath"))
        #expect(text.contains(#""loginMethod":"password""#))
    }

    // MARK: Keychain keys

    @Test func aKeyLoginHasKeychainKeyOfItsOwn() {
        #expect(key.credentialKey != password.credentialKey)
        // The key file is named by a stamp, not its path: the key is also what an entry is identified by when dragged.
        #expect(!key.credentialKey.contains("/Users"))
        #expect(!key.credentialKey.contains(".ssh"))
        // Pinned: a saved passphrase is found again only if the same file gives the same key, in every later version.
        #expect(key.credentialKey == "sftp+key://me@example.com:22#6abd69bd8784c0c0")
    }

    @Test func eachKeyFileGetsItsOwnKeychainKey() {
        var other = key
        other.keyFilePath = "/Users/me/.ssh/id_rsa"
        var again = key
        again.remoteDirectory = "/elsewhere"
        #expect(other.credentialKey == "sftp+key://me@example.com:22#b16e7a87b2e85f27")
        #expect(other.credentialKey != key.credentialKey)
        #expect(again.credentialKey == key.credentialKey)
    }

    @Test func ftpIsNeverAKeyLoginWhateverIsStored() {
        let ftp = ServerConfig(
            transferProtocol: .ftp, host: "example.com", username: "me", remoteDirectory: "/",
            loginMethod: .sshKey, keyFilePath: "/Users/me/.ssh/id_ed25519"
        )
        #expect(!ftp.usesKey)
        #expect(ftp.credentialKey == "ftp://me@example.com:21")
        #expect(ftp.validationErrors().isEmpty)
    }

    @Test func aKeyLoginNeedsAKeyFile() {
        var blank = key
        blank.keyFilePath = "  "
        var missing = key
        missing.keyFilePath = nil
        #expect(blank.validationErrors() == [.emptyKeyFile])
        #expect(missing.validationErrors() == [.emptyKeyFile])
        #expect(key.validationErrors().isEmpty)
        // A password login has no use for one.
        #expect(password.validationErrors().isEmpty)
    }

    @Test func thePasswordAndTheKeysPassphraseNeverShareAKeychainItem() throws {
        let store = InMemoryCredentialStore()
        try store.saveLoginSecret("the password", for: password)
        try store.saveLoginSecret("the passphrase", for: key)

        #expect(store.loginSecret(for: password) == "the password")
        #expect(store.loginSecret(for: key) == "the passphrase")
        try store.saveLoginSecret("", for: key)
        #expect(store.loginSecret(for: password) == "the password")
    }

    @Test func aPasswordLoginReadsAndSavesLikeBefore() throws {
        let store = InMemoryCredentialStore()
        #expect(store.loginSecret(for: password) == nil)
        try store.saveLoginSecret("pw", for: password)
        #expect(try store.password(for: password.credentialKey) == "pw")
        #expect(store.loginSecret(for: password) == "pw")
        // An empty password is saved as it always was, not taken for "none".
        try store.saveLoginSecret("", for: password)
        #expect(store.loginSecret(for: password) == "")
    }

    @Test func aKeyWithNoPassphraseHasNothingSavedAndStillSignsIn() throws {
        let store = InMemoryCredentialStore()
        #expect(store.loginSecret(for: key) == "")
        try store.saveLoginSecret("old passphrase", for: key)
        #expect(store.loginSecret(for: key) == "old passphrase")
        try store.saveLoginSecret("", for: key)
        #expect(try store.password(for: key.credentialKey) == nil)
        #expect(store.loginSecret(for: key) == "")
    }

    // MARK: The form

    @Test func theFormIsAPasswordLoginUntilAKeyIsPicked() {
        let draft = ServerDraft()
        #expect(draft.loginMethod == .password)
        #expect(!draft.usesKey)
        #expect(draft.config.loginMethod == .password)
        #expect(draft.config.keyFilePath == nil)
    }

    @Test func aPasswordDraftBuildsTheSameConfigAsBefore() {
        var draft = ServerDraft()
        draft.host = "example.com"
        draft.username = "me"
        draft.password = "pw"
        draft.remoteDirectory = "/drops"
        draft.keyFilePath = "/Users/me/.ssh/id_ed25519"
        draft.passphrase = "pp"
        // What was typed for the key is not part of a password login.
        #expect(draft.config == password)
        #expect(draft.secret == "pw")
    }

    @Test func aKeyDraftBuildsAKeyLogin() {
        var draft = ServerDraft()
        draft.host = "example.com"
        draft.username = "me"
        draft.remoteDirectory = "/drops"
        draft.password = "pw"
        draft.selectLoginMethod(.sshKey)
        draft.keyFilePath = "/Users/me/.ssh/id_ed25519"
        draft.passphrase = "pp"

        #expect(draft.config == key)
        #expect(draft.secret == "pp")
        #expect(draft.usesKey)
    }

    @Test func eachLoginMethodKeepsItsOwnFieldsAndNothingIsCarriedAcross() {
        var draft = ServerDraft()
        draft.host = "example.com"
        draft.username = "me"
        draft.password = "the password"
        draft.selectLoginMethod(.sshKey)
        // The password is not taken for a passphrase.
        #expect(draft.passphrase.isEmpty)
        #expect(draft.secret.isEmpty)
        draft.keyFilePath = "/Users/me/.ssh/id_rsa"
        draft.passphrase = "the passphrase"
        draft.selectLoginMethod(.password)
        #expect(draft.secret == "the password")
        #expect(draft.password == "the password")
        draft.selectLoginMethod(.sshKey)
        #expect(draft.keyFilePath == "/Users/me/.ssh/id_rsa")
        #expect(draft.secret == "the passphrase")
    }

    @Test func choosingTheMethodThatIsShownChangesNothing() {
        var draft = ServerDraft()
        draft.showProblems = true
        let before = draft
        draft.selectLoginMethod(.password)
        #expect(draft == before)
    }

    @Test func switchingMethodDoesNotPointOutProblemsOnTheEmptyKeyRow() {
        var draft = ServerDraft()
        draft.host = "example.com"
        draft.username = "me"
        draft.showProblems = true
        draft.selectLoginMethod(.sshKey)
        #expect(!draft.showProblems)
        #expect(draft.problems.isEmpty)
        draft.showProblems = true
        #expect(draft.problems == ["Choose your private key file."])
    }

    @Test func aKeyDraftCannotBeSavedWithoutAKeyFile() {
        var draft = ServerDraft()
        draft.host = "example.com"
        draft.username = "me"
        #expect(draft.isValid)
        draft.selectLoginMethod(.sshKey)
        #expect(!draft.isValid)
        #expect(!OnboardingStep.server.canContinue(with: draft))
        draft.keyFilePath = "/Users/me/.ssh/id_ed25519"
        #expect(draft.isValid)
        #expect(OnboardingStep.server.canContinue(with: draft))
    }

    @Test func aSavedKeyLoginFillsTheKeyFields() {
        let draft = ServerDraft(config: key, password: "pp")

        #expect(draft.loginMethod == .sshKey)
        #expect(draft.keyFilePath == "/Users/me/.ssh/id_ed25519")
        #expect(draft.passphrase == "pp")
        #expect(draft.password.isEmpty)
        #expect(draft.config == key)
    }

    @Test func aSavedPasswordLoginFillsOnlyThePassword() {
        let draft = ServerDraft(config: password, password: "pw")

        #expect(draft.loginMethod == .password)
        #expect(draft.password == "pw")
        #expect(draft.passphrase.isEmpty)
        #expect(draft.keyFilePath.isEmpty)
        #expect(draft.config == password)
    }

    @Test func theKeyChoiceSurvivesAWalkThroughFtp() {
        var draft = ServerDraft(config: key, password: "pp")
        draft.selectProtocol(.ftp)
        // Plain FTP has no key, and nothing of the key is carried to it.
        #expect(!draft.usesKey)
        #expect(draft.loginMethod == .password)
        #expect(draft.keyFilePath.isEmpty)
        #expect(draft.passphrase.isEmpty)
        #expect(draft.config.loginMethod == .password)
        draft.selectProtocol(.sftp)
        #expect(draft.config == key)
        #expect(draft.secret == "pp")
    }

    // MARK: Uploads

    private func makeQueue(
        saved: ServerConfig, secrets: [String: String], connector: FakeConnector
    ) -> UploadQueue {
        let credentials = InMemoryCredentialStore(passwords: secrets)
        return UploadQueue(settings: InMemorySettingsStore(config: saved), credentials: credentials, connectors: connector, progressInterval: 0)
    }

    private func collect(_ queue: UploadQueue) async -> [UploadEvent] {
        await queue.waitUntilIdle()
        await queue.finish()
        var events: [UploadEvent] = []
        for await event in queue.events { events.append(event) }
        return events
    }

    @Test func anUploadSignsInWithTheKeyAndItsPassphrase() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let connector = FakeConnector()
        let queue = makeQueue(saved: key, secrets: [key.credentialKey: "pp"], connector: connector)

        let ids = await queue.enqueue([try temp.file(named: "a.txt")])
        let events = await collect(queue)

        #expect(connector.configs == [key])
        #expect(connector.passwords == ["pp"])
        #expect(events.contains { if case .succeeded(let id, _) = $0 { id == ids[0] } else { false } })
    }

    @Test func aKeyWithNoPassphraseSignsInWithoutAnythingSaved() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let connector = FakeConnector()
        let queue = makeQueue(saved: key, secrets: [:], connector: connector)

        _ = await queue.enqueue([try temp.file(named: "a.txt")])
        let events = await collect(queue)

        #expect(connector.passwords == [""])
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
    }

    @Test func aPasswordLoginWithNothingSavedStillAsksForOne() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let connector = FakeConnector()
        let queue = makeQueue(saved: password, secrets: [:], connector: connector)

        let ids = await queue.enqueue([try temp.file(named: "a.txt")])
        let events = await collect(queue)

        #expect(connector.connectionCount == 0)
        #expect(events.contains(.failed(id: ids[0], .missingPassword)))
    }

    @Test func anUploadKeepsItsLoginWhenSettingsSwitchToTheOtherMethod() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let connector = FakeConnector()
        // The password was dropped for; the key is what is saved now.
        let queue = makeQueue(saved: key, secrets: [password.credentialKey: "pw", key.credentialKey: "pp"], connector: connector)

        _ = await queue.enqueue([try temp.file(named: "a.txt")], config: password)
        _ = await collect(queue)

        #expect(connector.configs == [password])
        #expect(connector.passwords == ["pw"])
    }

    @Test func aProblemWithTheKeyIsReportedOnceAndNotRetriedAsALostConnection() async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let failures: [UploaderError] = [
            .keyFileUnreadable, .keyFormatUnsupported, .keyTypeUnsupported("ECDSA"), .keyCipherUnsupported("chacha20-poly1305@openssh.com"),
            .keyNeedsPassphrase, .keyPassphraseWrong, .keyRejected(rsa: false), .keyRejected(rsa: true),
        ]
        for failure in failures {
            let connector = FakeConnector(connectError: failure)
            let queue = makeQueue(saved: key, secrets: [:], connector: connector)

            let ids = await queue.enqueue([try temp.file(named: "a.txt")])
            let events = await collect(queue)

            #expect(connector.connectionCount == 1, "\(failure)")
            #expect(events.contains(.failed(id: ids[0], .transfer(failure.errorDescription ?? ""))), "\(failure)")
        }
    }

    @Test(arguments: [UploaderError.keyFileUnreadable, .keyPassphraseWrong, .keyRejected(rsa: false)])
    func aKeyProblemWhenReconnectingFailsAtOnceInsteadOfWaitingForTheConnection(problem: UploaderError) async throws {
        let temp = try TempFiles()
        defer { temp.remove() }
        let file = try temp.file(named: "big.bin", size: 1000)
        // The first connection works and is cut off part of the way; the key is gone or refused when it comes back.
        let connector = ScriptedConnector([.success(FakeSession(drops: [400])), .failure(problem)])
        let credentials = InMemoryCredentialStore()
        let queue = UploadQueue(
            settings: InMemorySettingsStore(config: key), credentials: credentials, connectors: connector, progressInterval: 0,
            reconnect: ReconnectPolicy(delays: [0.01, 0.01], giveUpAfter: 5, noticeAfter: 2)
        )

        let ids = await queue.enqueue([file])
        let events = await collect(queue)

        #expect(connector.connectionCount == 2)
        #expect(events.contains(.waitingForConnection(id: ids[0])))
        #expect(events.last == .failed(id: ids[0], .transfer(problem.errorDescription ?? "")))
    }

    // MARK: Words

    @Test func noKeyProblemReadsAsAWrongPasswordOrShowsAPath() {
        let problems: [UploaderError] = [
            .keyFileUnreadable, .keyFormatUnsupported, .keyTypeUnsupported("ECDSA"), .keyCipherUnsupported("aes256-gcm@openssh.com"),
            .keyNeedsPassphrase, .keyPassphraseWrong, .keyRejected(rsa: false), .keyRejected(rsa: true),
        ]
        for problem in problems {
            let text = problem.errorDescription ?? ""
            #expect(!text.isEmpty)
            #expect(!text.lowercased().contains("password"), "\(text)")
            #expect(!text.contains("/Users"), "\(text)")
        }
        #expect(UploaderError.authenticationFailed.errorDescription == "The server rejected the username or password.")
        #expect(UploaderError.keyTypeUnsupported("ECDSA").errorDescription?.contains("ECDSA") == true)
        #expect(UploaderError.keyRejected(rsa: true).errorDescription?.contains("ed25519") == true)
        #expect(UploaderError.keyRejected(rsa: false).errorDescription?.contains("RSA") == false)
    }

    // MARK: Switching method keeps what waiting uploads need

    @Test func switchingFromThePasswordToAKeyKeepsThePasswordWhileAnUploadNeedsIt() throws {
        let store = InMemoryCredentialStore()
        try store.saveLoginSecret("pw", for: password)
        try store.saveLoginSecret("pp", for: key)
        var retired = RetiredPasswords()
        retired.retire(password, replacedBy: key)
        #expect(retired.keys == [password.credentialKey])

        var waiting = UploadActivity()
        waiting.restore([StoredUpload(
            fileName: "f", totalBytes: 10, outcome: .interrupted, detail: "", finishedAt: Date(timeIntervalSince1970: 0),
            resume: ResumePoint(sourcePath: "/tmp/f", isFolder: false, config: password, totalBytes: 10)
        )])
        retired.settle(current: key, items: waiting.items, credentials: store)

        #expect(try store.password(for: password.credentialKey) == "pw")
        #expect(try store.password(for: key.credentialKey) == "pp")

        retired.settle(current: key, items: [], credentials: store)

        #expect(try store.password(for: password.credentialKey) == nil)
        #expect(try store.password(for: key.credentialKey) == "pp")
        #expect(retired.keys.isEmpty)
    }

    @Test func switchingFromAKeyToThePasswordRetiresThePassphrase() throws {
        let store = InMemoryCredentialStore()
        try store.saveLoginSecret("pw", for: password)
        try store.saveLoginSecret("pp", for: key)
        var retired = RetiredPasswords()
        retired.retire(key, replacedBy: password)

        retired.settle(current: password, items: [], credentials: store)

        #expect(try store.password(for: key.credentialKey) == nil)
        #expect(try store.password(for: password.credentialKey) == "pw")
    }

    @Test func pickingAnotherKeyFileRetiresTheOldPassphrase() throws {
        var other = key
        other.keyFilePath = "/Users/me/.ssh/id_rsa"
        var retired = RetiredPasswords()
        retired.retire(key, replacedBy: other)
        #expect(retired.keys == [key.credentialKey])
        // The same key file with another folder is the same login.
        retired.retire(other, replacedBy: other.withRemoteDirectory("/x"))
        #expect(retired.keys == [key.credentialKey])
    }
}

/// Answers each connection with the next thing in the list, and the last thing from then on.
private final class ScriptedConnector: ServerConnector, ConnectorFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [Result<FakeSession, any Error>]
    private var count = 0

    init(_ steps: [Result<FakeSession, any Error>]) { self.steps = steps }

    var connectionCount: Int { lock.withLock { count } }

    func connect(to config: ServerConfig, password: String) async throws -> any ServerSession {
        let step = lock.withLock { () -> Result<FakeSession, any Error> in
            count += 1
            return steps.count > 1 ? steps.removeFirst() : steps[0]
        }
        return try step.get()
    }

    func connector(for transferProtocol: TransferProtocol) -> any ServerConnector { self }
}
