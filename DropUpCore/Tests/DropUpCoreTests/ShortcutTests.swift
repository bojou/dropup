import Foundation
import Testing
@testable import DropUpCore

struct ShortcutTests {
    // 2026-10-04 09:36:12 UTC
    let now = Date(timeIntervalSince1970: 1_791_106_572)
    let utc = TimeZone(identifier: "UTC")!

    private func combo(_ keyCode: UInt16, _ modifiers: KeyModifiers, _ label: String = "X") -> KeyCombo {
        KeyCombo(keyCode: keyCode, modifiers: modifiers, label: label)
    }

    // MARK: Settings

    @Test func everyActionStartsOffWithItsOwnDefaultKey() {
        let settings = ShortcutSettings()
        #expect(settings.active.isEmpty)
        for action in ShortcutAction.allCases {
            #expect(!settings[action].isOn)
            #expect(settings[action].combo == action.defaultCombo)
        }
        #expect(ShortcutAction.quickUpload.defaultCombo.display == "⌃⌥⌘U")
        #expect(ShortcutAction.uploadClipboard.defaultCombo.display == "⌃⌥⌘V")
        #expect(ShortcutAction.uploadScreenshot.defaultCombo.display == "⌃⌥⌘S")
        let combos = Set(ShortcutAction.allCases.map(\.defaultCombo))
        #expect(combos.count == ShortcutAction.allCases.count)
    }

    @Test func theDefaultKeysPassTheirOwnRules() {
        let settings = ShortcutSettings()
        for action in ShortcutAction.allCases {
            #expect(ShortcutRules.check(action.defaultCombo, for: action, in: settings) == .accepted)
        }
    }

    @Test func settingsSurviveSavingAndLoading() throws {
        var settings = ShortcutSettings()
        settings[.uploadClipboard].isOn = true
        settings[.uploadClipboard].combo = combo(0, [.control, .command], "A")
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(ShortcutSettings.self, from: data)
        #expect(back == settings)
        #expect(back.active.map(\.action) == [.uploadClipboard])
        #expect(back[.uploadClipboard].combo.display == "⌃⌘A")
        #expect(!back[.quickUpload].isOn)
    }

    @Test func untouchedAndSavedDefaultsCompareEqual() {
        var touched = ShortcutSettings()
        touched[.quickUpload] = touched[.quickUpload]
        #expect(touched == ShortcutSettings())
    }

