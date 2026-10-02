import AppKit
import DropUpCore
import DropUpTransport
import Observation

enum DropPanelState {
    case hidden
    /// The panel is showing because a file is being dragged near the icon.
    case open
    /// The dragged file is over the panel.
    case hot
}

/// UI state for the menubar icon, drop panel, popover, onboarding and Settings.
/// Everything with logic in it lives in DropUpCore and is tested there.
@MainActor
@Observable
final class AppModel {
    private(set) var activity = UploadActivity()
    /// Ticks while uploads run and shortly after, so time-based text and the success flash update.
    private(set) var now = Date()
    private(set) var config: ServerConfig?
    private(set) var preferences: Preferences
    /// Bumped when a stored host key changes, so views showing it refresh.
    private(set) var hostKeyRevision = 0

    var panelState: DropPanelState = .hidden
    /// A file is being dragged over the menubar icon itself.
    var isDragOverIcon = false
    /// The popover is showing its folder page instead of the upload list.
    var isChoosingFolder = false
    @ObservationIgnored var isPopoverShown = false
    @ObservationIgnored var onNeedsOnboarding: (() -> Void)?

    @ObservationIgnored let settings: any SettingsStore
    @ObservationIgnored let credentials: any CredentialStore
    @ObservationIgnored let hostKeys: any HostKeyStore
    @ObservationIgnored let browser: ServerBrowser
    @ObservationIgnored private let connectors: any ConnectorFactory
    @ObservationIgnored private let queue: UploadQueue
    @ObservationIgnored private var sourceURLs: [UUID: URL] = [:]
    /// Files dropped into the Browse window go to the folder it showed; a retry sends them there again.
    @ObservationIgnored private var destinations: [UUID: String] = [:]
    /// Called with the remote path of each file that finishes uploading. The Browse window uses it to refresh.
    @ObservationIgnored var onUploadSucceeded: ((String) -> Void)?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(
        settings: any SettingsStore = UserDefaultsSettingsStore(),
        credentials: any CredentialStore = KeychainCredentialStore(),
        hostKeys: any HostKeyStore = UserDefaultsHostKeyStore()
    ) {
        self.settings = settings
        self.credentials = credentials
        self.hostKeys = hostKeys
        let connectors = StandardConnectorFactory(hostKeys: hostKeys)
        self.connectors = connectors
        self.browser = ServerBrowser(connectors: connectors)
        self.queue = UploadQueue(settings: settings, credentials: credentials, connectors: connectors)
        self.config = settings.loadServerConfig()
        self.preferences = settings.loadPreferences()

        Task { @MainActor [weak self, events = queue.events] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    // MARK: Derived state

    var menubarState: MenubarState { activity.menubarState(now: now) }
    var needsOnboarding: Bool { settings.needsOnboarding }

    /// `SFTP · /var/www/uploads`, or `My website · /var/www/uploads` with a display name; nil before setup.
    var destinationSummary: String? { config?.destinationSummary }

    /// `SFTP · files.example.com:/var/www/uploads`, or `My website · /var/www/uploads` with a display name.
    var serverSummary: String? { config?.serverSummary }

    // MARK: Uploading

    /// - Parameter directory: a folder on the server to upload into instead of the saved upload folder.
    func upload(_ fileURLs: [URL], toDirectory directory: String? = nil) {
        let files = fileURLs.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if needsOnboarding {
            onNeedsOnboarding?()
            return
        }
        Task {
            let ids = await queue.enqueue(files, toDirectory: directory)
            for (id, url) in zip(ids, files) {
                sourceURLs[id] = url
                destinations[id] = directory
            }
        }
    }

    func cancel(_ id: UUID) {
        Task { await queue.cancel(id) }
    }

    func cancelAll() {
        Task { await queue.cancelAll() }
    }

    func retry(_ id: UUID) {
        guard let url = sourceURLs[id] else { return }
        let directory = destinations[id]
        activity.remove(id)
        sourceURLs[id] = nil
        destinations[id] = nil
        upload([url], toDirectory: directory)
    }

    func clearFinished() {
        activity.clearFinished()
        forgetUnusedSources()
    }

    func popoverVisibilityChanged(_ shown: Bool) {
        isPopoverShown = shown
        // Each time the popover opens it starts on the upload list.
        isChoosingFolder = false
        if shown { activity.markFailuresSeen() }
    }

    // MARK: Browsing

    /// The model behind a Browse window for the saved server, or nil before setup. It starts in the upload folder.
    func makeBrowseModel() -> BrowseModel? {
        guard let config else { return nil }
        let session = BrowseSession(connectors: connectors, config: config, password: password(for: config))
        return BrowseModel(config: config, session: session)
    }

    // MARK: Settings

    func password(for config: ServerConfig) -> String {
        (try? credentials.password(for: config.credentialKey)) ?? ""
    }

    /// Saves both halves of the setup: the config to UserDefaults and the password to the Keychain.
    func save(_ config: ServerConfig, password: String) throws {
        if let previous = settings.loadServerConfig(), previous.credentialKey != config.credentialKey {
            try? credentials.removePassword(for: previous.credentialKey)
        }
        try credentials.setPassword(password, for: config.credentialKey)
        try settings.saveServerConfig(config)
        self.config = config
    }

    /// Points future uploads at another folder on the same server. Only the folder is saved; the password stays as it is.
    func changeRemoteDirectory(to directory: String) throws {
        guard let current = config else { return }
        let updated = current.withRemoteDirectory(directory)
        try settings.saveServerConfig(updated)
        config = updated
    }

    func updatePreferences(_ change: (inout Preferences) -> Void) {
        var updated = preferences
        change(&updated)
        preferences = updated
        try? settings.savePreferences(updated)
    }

    /// The remembered SFTP server identity for `config`, as a fingerprint, or nil if none is stored.
    func hostKeyFingerprint(for config: ServerConfig) -> String? {
        _ = hostKeyRevision
        guard config.transferProtocol == .sftp, let key = hostKeys.trustedKey(for: config.hostKeyID) else { return nil }
        return HostKeyFingerprint.sha256(openSSHKey: key)
    }

    func forgetHostKey(for config: ServerConfig) {
        hostKeys.forget(hostID: config.hostKeyID)
        hostKeyRevision += 1
    }

    // MARK: Events

    private func handle(_ event: UploadEvent) {
        let wasBusy = activity.isBusy
        now = Date()
        activity.apply(event, now: now)
        switch event {
        case .succeeded, .failed, .cancelled:
            activity.trim(toRecent: preferences.recentLimit)
            forgetUnusedSources()
            refreshClock(after: 2.1)
        default:
            break
        }
        if case .succeeded(_, let remotePath) = event {
            onUploadSucceeded?(remotePath)
        }
        if case .failed(_, .notConfigured) = event {
            onNeedsOnboarding?()
        }
        if isPopoverShown { activity.markFailuresSeen() }
        if activity.isBusy { startTicker() } else { stopTicker() }
        if wasBusy, !activity.isBusy { batchFinished() }
    }

    /// Plays the sound and posts the notification, if wanted and if the user isn't already looking at the popover.
    private func batchFinished() {
        guard let notice = ActivityText.completionNotice(activity) else { return }
        if preferences.playSound { NSSound(named: "Glass")?.play() }
        if preferences.notifyWhenDone, !isPopoverShown {
            Notifier.post(title: notice.title, body: notice.body)
        }
    }

    private func forgetUnusedSources() {
        let live = Set(activity.items.map(\.id))
        sourceURLs = sourceURLs.filter { live.contains($0.key) }
        destinations = destinations.filter { live.contains($0.key) }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.now = Date()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    /// One more tick after a delay, so the "done" check disappears on its own.
    private func refreshClock(after seconds: Double) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self?.now = Date()
        }
    }
}
