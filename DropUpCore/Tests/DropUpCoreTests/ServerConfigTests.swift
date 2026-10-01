import Foundation
import Testing
@testable import DropUpCore

struct ServerConfigTests {
    @Test func defaultPortFollowsProtocol() {
        #expect(ServerConfig(transferProtocol: .ftp, host: "h", username: "u", remoteDirectory: "/").port == 21)
        #expect(ServerConfig(transferProtocol: .sftp, host: "h", username: "u", remoteDirectory: "/").port == 22)
        #expect(ServerConfig(transferProtocol: .sftp, host: "h", port: 2222, username: "u", remoteDirectory: "/").port == 2222)
    }

    @Test(arguments: [
        ("", "/"),
        ("/", "/"),
        ("drops", "/drops"),
        ("drops/", "/drops"),
        ("//drops//images/", "/drops/images"),
        (" /public_html/drops ", "/public_html/drops"),
    ])
    func normalizesRemoteDirectory(input: String, expected: String) {
        #expect(RemotePath.normalizedDirectory(input) == expected)
    }

    @Test func buildsRemotePathForFile() {
        let root = ServerConfig(transferProtocol: .ftp, host: "h", username: "u", remoteDirectory: "")
        let nested = ServerConfig(transferProtocol: .ftp, host: "h", username: "u", remoteDirectory: "uploads/2026/")
        #expect(root.remotePath(forFileNamed: "a b.png") == "/a b.png")
        #expect(nested.remotePath(forFileNamed: "a b.png") == "/uploads/2026/a b.png")
    }

    @Test func validConfigHasNoErrors() {
        let config = ServerConfig(transferProtocol: .sftp, host: "example.com", username: "me", remoteDirectory: "/drops")
        #expect(config.validationErrors().isEmpty)
        #expect(config.isValid)
    }

    @Test func reportsEveryProblemAtOnce() {
        let config = ServerConfig(transferProtocol: .ftp, host: "  ", port: 0, username: "", remoteDirectory: "/")
        #expect(config.validationErrors() == [.emptyHost, .invalidPort, .emptyUsername])
    }

    @Test(arguments: ["ftp://example.com", "example.com/drops", "exa mple.com"])
    func rejectsHostThatIsNotABareHostname(host: String) {
        let config = ServerConfig(transferProtocol: .ftp, host: host, username: "u", remoteDirectory: "/")
        #expect(config.validationErrors() == [.invalidHost])
    }

    @Test func credentialKeyIdentifiesServerAndUser() {
        let config = ServerConfig(transferProtocol: .sftp, host: "example.com", username: "me", remoteDirectory: "/")
        #expect(config.credentialKey == "sftp://me@example.com:22")
    }

    @Test func settingsStoreNeedsOnboardingUntilValidConfigSaved() throws {
        let store = InMemorySettingsStore()
        #expect(store.needsOnboarding)
        try store.saveServerConfig(ServerConfig(transferProtocol: .ftp, host: "", username: "u", remoteDirectory: "/"))
        #expect(store.needsOnboarding)
        try store.saveServerConfig(ServerConfig(transferProtocol: .ftp, host: "example.com", username: "u", remoteDirectory: "/"))
        #expect(!store.needsOnboarding)
    }

    @Test func userDefaultsStoreRoundTrips() throws {
        let suite = "DropUpCoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UserDefaultsSettingsStore(defaults: defaults)
        let config = ServerConfig(transferProtocol: .sftp, host: "example.com", port: 2222, username: "me", remoteDirectory: "/drops")
        #expect(store.loadServerConfig() == nil)
        try store.saveServerConfig(config)
        #expect(store.loadServerConfig() == config)
        store.clearServerConfig()
        #expect(store.loadServerConfig() == nil)
    }
}