    @Test func preferencesFromBeforeShortcutsLoadWithEverythingOff() throws {
        let old = Data(#"{"recentLimit":20,"playSound":true}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: old)
        #expect(decoded.shortcuts == ShortcutSettings())
        #expect(decoded.shortcuts.active.isEmpty)
    }

    @Test func aGarbledShortcutsEntryFallsBackToTheDefaults() throws {
        let broken = Data(#"{"playSound":true,"shortcuts":"nope"}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: broken)
        #expect(decoded.playSound)
        #expect(decoded.shortcuts == ShortcutSettings())
    }

    @Test func aFutureActionInTheFileIsIgnored() throws {
        let data = Data(#"{"quickUpload":{"isOn":true,"combo":{"keyCode":32,"modifiers":11,"label":"U"}},"somethingNew":{"isOn":true,"combo":{"keyCode":1,"modifiers":9,"label":"S"}}}"#.utf8)
        let decoded = try JSONDecoder().decode(ShortcutSettings.self, from: data)
        #expect(decoded.active.map(\.action) == [.quickUpload])
    }

    @Test func preferencesKeepShortcutsThroughTheStore() throws {
        let suite = "shortcut-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSettingsStore(defaults: defaults)
        var preferences = Preferences()
        preferences.shortcuts[.uploadScreenshot].isOn = true
        try store.savePreferences(preferences)
        #expect(store.loadPreferences().shortcuts[.uploadScreenshot].isOn)
    }

    // MARK: Rules

    @Test func aKeyNeedsTwoModifiersOneOfThemControlOrCommand() {
        let settings = ShortcutSettings()
        let tooFew: [KeyModifiers] = [[], [.command], [.option], [.shift], [.control]]
        for modifiers in tooFew {
            guard case .rejected = ShortcutRules.check(combo(40, modifiers), for: .quickUpload, in: settings) else {
                Issue.record("\(modifiers.symbols) alone should be rejected")
                continue
            }
        }
        // macOS 15 drops global shortcuts made of Option and Shift only.
        for modifiers: KeyModifiers in [[.option, .shift]] {
            guard case .rejected = ShortcutRules.check(combo(40, modifiers), for: .quickUpload, in: settings) else {
                Issue.record("\(modifiers.symbols) should be rejected")
                continue
            }
        }
        for modifiers: KeyModifiers in [[.control, .option], [.command, .shift], [.control, .command], [.option, .command], [.control, .option, .shift, .command]] {
            #expect(ShortcutRules.check(combo(40, modifiers), for: .quickUpload, in: settings) == .accepted, "\(modifiers.symbols)")
        }
    }

    @Test func aKeyAnotherActionHoldsIsRejectedByName() {
        var settings = ShortcutSettings()
        settings[.uploadClipboard].combo = combo(40, [.control, .command], "K")
        let verdict = ShortcutRules.check(combo(40, [.control, .command], "K"), for: .quickUpload, in: settings)
        #expect(verdict == .rejected("⌃⌘K is already used by Upload from Clipboard."))
        // The action's own key is not a clash with itself.
        #expect(ShortcutRules.check(combo(40, [.control, .command], "K"), for: .uploadClipboard, in: settings) == .accepted)
    }

    @Test func theSameKeyWithOtherModifiersIsNotAClash() {
        var settings = ShortcutSettings()
        settings[.uploadClipboard].combo = combo(40, [.control, .command], "K")
        #expect(ShortcutRules.check(combo(40, [.control, .option], "K"), for: .quickUpload, in: settings) == .accepted)
    }

    @Test func aKeyMacOSUsesIsAllowedWithAWarning() {
        let settings = ShortcutSettings()
        let verdict = ShortcutRules.check(combo(20, [.shift, .command], "3"), for: .quickUpload, in: settings)
        #expect(verdict == .warning("macOS uses ⇧⌘3 for Screenshot."))
        let lock = ShortcutRules.check(combo(12, [.control, .command], "Q"), for: .quickUpload, in: settings)
        #expect(lock == .warning("macOS uses ⌃⌘Q for Lock Screen."))
    }

    @Test func modifierSymbolsComeInMacOSOrder() {
        #expect(KeyModifiers([.command, .shift, .option, .control]).symbols == "⌃⌥⇧⌘")
        #expect(KeyModifiers([.command]).count == 1)
        #expect(KeyModifiers([]).count == 0)
    }

    // MARK: Clipboard

    private struct FakeClipboard: ClipboardReading {
        var files: [URL] = []
        var image: Data?
        var string: String?
        func fileURLs() -> [URL] { files }
        func imagePNG() -> Data? { image }
        func text() -> String? { string }
    }

    @Test func filesCopiedInFinderComeBeforeAnImageOrText() {
        let files = [URL(fileURLWithPath: "/a/one.txt"), URL(fileURLWithPath: "/a/folder")]
        let clipboard = FakeClipboard(files: files, image: Data([1]), string: "hello")
        #expect(ClipboardPlanner.plan(clipboard, now: now, timeZone: utc) == .upload(files))
    }

    @Test func anImageComesBeforeTextAndIsNamedByTheTime() {
        let clipboard = FakeClipboard(image: Data([1, 2, 3]), string: "hello")
        #expect(ClipboardPlanner.plan(clipboard, now: now, timeZone: utc) == .stage(name: "Clipboard 2026-10-04 09.36.12.png", data: Data([1, 2, 3])))
    }

    @Test func textBecomesATextFile() {
        let clipboard = FakeClipboard(string: "héllo\nworld")
        #expect(ClipboardPlanner.plan(clipboard, now: now, timeZone: utc) == .stage(name: "Clipboard 2026-10-04 09.36.12.txt", data: Data("héllo\nworld".utf8)))
    }

    @Test func theNameUsesTheLocalClockWithDotsNotColons() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let name = ClipboardPlanner.fileName(extension: "png", at: now, in: tokyo)
        #expect(name == "Clipboard 2026-10-04 18.36.12.png")
        #expect(!name.contains(":"))
    }

    @Test func blankTextAndEmptyImagesCountAsNothing() {
        #expect(ClipboardPlanner.plan(FakeClipboard(string: "  \n\t "), now: now, timeZone: utc) == .notice(ShortcutNotice.clipboardEmpty))
        #expect(ClipboardPlanner.plan(FakeClipboard(image: Data()), now: now, timeZone: utc) == .notice(ShortcutNotice.clipboardEmpty))
        #expect(ClipboardPlanner.plan(FakeClipboard(), now: now, timeZone: utc) == .notice(ShortcutNotice.clipboardEmpty))
    }

    @Test func anEmptyImageFallsThroughToText() {
        let clipboard = FakeClipboard(image: Data(), string: "text")
        #expect(ClipboardPlanner.plan(clipboard, now: now, timeZone: utc) == .stage(name: "Clipboard 2026-10-04 09.36.12.txt", data: Data("text".utf8)))
    }

    private final class CountingClipboard: ClipboardReading {
        var imageReads = 0
        var textReads = 0
        func fileURLs() -> [URL] { [URL(fileURLWithPath: "/a/one.txt")] }
        func imagePNG() -> Data? { imageReads += 1; return nil }
        func text() -> String? { textReads += 1; return nil }
    }

    @Test func theImageAndTheTextAreNotReadWhenFilesAreThere() {
        let clipboard = CountingClipboard()
        _ = ClipboardPlanner.plan(clipboard, now: now, timeZone: utc)
        #expect(clipboard.imageReads == 0)
        #expect(clipboard.textReads == 0)
    }

    // MARK: Screenshots

    private func shot(_ name: String, secondsAgo: TimeInterval, mark: Bool? = nil, folder: String = "/Users/me/Desktop") -> ScreenshotCandidate {
        ScreenshotCandidate(url: URL(fileURLWithPath: "\(folder)/\(name)"), created: now.addingTimeInterval(-secondsAgo), isScreenCapture: mark)
    }

    @Test func theNewestScreenshotFromTheLastTenMinutesWins() {
        let candidates = [
            shot("Screenshot 2026-10-04 at 09.00.00.png", secondsAgo: 300),
            shot("Screenshot 2026-10-04 at 09.30.00.png", secondsAgo: 60),
            shot("Screenshot 2026-10-04 at 09.20.00.png", secondsAgo: 120),
        ]
        #expect(ScreenshotPicker.latest(in: candidates, now: now)?.url.lastPathComponent == "Screenshot 2026-10-04 at 09.30.00.png")
        #expect(ScreenshotPicker.plan(candidates, now: now) == .upload([candidates[1].url]))
    }

    @Test func aScreenshotOlderThanTenMinutesIsNotTheLatest() {
        let candidates = [shot("Screenshot a.png", secondsAgo: ScreenshotPicker.window + 1)]
        #expect(ScreenshotPicker.plan(candidates, now: now) == .notice(ShortcutNotice.noScreenshot))
        #expect(ScreenshotPicker.latest(in: [shot("Screenshot a.png", secondsAgo: ScreenshotPicker.window)], now: now) != nil)
        #expect(ScreenshotPicker.plan([], now: now) == .notice(ShortcutNotice.noScreenshot))
    }

    @Test func aDifferentNameCountsWhenMacOSMarkedItAsAScreenshot() {
        // A Mac set to another language names its screenshots differently.
        let candidates = [shot("Bildschirmfoto 2026-10-04 um 09.35.00.png", secondsAgo: 30, mark: true)]
        #expect(ScreenshotPicker.latest(in: candidates, now: now) != nil)
    }

    @Test func theMarkOverridesTheName() {
        // Not a screenshot even though it is called one, and the other way round.
        #expect(ScreenshotPicker.latest(in: [shot("Screenshot notes.png", secondsAgo: 30, mark: false)], now: now) == nil)
        #expect(ScreenshotPicker.latest(in: [shot("holiday.png", secondsAgo: 30, mark: true)], now: now) != nil)
    }

    @Test func withoutAMarkTheNamePrefixDecides() {
        #expect(ScreenshotPicker.latest(in: [shot("holiday.png", secondsAgo: 30)], now: now) == nil)
        #expect(ScreenshotPicker.latest(in: [shot("Screenshot 1.png", secondsAgo: 30)], now: now) != nil)
    }

    @Test func onlyImagesAreScreenshotsNotRecordings() {
        #expect(ScreenshotPicker.latest(in: [shot("Screen Recording 2026-10-04.mov", secondsAgo: 30, mark: true)], now: now) == nil)
        #expect(ScreenshotPicker.latest(in: [shot("Screenshot 1.mov", secondsAgo: 30)], now: now) == nil)
        for ext in ["PNG", "jpg", "jpeg", "heic", "tiff", "gif"] {
            #expect(ScreenshotPicker.latest(in: [shot("Screenshot 1.\(ext)", secondsAgo: 30)], now: now) != nil, "\(ext)")
        }
    }

    @Test func aFileDatedInTheFutureIsNotLatest() {
        // A skewed clock should not make an old file look new, or a new one look old. A minute of slack is allowed.
        let candidates = [
            shot("Screenshot soon.png", secondsAgo: -30),
            shot("Screenshot much later.png", secondsAgo: -3_600),
        ]
        #expect(ScreenshotPicker.latest(in: candidates, now: now)?.url.lastPathComponent == "Screenshot soon.png")
    }

    // MARK: Quick Upload

    private struct FakeFinder: FinderSelectionReading {
        var finderIsFrontmost = true
        var result: Result<[URL], FinderSelectionError> = .success([])
        func selection() throws -> [URL] { try result.get() }
    }

    @Test func theFinderSelectionIsUploadedWhenFinderIsInFront() {
        let items = [URL(fileURLWithPath: "/Users/me/a.txt"), URL(fileURLWithPath: "/Users/me/Folder")]
        #expect(QuickUploadPlanner.plan(FakeFinder(result: .success(items))) == .upload(items))
    }

    @Test func nothingIsAskedOfFinderWhenItIsNotInFront() {
        struct Untouchable: FinderSelectionReading {
            var finderIsFrontmost: Bool { false }
            func selection() throws -> [URL] { Issue.record("The selection was read"); return [] }
        }
        #expect(QuickUploadPlanner.plan(Untouchable()) == .notice(ShortcutNotice.finderNotInFront))
    }

    @Test func anEmptySelectionSaysSo() {
        #expect(QuickUploadPlanner.plan(FakeFinder(result: .success([]))) == .notice(ShortcutNotice.nothingSelected))
    }

    @Test func aRefusedAutomationPermissionPointsToTheSetting() {
        #expect(QuickUploadPlanner.plan(FakeFinder(result: .failure(.notAllowed))) == .notice(ShortcutNotice.finderNotAllowed))
        #expect(ShortcutNotice.finderNotAllowed.contains("Automation"))
    }

    @Test func anyOtherFinderErrorIsReportedPlainly() {
        #expect(QuickUploadPlanner.plan(FakeFinder(result: .failure(.failed("timeout")))) == .notice(ShortcutNotice.finderFailed))
    }

    // MARK: Staging

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func aStagedFileHasItsNameAndItsBytes() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = ClipboardStaging(root: root)
        let url = try staging.write(name: "Clipboard 2026-10-04 09.36.12.txt", data: Data("hi".utf8))
        #expect(url.lastPathComponent == "Clipboard 2026-10-04 09.36.12.txt")
        #expect(try Data(contentsOf: url) == Data("hi".utf8))
        #expect(url.path.hasPrefix(root.path))
    }

    @Test func twoStagedFilesWithTheSameNameDoNotMeet() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = ClipboardStaging(root: root)
        let first = try staging.write(name: "same.txt", data: Data("1".utf8))
        let second = try staging.write(name: "same.txt", data: Data("2".utf8))
        #expect(first != second)
        #expect(try Data(contentsOf: first) == Data("1".utf8))
        #expect(try Data(contentsOf: second) == Data("2".utf8))
    }

