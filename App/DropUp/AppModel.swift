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

    var panelState: DropPanelState = .hidden
    /// A file is being dragged over the menubar icon itself.
    var isDragOverIcon = false
    @ObservationIgnored var isPopoverShown = false
    @ObservationIgnored var onNeedsOnboarding: (() -> Void)?

    @ObservationIgnored let settings: any SettingsStore
    @ObservationIgnored let credentials: any CredentialStore
    @ObservationIgnored let hostKeys: any HostKeyStore
    @ObservationIgnored let browser: ServerBrowser
    @ObservationIgnored private let queue: UploadQueue
    @ObservationIgnored private var sourceURLs: [UUID: URL] = [:]
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
        self.browser = ServerBrowser(connectors: connectors)
        self.queue = UploadQueue(settings: settings, credentials: credentials, connectors: connectors)
        self.config = settings.loadServerConfig()

        Task { @MainActor [weak self, events = queue.events] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    // MARK: Derived state

    var menubarState: MenubarState { activity.menubarState(now: now) }
    var needsOnboarding: Bool { settings.needsOnboarding }

    /// `SFTP · /var/www/uploads`, or nil before setup.
    var destinationSummary: String? {
        guard let config else { return nil }
        return "\(config.transferProtocol.rawValue.uppercased()) · \(config.remoteDirectory)"
    }

    /// `SFTP · files.example.com:/var/www/uploads`
    var serverSummary: String? {
        guard let config else { return nil }
        return "\(config.transferProtocol.rawValue.uppercased()) · \(config.host):\(config.remoteDirectory)"
    }

    // MARK: Uploading

    func upload(_ fileURLs: [URL]) {
        let files = fileURLs.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if needsOnboarding {
            onNeedsOnboarding?()
            return
        }
        Task {
            let ids = await queue.enqueue(files)
            for (id, url) in zip(ids, files) {
                sourceURLs[id] = url
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
        activity.remove(id)
        sourceURLs[id] = nil
        upload([url])
    }

    func clearFinished() {
        activity.clearFinished()
        forgetUnusedSources()
    }

    func popoverVisibilityChanged(_ shown: Bool) {
        isPopoverShown = shown
        if shown { activity.markFailuresSeen() }
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

    // MARK: Events

    private func handle(_ event: UploadEvent) {
        now = Date()
        activity.apply(event, now: now)
        switch event {
        case .succeeded, .failed, .cancelled:
            activity.trim(toRecent: settings.loadPreferences().recentLimit)
            forgetUnusedSources()
            refreshClock(after: 2.1)
        default:
            break
        }
        if case .failed(_, .notConfigured) = event {
            onNeedsOnboarding?()
        }
        if isPopoverShown { activity.markFailuresSeen() }
        if activity.isBusy { startTicker() } else { stopTicker() }
    }

    private func forgetUnusedSources() {
        let live = Set(activity.items.map(\.id))
        sourceURLs = sourceURLs.filter { live.contains($0.key) }
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
