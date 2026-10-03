import Foundation

public enum UploadFailure: Error, Equatable, Sendable {
    /// No valid server config saved yet; the app should open onboarding.
    case notConfigured
    /// The Keychain has no password for the configured server.
    case missingPassword
    /// The dropped item is missing or unreadable.
    case unsupportedItem
    /// The transfer failed; the message is suitable for display.
    case transfer(String)
    /// The connection was lost and could not be picked up again in time. Whatever was sent is still on the server,
    /// and the upload can carry on from there.
    case connectionLost(String)
}

extension UploadFailure {
    public var displayMessage: String {
        switch self {
        case .notConfigured: "Set up your server first."
        case .missingPassword: "No password saved for this server. Add it in Settings."
        case .unsupportedItem: "DropUp can't read this item."
        case .transfer(let message), .connectionLost(let message): message
        }
    }

    /// Whether the upload was stopped by the connection, and so can be resumed, rather than refused.
    public var isInterruption: Bool {
        if case .connectionLost = self { true } else { false }
    }
}

public enum UploadEvent: Sendable, Equatable {
    case queued(id: UUID, fileName: String, totalBytes: Int64)
    case started(id: UUID)
    case progress(id: UUID, UploadProgress)
    /// `remotePath` is where the file actually landed, which differs from the dropped name
    /// when `ConflictPolicy.keepBoth` picked a numbered name.
    case succeeded(id: UUID, remotePath: String)
    case failed(id: UUID, UploadFailure)
    case cancelled(id: UUID)
    /// What it takes to carry the upload on if it is interrupted. Sent when the upload is queued and again as it
    /// gets somewhere: once the server holds the file, and for a folder after each file.
    case resumable(id: UUID, ResumePoint)
    /// The connection is down. DropUp is trying again by itself, and carries on from what the server has.
    case waitingForConnection(id: UUID)
    /// The upload started over from the beginning instead of carrying on, for the reason given.
    case restarted(id: UUID, reason: String)
    /// The user paused the upload. Whatever was sent stays on the server, and the upload can be resumed later.
    case paused(id: UUID)
}

