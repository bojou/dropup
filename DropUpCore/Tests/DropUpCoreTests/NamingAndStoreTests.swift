import Foundation
import Testing
@testable import DropUpCore

struct NamingAndStoreTests {
    @Test(arguments: [
        ("photo.png", 1, "photo-1.png"),
        ("photo.png", 12, "photo-12.png"),
        ("archive.tar.gz", 2, "archive-2.tar.gz"),
        ("ARCHIVE.TAR.GZ", 1, "ARCHIVE-1.TAR.GZ"),
        (".env", 1, ".env-1"),
        ("README", 1, "README-1"),
        ("a.b.c.txt", 1, "a.b.c-1.txt"),
        (".tar.gz", 1, ".tar-1.gz"),
    ])
    func numbersFileNames(name: String, index: Int, expected: String) {
        #expect(RemoteFileName.numbered(name, index: index) == expected)
    }

    @Test func parentAndAppendingNormalizePaths() {
        #expect(RemotePath.parent(of: "/a/b") == "/a")
        #expect(RemotePath.parent(of: "/a") == "/")
        #expect(RemotePath.parent(of: "/") == "/")
        #expect(RemotePath.appending("b", to: "/a/") == "/a/b")
        #expect(RemotePath.appending("b", to: "/") == "/b")
    }

    @Test func preferencesDefaultsAndPartialDecoding() throws {
        #expect(Preferences() == Preferences(conflictPolicy: .keepBoth, notifyWhenDone: true, playSound: false, recentLimit: 10))
        // A preferences blob from an older version that only knew one field still loads.
        let old = Data(#"{"playSound":true}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: old)
        #expect(decoded.playSound)
        #expect(decoded.conflictPolicy == .keepBoth)
        #expect(decoded.recentLimit == 10)
    }

    @Test func theDropZoneSizeStartsAtDefaultAndEarlierPreferencesKeepIt() throws {
        #expect(Preferences().dropZoneSize == .standard)
        let old = Data(#"{"playSound":true,"recentLimit":25}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: old)
        #expect(decoded.dropZoneSize == .standard)
        #expect(decoded.recentLimit == 25)
        // A value from a version that does not exist yet falls back instead of losing every other setting.
        let unknown = Data(#"{"dropZoneSize":"huge","playSound":true}"#.utf8)
        let fallback = try JSONDecoder().decode(Preferences.self, from: unknown)
        #expect(fallback.dropZoneSize == .standard)
        #expect(fallback.playSound)
    }

    @Test(arguments: DropZoneSize.allCases)
    func theDropZoneSizeIsStoredAndTheOtherSettingsAreLeftAlone(zone: DropZoneSize) throws {
        let suite = "DropUpCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = UserDefaultsSettingsStore(defaults: defaults)
        var preferences = Preferences(conflictPolicy: .replace, playSound: true, recentLimit: 25, hideRecentNames: true)
        preferences.dropZoneSize = zone
        try settings.savePreferences(preferences)

        let loaded = settings.loadPreferences()
        #expect(loaded == preferences)
        #expect(loaded.dropZoneSize == zone)
        #expect(loaded.conflictPolicy == .replace && loaded.hideRecentNames && loaded.recentLimit == 25)
    }

    @Test func userDefaultsStoresRoundTrip() throws {
        let suite = "DropUpCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = UserDefaultsSettingsStore(defaults: defaults)
        #expect(settings.loadPreferences() == Preferences())
        try settings.savePreferences(Preferences(conflictPolicy: .replace, notifyWhenDone: false, playSound: true, recentLimit: 20))
        #expect(settings.loadPreferences().conflictPolicy == .replace)
        #expect(settings.loadPreferences().recentLimit == 20)

        let hostKeys = UserDefaultsHostKeyStore(defaults: defaults)
        #expect(hostKeys.trustedKey(for: "h:22") == nil)
        hostKeys.trust("ssh-ed25519 AAAA", for: "h:22")
        #expect(hostKeys.trustedKey(for: "h:22") == "ssh-ed25519 AAAA")
        hostKeys.forget(hostID: "h:22")
        #expect(hostKeys.trustedKey(for: "h:22") == nil)
    }

    @Test func hostKeyIDIgnoresHostCase() {
        let config = ServerConfig(transferProtocol: .sftp, host: "Files.Example.com", username: "u", remoteDirectory: "/")
        #expect(config.hostKeyID == "files.example.com:22")
    }

    @Test func browserListsThroughTheConnector() async throws {
        let session = FakeSession(folders: ["/drops": ["b", "a"]])
        let browser = ServerBrowser(connectors: FakeConnector(session: session))
        let config = ServerConfig(transferProtocol: .sftp, host: "h", username: "u", remoteDirectory: "drops/")

        let result = try await browser.testConnection(config, password: "p")

        #expect(result.folders == ["b", "a"])
        #expect(session.closeCount == 1)
    }

    @Test func browserClosesTheSessionOnFailure() async throws {
        let session = FakeSession(error: UploaderError.timedOut)
        let browser = ServerBrowser(connectors: FakeConnector(session: session))
        let config = ServerConfig(transferProtocol: .sftp, host: "h", username: "u", remoteDirectory: "/")

        await #expect(throws: UploaderError.timedOut) {
            _ = try await browser.testConnection(config, password: "p")
        }
        #expect(session.closeCount == 1)
    }

    @Test func timeoutCancelsSlowWork() async {
        await #expect(throws: UploaderError.timedOut) {
            try await withTimeout(seconds: 0.05) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    @Test func messagesAreReadable() {
        #expect(UploadQueue.message(for: UploaderError.hostKeyChanged(fingerprint: "SHA256:abc")).contains("SHA256:abc"))
        #expect(UploadQueue.message(for: UploaderError.serverRejected(code: 550, message: "No such file")) == "The server refused: No such file (550)")
    }
}
