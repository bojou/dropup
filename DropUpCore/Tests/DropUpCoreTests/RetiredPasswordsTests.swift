import Foundation
import Testing
@testable import DropUpCore

/// What happens to the Keychain password of a server that was replaced in Settings.
struct RetiredPasswordsTests {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let a = ServerConfig(transferProtocol: .sftp, host: "a.example.com", username: "me", remoteDirectory: "/a")
    let b = ServerConfig(transferProtocol: .ftp, host: "b.example.com", username: "me", remoteDirectory: "/b")

    private func credentials() throws -> InMemoryCredentialStore {
        let store = InMemoryCredentialStore()
        try store.setPassword("pw-a", for: a.credentialKey)
        try store.setPassword("pw-b", for: b.credentialKey)
        return store
    }

    /// A list with one upload to `server` in the given state.
    private func activity(_ outcome: StoredUpload.Outcome?, server: ServerConfig?, running: Bool = false) -> UploadActivity {
        var activity = UploadActivity()
        if let outcome {
            activity.restore([StoredUpload(
                fileName: "f", totalBytes: 10, outcome: outcome, detail: "", finishedAt: t0,
                resume: ResumePoint(sourcePath: "/tmp/f", isFolder: false, config: server, totalBytes: 10)
            )])
        }
        if running {
            let id = UUID()
            activity.apply(.queued(id: id, fileName: "g", totalBytes: 10), now: t0)
            activity.apply(.resumable(id: id, ResumePoint(sourcePath: "/tmp/g", isFolder: false, config: server, totalBytes: 10)), now: t0)
            activity.apply(.started(id: id), now: t0)
        }
        return activity
    }

    // MARK: The decision

    @Test func aReplacedServerNothingNeedsIsRemoved() {
        let plan = RetiredPasswords.plan(retired: ["a", "b"], current: "c", needed: [])
        #expect(plan == .init(remove: ["a", "b"], stillRetired: []))
    }

    @Test func aReplacedServerSomethingNeedsIsKeptForLater() {
        let plan = RetiredPasswords.plan(retired: ["a", "b"], current: "c", needed: ["a"])
        #expect(plan == .init(remove: ["b"], stillRetired: ["a"]))
    }

    @Test func aServerThatIsSavedAgainIsNotRetiredAnyMore() {
        // Whether or not an upload needs it: it is the current server again, so its password stays.
        #expect(RetiredPasswords.plan(retired: ["a"], current: "a", needed: []) == .init(remove: [], stillRetired: []))
        #expect(RetiredPasswords.plan(retired: ["a"], current: "a", needed: ["a"]) == .init(remove: [], stillRetired: []))
    }

    @Test func nothingRetiredNothingToDo() {
        #expect(RetiredPasswords.plan(retired: [], current: "a", needed: ["b"]) == .init(remove: [], stillRetired: []))
    }

    // MARK: Retiring

    @Test func replacingTheSavedServerRetiresIt() {
        var retired = RetiredPasswords()
        retired.retire(a, replacedBy: b)
        #expect(retired.keys == [a.credentialKey])
    }

    @Test func savingTheSameServerAgainOrTheFirstOneRetiresNothing() {
        var retired = RetiredPasswords()
        retired.retire(nil, replacedBy: a)
        retired.retire(a, replacedBy: a.withRemoteDirectory("/elsewhere"))
        #expect(retired.keys.isEmpty)
    }

    @Test func theSameHostOverAnotherProtocolIsAnotherServer() {
        let ftp = ServerConfig(transferProtocol: .ftp, host: a.host, username: a.username, remoteDirectory: "/")
        var retired = RetiredPasswords()
        retired.retire(a, replacedBy: ftp)
        #expect(retired.keys == [a.credentialKey])
    }

    // MARK: Settling against the list and the Keychain

    @Test func theOldPasswordGoesAtOnceWhenNothingWaitsForIt() throws {
        let store = try credentials()
        var retired = RetiredPasswords()
        retired.retire(a, replacedBy: b)

        let changed = retired.settle(current: b, items: UploadActivity().items, credentials: store)

        #expect(changed)
        #expect(retired.keys.isEmpty)
        #expect(try store.password(for: a.credentialKey) == nil)
        #expect(try store.password(for: b.credentialKey) == "pw-b")
    }