/// Uploads dropped files and folders one at a time and reports what happens on `events`.
///
/// A folder is one item in the queue: it is sent with everything inside it, as the same name on the server (numbered
/// when that name is taken, unless the setting is to replace). Its name in the events ends with `/`.
/// Symbolic links inside it are left out. A folder that is cancelled or fails halfway keeps the files already sent.
/// A folder is read (to learn what is in it and how big it is) on its own, off the queue, so a big one never holds up
/// a cancel or the files behind it. Its subfolders are made on the server as the files going into them come up.
///
/// An upload that is interrupted (the connection is lost for good, or DropUp quits or crashes) leaves what it sent on
/// the server, and can be carried on later with `resume(_:from:)` from the `ResumePoint` the queue reported while it ran:
/// the file goes on from the size the server holds, the same file under the same name, never a numbered copy. A lost
/// connection is first tried again by itself for a couple of minutes. Only a cancel by the user takes the half-sent
/// file away.
///
/// The queue reads settings and credentials at the moment each upload starts,
/// so edits made in Settings apply to the next file without restarting anything.
/// One server session is reused for consecutive files and closed when the queue runs dry.
public actor UploadQueue {
    public nonisolated let events: AsyncStream<UploadEvent>
    private nonisolated let continuation: AsyncStream<UploadEvent>.Continuation

    private let settings: any SettingsStore
    private let credentials: any CredentialStore
    private let connectors: any ConnectorFactory
    private let fileManager: FileManager
    private let progressInterval: TimeInterval
    private let cleanupTimeout: Double
    private let reconnect: ReconnectPolicy
    private let cancelGrace: TimeInterval

    private struct Job {
        let id: UUID
        let fileURL: URL
        /// Where to put the file instead of the saved upload folder.
        let remoteDirectory: String?
        /// For a folder: reading what is inside it, started when it was dropped and running while it waits its turn.
        let scan: Task<LocalTree, any Error>?
        /// What an interrupted upload had got to, when this job carries it on.
        let resume: ResumePoint?
    }

    private struct OpenSession {
        let config: ServerConfig
        let password: String
        let session: any ServerSession
    }

    private var pending: [Job] = []
    private var worker: Task<Void, Never>?
    private var active: (id: UUID, task: Task<String, any Error>)?
    /// What the user asked of the upload that is running, until it has stopped.
    private enum Stop { case cancel, pause }
    private var stops: [UUID: Stop] = [:]
    private var openSession: OpenSession?

    /// - Parameters:
    ///   - progressInterval: minimum seconds between `.progress` events per file.
    ///     The final progress event of a file is always sent.
    ///   - cleanupTimeout: seconds to spend deleting the half-sent file after a cancel before giving up.
    ///   - reconnect: how long and how often an upload tries again when the connection is lost.
    ///   - cancelGrace: seconds a transfer gets to notice a cancel before its connection is closed under it.
    public init(
        settings: any SettingsStore,
        credentials: any CredentialStore,
        connectors: any ConnectorFactory,
        fileManager: FileManager = .default,
        progressInterval: TimeInterval = 0.1,
        cleanupTimeout: Double = 15,
        reconnect: ReconnectPolicy = .standard,
        cancelGrace: TimeInterval = 1.5
    ) {
        self.settings = settings
        self.credentials = credentials
        self.connectors = connectors
        self.fileManager = fileManager
        self.progressInterval = progressInterval
        self.cleanupTimeout = cleanupTimeout
        self.reconnect = reconnect
        self.cancelGrace = cancelGrace
        let (stream, continuation) = AsyncStream.makeStream(of: UploadEvent.self)
        self.events = stream
        self.continuation = continuation
    }

    /// Adds files to the end of the queue and returns their ids, in order.
    /// - Parameter remoteDirectory: a folder on the same server to upload into instead of the saved upload folder.
    @discardableResult
    public func enqueue(_ fileURLs: [URL], toDirectory remoteDirectory: String? = nil) -> [UUID] {
        var ids: [UUID] = []
        for url in fileURLs {
            let id = UUID()
            ids.append(id)
            let name = url.lastPathComponent
            var scan: Task<LocalTree, any Error>?
            let folder = isFolder(url)
            let size = folder ? 0 : size(of: url)
            if folder {
                // The row shows up at once. Its size follows when the folder has been read, which can take a while.
                continuation.yield(.queued(id: id, fileName: name + "/", totalBytes: 0))
                scan = Self.readFolder(url, id: id, continuation: continuation)
            } else {
                continuation.yield(.queued(id: id, fileName: name, totalBytes: size))
            }
            // Even before it starts, a waiting upload is something to pick up again if DropUp quits.
            continuation.yield(.resumable(id: id, ResumePoint(sourcePath: url.path, isFolder: folder, directory: remoteDirectory, totalBytes: size)))
            pending.append(Job(id: id, fileURL: url, remoteDirectory: remoteDirectory, scan: scan, resume: nil))
        }
        if worker == nil, !pending.isEmpty {
            worker = Task { await self.drain() }
        }
        return ids
    }

    /// Carries on an upload that was interrupted, under the id its row already has. It waits its turn like a new one.
    /// The file goes on from what the server holds, as the same file, unless that can't be trusted any more: the file
    /// on this Mac changed, or the server lost what it had, or can't carry on. Then it starts over and says why.
    public func resume(_ id: UUID, from point: ResumePoint) {
        // A second press on the same button, before the row has changed, must not start the upload twice.
        guard active?.id != id, !pending.contains(where: { $0.id == id }) else { return }
        let url = point.sourceURL
        continuation.yield(.queued(id: id, fileName: point.fileName, totalBytes: point.totalBytes))
        continuation.yield(.resumable(id: id, point))
        let scan = point.isFolder ? Self.readFolder(url, id: id, continuation: continuation) : nil
        pending.append(Job(id: id, fileURL: url, remoteDirectory: point.directory, scan: scan, resume: point))
        if worker == nil {
            worker = Task { await self.drain() }
        }
    }

    /// Reads a folder away from the queue, and reports its size once it is known.
    private static func readFolder(_ url: URL, id: UUID, continuation: AsyncStream<UploadEvent>.Continuation) -> Task<LocalTree, any Error> {
        Task.detached(priority: .userInitiated) {
            let tree = try LocalTree.scan(url)
            if !Task.isCancelled {
                continuation.yield(.progress(id: id, UploadProgress(bytesSent: 0, totalBytes: tree.totalBytes)))
            }
            return tree
        }
    }

    /// Cancels a waiting or running upload, and takes the half-sent file off the server. Does nothing for finished or
    /// unknown ids.
    public func cancel(_ id: UUID) {
        if let index = pending.firstIndex(where: { $0.id == id }) {
            let job = pending.remove(at: index)
            job.scan?.cancel()
            continuation.yield(.cancelled(id: id))
            discardLater(job.resume)
        } else {
            stopActive(id, .cancel)
        }
    }

    /// Pauses a waiting or running upload: sending stops, what the server holds stays, and the next upload in the queue
    /// starts. It carries on later with `resume(_:from:)`, from the `ResumePoint` the queue reported. A cancel that
    /// comes after a pause still wins and takes the half-sent file away. Does nothing for finished or unknown ids.
    public func pause(_ id: UUID) {
        if let index = pending.firstIndex(where: { $0.id == id }) {
            let job = pending.remove(at: index)
            job.scan?.cancel()
            continuation.yield(.paused(id: id))
        } else {
            stopActive(id, .pause)
        }
    }

    private func stopActive(_ id: UUID, _ how: Stop) {
        guard let active, active.id == id else { return }
        // Cancel is the stronger of the two: it is the one that deletes.
        if stops[id] != .cancel { stops[id] = how }
        active.task.cancel()
        // A transfer on a dead connection can't see a cancel. Closing the connection under it makes it let go.
        let grace = cancelGrace
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            await self?.closeSessionIfStillRunning(id)
        }
    }

    public func cancelAll() {
        let waiting = pending
        pending.removeAll()
        for job in waiting {
            job.scan?.cancel()
            continuation.yield(.cancelled(id: job.id))
            discardLater(job.resume)
        }
        if let active { cancel(active.id) }
    }

    /// Takes the half-sent file of an interrupted upload off the server, on a connection of its own, so it can run
    /// while other uploads do. For a folder that is only the file it was in the middle of: the files it finished and
    /// the folders stay. Returns nil when nothing is left, or why it couldn't be done.
    public func discard(_ point: ResumePoint) async -> String? {
        guard let path = point.partialPath, let config = point.config else { return nil }
        guard let password = try? credentials.password(for: config.credentialKey) else {
            return UploadFailure.missingPassword.displayMessage
        }
        let connectors = self.connectors
        do {
            try await withTimeout(seconds: cleanupTimeout) {
                let session = try await connectors.connector(for: config.transferProtocol).connect(to: config, password: password)
                do {
                    let size: Int64?
                    do { size = try await session.fileSize(atPath: path) } catch UploaderError.cannotResume { size = 0 }
                    if size != nil { try await session.deleteFile(atPath: path) }
                } catch {
                    await session.close()
                    throw error
                }
                await session.close()
            }
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    /// `discard`, for a waiting upload that is cancelled: nobody waits for the answer.
    private func discardLater(_ point: ResumePoint?) {
        guard let point, point.partialPath != nil else { return }
        Task { _ = await self.discard(point) }
    }

    private func closeSessionIfStillRunning(_ id: UUID) async {
        guard active?.id == id else { return }
        await closeSession()
    }

    /// Suspends until every queued file has finished, successfully or not.
    public func waitUntilIdle() async {
        while let worker {
            await worker.value
        }
    }

    /// Ends the `events` stream. Call when the app quits, or in tests to stop collecting.
    public func finish() {
        continuation.finish()
    }

    // MARK: Processing

    private func drain() async {
        while !pending.isEmpty {
            let job = pending.removeFirst()
            await process(job)
        }
        await closeSession()
        worker = nil
    }

    private enum Ending {
        case succeeded(String)
        case cancelled
        case paused
        case failed(UploadFailure)
    }

    private func process(_ job: Job) async {
        continuation.yield(.started(id: job.id))
        let written = WrittenFile()
        // An interrupted upload has a file on the server that is its own. A cancel has to know, even before it connects.
        if let point = job.resume, let path = point.partialPath, let config = point.config,
           let password = try? credentials.password(for: config.credentialKey) {
            written.willUpload(to: path, on: config, password: password, alreadyThere: true)
        }
        let run = UploadRun(point: job.resume)
        let ending = await attempts(job, written: written, run: run)
        // Nothing is left to read for this job, whatever way it ended (a no-op once the reading is done).
        job.scan?.cancel()

        switch ending {
        case .cancelled:
            // The session is mid-transfer and in an unknown state.
            await closeSession()
            continuation.yield(.cancelled(id: job.id))
            if let leftover = written.leftover {
                await delete(leftover)
            }
        case .paused:
            await closeSession()
            // Where it got to, for the row to carry on from. The half-sent file stays where it is.
            if let point = run.point { continuation.yield(.resumable(id: job.id, point)) }
            continuation.yield(.paused(id: job.id))
        case .succeeded(let remotePath):
            continuation.yield(.succeeded(id: job.id, remotePath: remotePath))
        case .failed(let failure):
            continuation.yield(.failed(id: job.id, failure))
        }
    }

    /// Runs the transfer, and runs it again from what the server holds for as long as a lost connection looks worth
    /// waiting for. A cancel by the user ends it at once, in whichever of those it lands.
    private func attempts(_ job: Job, written: WrittenFile, run: UploadRun) async -> Ending {
        var delays = reconnect.delays[...]
        while true {
            let task = Task { try await self.transfer(job, written: written, run: run) }
            active = (job.id, task)
            let watchdog = watch(job.id, run: run, task: task)
            let result = await task.result
            watchdog.cancel()
            active = nil

            let stop = stops.removeValue(forKey: job.id)
            // An upload that got all the way through before the pause was noticed is simply done.
            if case .success(let remotePath) = result, stop == .pause { return .succeeded(remotePath) }
            if let stop { return stop == .cancel ? .cancelled : .paused }
            let error: any Error
            switch result {
            case .success(let remotePath):
                return .succeeded(remotePath)
            case .failure(let failure as UploadFailure):
                return .failed(failure)
            case .failure(let thrown):
                error = thrown
            }
            await closeSession()
            let stalled = run.wasStalled
            let lost = stalled || Self.isConnectionLoss(error)
            let message = stalled ? UploaderError.timedOut.errorDescription ?? "" : Self.message(for: error)
            // An upload that never got through fails as it always did: a server that can't be reached is most likely a
            // mistake in the settings, and waiting would only hide it. One the user asked to carry on stays resumable.
            guard lost, run.hadContact else {
                return .failed(lost && job.resume != nil ? .connectionLost(message) : .transfer(message))
            }
            guard let wait = nextWait(&delays, run: run) else { return .failed(.connectionLost(message)) }
            continuation.yield(.waitingForConnection(id: job.id))
            run.clearStalled()
            if let stop = await sleep(job.id, seconds: wait) { return stop == .cancel ? .cancelled : .paused }
        }
    }

    /// The seconds to wait before the next attempt after a lost connection, or nil when it is time to give up: the
    /// waits are used up, or the next one would end more than `giveUpAfter` seconds after the last sign of life.
    private func nextWait(_ delays: inout ArraySlice<TimeInterval>, run: UploadRun) -> TimeInterval? {
        // Bytes moved since the last time the connection was lost: this is a new outage, with all its tries again.
        if run.takeProgressed() { delays = reconnect.delays[...] }
        guard let delay = delays.first, run.idle + delay <= reconnect.giveUpAfter else { return nil }
        delays.removeFirst()
        return delay
    }

    /// Waits, in a way a cancel or a pause can end. Returns what the user asked for meanwhile, if anything.
    private func sleep(_ id: UUID, seconds: TimeInterval) async -> Stop? {
        let sleeper = Task<String, any Error> {
            try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
            return ""
        }
        active = (id, sleeper)
        _ = await sleeper.result
        active = nil
        return stops.removeValue(forKey: id)
    }

    /// One timer for the running transfer, with no polling: it sleeps until the moment a stall could first matter and looks
    /// again then. Without a sign of life for `noticeAfter` seconds the row says it is waiting for the connection;
    /// after `giveUpAfter` the transfer is stopped, and closed under if it doesn't let go.
    private func watch(_ id: UUID, run: UploadRun, task: Task<String, any Error>) -> Task<Void, Never> {
        let policy = reconnect
        let grace = cancelGrace
        let continuation = self.continuation
        return Task { [weak self] in
            var noticed = false
            while !Task.isCancelled {
                let idle = run.idle
                if idle >= policy.giveUpAfter {
                    // A busy machine can wake this up late, past the notice: the row still says why before it fails.
                    if !noticed { continuation.yield(.waitingForConnection(id: id)) }
                    run.markStalled()
                    task.cancel()
                    try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
                    if !Task.isCancelled { await self?.closeSessionIfStillRunning(id) }
                    return
                }
                let wait: TimeInterval
                if idle >= policy.noticeAfter {
                    if !noticed {
                        noticed = true
                        continuation.yield(.waitingForConnection(id: id))
                    }
                    wait = policy.giveUpAfter - idle
                } else {
                    noticed = false
                    wait = policy.noticeAfter - idle
                }
                try? await Task.sleep(nanoseconds: UInt64(max(wait, 0.005) * 1_000_000_000))
            }
        }
    }

    /// Whether `error` says the connection broke, as opposed to the server refusing something or the file being unreadable.
    static func isConnectionLoss(_ error: any Error) -> Bool {
        guard let error = error as? UploaderError else { return false }
        switch error {
        case .connectionFailed, .timedOut:
            return true
        case .serverRejected(let code, _):
            // 421 the server is closing the connection, 425 and 426 the data connection could not be had or broke.
            return code == 421 || code == 425 || code == 426
        case .authenticationFailed, .hostKeyChanged, .invalidRemotePath, .cannotResume:
            return false
        }
    }

    /// Where a file (or folder) stands on the server: not there, there with this many bytes, or not known.
    private enum OnServer {
        case missing
        case size(Int64)
        case unknown
    }

    private static func look(at path: String, session: any ServerSession) async throws -> OnServer {
        do {
            if let size = try await session.fileSize(atPath: path) { return .size(size) }
            return .missing
        } catch UploaderError.cannotResume {
            return .unknown
        }
    }

    private func transfer(_ job: Job, written: WrittenFile, run: UploadRun) async throws -> String {
        // An upload carried on from an earlier attempt or launch goes to the server and the name it used before.
        let earlier = run.point ?? job.resume
        guard let config = earlier?.config ?? settings.loadServerConfig(), config.isValid else {
            throw UploadFailure.notConfigured
        }
        guard fileManager.fileExists(atPath: job.fileURL.path),
              fileManager.isReadableFile(atPath: job.fileURL.path)
        else {
            if let earlier, earlier.hasProgress {
                throw UploadFailure.transfer(earlier.isFolder
                    ? "The folder is no longer where it was, so it can't carry on."
                    : "The file is no longer where it was, so it can't carry on.")
            }
            throw UploadFailure.unsupportedItem
        }
        guard let password = try? credentials.password(for: config.credentialKey) else {
            throw UploadFailure.missingPassword
        }

        let session = try await session(for: config, password: password)
        run.markContact()
        // Only the target folder changes. The session is still matched on the saved config, so it is reused.
        let target = job.remoteDirectory.map(config.withRemoteDirectory) ?? config
        if isFolder(job.fileURL) {
            return try await transferFolder(job, earlier: earlier, to: target, config: config, password: password, session: session, written: written, run: run)
        }

        let total = size(of: job.fileURL)
        let modified = modificationDate(of: job.fileURL)
        let remotePath: String
        var offset: Int64 = 0
        var holdsPartial = false
        if let earlier, earlier.created, !earlier.isFolder, let held = earlier.remotePath {
            // Carrying on: the same file, never a numbered copy, from what the server holds.
            remotePath = held
            var restart: String?
            if !earlier.matches(size: total, modified: modified) {
                restart = "The file changed, so it starts over."
                holdsPartial = true
            } else {
                switch try await Self.look(at: held, session: session) {
                case .missing:
                    restart = "The partly sent file was gone, so it starts over."
                case .unknown:
                    restart = "The server can't say how much it has, so it starts over."
                    holdsPartial = true
                case .size(let size) where size == total:
                    return held // it was all there already
                case .size(let size) where size < total:
                    offset = size
                    holdsPartial = true
                case .size:
                    restart = "The file on the server was bigger than this one, so it starts over."
                    holdsPartial = true
                }
            }
            if let restart { continuation.yield(.restarted(id: job.id, reason: restart)) }
        } else {
            remotePath = try await RemoteFileName.resolve(
                fileName: job.fileURL.lastPathComponent,
                in: target,
                policy: settings.loadPreferences().conflictPolicy,
                session: session
            )
        }
        run.touch()

        let throttle = ProgressThrottle(interval: progressInterval, total: total)
        let continuation = self.continuation
        let id = job.id
        written.willUpload(to: remotePath, on: config, password: password, alreadyThere: holdsPartial)
        note(ResumePoint(
            sourcePath: job.fileURL.path, isFolder: false, directory: job.remoteDirectory, config: config,
            remotePath: remotePath, totalBytes: total, sourceModified: modified, created: holdsPartial
        ), id: id, run: run)
        let report: @Sendable (Int64) -> Void = { sent in
            written.serverHasFile()
            run.report(sent)
            if let point = run.markCreated() { continuation.yield(.resumable(id: id, point)) }
            if sent > 0, throttle.shouldReport(sent) {
                continuation.yield(.progress(id: id, UploadProgress(bytesSent: sent, totalBytes: total)))
            }
        }
        try await Self.send(job.fileURL, to: remotePath, from: offset, total: total, session: session, id: id, continuation: continuation, run: run, report: report)
        return remotePath
    }

    /// Sends a file from `offset`, and checks that a file carried on has the right size afterwards. A server that can't
    /// carry on from the middle (or does it wrong, which the size shows) gets the whole file again over the same name.
    private static func send(
        _ fileURL: URL,
        to remotePath: String,
        from offset: Int64,
        total: Int64,
        session: any ServerSession,
        id: UUID,
        continuation: AsyncStream<UploadEvent>.Continuation,
        run: UploadRun,
        report: @escaping @Sendable (Int64) -> Void
    ) async throws {
        do {
            run.beginTransfer()
            try await session.upload(fileURL: fileURL, to: remotePath, startingAt: offset, progress: report)
            if offset > 0, let after = try await session.fileSize(atPath: remotePath), after != total {
                throw UploaderError.cannotResume
            }
        } catch UploaderError.cannotResume where offset > 0 {
            continuation.yield(.restarted(id: id, reason: "The server can't carry on a partly sent file, so it starts over."))
            run.beginTransfer()
            try await session.upload(fileURL: fileURL, to: remotePath, startingAt: 0, progress: report)
        }
    }

    /// Sends a folder and everything in it. Returns the folder's path on the server.
    private func transferFolder(
        _ job: Job,
        earlier: ResumePoint?,
        to target: ServerConfig,
        config: ServerConfig,
        password: String,
        session: any ServerSession,
        written: WrittenFile,
        run: UploadRun
    ) async throws -> String {
        let tree: LocalTree
        do {
            // Normally finished long ago, since reading started when the folder was dropped. A cancel stops the reading too.
            let scan = job.scan ?? Self.readFolder(job.fileURL, id: job.id, continuation: continuation)
            tree = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
        } catch let error as FileOperationError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UploadFailure.unsupportedItem
        }
        run.touch()

        let fingerprint = tree.fingerprint
        let total = tree.totalBytes
        let previous = earlier.flatMap { $0.isFolder && $0.remotePath != nil ? $0 : nil }
        let root: String
        var index = 0
        var firstOffset: Int64 = 0
        if let previous, let held = previous.remotePath {
            // Carrying on: the same folder, with the files that are done left alone.
            root = held
            try await Self.ensureFolder(root, session: session)
            if previous.fingerprint == fingerprint {
                index = min(previous.finishedFiles, tree.files.count)
                if index > 0 {
                    // The files the note calls done have to still be there: a folder the user cleared out on the server
                    // in the meantime starts over, instead of being finished without them.
                    let last = tree.files[index - 1]
                    run.touch()
                    switch try await Self.look(at: Self.join(root, last.relativePath), session: session) {
                    case .missing:
                        index = 0
                        continuation.yield(.restarted(id: job.id, reason: "Files already sent are gone from the server, so the folder starts over."))
                    case .size(let size) where size != last.size:
                        index = 0
                        continuation.yield(.restarted(id: job.id, reason: "Files already sent have changed on the server, so the folder starts over."))
                    default:
                        break
                    }
                }
                // Notes are made now and then, not after every file, so a few more may be done than the last one says.
                // A file is done when the server holds as many bytes of it as it has; the one after is carried on from
                // what it holds, if that is the file the last note was in the middle of.
                look: while index < tree.files.count {
                    let file = tree.files[index]
                    run.touch()
                    switch try await Self.look(at: Self.join(root, file.relativePath), session: session) {
                    case .size(let size) where size == file.size:
                        index += 1
                        continue look
                    case .size(let size) where size < file.size && previous.created && previous.currentFile == file.relativePath:
                        firstOffset = size
                    default:
                        break
                    }
                    break
                }
            } else {
                continuation.yield(.restarted(id: job.id, reason: "The folder changed, so it starts over."))
            }
        } else {
            let parent = RemotePath.normalizedDirectory(target.remoteDirectory)
            let name = job.fileURL.lastPathComponent
            var finalName = name
            if settings.loadPreferences().conflictPolicy == .keepBoth {
                let taken = Set(try await session.listEntries(atPath: parent).map(\.name))
                var attempt = 0
                while taken.contains(finalName), attempt < 1000 {
                    attempt += 1
                    finalName = RemoteFileName.numberedFolder(name, index: attempt)
                }
            }
            root = Self.join(parent, finalName)
            try await Self.ensureFolder(root, session: session)
        }
        run.touch()

        // Folders are made as the files going into them come up, not all in front: a folder with thousands of
        // subfolders starts sending, and can be cancelled, right away. Each one is made once, outermost first.
        // The ones the finished files sit in are there already.
        var made: Set<String> = []
        for file in tree.files[..<index] {
            made.formUnion(LocalTree.folders(containing: file.relativePath))
        }

        let throttle = ProgressThrottle(interval: progressInterval, total: total)
        let continuation = self.continuation
        let id = job.id
        var sentBefore = tree.files[..<index].reduce(Int64(0)) { $0 + $1.size }
        var point = ResumePoint(
            sourcePath: job.fileURL.path, isFolder: true, directory: job.remoteDirectory, config: config,
            remotePath: root, totalBytes: total, finishedFiles: index, fingerprint: fingerprint
        )
        note(point, id: id, run: run)
        var lastNote = Uptime.now
        let carriedOnAt = index
        while index < tree.files.count {
            let file = tree.files[index]
            try Task.checkCancellation()
            run.touch()
            for folder in LocalTree.folders(containing: file.relativePath) {
                try await Self.make(folder, under: root, made: &made, session: session)
            }
            let remotePath = Self.join(root, file.relativePath)
            let offset = index == carriedOnAt ? firstOffset : 0
            written.willUpload(to: remotePath, on: config, password: password, alreadyThere: offset > 0)
            // What a note says is the file being sent, so a file is noted if it is big enough to be worth carrying on
            // or it has been a while; a stretch of small files in between is looked over when carrying on.
            let now = Uptime.now
            let noted = file.size >= Self.noteFilesFrom || now - lastNote >= 1
            if noted {
                point.finishedFiles = index
                point.currentFile = file.relativePath
                point.created = offset > 0
                note(point, id: id, run: run)
                lastNote = now
            }
            let base = sentBefore
            let report: @Sendable (Int64) -> Void = { sent in
                written.serverHasFile()
                run.report(sent)
                if noted, let updated = run.markCreated() { continuation.yield(.resumable(id: id, updated)) }
                let overall = base + sent
                if sent > 0, throttle.shouldReport(overall) {
                    continuation.yield(.progress(id: id, UploadProgress(bytesSent: overall, totalBytes: total)))
                }
            }
            try await Self.wrapped(file.relativePath) {
                try await Self.send(file.url, to: remotePath, from: offset, total: file.size, session: session, id: id, continuation: continuation, run: run, report: report)
            }
            sentBefore += file.size
            index += 1
            if noted {
                point.finishedFiles = index
                point.currentFile = nil
                point.created = false
                note(point, id: id, run: run)
            }
        }
        // Folders with no files in them (and nothing but such folders inside) are still part of the folder.
        for folder in tree.directories {
            try await Self.make(folder, under: root, made: &made, session: session)
        }
        return root
    }

    /// Files from this size up are noted when they start, whatever the time since the last note: they take long enough
    /// that being able to carry them on matters, and then the note names the file exactly.
    private static let noteFilesFrom: Int64 = 1_048_576

    /// Reports what it takes to carry the upload on from here, and keeps it for a later attempt.
    private func note(_ point: ResumePoint, id: UUID, run: UploadRun) {
        run.setPoint(point)
        continuation.yield(.resumable(id: id, point))
    }

    /// Makes a folder inside the uploaded one, unless that has been done already.
    private static func make(_ folder: String, under root: String, made: inout Set<String>, session: any ServerSession) async throws {
        guard made.insert(folder).inserted else { return }
        // A real server answers each command in turn, however many are waiting: look for a cancel before every one.
        try Task.checkCancellation()
        try await wrapped(folder) { try await ensureFolder(join(root, folder), session: session) }
    }

    private static func join(_ folder: String, _ name: String) -> String {
        folder == "/" ? "/" + name : folder + "/" + name
    }

    /// Makes the folder, accepting one that is already there (as when merging into an existing folder).
    private static func ensureFolder(_ path: String, session: any ServerSession) async throws {
        do {
            try await session.makeDirectory(atPath: path)
        } catch let error as UploaderError {
            guard case .serverRejected = error, (try? await session.listEntries(atPath: path)) != nil else { throw error }
        }
    }

    /// Names where in the folder a refusal happened, so the message says which file.
    private static func wrapped<T>(_ path: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as UploaderError where !isConnectionLoss(error) {
            throw FolderTransferError(path: path, reason: error.errorDescription ?? "\(error)")
        }
    }

    private func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Reuses the open session when the server and password are unchanged.
    private func session(for config: ServerConfig, password: String) async throws -> any ServerSession {
        if let openSession, openSession.config == config, openSession.password == password {
            return openSession.session
        }
        await closeSession()
        let session = try await connectors.connector(for: config.transferProtocol).connect(to: config, password: password)
        openSession = OpenSession(config: config, password: password, session: session)
        return session
    }

    /// Removes the half-sent file of a cancelled upload, from the server the upload went to.
    /// Best effort: if the server can't be reached or refuses, the file stays and the cancel still stands.
    private func delete(_ leftover: WrittenFile.Leftover) async {
        do {
            try await withTimeout(seconds: cleanupTimeout) {
                let session = try await self.session(for: leftover.config, password: leftover.password)
                try await session.deleteFile(atPath: leftover.remotePath)
            }
        } catch {
            await closeSession()
        }
    }

    private func closeSession() async {
        guard let openSession else { return }
        self.openSession = nil
        await openSession.session.close()
    }

    private func size(of url: URL) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func modificationDate(of url: URL) -> Date? {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }

    static func message(for error: any Error) -> String {
        if let error = error as? UploaderError { return error.errorDescription ?? "\(error)" }
        if error is CancellationError { return "Cancelled." }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// Tracks whether an upload has put a file on the server, so a cancel knows if there is anything to clean up.
/// A cancel that lands before the server created the file (while connecting, or while picking a name)
/// must leave the path alone: with `ConflictPolicy.replace` it can belong to a file the user already had.
final class WrittenFile: @unchecked Sendable {
    struct Leftover {
        let remotePath: String
        let config: ServerConfig
        let password: String
    }

    private let lock = NSLock()
    private var target: Leftover?
    private var created = false

    /// Starts tracking a new file. A folder upload calls this once per file. With `alreadyThere` the server holds a
    /// partly sent copy of it that is this upload's own, from an earlier try, so a cancel has it to clean up even before
    /// anything is sent this time.
    func willUpload(to remotePath: String, on config: ServerConfig, password: String, alreadyThere: Bool = false) {
        lock.withLock {
            target = Leftover(remotePath: remotePath, config: config, password: password)
            created = alreadyThere
        }
    }

    /// The server reported progress, which `ServerSession.upload` does first with 0 once it has created the file.
    func serverHasFile() {
        lock.withLock { created = true }
    }

    var leftover: Leftover? {
        lock.withLock { created ? target : nil }
    }
}

/// Limits how often progress is reported, always letting the final byte count through.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private let total: Int64
    private var lastReport: Date?

    init(interval: TimeInterval, total: Int64) {
        self.interval = interval
        self.total = total
    }

    func shouldReport(_ sent: Int64, now: Date = Date()) -> Bool {
        lock.withLock {
            if sent < total, let lastReport, now.timeIntervalSince(lastReport) < interval {
                return false
            }
            lastReport = now
            return true
        }
    }
}

/// How an upload rides out a lost connection: how long it waits before each new try, when the row starts saying it is
/// waiting, and when it gives up for good. Times are counted from the last sign of life (bytes moving).
public struct ReconnectPolicy: Sendable {
    /// Seconds to wait before each try after the connection is lost, one try per entry.
    public var delays: [TimeInterval]
    /// Seconds without a sign of life after which the upload gives up and can be resumed by hand.
    public var giveUpAfter: TimeInterval
    /// Seconds without a sign of life after which the row says it is waiting for the connection.
    public var noticeAfter: TimeInterval

    public init(delays: [TimeInterval], giveUpAfter: TimeInterval, noticeAfter: TimeInterval) {
        self.delays = delays
        self.giveUpAfter = giveUpAfter
        self.noticeAfter = noticeAfter
    }

    /// Tries again after 5, 15, 30 and 60 seconds, and gives up two minutes after the last byte went through.
    public static let standard = ReconnectPolicy(delays: [5, 15, 30, 60], giveUpAfter: 120, noticeAfter: 15)
}

/// Seconds the Mac has been awake. Unlike the wall clock it stands still while the Mac sleeps, so an upload that was
/// asleep with the lid closed gets its full time to find the network again when the Mac wakes.
enum Uptime {
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// What one upload, with all its tries, knows about how it is going. The code that watches it and the code that
/// transfers share it.
final class UploadRun: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSign = Uptime.now
    private var lastSent: Int64?
    private var progressed = false
    private var contacted = false
    private var stalled = false
    private var current: ResumePoint?

    init(point: ResumePoint?) {
        current = point
    }

    /// A sign of life other than bytes: a command the server answered.
    func touch() {
        lock.withLock { lastSign = Uptime.now }
    }

    /// Bytes of a file are going through. `sent` is how many of the file the server holds.
    func report(_ sent: Int64) {
        lock.withLock {
            lastSign = Uptime.now
            // The first number only says where the file stands; after that, more means the connection works.
            if let lastSent, sent > lastSent { progressed = true }
            lastSent = sent
        }
    }

    /// A file's upload is about to start, so its first number is not compared with the one before.
    func beginTransfer() {
        lock.withLock { lastSent = nil }
    }

    /// Seconds since the last sign of life.
    var idle: TimeInterval {
        lock.withLock { Uptime.now - lastSign }
    }

    /// Whether bytes went through since the last time this was asked.
    func takeProgressed() -> Bool {
        lock.withLock {
            defer { progressed = false }
            return progressed
        }
    }

    func markContact() {
        lock.withLock { contacted = true }
    }

    /// Whether a connection to the server was ever made for this upload.
    var hadContact: Bool { lock.withLock { contacted } }

    func markStalled() {
        lock.withLock { stalled = true }
    }

    func clearStalled() {
        lock.withLock { stalled = false }
    }

    var wasStalled: Bool { lock.withLock { stalled } }

    var point: ResumePoint? { lock.withLock { current } }

    func setPoint(_ point: ResumePoint) {
        lock.withLock { current = point }
    }

    /// Marks the file being sent as one the server holds, and returns the point to report if that changed anything.
    func markCreated() -> ResumePoint? {
        lock.withLock {
            guard var point = current, !point.created else { return nil }
            point.created = true
            current = point
            return point
        }
    }
}
