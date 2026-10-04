import Foundation
import Testing
@testable import DropUpCore

struct ServerDraftTests {
    @Test func defaultsToSFTP() {
        let draft = ServerDraft()
        #expect(draft.transferProtocol == .sftp)
        #expect(draft.port == "22")
        #expect(!draft.isValid)
    }

    @Test func aTypeThatWasNeverShownStartsBlankWithItsOwnPort() {
        var draft = ServerDraft()
        draft.displayName = "My website"
        draft.host = "files.example.com"
        draft.username = "deploy"
        draft.password = "secret"
        draft.remoteDirectory = "/var/www"
        draft.selectProtocol(.ftp)
        #expect(draft.transferProtocol == .ftp)
        #expect(draft.host.isEmpty)
        #expect(draft.username.isEmpty)
        #expect(draft.displayName.isEmpty)
        #expect(draft.remoteDirectory == "/")
        #expect(draft.port == "21")
    }

    @Test func nothingTypedForOneTypeIsCarriedToTheOther() {
        var draft = ServerDraft()
        draft.host = "files.example.com"
        draft.password = "secret"
        draft.selectProtocol(.ftp)
        // The password least of all: plain FTP would send it unencrypted to whatever host is typed next.
        #expect(draft.password.isEmpty)
        draft.host = "ftp.example.com"
        draft.selectProtocol(.sftp)
        #expect(draft.host == "files.example.com")
        #expect(draft.password == "secret")
    }

    @Test func eachTypeKeepsItsOwnFieldsWhileTheFormIsOpen() {
        var draft = ServerDraft()
        draft.displayName = "Work"
        draft.host = "sftp.example.com"
        draft.port = "2222"
        draft.username = "alice"
        draft.password = "one"
        draft.remoteDirectory = "/srv/a"
        draft.selectProtocol(.ftp)
        draft.displayName = "Old site"
        draft.host = "ftp.example.com"
        draft.username = "bob"
        draft.password = "two"
        draft.remoteDirectory = "/pub"
        draft.selectProtocol(.sftp)
        #expect(draft.config == ServerConfig(transferProtocol: .sftp, host: "sftp.example.com", port: 2222, username: "alice", remoteDirectory: "/srv/a", displayName: "Work"))
        #expect(draft.password == "one")
        draft.selectProtocol(.ftp)
        #expect(draft.config == ServerConfig(transferProtocol: .ftp, host: "ftp.example.com", port: 21, username: "bob", remoteDirectory: "/pub", displayName: "Old site"))
        #expect(draft.password == "two")
    }

    @Test func aHalfTypedPortComesBackAsItWasLeft() {
        var draft = ServerDraft()
        draft.port = ""
        draft.selectProtocol(.ftp)
        #expect(draft.port == "21")
        draft.port = "x"
        draft.selectProtocol(.sftp)
        #expect(draft.port == "")
        draft.selectProtocol(.ftp)
        #expect(draft.port == "x")
    }

    @Test func choosingTheTypeThatIsShownChangesNothing() {
        var draft = ServerDraft()
        draft.host = "files.example.com"
        draft.port = "2200"
        draft.showProblems = true
        let before = draft
        draft.selectProtocol(.sftp)
        #expect(draft == before)
    }

    @Test func switchingTypeDoesNotPointOutProblemsOnTheEmptyForm() {
        var draft = ServerDraft()
        draft.showProblems = true
        draft.selectProtocol(.ftp)
        #expect(!draft.showProblems)
        #expect(draft.problems.isEmpty)
    }

    @Test func aSavedServerFillsOnlyItsOwnType() {
        let config = ServerConfig(transferProtocol: .ftp, host: "h.example.com", port: 2121, username: "u", remoteDirectory: "/x", displayName: "Site")
        var draft = ServerDraft(config: config, password: "pw")
        draft.selectProtocol(.sftp)
        #expect(draft.host.isEmpty)
        #expect(draft.username.isEmpty)
        #expect(draft.password.isEmpty)
        #expect(draft.displayName.isEmpty)
        #expect(draft.port == "22")
        draft.selectProtocol(.ftp)
        #expect(draft.config == config)
        #expect(draft.password == "pw")
    }

