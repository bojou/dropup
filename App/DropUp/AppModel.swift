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
    /// Interrupted uploads whose half-sent file is being taken off the server, because the user removed them.
    private(set) var removing: Set<UUID> = []
    /// Why an interrupted upload could not be removed: its half-sent file is still on the server, so its row stays.
    private(set) var removalProblems: [UUID: String] = [:]

    var panelState: DropPanelState = .hidden
    /// A file is being dragged over the menubar icon itself.
    var isDragOverIcon = false
    @ObservationIgnored var isPopoverShown = false
    @ObservationIgnored var onNeedsOnboarding: (() -> Void)?

    @ObservationIgnored let settings: any SettingsStore
    @ObservationIgnored let credentials: any CredentialStore
    @ObservationIgnored let hostKeys: any HostKeyStore
    /// Where the Recent list is kept for the settings that keep it between launches.
    @ObservationIgnored private let recentStore: any RecentStore
    @ObservationIgnored let browser: ServerBrowser
    @ObservationIgnored private let connectors: any ConnectorFactory
    /// Downloads started from the Browse window.
    @ObservationIgnored let downloads: DownloadModel
    /// Fetches items dragged out of the Browse window once they are dropped on the Mac.
    @ObservationIgnored let dragExport: DragExport
    @ObservationIgnored private let queue: UploadQueue
    /// Looks for new versions of DropUp.
    @ObservationIgnored let updates = Updates()
    @ObservationIgnored private var sourceURLs: [UUID: URL] = [:]
    /// Files dropped into the Browse window go to the folder it showed; a retry sends them there again.
    @ObservationIgnored private var destinations: [UUID: String] = [:]
    /// The folder each listed upload went to, so its error message can still be cleaned after the upload folder changes.
    @ObservationIgnored private var uploadFolders: [UUID: String] = [:]
    /// Called with the remote path of each file that finishes uploading. The Browse window uses it to refresh.
    @ObservationIgnored var onUploadSucceeded: ((String) -> Void)?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// Sleeps until the next finished upload is due to leave the Recent list.
    @ObservationIgnored private var expiry: Task<Void, Never>?
    /// Saves the Recent list a moment from now, once for any number of changes in between.
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    init(
        settings: any SettingsStore = UserDefaultsSettingsStore(),
        credentials: any CredentialStore = KeychainCredentialStore(),
        hostKeys: any HostKeyStore = UserDefaultsHostKeyStore(),
        recentStore: any RecentStore = UserDefaultsRecentStore()
    ) {
        self.settings = settings
        self.credentials = credentials
        self.hostKeys = hostKeys
        self.recentStore = recentStore
        let connectors = StandardConnectorFactory(hostKeys: hostKeys)
        self.connectors = connectors
        self.downloads = DownloadModel(connectors: connectors)
        self.dragExport = DragExport(connectors: connectors)
        self.browser = ServerBrowser(connectors: connectors)
        self.queue = UploadQueue(settings: settings, credentials: credentials, connectors: connectors)
        self.config = settings.loadServerConfig()
        self.preferences = settings.loadPreferences()
        // What the settings keep: finished uploads only when the list survives a quit, and interrupted ones for as long
        // as the list is on at all. They are what is left of a transfer, and the way to carry it on.
        let keepsInterrupted = preferences.recentLimit > 0
        let keepsFinished = preferences.recentSurvivesQuit
        activity.restore(recentStore.load().filter { $0.isInterrupted ? keepsInterrupted : keepsFinished })
        for item in activity.items {
            if let point = item.resume { uploadFolders[item.id] = point.directory ?? point.config?.remoteDirectory }
        }
        pruneRecent()

        Task { @MainActor [weak self, events = queue.events] in
            for await event in events {
                self?.handle(event)
            }
        }
        downloads.onRunFinished = { [weak self] done, failed in
            self?.downloadsFinished(done: done, failed: failed)
            self?.updates.transfersMayHaveEnded()
        }
        updates.watchTransfers { [weak self] in
            guard let self else { return false }
            return activity.isBusy || downloads.isBusy
        }
    }

    // MARK: Derived state

    var menubarState: MenubarState { activity.menubarState(now: now) }
    var needsOnboarding: Bool { settings.needsOnboarding }

    /// `SFTP · /var/www/uploads`, or `My website · /var/www/uploads` with a display name; nil before setup.
    var destinationSummary: String? { config?.destinationSummary }

    /// `SFTP · files.example.com:/var/www/uploads`, or `My website · /var/www/uploads` with a display name.
    var serverSummary: String? { config?.serverSummary }

    /// The folders "Hide file names" keeps out of error messages: the upload folder, and every folder the listed
    /// uploads went to, including the ones a drop in Browse chose.
    var hiddenPaths: [String] {
        (config.map { [$0.remoteDirectory] } ?? []) + Array(Set(uploadFolders.values))
    }

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
            let folder = directory ?? config?.remoteDirectory
            let ids = await queue.enqueue(files, toDirectory: directory)
            for (id, url) in zip(ids, files) {
                sourceURLs[id] = url
                destinations[id] = directory
                uploadFolders[id] = folder
            }
        }
    }

    func cancel(_ id: UUID) {
        Task { await queue.cancel(id) }
    }

    func cancelAll() {
        Task { await queue.cancelAll() }
    }

    /// Whether a failed or interrupted upload can be sent again: while DropUp runs it knows where the file is, and
    /// one that was kept across a quit has that written down with it.
    func canRetry(_ id: UUID) -> Bool {
        guard !removing.contains(id) else { return false }
        return sourceURLs[id] != nil || row(id)?.resume != nil
    }

    /// `Resume` for an upload that has part of its file on the server, `Retry` for one that starts from the beginning.
    func retryTitle(_ id: UUID) -> String {
        guard let item = row(id) else { return "Retry" }
        if item.state == .interrupted { return "Resume" }
        return item.resume?.hasProgress == true ? "Resume" : "Retry"
    }

    func retry(_ id: UUID) {
        guard canRetry(id) else { return }
        removalProblems[id] = nil
        if let point = row(id)?.resume, point.hasProgress {
            // Part of it is on the server: carry on from there, as the same row.
            sourceURLs[id] = point.sourceURL
            destinations[id] = point.directory
            uploadFolders[id] = point.directory ?? point.config?.remoteDirectory
            Task { await queue.resume(id, from: point) }
            return
        }
        guard let url = sourceURLs[id] ?? row(id)?.resume?.sourceURL else { return }
        let directory = destinations[id] ?? row(id)?.resume?.directory
        activity.remove(id)
        sourceURLs[id] = nil
        destinations[id] = nil
        uploadFolders[id] = nil
        persistRecent()
        upload([url], toDirectory: directory)
    }

    /// Takes one finished upload out of the Recent list. An interrupted one is cancelled by this: the half-sent file
    /// goes off the server first, and if that can't be done the row stays, with the reason, so nothing is left behind
    /// unseen. `force` drops the row anyway.
    func dismiss(_ id: UUID, force: Bool = false) {
        if !force, let item = row(id), item.isResumable {
            if activity.canDismiss(item), let point = item.resume { removeInterrupted(id, point: point) }
            return
        }
        removalProblems[id] = nil
        if force, row(id)?.state.isFinished == true { activity.remove(id) } else { activity.dismiss(id) }
        forgetUnusedSources()
        persistRecent()
        scheduleRecentExpiry()
    }

    private func row(_ id: UUID) -> UploadActivity.Item? {
        activity.items.first { $0.id == id }
    }

    private func removeInterrupted(_ id: UUID, point: ResumePoint) {
        guard !removing.contains(id) else { return }
        removing.insert(id)
        removalProblems[id] = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let problem = await queue.discard(point)
            removing.remove(id)
            if let problem {
                removalProblems[id] = problem
            } else {
                activity.remove(id)
                forgetUnusedSources()
                persistRecent()
                scheduleRecentExpiry()
            }
        }
    }

    func clearFinished() {
        activity.clearFinished()
        forgetUnusedSources()
        persistRecent()
        scheduleRecentExpiry()
    }

    func popoverVisibilityChanged(_ shown: Bool) {
        isPopoverShown = shown
        if shown {
            activity.markFailuresSeen()
            // The timer can sleep through a Mac's sleep, so look again whenever someone is about to read the list.
            pruneRecent()
        }
    }

    // MARK: Browsing

    /// The model behind a Browse window for the saved server, or nil before setup. It starts in the upload folder.
    /// With `.chooseFolder` it is the window for picking another upload folder, which changes nothing on the server.
    func makeBrowseModel(purpose: BrowseModel.Purpose = .browse) -> BrowseModel? {
        guard let config else { return nil }
        let password = password(for: config)
        let session = BrowseSession(connectors: connectors, config: config, password: password)
        return BrowseModel(
            config: config,
            password: password,
            session: session,
            purpose: purpose,
            conflictPolicy: { [weak self] in self?.preferences.conflictPolicy ?? .keepBoth }
        )
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
        // A new count or clearing time applies to what is listed right away.
        pruneRecent()
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
            forgetUnusedSources()
            refreshClock(after: 2.1)
        case .resumable:
            // What it takes to carry the upload on is kept as it changes, so a crash leaves something to resume from.
            // A folder reports after every file, and a big drop reports for every file in it: saved together, a moment later.
            persistRecentSoon()
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
        if wasBusy, !activity.isBusy {
            batchFinished()
            updates.transfersMayHaveEnded()
        }
        // After the notice, which is worded from the batch's own items: the rules may remove them.
        switch event {
        case .succeeded, .failed, .cancelled: pruneRecent()
        default: break
        }
    }

    // MARK: Recent list

    /// Applies the Recent list settings to what is listed, then keeps what has to be kept and schedules the next removal.
    private func pruneRecent() {
        activity.applyRecentPolicy(preferences.recentPolicy, now: Date())
        forgetUnusedSources()
        // While uploads run, every one that finishes comes through here: a big drop is saved in one go, not once per file.
        if activity.isBusy { persistRecentSoon() } else { persistRecent() }
        scheduleRecentExpiry()
    }

    private func persistRecent() {
        pendingSave?.cancel()
        pendingSave = nil
        var kept: [StoredUpload] = []
        if preferences.recentSurvivesQuit { kept += activity.storedFinished }
        // With the list off there is nothing to resume from, so nothing is kept for it.
        if preferences.recentLimit > 0 { kept += activity.storedInterrupted() }
        recentStore.save(kept)
    }

    private func persistRecentSoon() {
        guard pendingSave == nil else { return }
        pendingSave = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.persistRecent()
        }
    }

    /// Writes the Recent list down now, for when DropUp is about to quit.
    func flushRecent() {
        persistRecent()
    }

    private func scheduleRecentExpiry() {
        expiry?.cancel()
        expiry = nil
        // While uploads run nothing is removed; the end of the batch prunes and schedules again.
        guard !activity.isBusy, let due = activity.nextRecentExpiry(lifetime: preferences.recentLifetime) else { return }
        let delay = max(due.timeIntervalSinceNow, 1)
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.pruneRecent()
        }
    }

    /// Plays the sound and posts the notification, if wanted and if the user isn't already looking at the popover.
    private func batchFinished() {
        guard let notice = ActivityText.completionNotice(activity, hidingNames: preferences.hideRecentNames, hiddenPaths: hiddenPaths) else { return }
        if preferences.playSound { Self.playFinishSound(failed: activity.batchHadFailure) }
        if preferences.notifyWhenDone, !isPopoverShown {
            Notifier.post(title: notice.title, body: notice.body)
        }
    }

    /// One sound when everything went through and another, lower one when something failed.
    private static func playFinishSound(failed: Bool) {
        NSSound(named: failed ? "Basso" : "Glass")?.play()
    }

    /// Plays the sound and posts the notification for finished downloads, unless the user is looking at the app already.
    private func downloadsFinished(done: [DownloadModel.Item], failed: [DownloadModel.Item]) {
        if preferences.playSound { Self.playFinishSound(failed: !failed.isEmpty) }
        guard preferences.notifyWhenDone, !NSApp.isActive else { return }
        let names = (done + failed).prefix(3).map(\.fileName).joined(separator: ", ")
        switch (done.count, failed.count) {
        case (1, 0):
            Notifier.post(title: "Downloaded", body: done[0].fileName)
        case (let count, 0):
            Notifier.post(title: "Downloaded \(count) files", body: names + (count > 3 ? "…" : ""))
        case (0, 1):
            if case .failed(let message) = failed[0].state {
                Notifier.post(title: "Download failed", body: "\(failed[0].fileName): \(message)")
            }
        case (0, let count):
            Notifier.post(title: "\(count) downloads failed", body: names)
        case (let ok, let bad):
            Notifier.post(title: "\(ok) downloaded, \(bad) failed", body: failed.prefix(3).map(\.fileName).joined(separator: ", "))
        }
    }

    private func forgetUnusedSources() {
        let live = Set(activity.items.map(\.id))
        sourceURLs = sourceURLs.filter { live.contains($0.key) }
        destinations = destinations.filter { live.contains($0.key) }
        uploadFolders = uploadFolders.filter { live.contains($0.key) }
        removalProblems = removalProblems.filter { live.contains($0.key) }
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