    @Test func sweepingKeepsOnlyWhatIsStillNeeded() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = ClipboardStaging(root: root)
        let keep = try staging.write(name: "keep.png", data: Data([1]))
        let drop = try staging.write(name: "drop.png", data: Data([2]))
        #expect(staging.sweep(keeping: [keep]) == 1)
        #expect(FileManager.default.fileExists(atPath: keep.path))
        #expect(!FileManager.default.fileExists(atPath: drop.path))
        #expect(!FileManager.default.fileExists(atPath: drop.deletingLastPathComponent().path))
        #expect(staging.sweep(keeping: []) == 0)
        #expect(!FileManager.default.fileExists(atPath: keep.path))
    }

    @Test func sweepingWithNothingStagedIsHarmless() {
        #expect(ClipboardStaging(root: temporaryRoot()).sweep(keeping: []) == 0)
    }

    // MARK: Registering keys

    @MainActor
    private final class FakeRegistrar: HotKeyRegistrar {
        var live: [Int: (combo: KeyCombo, handler: @MainActor () -> Void)] = [:]
        var taken: Set<KeyCombo> = []
        var registrations = 0
        private var next = 0

        func register(_ combo: KeyCombo, handler: @escaping @MainActor () -> Void) -> Result<HotKeyToken, HotKeyFailure> {
            registrations += 1
            if taken.contains(combo) { return .failure(.takenByAnotherApp) }
            next += 1
            live[next] = (combo, handler)
            return .success(HotKeyToken(id: next))
        }

        func unregister(_ token: HotKeyToken) { live[token.id] = nil }

        var combos: Set<KeyCombo> { Set(live.values.map(\.combo)) }
        func press(_ combo: KeyCombo) { live.values.first { $0.combo == combo }?.handler() }
    }

    @MainActor
    private func coordinator(_ registrar: FakeRegistrar, _ performed: Box) -> ShortcutCoordinator {
        ShortcutCoordinator(registrar: registrar) { performed.actions.append($0) }
    }

    @MainActor final class Box { var actions: [ShortcutAction] = [] }

    @MainActor @Test func onlyTheActionsThatAreOnHaveAKey() {
        let registrar = FakeRegistrar()
        let performed = Box()
        let coordinator = coordinator(registrar, performed)
        var settings = ShortcutSettings()
        coordinator.apply(settings)
        #expect(registrar.live.isEmpty)

        settings[.uploadClipboard].isOn = true
        coordinator.apply(settings)
        #expect(registrar.combos == [ShortcutAction.uploadClipboard.defaultCombo])

        registrar.press(ShortcutAction.uploadClipboard.defaultCombo)
        #expect(performed.actions == [.uploadClipboard])

        settings[.uploadClipboard].isOn = false
        coordinator.apply(settings)
        #expect(registrar.live.isEmpty)
    }

    @MainActor @Test func aChangedKeyMovesAndTheOldOneIsFree() {
        let registrar = FakeRegistrar()
        let performed = Box()
        let coordinator = coordinator(registrar, performed)
        var settings = ShortcutSettings()
        settings[.quickUpload].isOn = true
        coordinator.apply(settings)
        let old = settings[.quickUpload].combo
        let new = KeyCombo(keyCode: 40, modifiers: [.control, .command], label: "K")
        settings[.quickUpload].combo = new
        coordinator.apply(settings)
        #expect(registrar.combos == [new])
        registrar.press(new)
        #expect(performed.actions == [.quickUpload])
        #expect(!registrar.combos.contains(old))
    }

    @MainActor @Test func applyingTheSameSettingsAgainRegistersNothingNew() {
        let registrar = FakeRegistrar()
        let coordinator = coordinator(registrar, Box())
        var settings = ShortcutSettings()
        settings[.quickUpload].isOn = true
        settings[.uploadScreenshot].isOn = true
        coordinator.apply(settings)
        let count = registrar.registrations
        coordinator.apply(settings)
        #expect(registrar.registrations == count)
        #expect(registrar.live.count == 2)
    }

    @MainActor @Test func aKeyAnotherAppHoldsIsReportedAndRetriedOnTheNextApply() {
        let registrar = FakeRegistrar()
        registrar.taken = [ShortcutAction.quickUpload.defaultCombo]
        let coordinator = coordinator(registrar, Box())
        var settings = ShortcutSettings()
        settings[.quickUpload].isOn = true
        settings[.uploadClipboard].isOn = true
        coordinator.apply(settings)
        #expect(coordinator.failures == [.quickUpload: .takenByAnotherApp])
        #expect(registrar.combos == [ShortcutAction.uploadClipboard.defaultCombo])

        // The other app lets go; the next time the settings are applied it works.
        registrar.taken = []
        coordinator.apply(settings)
        #expect(coordinator.failures.isEmpty)
        #expect(registrar.combos.count == 2)
    }

    @MainActor @Test func aFailureGoesAwayWhenTheActionIsSwitchedOff() {
        let registrar = FakeRegistrar()
        registrar.taken = [ShortcutAction.quickUpload.defaultCombo]
        let coordinator = coordinator(registrar, Box())
        var settings = ShortcutSettings()
        settings[.quickUpload].isOn = true
        coordinator.apply(settings)
        #expect(coordinator.failures[.quickUpload] == .takenByAnotherApp)
        settings[.quickUpload].isOn = false
        coordinator.apply(settings)
        #expect(coordinator.failures.isEmpty)
    }

    @MainActor @Test func pausingLetsGoOfEveryKeyAndResumingTakesThemBack() {
        let registrar = FakeRegistrar()
        let performed = Box()
        let coordinator = coordinator(registrar, performed)
        var settings = ShortcutSettings()
        settings[.quickUpload].isOn = true
        settings[.uploadScreenshot].isOn = true
        coordinator.apply(settings)
        coordinator.pause()
        #expect(registrar.live.isEmpty)
        // Settings applied while the recorder listens do not take a key back early.
        coordinator.apply(settings)
        #expect(registrar.live.isEmpty)
        coordinator.resume()
        #expect(registrar.combos == [ShortcutAction.quickUpload.defaultCombo, ShortcutAction.uploadScreenshot.defaultCombo])
    }

    @MainActor @Test func aHandlerOutlivingTheCoordinatorDoesNothing() {
        let registrar = FakeRegistrar()
        let performed = Box()
        var settings = ShortcutSettings()
        settings[.quickUpload].isOn = true
        var coordinator: ShortcutCoordinator? = self.coordinator(registrar, performed)
        coordinator?.apply(settings)
        coordinator = nil
        registrar.press(ShortcutAction.quickUpload.defaultCombo)
        #expect(performed.actions.isEmpty)
    }
}
