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

    @Test func switchingProtocolMovesTheDefaultPortOnly() {
        var draft = ServerDraft()
        draft.selectProtocol(.ftp)
        #expect(draft.port == "21")
        draft.selectProtocol(.sftp)
        #expect(draft.port == "22")
        draft.port = "2222"
        draft.selectProtocol(.ftp)
        #expect(draft.port == "2222")
        draft.port = ""
        draft.selectProtocol(.sftp)
        #expect(draft.port == "22")
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
