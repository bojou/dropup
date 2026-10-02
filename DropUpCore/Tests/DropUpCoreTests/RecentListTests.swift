import Foundation
import Testing
@testable import DropUpCore

struct RecentListTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func finish(
        _ activity: inout UploadActivity,
        _ name: String,
        at time: Date,
        fails: Bool = false,
        cancels: Bool = false
    ) {
        let id = UUID()
        activity.apply(.queued(id: id, fileName: name, totalBytes: 10), now: time)
        activity.apply(.started(id: id), now: time)
        if fails {
            activity.apply(.failed(id: id, .unsupportedItem), now: time)
        } else if cancels {
            activity.apply(.cancelled(id: id), now: time)
        } else {
            activity.apply(.succeeded(id: id, remotePath: "/drops/\(name)"), now: time)
        }
    }

    // MARK: Preferences

    @Test func untouchedSettingsKeepTheListAsItAlwaysWas() {
        let preferences = Preferences()
        #expect(preferences.recentPolicy == RecentPolicy(limit: 10, lifetime: nil))
        #expect(!preferences.recentSurvivesQuit)
        #expect(!preferences.hideRecentNames)
    }

    @Test func preferencesFromBeforeTheNewSettingsStillLoad() throws {
        let old = Data(#"{"recentLimit":20,"playSound":true}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: old)
        #expect(decoded.recentLimit == 20)
        #expect(decoded.recentClearMode == .onQuit)
        #expect(!decoded.hideRecentNames)
        // The count they had chosen stays on offer next to the fixed ones.
        #expect(decoded.recentLimitChoices == [5, 10, 20, 25, 50])
        #expect(Preferences().recentLimitChoices == [5, 10, 25, 50])
    }

    @Test func theRetiredHideFailedUploadsSettingIsIgnored() throws {
        // 0.1.23 and 0.1.24 saved this. Off now means off for failed uploads too, so there is nothing to carry over.
        let old = Data(#"{"recentLimit":0,"hideFailedUploads":false,"hideRecentNames":true}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: old)
        #expect(decoded.recentLimit == 0)
        #expect(decoded.hideRecentNames)
        #expect(decoded.recentPolicy == RecentPolicy(limit: 0, lifetime: nil))
    }

    @Test func newSettingsRoundTrip() throws {
        let preferences = Preferences(
            recentLimit: 0,
            recentClearMode: .custom,
            recentClearAmount: 30,
            recentClearUnit: .minutes,
            hideRecentNames: true
        )
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded == preferences)
    }

    @Test(arguments: [
        (RecentClearMode.onQuit, nil as TimeInterval?),
        (.never, nil),
        (.hour, 3_600),
        (.day, 86_400),
        (.week, 604_800),
    ])
    func presetsMapToLifetimes(mode: RecentClearMode, lifetime: TimeInterval?) {
        #expect(Preferences(recentClearMode: mode).recentLifetime == lifetime)
    }

    @Test func aCustomTimeIsAmountTimesUnitAndStaysInRange() {
        func lifetime(_ amount: Int, _ unit: RecentClearUnit) -> TimeInterval? {
            Preferences(recentClearMode: .custom, recentClearAmount: amount, recentClearUnit: unit).recentLifetime
        }
        #expect(lifetime(30, .minutes) == 1_800)
        #expect(lifetime(3, .hours) == 10_800)
        #expect(lifetime(2, .days) == 172_800)
        #expect(lifetime(0, .minutes) == 60)
        #expect(lifetime(-5, .hours) == 3_600)
        #expect(lifetime(5_000, .minutes) == TimeInterval(999 * 60))
    }

    @Test func onlyQuitClearingKeepsTheListInMemory() {
        for mode in RecentClearMode.allCases {
            #expect(Preferences(recentClearMode: mode).recentSurvivesQuit == (mode != .onQuit))
        }
    }

    // MARK: Rules

    @Test func keepsTheNewestFinishedUpToTheCount() {
        var activity = UploadActivity()
        for index in 0..<6 { finish(&activity, "f\(index)", at: t0.addingTimeInterval(Double(index))) }
        activity.applyRecentPolicy(RecentPolicy(limit: 3, lifetime: nil), now: t0.addingTimeInterval(10))
        #expect(activity.items.map(\.fileName) == ["f5", "f4", "f3"])
    }

    @Test func removesWhatIsOlderThanTheLifetime() {
        var activity = UploadActivity()
        finish(&activity, "old", at: t0)
        finish(&activity, "newer", at: t0.addingTimeInterval(3_000))
        activity.applyRecentPolicy(RecentPolicy(limit: 10, lifetime: 3_600), now: t0.addingTimeInterval(3_600))
        #expect(activity.items.map(\.fileName) == ["newer"])
        activity.applyRecentPolicy(RecentPolicy(limit: 10, lifetime: 3_600), now: t0.addingTimeInterval(6_600))
        #expect(activity.items.isEmpty)
    }

    @Test func failedUploadsFollowTheSameRules() {
        var activity = UploadActivity()
        finish(&activity, "bad", at: t0, fails: true)
        #expect(activity.hasUnseenFailure)
        // The count pushes a failure out like anything else.
        for index in 0..<3 { finish(&activity, "ok\(index)", at: t0.addingTimeInterval(Double(index + 1))) }
        activity.applyRecentPolicy(RecentPolicy(limit: 3, lifetime: nil), now: t0.addingTimeInterval(5))
        #expect(activity.items.map(\.fileName) == ["ok2", "ok1", "ok0"])

        // And so does the clock.
        var other = UploadActivity()
        finish(&other, "bad", at: t0, fails: true)
        other.applyRecentPolicy(RecentPolicy(limit: 10, lifetime: 60), now: t0.addingTimeInterval(59))
        #expect(other.items.count == 1)
        #expect(other.hasUnseenFailure)
        other.applyRecentPolicy(RecentPolicy(limit: 10, lifetime: 60), now: t0.addingTimeInterval(60))
        #expect(other.items.isEmpty)
    }

    @Test func theIconKeepsShowingAFailureTheListNoLongerHolds() {
        var activity = UploadActivity()
        finish(&activity, "bad", at: t0, fails: true)
        // The list may be set to keep nothing, or to clear itself; the failure is still unseen.
        activity.applyRecentPolicy(RecentPolicy(limit: 10, lifetime: 1), now: t0.addingTimeInterval(5))
        #expect(activity.items.isEmpty)
        #expect(activity.menubarState(now: t0.addingTimeInterval(5)) == .failed)
        activity.markFailuresSeen()
        #expect(activity.menubarState(now: t0.addingTimeInterval(5)) == .idle)
    }

    @Test func withTheListOffNothingStaysFailedUploadsIncluded() {
        var activity = UploadActivity()
        finish(&activity, "fine", at: t0)
        finish(&activity, "bad", at: t0.addingTimeInterval(1), fails: true)
        finish(&activity, "stopped", at: t0.addingTimeInterval(2), cancels: true)
        activity.applyRecentPolicy(RecentPolicy(limit: 0, lifetime: nil), now: t0.addingTimeInterval(3))
        #expect(activity.items.isEmpty)
    }

    @Test func withTheListOffAFailureIsStillToldByTheIcon() {
        var activity = UploadActivity()
        finish(&activity, "fine", at: t0)
        finish(&activity, "bad", at: t0.addingTimeInterval(1), fails: true)
        #expect(activity.batchHadFailure)
        let policy = Preferences(recentLimit: 0).recentPolicy
        activity.applyRecentPolicy(policy, now: t0.addingTimeInterval(2))
        #expect(activity.items.isEmpty)
        // Not listed, but the cross stays until the popover is opened.
        #expect(activity.menubarState(now: t0.addingTimeInterval(2)) == .failed)
        activity.markFailuresSeen()
        #expect(activity.menubarState(now: t0.addingTimeInterval(2)) == .idle)
    }

    @Test func aBatchInProgressIsLeftAlone() {
        var activity = UploadActivity()
        finish(&activity, "done", at: t0)
        let running = UUID()
        activity.apply(.queued(id: running, fileName: "big", totalBytes: 100), now: t0.addingTimeInterval(1))
        activity.applyRecentPolicy(RecentPolicy(limit: 0, lifetime: 1), now: t0.addingTimeInterval(100))
        #expect(activity.items.map(\.fileName) == ["big", "done"])
        activity.apply(.succeeded(id: running, remotePath: "/big"), now: t0.addingTimeInterval(101))
        activity.applyRecentPolicy(RecentPolicy(limit: 0, lifetime: nil), now: t0.addingTimeInterval(101))
        #expect(activity.items.isEmpty)
    }

    @Test func theIconStillFlashesWhenNothingIsListed() {
        var activity = UploadActivity()
        finish(&activity, "fine", at: t0)
        activity.applyRecentPolicy(RecentPolicy(limit: 0, lifetime: nil), now: t0)
        #expect(activity.items.isEmpty)
        #expect(activity.menubarState(now: t0.addingTimeInterval(1)) == .succeeded)
        #expect(activity.menubarState(now: t0.addingTimeInterval(3)) == .idle)
    }

    @Test func findsWhenTheNextUploadIsDueToGo() {
        var activity = UploadActivity()
        #expect(activity.nextRecentExpiry(lifetime: 60) == nil)
        finish(&activity, "a", at: t0)
        finish(&activity, "b", at: t0.addingTimeInterval(30))
        #expect(activity.nextRecentExpiry(lifetime: 60) == t0.addingTimeInterval(60))
        #expect(activity.nextRecentExpiry(lifetime: nil) == nil)
        let running = UUID()
        activity.apply(.queued(id: running, fileName: "c", totalBytes: 1), now: t0.addingTimeInterval(40))
        #expect(activity.nextRecentExpiry(lifetime: 60) == t0.addingTimeInterval(60))
    }

    // MARK: Between launches

    @Test func finishedUploadsComeBackAfterARelaunch() throws {
        var activity = UploadActivity()
        finish(&activity, "fine.png", at: t0)
        finish(&activity, "bad.zip", at: t0.addingTimeInterval(1), fails: true)
        finish(&activity, "stopped.mov", at: t0.addingTimeInterval(2), cancels: true)
        let running = UUID()
        activity.apply(.queued(id: running, fileName: "still-going", totalBytes: 5), now: t0.addingTimeInterval(3))

        let suite = "DropUpCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsRecentStore(defaults: defaults)
        #expect(store.load().isEmpty)
        store.save(activity.storedFinished)

        var restored = UploadActivity()
        restored.restore(store.load())
        #expect(restored.items.map(\.fileName) == ["stopped.mov", "bad.zip", "fine.png"])
        #expect(restored.items[0].state == .cancelled)
        #expect(restored.items[1].state == .failed(message: UploadFailure.unsupportedItem.displayMessage))
        #expect(restored.items[2].state == .succeeded(remotePath: "/drops/fine.png"))
        #expect(restored.items[2].finishedAt == t0)
        #expect(restored.items[2].fraction == 1)
        #expect(!restored.isBusy)
        // Nobody needs the red badge for something they could already have seen.
        #expect(!restored.hasUnseenFailure)
        #expect(restored.menubarState(now: t0) == .idle)

        store.save([])
        #expect(store.load().isEmpty)
    }

    // MARK: Hiding names

    @Test func hiddenNamesSayWhatHappenedNotWhatItWasCalled() {
        var activity = UploadActivity()
        finish(&activity, "taxes.pdf", at: t0)
        finish(&activity, "photos/", at: t0.addingTimeInterval(1))
        finish(&activity, "bad.zip", at: t0.addingTimeInterval(2), fails: true)
        let byName = Dictionary(uniqueKeysWithValues: activity.items.map { ($0.fileName, $0) })
        #expect(ActivityText.displayName(of: byName["taxes.pdf"]!, hidingNames: false) == "taxes.pdf")
        #expect(ActivityText.displayName(of: byName["taxes.pdf"]!, hidingNames: true) == "Uploaded file")
        #expect(ActivityText.displayName(of: byName["photos/"]!, hidingNames: true) == "Uploaded folder")
        #expect(ActivityText.displayName(of: byName["bad.zip"]!, hidingNames: true) == "File")
    }

    @Test func hiddenNamesAreTakenOutOfErrorMessages() {
        func item(_ name: String) -> UploadActivity.Item {
            UploadActivity.Item(id: UUID(), fileName: name, totalBytes: 1)
        }
        let photo = item("photo.png")
        let message = "550 Permission denied: /var/www/photo.png (could not write photo-2.png either)"
        #expect(ActivityText.failureMessage(message, for: photo, hidingNames: false) == message)
        #expect(ActivityText.failureMessage(message, for: photo, hidingNames: true)
            == "550 Permission denied: the file (could not write the file either)")
        #expect(ActivityText.failureMessage("Can't open 'photo.png'.", for: photo, hidingNames: true) == "Can't open 'the file'.")
        // Other names and words around it stay.
        #expect(ActivityText.failureMessage("Disk full while sending photo.pngx", for: photo, hidingNames: true)
            == "Disk full while sending photo.pngx")
        #expect(ActivityText.failureMessage("Connection timed out", for: photo, hidingNames: true) == "Connection timed out")

        let folder = item("holiday photos/")
        #expect(ActivityText.failureMessage("Couldn't create holiday photos", for: folder, hidingNames: true) == "Couldn't create the folder")

        // A short name only matches as a whole word.
        let short = item("a")
        #expect(ActivityText.failureMessage("Permission denied for a", for: short, hidingNames: true) == "Permission denied for the file")
        #expect(ActivityText.failureMessage("Permission denied", for: short, hidingNames: true) == "Permission denied")
    }

    @Test func hiddenNamesTakeTheWholeUploadPathOutOfErrorMessages() {
        func hidden(_ message: String, name: String = "photo.png", paths: [String] = []) -> String {
            let item = UploadActivity.Item(id: UUID(), fileName: name, totalBytes: 1)
            return ActivityText.failureMessage(message, for: item, hidingNames: true, hiddenPaths: paths)
        }
        // A path goes as one piece, wherever it sits and whatever it is called.
        #expect(hidden("550 /clients/acme/invoices/photo.png: Permission denied") == "550 the file: Permission denied")
        #expect(hidden("Couldn't change to /clients/acme/invoices.") == "Couldn't change to the folder.")
        #expect(hidden("No such directory (/clients/acme/)") == "No such directory (the folder)")
        #expect(hidden(#"Can't write "/clients/acme/photo.png" now"#) == "Can't write the file now")
        #expect(hidden("Failed: ~/uploads/2024/x.txt, C:\\Sites\\acme\\x.txt") == "Failed: the folder, the folder")
        // What a folder upload reports for an item inside the folder.
        #expect(hidden("“sub/dir/inner.txt”: Permission denied", name: "docs/") == "the folder: Permission denied")
        #expect(hidden("“inner.txt”: Permission denied", name: "docs/") == "the item: Permission denied")
        #expect(hidden("“photo.png”: Permission denied") == "the file: Permission denied")

        // Messages with no path in them are left alone.
        #expect(hidden("The server refused: disk quota exceeded (552)") == "The server refused: disk quota exceeded (552)")
    }

    @Test func hiddenNamesTakeTheUploadFolderOutEvenWithoutASlash() {
        func hidden(_ message: String, paths: [String]) -> String {
            let item = UploadActivity.Item(id: UUID(), fileName: "photo.png", totalBytes: 1)
            return ActivityText.failureMessage(message, for: item, hidingNames: true, hiddenPaths: paths)
        }
        let paths = ["/clients/Acme Corp/invoices/"]
        // Each folder of the upload path goes wherever it is named, in any case, as whole words.
        #expect(hidden("Couldn't create invoices", paths: paths) == "Couldn't create the folder")
        #expect(hidden("No such directory: ACME CORP", paths: paths) == "No such directory: the folder")
        #expect(hidden("Permission denied for clients", paths: paths) == "Permission denied for the folder")
        #expect(hidden("Invoicing is closed", paths: paths) == "Invoicing is closed")
        // A second folder given for the same upload (dropped into Browse) goes too.
        #expect(hidden("Can't open archive-2019", paths: ["/clients/", "/archive-2019/old"]) == "Can't open the folder")
        // The root and dots have nothing to hide.
        #expect(hidden("Permission denied", paths: ["/", "./..", ""]) == "Permission denied")
    }

    @Test func hiddenPathsLeaveOneStandInPerRun() {
        let item = UploadActivity.Item(id: UUID(), fileName: "photo.png", totalBytes: 1)
        let message = "Can't enter Acme Corp Invoices Archive"
        #expect(ActivityText.failureMessage(message, for: item, hidingNames: true, hiddenPaths: ["/Acme Corp/Invoices/Archive"])
            == "Can't enter the folder")
    }

    @Test func showingNamesLeavesErrorMessagesAsTheServerSaidThem() {
        let item = UploadActivity.Item(id: UUID(), fileName: "photo.png", totalBytes: 1)
        let message = "550 /clients/acme/photo.png: Permission denied"
        #expect(ActivityText.failureMessage(message, for: item, hidingNames: false, hiddenPaths: ["/clients/acme"]) == message)
    }

    @Test func aBatchWithAFailureIsToldApartFromOneWithout() {
        var activity = UploadActivity()
        let ok = UUID(), bad = UUID()
        activity.apply(.queued(id: ok, fileName: "a", totalBytes: 1), now: t0)
        activity.apply(.queued(id: bad, fileName: "b", totalBytes: 1), now: t0)
        activity.apply(.succeeded(id: ok, remotePath: "/a"), now: t0)
        #expect(!activity.batchHadFailure)
        activity.apply(.failed(id: bad, .unsupportedItem), now: t0)
        #expect(activity.batchHadFailure)

        // The next batch starts clean, though the failure is still listed.
        let next = UUID()
        activity.apply(.queued(id: next, fileName: "c", totalBytes: 1), now: t0.addingTimeInterval(5))
        activity.apply(.succeeded(id: next, remotePath: "/c"), now: t0.addingTimeInterval(6))
        #expect(!activity.batchHadFailure)
        #expect(activity.items.count == 3)
    }

    @Test func notificationsLeaveNamesOutWhenHidden() throws {
        var one = UploadActivity()
        finish(&one, "taxes.pdf", at: t0)
        #expect(try #require(ActivityText.completionNotice(one)).body == "taxes.pdf")
        let hiddenOne = try #require(ActivityText.completionNotice(one, hidingNames: true))
        #expect(hiddenOne.title == "Uploaded")
        #expect(hiddenOne.body == "Uploaded file")

        // Two files dropped together are one batch.
        var several = UploadActivity()
        let first = UUID(), second = UUID()
        several.apply(.queued(id: first, fileName: "a.txt", totalBytes: 1), now: t0)
        several.apply(.queued(id: second, fileName: "b.txt", totalBytes: 1), now: t0)
        several.apply(.succeeded(id: first, remotePath: "/a.txt"), now: t0)
        several.apply(.succeeded(id: second, remotePath: "/b.txt"), now: t0.addingTimeInterval(1))
        #expect(try #require(ActivityText.completionNotice(several)).body == "b.txt, a.txt")
        let hiddenSeveral = try #require(ActivityText.completionNotice(several, hidingNames: true))
        #expect(hiddenSeveral.title == "Uploaded 2 files")
        #expect(hiddenSeveral.body.isEmpty)

        var failure = UploadActivity()
        finish(&failure, "bad.zip", at: t0, fails: true)
        let shown = try #require(ActivityText.completionNotice(failure))
        let hidden = try #require(ActivityText.completionNotice(failure, hidingNames: true))
        #expect(shown.body.hasPrefix("bad.zip: "))
        #expect(!hidden.body.contains("bad.zip"))
        #expect(hidden.body == UploadFailure.unsupportedItem.displayMessage)

        // The server's own words can carry the name; those are cleaned too.
        var wordy = UploadActivity()
        let id = UUID()
        wordy.apply(.queued(id: id, fileName: "taxes.pdf", totalBytes: 1), now: t0)
        wordy.apply(.failed(id: id, .transfer("550 taxes.pdf: permission denied")), now: t0)
        #expect(try #require(ActivityText.completionNotice(wordy, hidingNames: true)).body == "550 the file: permission denied")

        // And so is the upload path, whether the server spells it out or the notice is told where the upload went.
        var placed = UploadActivity()
        let target = UUID()
        placed.apply(.queued(id: target, fileName: "taxes.pdf", totalBytes: 1), now: t0)
        placed.apply(.failed(id: target, .transfer("550 /clients/acme/taxes.pdf: no space; acme is full")), now: t0)
        let notice = try #require(ActivityText.completionNotice(placed, hidingNames: true, hiddenPaths: ["/clients/acme"]))
        #expect(notice.body == "550 the file: no space; the folder is full")
        // Shown names are not touched.
        #expect(try #require(ActivityText.completionNotice(placed, hiddenPaths: ["/clients/acme"])).body
            == "taxes.pdf: 550 /clients/acme/taxes.pdf: no space; acme is full")
    }
}