    @Test func buildsAConfigFromMessyInput() {
        var draft = ServerDraft()
        draft.host = "  files.example.com "
        draft.port = " 2200 "
        draft.username = " deploy "
        draft.remoteDirectory = "var//www/uploads/"
        #expect(draft.config == ServerConfig(transferProtocol: .sftp, host: "files.example.com", port: 2200, username: "deploy", remoteDirectory: "/var/www/uploads"))
        #expect(draft.isValid)
    }

    @Test func problemsAppearOnlyAfterAnAttempt() {
        var draft = ServerDraft()
        draft.port = "abc"
        #expect(draft.problems.isEmpty)
        draft.showProblems = true
        #expect(draft.problems == [
            "Enter the server address.",
            "Port must be a number between 1 and 65535.",
            "Enter your username.",
        ])
    }

    @Test func roundTripsAnExistingConfig() {
        let config = ServerConfig(transferProtocol: .ftp, host: "h.example.com", port: 2121, username: "u", remoteDirectory: "/x")
        let draft = ServerDraft(config: config, password: "pw")
        #expect(draft.config == config)
        #expect(draft.password == "pw")
    }

    @Test func onboardingStepsGateOnTheDraft() {
        var draft = ServerDraft()
        #expect(OnboardingStep.welcome.canContinue(with: draft))
        #expect(!OnboardingStep.server.canContinue(with: draft))
        draft.host = "h.example.com"
        draft.username = "u"
        #expect(OnboardingStep.server.canContinue(with: draft))
        #expect(OnboardingStep.server.next == .folder)
        #expect(OnboardingStep.done.next == nil)
        #expect(OnboardingStep.welcome.previous == nil)
        #expect(OnboardingStep.folder.showsBack)
        #expect(!OnboardingStep.done.showsBack)
        #expect(OnboardingStep.connectionType.accessibilityLabel == "Step 2 of 5: Connection type")
        #expect(OnboardingStep.welcome.nextLabel == "Get Started")
    }
}

struct CompletionNoticeTests {
    let t = Date(timeIntervalSince1970: 0)

    /// Queues every file first, as the real queue does, then finishes them.
    private func run(_ outcomes: [(String, Bool?)]) -> UploadActivity {
        var activity = UploadActivity()
        let ids = outcomes.map { _ in UUID() }
        for (id, outcome) in zip(ids, outcomes) {
            activity.apply(.queued(id: id, fileName: outcome.0, totalBytes: 1), now: t)
        }
        for (id, outcome) in zip(ids, outcomes) {
            switch outcome.1 {
            case true?: activity.apply(.succeeded(id: id, remotePath: "/\(outcome.0)"), now: t)
            case false?: activity.apply(.failed(id: id, .transfer("Connection lost")), now: t)
            case nil: activity.apply(.cancelled(id: id), now: t)
            }
        }
        return activity
    }

    @Test func describesEachKindOfBatch() {
        #expect(ActivityText.completionNotice(run([("a.png", true)]))?.title == "Uploaded")
        #expect(ActivityText.completionNotice(run([("a.png", true)]))?.body == "a.png")
        #expect(ActivityText.completionNotice(run([("a", true), ("b", true)]))?.title == "Uploaded 2 files")
        #expect(ActivityText.completionNotice(run([("a", false)]))?.body == "a: Connection lost")
        #expect(ActivityText.completionNotice(run([("a", false), ("b", false)]))?.title == "2 uploads failed")
        #expect(ActivityText.completionNotice(run([("a", true), ("b", false)]))?.title == "1 uploaded, 1 failed")
        #expect(ActivityText.completionNotice(run([("a", nil)])) == nil)
    }
}
