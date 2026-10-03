import Foundation
import Observation
import Sparkle

/// Checks for new versions of DropUp with Sparkle and installs them when the user says so.
///
/// The feed and the public key that signed updates must match come from Info.plist (`SUFeedURL`, `SUPublicEDKey`).
/// A build without the key, such as one made on a developer's machine, never starts the updater, so there is nothing
/// to check against and the controls in Settings stay greyed out.
///
/// DropUp has no Dock icon, so a window that opens by itself would land among whatever is on screen. When the daily check
/// finds a version, `availableVersion` is set instead, for the menubar icon and the popover to show, and Sparkle's window
/// opens only when the user asks for it with `showAvailableUpdate()`.
@MainActor
@Observable
final class Updates {
    /// Whether Sparkle is ready to check right now: not while a check or an install is already running.
    private(set) var canCheckNow = false
    /// Whether DropUp looks for new versions by itself (once a day, and not more often than that).
    private(set) var automaticallyChecks = false
    /// The version the daily check found, until the user has looked at it, skipped it or put it off. Nil otherwise.
    private(set) var availableVersion: String?

    @ObservationIgnored private let relay = UpdateRelay()
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    /// Whether a build carries the key that updates are verified with.
    static var isConfigured: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        return !(key ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: relay, userDriverDelegate: relay)
        relay.onAvailableVersion = { [weak self] version in
            Task { @MainActor in self?.availableVersion = version }
        }
        guard Self.isConfigured else { return }
        controller.startUpdater()
        let updater = controller.updater
        automaticallyChecks = updater.automaticallyChecksForUpdates
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckNow = canCheck }
        }
    }

    /// Tells Updates how to see whether an upload or a download is running. An update that is ready waits for them to
    /// end before DropUp restarts, so a restart never cuts a transfer in half.
    func watchTransfers(isBusy: @escaping () -> Bool) {
        relay.isBusy = isBusy
    }

    /// Looks for a new version now and tells the user what it found, like the Check Now button.
    func checkNow() {
        guard canCheckNow else { return }
        controller.updater.checkForUpdates()
    }

    /// Opens Sparkle's window for the version the daily check found, with its notes and the choice to install, skip or wait.
    func showAvailableUpdate() {
        controller.updater.checkForUpdates()
    }

    func setAutomaticallyChecks(_ value: Bool) {
        guard Self.isConfigured else { return }
        controller.updater.automaticallyChecksForUpdates = value
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
    }

    /// Lets a waiting update restart DropUp, if nothing is running any more. Call it when a transfer ends.
    func transfersMayHaveEnded() {
        relay.releaseRelaunchIfIdle()
    }
}

/// Tells Sparkle two things: hold an update back from restarting DropUp while a transfer runs, and don't open the window
/// for an update the daily check found, because the icon and the popover announce it.
private final class UpdateRelay: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    var isBusy: () -> Bool = { false }
    /// Called with the version waiting for the user, and with nil once it is no longer waiting.
    var onAvailableVersion: (String?) -> Void = { _ in }
    private var waiting: (() -> Void)?

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard isBusy() else { return false }
        waiting = installHandler
        return true
    }

    func releaseRelaunchIfIdle() {
        guard let waiting, !isBusy() else { return }
        self.waiting = nil
        waiting()
    }

    // MARK: Quiet reminders

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Not asked for Check Now, which always opens the window.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        onAvailableVersion(update.displayVersionString)
    }

    /// The window came to the front, or the user chose to install or skip.
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        onAvailableVersion(nil)
    }

    func standardUserDriverWillFinishUpdateSession() {
        onAvailableVersion(nil)
    }
}
