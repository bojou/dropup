import Foundation
import Testing
@testable import DropUpCore

/// How the list treats uploads that were interrupted: they stay until resumed or removed, and survive a quit.
struct InterruptedUploadTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let config = ServerConfig(transferProtocol: .sftp, host: "example.com", username: "me", remoteDirectory: "/drops")

    private func point(_ name: String, created: Bool = true) -> ResumePoint {
        ResumePoint(sourcePath: "/Users/me/\(name)", isFolder: false, config: config, remotePath: "/drops/\(name)", totalBytes: 100, created: created)
    }

    /// An upload that went as far as the server holding part of it.
    private func start(_ activity: inout UploadActivity, _ name: String, at time: Date, created: Bool = true) -> UUID {
        let id = UUID()
        activity.apply(.queued(id: id, fileName: name, totalBytes: 100), now: time)
        activity.apply(.started(id: id), now: time)
        activity.apply(.resumable(id: id, point(name, created: created)), now: time)
        return id
    }

    private func lose(_ activity: inout UploadActivity, _ name: String, at time: Date) -> UUID {
        let id = start(&activity, name, at: time)
        activity.apply(.failed(id: id, .connectionLost("The connection was lost.")), now: time)
        return id
    }

    private func finish(_ activity: inout UploadActivity, _ name: String, at time: Date) {
        let id = UUID()
        activity.apply(.queued(id: id, fileName: name, totalBytes: 10), now: time)
        activity.apply(.started(id: id), now: time)
        activity.apply(.succeeded(id: id, remotePath: "/drops/\(name)"), now: time)
    }

    private func restored(_ uploads: [StoredUpload]) -> UploadActivity {
        var activity = UploadActivity()
        activity.restore(uploads)
        return activity
    }

    // MARK: What a failure leaves

    @Test func aLostConnectionKeepsWhatItTakesToResume() {
        var activity = UploadActivity()
        let id = lose(&activity, "big.bin", at: t0)

        let item = activity.items[0]
        #expect(item.id == id)
        #expect(item.state == .failed(message: "The connection was lost."))
        #expect(item.resume == point("big.bin"))
        #expect(item.isResumable)
        // It still counts as a failure for the icon, the sound and the notice.
        #expect(activity.hasUnseenFailure)
        #expect(activity.batchHadFailure)
    }

    @Test func aRefusalWithNothingSentIsAnOrdinaryFailure() {
        var activity = UploadActivity()
        let id = start(&activity, "a.txt", at: t0, created: false)
        activity.apply(.failed(id: id, .transfer("The server refused: Permission denied (550)")), now: t0)

        // It can be sent again, but it has no partial file to protect and follows the usual rules for Recent.
        #expect(activity.items[0].resume != nil)
        #expect(!activity.items[0].isResumable)
        #expect(activity.canClear)
    }

    @Test func aFailedUploadCanBeSentAgainAfterARelaunchWithoutBecomingExempt() {
        var activity = UploadActivity()
        let id = start(&activity, "a.txt", at: t0, created: false)
        activity.apply(.failed(id: id, .transfer("The server refused: Permission denied (550)")), now: t0)

        #expect(activity.storedInterrupted(now: t0).isEmpty)
        let stored = activity.storedFinished
        #expect(stored.count == 1)
        #expect(stored[0].resume == point("a.txt", created: false))
        #expect(!stored[0].isInterrupted)

        let back = restored(stored)
        #expect(back.items[0].resume == point("a.txt", created: false))
        #expect(!back.items[0].isResumable)
        #expect(back.canClear)
    }

    @Test func aRefusalAfterSomethingWasSentCanStillBeResumed() {
        var activity = UploadActivity()
        let id = start(&activity, "a.txt", at: t0, created: true)
        activity.apply(.failed(id: id, .transfer("The server refused: Disk full (552)")), now: t0)

        #expect(activity.items[0].isResumable)
    }

    @Test func aConnectionLostBeforeAnythingWasSentLeavesNothingToProtect() {
        var activity = UploadActivity()
        let id = start(&activity, "a.txt", at: t0, created: false)
        activity.apply(.failed(id: id, .connectionLost("The server refused the connection.")), now: t0)

        #expect(!activity.items[0].isResumable)
    }

    @Test func finishingOrCancellingLetsGoOfIt() {
        var activity = UploadActivity()
        let done = start(&activity, "done.bin", at: t0)
        activity.apply(.succeeded(id: done, remotePath: "/drops/done.bin"), now: t0)
        let stopped = start(&activity, "stopped.bin", at: t0)
        activity.apply(.cancelled(id: stopped), now: t0)

        #expect(activity.items.allSatisfy { $0.resume == nil && !$0.isResumable })
    }

    @Test func theRowSaysItIsWaitingForTheConnectionUntilBytesMoveAgain() {
        var activity = UploadActivity()
        let id = start(&activity, "big.bin", at: t0)
        activity.apply(.waitingForConnection(id: id), now: t0)
        #expect(activity.items[0].isReconnecting)
        #expect(activity.items[0].state == .uploading)

        activity.apply(.progress(id: id, UploadProgress(bytesSent: 40, totalBytes: 100)), now: t0)
        #expect(!activity.items[0].isReconnecting)
    }

    @Test func carryingOnTakesTheRowsPlaceUnderTheSameId() {
        var activity = UploadActivity()
        _ = lose(&activity, "other.bin", at: t0)
        let id = lose(&activity, "big.bin", at: t0.addingTimeInterval(1))
        #expect(activity.items.count == 2)

        activity.apply(.queued(id: id, fileName: "big.bin", totalBytes: 100), now: t0.addingTimeInterval(5))
        activity.apply(.resumable(id: id, point("big.bin")), now: t0.addingTimeInterval(5))

        // One row for it, now waiting: the failure is not carried over, and the other interrupted row is left alone.
        #expect(activity.items.filter { $0.id == id }.count == 1)
        #expect(activity.items.count == 2)
        #expect(activity.items.first { $0.id == id }?.state == .waiting)
        #expect(activity.items.first { $0.id == id }?.resume == point("big.bin"))
        #expect(activity.batchTotal == 1)
        #expect(!activity.hasUnseenFailure)
    }

    @Test func theSummaryCountsInterruptedUploads() {
        let restoredOne = restored([StoredUpload(fileName: "a.bin", totalBytes: 10, outcome: .interrupted, detail: "", finishedAt: t0, resume: point("a.bin"))])
        #expect(ActivityText.finishedSummary(restoredOne) == "1 interrupted")
    }

    @Test func startingOverSaysWhyAndStartsTheBarAgain() {
        var activity = UploadActivity()
        let id = start(&activity, "big.bin", at: t0)
        activity.apply(.progress(id: id, UploadProgress(bytesSent: 40, totalBytes: 100)), now: t0)
        activity.apply(.restarted(id: id, reason: "The file changed, so it starts over."), now: t0)

        #expect(activity.items[0].notice == "The file changed, so it starts over.")
        #expect(activity.items[0].bytesSent == 0)
        activity.apply(.succeeded(id: id, remotePath: "/drops/big.bin"), now: t0)
        #expect(activity.items[0].notice == nil)
    }

    // MARK: Paused uploads

    private func pause(_ activity: inout UploadActivity, _ name: String, at time: Date) -> UUID {
        let id = start(&activity, name, at: time)
        activity.apply(.progress(id: id, UploadProgress(bytesSent: 40, totalBytes: 100)), now: time)
        activity.apply(.paused(id: id), now: time)
        return id
    }

    @Test func aPausedUploadStaysInTheListWithWhatItTakesToResume() {
        var activity = UploadActivity()
        let id = pause(&activity, "big.bin", at: t0)

        let item = activity.items[0]
        #expect(item.id == id)
        #expect(item.state == .paused)
        #expect(item.bytesSent == 40)
        #expect(item.resume == point("big.bin"))
        #expect(item.isResumable)
        #expect(!activity.canClear)
    }

    @Test func aPausedUploadIsNotBusyAndRaisesNoFailureCues() {
        var activity = UploadActivity()
        _ = pause(&activity, "big.bin", at: t0)

        #expect(!activity.isBusy)
        #expect(!activity.hasUnseenFailure)
        #expect(!activity.batchHadFailure)
        #expect(activity.menubarState(now: t0.addingTimeInterval(10)) == .idle)
        // Nothing to tell: no sound, no notification.
        #expect(ActivityText.completionNotice(activity) == nil)
        #expect(ActivityText.finishedSummary(activity) == "1 paused")
    }

    @Test func aPausedUploadLeavesTheBatchSoTheRestGoesOnWithoutIt() {
        var activity = UploadActivity()
        let id = start(&activity, "a.bin", at: t0)
        let next = UUID()
        activity.apply(.queued(id: next, fileName: "b.bin", totalBytes: 100), now: t0)
        #expect(activity.batchTotal == 2)

        activity.apply(.paused(id: id), now: t0)

        #expect(activity.batchTotal == 1)
        #expect(activity.isBusy)
        #expect(ActivityText.uploadingHeader(activity) == "Uploading 1 of 1")
        // It can be removed, or cancelled, while the others run: it is not being counted.
        #expect(activity.canDismiss(activity.items.first { $0.id == id }!))
    }

    @Test func pausedUploadsAreExemptFromTheRecentRules() {
        var activity = UploadActivity()
        finish(&activity, "old.png", at: t0)
        for index in 0..<3 { finish(&activity, "f\(index)", at: t0.addingTimeInterval(Double(index + 1))) }
        _ = pause(&activity, "big.bin", at: t0)

        activity.applyRecentPolicy(RecentPolicy(limit: 1, lifetime: 60), now: t0.addingTimeInterval(86_400 * 30))

        #expect(activity.items.map(\.fileName) == ["big.bin"])
        activity.clearFinished()
        #expect(activity.items.map(\.fileName) == ["big.bin"])
        #expect(activity.nextRecentExpiry(lifetime: 60) == nil)
    }

    @Test func aPausedUploadComesBackPausedAfterARelaunch() throws {
        var activity = UploadActivity()
        _ = pause(&activity, "big.bin", at: t0)

        let stored = activity.storedInterrupted(now: t0)
        #expect(stored.count == 1 && stored[0].outcome == .paused && stored[0].isInterrupted)
        #expect(activity.storedFinished.isEmpty)

        let data = try JSONEncoder().encode(stored)
        let back = restored(try JSONDecoder().decode([StoredUpload].self, from: data))
        #expect(back.items[0].state == .paused)
        #expect(back.items[0].resume == point("big.bin"))
        #expect(back.items[0].isResumable)
        #expect(!back.isBusy && !back.hasUnseenFailure)
    }

    @Test func resumingAPausedUploadQueuesItAgainAsPartOfANewBatch() {
        var activity = UploadActivity()
        let id = pause(&activity, "big.bin", at: t0)

        activity.apply(.queued(id: id, fileName: "big.bin", totalBytes: 100), now: t0.addingTimeInterval(5))
        activity.apply(.resumable(id: id, point("big.bin")), now: t0.addingTimeInterval(5))

        #expect(activity.items.count == 1)
        #expect(activity.items[0].state == .waiting)
        #expect(activity.batchTotal == 1)
    }

    // MARK: The rules for Recent

    @Test func clearLeavesInterruptedUploadsAlone() {
        var activity = UploadActivity()
        finish(&activity, "fine.png", at: t0)
        _ = lose(&activity, "big.bin", at: t0.addingTimeInterval(1))
        #expect(activity.canClear)

        activity.clearFinished()

        #expect(activity.items.map(\.fileName) == ["big.bin"])
        #expect(!activity.canClear)
    }

    @Test func theCountIgnoresThemAndDoesntRemoveThem() {
        var activity = UploadActivity()
        for index in 0..<4 { finish(&activity, "f\(index)", at: t0.addingTimeInterval(Double(index))) }
        _ = lose(&activity, "big.bin", at: t0.addingTimeInterval(10))
        _ = lose(&activity, "huge.bin", at: t0.addingTimeInterval(11))

        activity.applyRecentPolicy(RecentPolicy(limit: 2, lifetime: nil), now: t0.addingTimeInterval(20))

        // Two finished ones are kept, as asked, and both interrupted ones on top of them.
        #expect(Set(activity.items.map(\.fileName)) == ["f3", "f2", "big.bin", "huge.bin"])
    }

    @Test func theClockIgnoresThemWhateverTheTime() {
        var activity = UploadActivity()
        finish(&activity, "old.png", at: t0)
        _ = lose(&activity, "big.bin", at: t0)

        activity.applyRecentPolicy(RecentPolicy(limit: 10, lifetime: 60), now: t0.addingTimeInterval(86_400 * 30))

        #expect(activity.items.map(\.fileName) == ["big.bin"])
        #expect(activity.nextRecentExpiry(lifetime: 60) == nil)
    }

    @Test func keepingNothingMeansNothingInterruptedUploadsIncluded() {
        var activity = UploadActivity()
        finish(&activity, "fine.png", at: t0)
        _ = lose(&activity, "big.bin", at: t0)

        activity.applyRecentPolicy(RecentPolicy(limit: 0, lifetime: nil), now: t0)

        #expect(activity.items.isEmpty)
    }

    @Test func anInterruptedUploadCanBeRemovedByItselfWhileAnotherBatchRuns() {
        var activity = UploadActivity()
        let lost = lose(&activity, "big.bin", at: t0)
        let stopped = activity.items[0]
        activity.apply(.queued(id: UUID(), fileName: "next.bin", totalBytes: 10), now: t0.addingTimeInterval(5))
        #expect(activity.isBusy)

        // The old one is not part of this batch. A failure from this batch still waits for it to end.
        #expect(activity.canDismiss(activity.items.first { $0.id == lost } ?? stopped))
        let thisBatch = UUID()
        activity.apply(.queued(id: thisBatch, fileName: "x.bin", totalBytes: 10), now: t0.addingTimeInterval(6))
        activity.apply(.started(id: thisBatch), now: t0.addingTimeInterval(6))
        activity.apply(.resumable(id: thisBatch, point("x.bin")), now: t0.addingTimeInterval(6))
        activity.apply(.failed(id: thisBatch, .connectionLost("lost")), now: t0.addingTimeInterval(7))
        #expect(!activity.canDismiss(activity.items.first { $0.id == thisBatch }!))
    }

    // MARK: Between launches

    @Test func interruptedAndRunningUploadsComeBackAsInterruptedAfterARelaunch() throws {
        var activity = UploadActivity()
        finish(&activity, "fine.png", at: t0)
        let lost = lose(&activity, "lost.bin", at: t0.addingTimeInterval(1))
        let running = start(&activity, "running.bin", at: t0.addingTimeInterval(2))
        let waiting = UUID()
        activity.apply(.queued(id: waiting, fileName: "waiting.bin", totalBytes: 100), now: t0.addingTimeInterval(3))
        activity.apply(.resumable(id: waiting, ResumePoint(sourcePath: "/Users/me/waiting.bin", isFolder: false, totalBytes: 100)), now: t0.addingTimeInterval(3))
        // Not yet known to be anything to carry on: a row with nothing to pick up from isn't stored.
        activity.apply(.queued(id: UUID(), fileName: "unknown.bin", totalBytes: 100), now: t0.addingTimeInterval(4))
        _ = (lost, running)

        let stored = activity.storedInterrupted(now: t0.addingTimeInterval(10))

        #expect(Set(stored.map(\.fileName)) == ["lost.bin", "running.bin", "waiting.bin"])
        #expect(stored.first { $0.fileName == "lost.bin" }?.outcome == .failed)
        #expect(stored.first { $0.fileName == "running.bin" }?.outcome == .interrupted)
        #expect(stored.allSatisfy { $0.resume != nil && $0.isInterrupted })
        // The finished one is the other list's business.
        #expect(activity.storedFinished.map(\.fileName) == ["fine.png"])

        let suite = "DropUpCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsRecentStore(defaults: defaults)
        store.save(stored)

        let back = restored(store.load())
        #expect(Set(back.items.map(\.fileName)) == ["lost.bin", "running.bin", "waiting.bin"])
        let byName = Dictionary(uniqueKeysWithValues: back.items.map { ($0.fileName, $0) })
        #expect(byName["running.bin"]?.state == .interrupted)
        #expect(byName["running.bin"]?.resume == point("running.bin"))
        #expect(byName["lost.bin"]?.state == .failed(message: "The connection was lost."))
        #expect(byName["waiting.bin"]?.state == .interrupted)
        #expect(byName["waiting.bin"]?.resume?.remotePath == nil)
        #expect(back.items.allSatisfy { $0.isResumable })
        // They are not running, and nobody needs the red badge for something they could already have seen.
        #expect(!back.isBusy)
        #expect(!back.hasUnseenFailure)
        #expect(back.menubarState(now: t0) == .idle)
        #expect(!back.canClear)
    }

    @Test func aStoredInterruptionWithoutWhatItTakesToResumeIsNotListed() {
        let broken = StoredUpload(fileName: "a.bin", totalBytes: 10, outcome: .interrupted, detail: "", finishedAt: t0)
        #expect(restored([broken]).items.isEmpty)
        #expect(!broken.isInterrupted)
    }

    @Test func listsSavedByAnEarlierVersionStillLoad() throws {
        let old = Data(#"[{"fileName":"a.png","totalBytes":5,"outcome":"succeeded","detail":"/drops/a.png","finishedAt":1000}]"#.utf8)
        let decoded = try JSONDecoder().decode([StoredUpload].self, from: old)
        #expect(decoded.count == 1)
        #expect(decoded[0].resume == nil)
        #expect(restored(decoded).items.first?.state == .succeeded(remotePath: "/drops/a.png"))
    }

    @Test func aResumePointSurvivesBeingSaved() throws {
        var folder = ResumePoint(
            sourcePath: "/Users/me/photos", isFolder: true, directory: "/other", config: config, remotePath: "/drops/photos-1",
            totalBytes: 123_456_789_012, created: true, finishedFiles: 41, fingerprint: "cbf29ce484222325", currentFile: "b/big.bin"
        )
        folder.sourceModified = Date(timeIntervalSince1970: 1_700_000_000.123)
        let decoded = try JSONDecoder().decode(ResumePoint.self, from: JSONEncoder().encode(folder))
        #expect(decoded == folder)
        #expect(decoded.partialPath == "/drops/photos-1/b/big.bin")
        #expect(decoded.fileName == "photos/")
        #expect(decoded.hasProgress)
    }

    // MARK: The point itself

    @Test func whereTheHalfSentFileIs() {
        var single = point("a.txt")
        #expect(single.partialPath == "/drops/a.txt")
        single.created = false
        #expect(single.partialPath == nil)
        #expect(!single.hasProgress)

        var folder = ResumePoint(sourcePath: "/x/photos", isFolder: true, remotePath: "/", created: true, currentFile: "a.txt")
        #expect(folder.partialPath == "/a.txt")
        folder.currentFile = nil
        #expect(folder.partialPath == nil)
        folder.finishedFiles = 3
        #expect(folder.hasProgress)
    }

    @Test func aFileIsTheSameOneWhenSizeAndDateMatch() {
        var original = point("a.txt")
        original.sourceModified = Date(timeIntervalSince1970: 1000)
        #expect(original.matches(size: 100, modified: Date(timeIntervalSince1970: 1000.0004)))
        #expect(!original.matches(size: 101, modified: Date(timeIntervalSince1970: 1000)))
        #expect(!original.matches(size: 100, modified: Date(timeIntervalSince1970: 1001)))
        // Without a date on one side only the size can tell.
        #expect(original.matches(size: 100, modified: nil))
    }

    @Test func aFolderStampChangesWithNamesAndSizesAndNothingElse() {
        func tree(_ files: [(String, Int64)]) -> LocalTree {
            var tree = LocalTree()
            tree.files = files.map { LocalTree.File(relativePath: $0.0, url: URL(fileURLWithPath: "/x/\($0.0)"), size: $0.1) }
            return tree
        }
        let base = tree([("a", 1), ("b/c", 2)])
        #expect(base.fingerprint == tree([("a", 1), ("b/c", 2)]).fingerprint)
        #expect(base.fingerprint != tree([("a", 1), ("b/c", 3)]).fingerprint)
        #expect(base.fingerprint != tree([("a", 1), ("b/d", 2)]).fingerprint)
        #expect(base.fingerprint != tree([("a", 1)]).fingerprint)
        #expect(base.fingerprint != tree([("b/c", 2), ("a", 1)]).fingerprint)
        // 1 + "2" must not read as 12.
        #expect(tree([("a", 12)]).fingerprint != tree([("a", 1), ("2", 0)]).fingerprint)
    }
}
