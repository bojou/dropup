import Foundation
import Testing
@testable import DropUpCore

struct ServerEditorTests {
    let server = ServerConfig(transferProtocol: .sftp, host: "files.example.com", port: 22, username: "deploy", remoteDirectory: "/www")

    @Test func aFinishedEditIsSavedAndOnlyOnce() throws {
        var editor = ServerEditor(saved: server, secret: "old")
        #expect(!editor.hasChanges)
        #expect(editor.finishEdit() == nil)

        editor.draft.remoteDirectory = "/www/drops"
        let finished = editor.finishEdit()
        let change = try #require(finished)
        #expect(change.config == server.withRemoteDirectory("/www/drops"))
        #expect(change.secret == "old")
        editor.didSave(change.config, secret: change.secret)
        #expect(!editor.hasChanges)
        // Leaving the next field without touching it saves nothing.
        #expect(editor.finishEdit() == nil)
    }

    @Test func aNewPasswordAloneIsSaved() throws {
        var editor = ServerEditor(saved: server, secret: "old")
        editor.draft.password = "new"
        let finished = editor.finishEdit()
        let change = try #require(finished)
        #expect(change.config == server)
        #expect(change.secret == "new")
    }

    @Test func anIncompleteFormIsNotSavedAndSaysWhy() {
        var editor = ServerEditor(saved: server, secret: "old")
        editor.draft.host = ""
        #expect(editor.finishEdit() == nil)
        #expect(editor.draft.problems == ["Enter the server address."])
        #expect(editor.saved == server)

        editor.draft.host = "other.example.com"
        #expect(editor.finishEdit()?.config.host == "other.example.com")
    }

    @Test func aChoiceThatEmptiesTheFormDoesNotPointAtWhatIsMissingYet() {
        var editor = ServerEditor(saved: server, secret: "old")
        editor.draft.selectProtocol(.ftp)
        #expect(editor.finishEdit(showingProblems: false) == nil)
        #expect(editor.draft.problems.isEmpty)
        // Going back finds the saved server as it was, with nothing to save.
        editor.draft.selectProtocol(.sftp)
        #expect(!editor.hasChanges)
    }

    @Test func aSavedEditStopsShowingProblemsUntilTheNextMistakeIsFinished() throws {
        var editor = ServerEditor(saved: server, secret: "old")
        editor.draft.port = "x"
        _ = editor.finishEdit()
        editor.draft.port = "2222"
        let finished = editor.finishEdit()
        let change = try #require(finished)
        editor.didSave(change.config, secret: change.secret)
        editor.draft.username = ""
        #expect(editor.draft.problems.isEmpty)
        _ = editor.finishEdit()
        #expect(editor.draft.problems == ["Enter your username."])
    }

    @Test func theFirstServerIsSavedOnceTheFormIsComplete() throws {
        var editor = ServerEditor(saved: nil, secret: "")
        editor.draft.host = "files.example.com"
        #expect(editor.finishEdit() == nil)
        editor.draft.username = "deploy"
        let finished = editor.finishEdit()
        let change = try #require(finished)
        #expect(change.config.host == "files.example.com")
        #expect(change.config.username == "deploy")
    }

    @Test func aServerSavedElsewhereShowsInAFormWithoutEdits() {
        var editor = ServerEditor(saved: server, secret: "old")
        let moved = server.withRemoteDirectory("/www/new")
        editor.savedElsewhere(moved, secret: "old")
        #expect(editor.draft.remoteDirectory == "/www/new")
        #expect(!editor.hasChanges)
        // So the next edit keeps the new folder.
        editor.draft.displayName = "Site"
        #expect(editor.finishEdit()?.config.remoteDirectory == "/www/new")
    }

    @Test func aFormWithEditsKeepsThemWhenTheServerIsSavedElsewhere() {
        var editor = ServerEditor(saved: server, secret: "old")
        editor.draft.host = ""
        editor.savedElsewhere(server.withRemoteDirectory("/www/new"), secret: "old")
        #expect(editor.draft.host == "")
        #expect(editor.saved == server.withRemoteDirectory("/www/new"))
    }
}