    @Test(arguments: [StoredUpload.Outcome.interrupted, .paused, .failed])
    func theOldPasswordStaysWhileAnUploadThatCanRunAgainNeedsIt(outcome: StoredUpload.Outcome) throws {
        let store = try credentials()
        var retired = RetiredPasswords()
        retired.retire(a, replacedBy: b)

        retired.settle(current: b, items: activity(outcome, server: a).items, credentials: store)

        #expect(retired.keys == [a.credentialKey])
        #expect(try store.password(for: a.credentialKey) == "pw-a")
    }

    @Test func theOldPasswordStaysWhileAnUploadIsWaitingOrRunningForIt() throws {
        let store = try credentials()
        var retired = RetiredPasswords()
        retired.retire(a, replacedBy: b)

        retired.settle(current: b, items: activity(nil, server: a, running: true).items, credentials: store)

        #expect(try store.password(for: a.credentialKey) == "pw-a")
    }

    @Test func theOldPasswordGoesOnceTheLastUploadForItIsDone() throws {
        let store = try credentials()
        var retired = RetiredPasswords()
        retired.retire(a, replacedBy: b)
        var list = activity(nil, server: a, running: true)
        retired.settle(current: b, items: list.items, credentials: store)
        #expect(try store.password(for: a.credentialKey) == "pw-a")

        list.apply(.succeeded(id: list.items[0].id, remotePath: "/a/g"), now: t0)
        let changed = retired.settle(current: b, items: list.items, credentials: store)

        #expect(changed)
        #expect(retired.keys.isEmpty)
        #expect(try store.password(for: a.credentialKey) == nil)
    }

    @Test func aCancelledOrFinishedUploadDoesNotKeepAPassword() throws {
        for outcome in [StoredUpload.Outcome.cancelled, .succeeded] {
            let store = try credentials()
            var retired = RetiredPasswords()
            retired.retire(a, replacedBy: b)
            // Cancelled and finished rows carry no resume point of their own; the server is only ever read from one
            // that can run again.
            retired.settle(current: b, items: activity(outcome, server: a).items, credentials: store)
            #expect(try store.password(for: a.credentialKey) == nil)
        }
    }

    @Test func switchingBackKeepsThePasswordEvenWithNothingWaiting() throws {
        let store = try credentials()
        var retired = RetiredPasswords()
        retired.retire(a, replacedBy: b)
        retired.settle(current: b, items: activity(.interrupted, server: a).items, credentials: store)
        #expect(retired.keys == [a.credentialKey])

        // Back to A: B is retired in its place, and A is the current server again.
        retired.retire(b, replacedBy: a)
        let list = UploadActivity().items
        retired.settle(current: a, items: list, credentials: store)

        #expect(retired.keys.isEmpty)
        #expect(try store.password(for: a.credentialKey) == "pw-a")
        #expect(try store.password(for: b.credentialKey) == nil)
    }

    @Test func aRowSavedByAnEarlierVersionWithNoServerNeedsNoRetiredPassword() throws {
        let store = try credentials()
        var retired = RetiredPasswords()
        retired.retire(a, replacedBy: b)

        // It goes to whichever server is saved, which is never a retired one.
        retired.settle(current: b, items: activity(.interrupted, server: nil).items, credentials: store)

        #expect(try store.password(for: a.credentialKey) == nil)
    }

    @Test func aPasswordTheKeychainWillNotGiveUpIsTriedAgainLater() throws {
        struct Stubborn: CredentialStore {
            let inner: InMemoryCredentialStore
            let refuses: Bool
            func password(for key: String) throws -> String? { try inner.password(for: key) }
            func setPassword(_ password: String, for key: String) throws { try inner.setPassword(password, for: key) }
            func removePassword(for key: String) throws {
                struct Locked: Error {}
                if refuses { throw Locked() }
                try inner.removePassword(for: key)
            }
        }
        let inner = try credentials()
        var retired = RetiredPasswords()
        retired.retire(a, replacedBy: b)

        let changed = retired.settle(current: b, items: [], credentials: Stubborn(inner: inner, refuses: true))
        #expect(!changed)
        #expect(retired.keys == [a.credentialKey])

        retired.settle(current: b, items: [], credentials: Stubborn(inner: inner, refuses: false))
        #expect(retired.keys.isEmpty)
        #expect(try inner.password(for: a.credentialKey) == nil)
    }
}
