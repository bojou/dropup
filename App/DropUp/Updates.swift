import Foundation
import Observation
import Sparkle

/// Checks for new versions of DropUp with Sparkle and installs them when the user says so.
///
/// The feed and the public key that signed updates must match come from Info.plist (`SUFeedURL`, `SUPublicEDKey`).
/// A build without the key, such as one made on a developer's machine, never starts the updater, so there is nothing
/// to check against and the controls in Settings stay greyed out.
@MainActor
@Observable
final class Updates {
    /// Whether Sparkle is ready to check right now: not while a check or an install is already running.
    private(set) var canCheckNow = false
    /// Whether DropUp looks for new versions by itself (once a day, and not more often than that).
    private(set) var automaticallyChecks = false

    @ObservationIgnored private let relay = RelaunchRelay()
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    /// Whether a build carries the key that updates are verified with.
    static var isConfigured: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        return !(key ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: relay, userDriverDelegate: nil)
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

/// Holds an update back from restarting DropUp while a transfer runs.
private final class RelaunchRelay: NSObject, SPUUpdaterDelegate {
    var isBusy: () -> Bool = { false }
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
}
