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
        #expect(!activity.hasUnseenFailure)

        // And so does the clock.
        var other = UploadActivity()
        finish(&other, "bad", at: t0, fails: true)
        other.applyRecentPolicy(RecentPolicy(limit: 10, lifetime: 60), now: t0.addingTimeInterval(59))
        #expect(other.items.count == 1)
        #expect(other.hasUnseenFailure)
        other.applyRecentPolicy(RecentPolicy(limit: 10, lifetime: 60), now: t0.addingTimeInterval(60))
        #expect(other.items.isEmpty)
        #expect(!other.hasUnseenFailure)
    }

    @Test func withTheListOffOnlyFailuresStay() {
        var activity = UploadActivity()
        finish(&activity, "fine", at: t0)
        finish(&activity, "bad", at: t0.addingTimeInterval(1), fails: true)
        finish(&activity, "stopped", at: t0.addingTimeInterval(2), cancels: true)
        activity.applyRecentPolicy(RecentPolicy(limit: 0, lifetime: nil), now: t0.addingTimeInterval(3))
        #expect(activity.items.map(\.fileName) == ["bad"])
        #expect(activity.hasUnseenFailure)
        // Dismissing it empties the list.
        activity.clearFinished()
        #expect(activity.items.isEmpty)
    }

    @Test func withTheListOffAFailureStillExpiresWithTheClock() {
        var activity = UploadActivity()
        finish(&activity, "bad", at: t0, fails: true)
        let policy = RecentPolicy(limit: 0, lifetime: 3_600)
        activity.applyRecentPolicy(policy, now: t0.addingTimeInterval(3_599))
        #expect(activity.items.count == 1)
        activity.applyRecentPolicy(policy, now: t0.addingTimeInterval(3_600))
        #expect(activity.items.isEmpty)
    }

    @Test func withTheListOffFailuresAreCapped() {
        var activity = UploadActivity()
        for index in 0..<(RecentPolicy.failureCap + 5) {
            finish(&activity, "bad\(index)", at: t0.addingTimeInterval(Double(index)), fails: true)
        }
        activity.applyRecentPolicy(RecentPolicy(limit: 0, lifetime: nil), now: t0.addingTimeInterval(1_000))
        #expect(activity.items.count == RecentPolicy.failureCap)
        #expect(activity.items.first?.fileName == "bad\(RecentPolicy.failureCap + 4)")
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
    }
}
