import Foundation
import Testing
@testable import DropUpCore

struct FreshInstallTests {
    /// A marker in a temporary folder and an isolated preferences domain.
    struct Sandbox {
        let directory: URL
        let marker: InstallMarker
        let defaults: UserDefaults
        private let suite: String

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("dropup-install-\(UUID().uuidString)")
            marker = InstallMarker(directory: directory)
            suite = "dropup.test.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }

        /// Runs the launch check and reports the state and how many times the wipe ran.
        func launch(hasSettings: Bool = false) -> (state: InstallState, wipes: Int) {
            var wipes = 0
            let state = FreshInstall.reconcile(marker: marker, defaults: defaults, hasSettings: hasSettings) { wipes += 1 }
            return (state, wipes)
        }
    }

    @Test func decisionTable() {
        #expect(FreshInstall.decide(markerToken: "a", defaultsToken: "a", hasSettings: true) == .continuing)
        #expect(FreshInstall.decide(markerToken: "a", defaultsToken: nil, hasSettings: false) == .continuing)
        #expect(FreshInstall.decide(markerToken: "a", defaultsToken: "b", hasSettings: true) == .continuing)
        #expect(FreshInstall.decide(markerToken: nil, defaultsToken: "a", hasSettings: true) == .fresh)
        #expect(FreshInstall.decide(markerToken: nil, defaultsToken: "a", hasSettings: false) == .fresh)
        #expect(FreshInstall.decide(markerToken: nil, defaultsToken: nil, hasSettings: false) == .fresh)
        #expect(FreshInstall.decide(markerToken: nil, defaultsToken: nil, hasSettings: true) == .legacySettings)
    }

    @Test func firstLaunchIsFreshThenContinues() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }

        let first = box.launch()
        #expect(first.state == .fresh)
        #expect(first.wipes == 1)
        #expect(box.marker.read()?.isEmpty == false)
        #expect(box.defaults.string(forKey: FreshInstall.tokenKey) == box.marker.read())

        let second = box.launch(hasSettings: true)
        #expect(second.state == .continuing)
        #expect(second.wipes == 0)
    }

    @Test func reinstallAfterRemovalWipesLeftovers() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        _ = box.launch()
        #expect(box.launch(hasSettings: true).state == .continuing)

        // The app is removed with AppCleaner: its Application Support folder goes, but the preferences
        // (still cached by the system) and the Keychain stay.
        try FileManager.default.removeItem(at: box.directory)

        let afterReinstall = box.launch(hasSettings: true)
        #expect(afterReinstall.state == .fresh)
        #expect(afterReinstall.wipes == 1)
        #expect(box.launch(hasSettings: false).state == .continuing)
    }

    @Test func reinstallWithPreferencesAlsoGoneStillClearsTheKeychain() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        _ = box.launch()
        try FileManager.default.removeItem(at: box.directory)
        box.defaults.removeObject(forKey: FreshInstall.tokenKey)

        let result = box.launch(hasSettings: false)
        #expect(result.state == .fresh)
        #expect(result.wipes == 1) // Keychain items are the only thing left to clear
    }

    @Test func settingsFromBeforeTheMarkerExistedAreNotWipedUntilAsked() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }

        let first = box.launch(hasSettings: true)
        #expect(first.state == .legacySettings)
        #expect(first.wipes == 0)
        #expect(box.marker.read() == nil)

        // Still undecided on the next launch.
        #expect(box.launch(hasSettings: true).state == .legacySettings)

        FreshInstall.adoptLegacy(marker: box.marker, defaults: box.defaults)
        let after = box.launch(hasSettings: true)
        #expect(after.state == .continuing)
        #expect(after.wipes == 0)
    }

    @Test func startingFreshFromLegacySettingsWipes() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        #expect(box.launch(hasSettings: true).state == .legacySettings)

        var wipes = 0
        FreshInstall.startFresh(marker: box.marker, defaults: box.defaults) { wipes += 1 }
        #expect(wipes == 1)
        #expect(box.launch(hasSettings: false).state == .continuing)
    }

    @Test func neverWipesWhenTheMarkerCannotBeWritten() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        // A regular file where the folder should be: creating the marker fails.
        try Data().write(to: box.directory)

        let result = box.launch()
        #expect(result.wipes == 0)
        #expect(box.defaults.string(forKey: FreshInstall.tokenKey) == nil)
    }

    @Test func repairsPreferencesThatLostTheToken() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        _ = box.launch()
        box.defaults.removeObject(forKey: FreshInstall.tokenKey)

        let result = box.launch(hasSettings: false)
        #expect(result.state == .continuing)
        #expect(result.wipes == 0)
        #expect(box.defaults.string(forKey: FreshInstall.tokenKey) == box.marker.read())
    }

    @Test func unreadableMarkerIsNotTreatedAsMissing() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try FileManager.default.createDirectory(at: box.directory, withIntermediateDirectories: true)
        // A folder where the file should be: it exists, but can't be read as text.
        try FileManager.default.createDirectory(at: box.marker.fileURL, withIntermediateDirectories: true)

        #expect(box.marker.read() == "")
        #expect(box.launch(hasSettings: true).state == .continuing)
    }
}
