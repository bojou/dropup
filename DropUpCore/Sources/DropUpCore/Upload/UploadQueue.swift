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
}

extension UploadFailure {
    public var displayMessage: String {
        switch self {
        case .notConfigured: "Set up your server first."
        case .missingPassword: "No password saved for this server. Add it in Settings."
        case .unsupportedItem: "DropUp can't read this item."
        case .transfer(let message): message
        }
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
}

/// Uploads dropped files and folders one at a time and reports what happens on `events`.
///
/// A folder is one item in the queue: it is sent with everything inside it, as the same name on the server (numbered
/// when that name is taken, unless the setting is to replace). Its name in the events ends with `/`.
/// Symbolic links inside it are left out. A folder that is cancelled or fails halfway keeps the files already sent.
/// A folder is read (to learn what is in it and how big it is) on its own, off the queue, so a big one never holds up
/// a cancel or the files behind it. Its subfolders are made on the server as the files going into them come up.
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

    private struct Job {
        let id: UUID
        let fileURL: URL
        /// Where to put the file instead of the saved upload folder.
        let remoteDirectory: String?
        /// For a folder: reading what is inside it, started when it was dropped and running while it waits its turn.
        let scan: Task<LocalTree, any Error>?
    }

    private struct OpenSession {
        let config: ServerConfig
        let password: String
        let session: any ServerSession
    }

    private var pending: [Job] = []
    private var worker: Task<Void, Never>?
    private var active: (id: UUID, task: Task<String, any Error>)?
    private var cancelledIDs: Set<UUID> = []
    private var openSession: OpenSession?

    /// - Parameters:
    ///   - progressInterval: minimum seconds between `.progress` events per file.
    ///     The final progress event of a file is always sent.
    ///   - cleanupTimeout: seconds to spend deleting the half-sent file after a cancel before giving up.
    public init(
        settings: any SettingsStore,
        credentials: any CredentialStore,
        connectors: any ConnectorFactory,
        fileManager: FileManager = .default,
        progressInterval: TimeInterval = 0.1,
        cleanupTimeout: Double = 15
    ) {
        self.settings = settings
        self.credentials = credentials
        self.connectors = connectors
        self.fileManager = fileManager
        self.progressInterval = progressInterval
        self.cleanupTimeout = cleanupTimeout
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
            if isFolder(url) {
                // The row shows up at once. Its size follows when the folder has been read, which can take a while.
                continuation.yield(.queued(id: id, fileName: name + "/", totalBytes: 0))
                scan = Self.readFolder(url, id: id, continuation: continuation)
            } else {
                continuation.yield(.queued(id: id, fileName: name, totalBytes: size(of: url)))
            }
            pending.append(Job(id: id, fileURL: url, remoteDirectory: remoteDirectory, scan: scan))
        }
        if worker == nil, !pending.isEmpty {
            worker = Task { await self.drain() }
        }
        return ids
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

    /// Cancels a waiting or running upload. Does nothing for finished or unknown ids.
    public func cancel(_ id: UUID) {
        if let index = pending.firstIndex(where: { $0.id == id }) {
            pending.remove(at: index).scan?.cancel()
            continuation.yield(.cancelled(id: id))
        } else if let active, active.id == id {
            cancelledIDs.insert(id)
            active.task.cancel()
        }
    }

    public func cancelAll() {
        let waiting = pending
        pending.removeAll()
        for job in waiting {
            job.scan?.cancel()
            continuation.yield(.cancelled(id: job.id))
        }
        if let active { cancel(active.id) }
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

    private func process(_ job: Job) async {
        continuation.yield(.started(id: job.id))
        let written = WrittenFile()
        let task = Task { try await self.transfer(job, written: written) }
        active = (job.id, task)
        let result = await task.result
        active = nil
        // Nothing is left to read for this job, whatever way it ended (a no-op once the reading is done).
        job.scan?.cancel()

        if cancelledIDs.remove(job.id) != nil {
            // The session is mid-transfer and in an unknown state.
            await closeSession()
            continuation.yield(.cancelled(id: job.id))
            if let leftover = written.leftover {
                await delete(leftover)
            }
            return
        }
        switch result {
        case .success(let remotePath):
            continuation.yield(.succeeded(id: job.id, remotePath: remotePath))
        case .failure(let failure as UploadFailure):
            continuation.yield(.failed(id: job.id, failure))
        case .failure(let error):
            await closeSession()
            continuation.yield(.failed(id: job.id, .transfer(Self.message(for: error))))
        }
    }

    private func transfer(_ job: Job, written: WrittenFile) async throws -> String {
        guard let config = settings.loadServerConfig(), config.isValid else {
            throw UploadFailure.notConfigured
        }
        guard fileManager.fileExists(atPath: job.fileURL.path),
              fileManager.isReadableFile(atPath: job.fileURL.path)
        else {
            throw UploadFailure.unsupportedItem
        }
        guard let password = try? credentials.password(for: config.credentialKey) else {
            throw UploadFailure.missingPassword
        }

        let session = try await session(for: config, password: password)
        // Only the target folder changes. The session is still matched on the saved config, so it is reused.
        let target = job.remoteDirectory.map(config.withRemoteDirectory) ?? config
        if isFolder(job.fileURL) {
            return try await transferFolder(job, to: target, config: config, password: password, session: session, written: written)
        }
        let remotePath = try await RemoteFileName.resolve(
            fileName: job.fileURL.lastPathComponent,
            in: target,
            policy: settings.loadPreferences().conflictPolicy,
            session: session
        )
        let total = size(of: job.fileURL)
        let throttle = ProgressThrottle(interval: progressInterval, total: total)
        let continuation = self.continuation
        let id = job.id
        written.willUpload(to: remotePath, on: config, password: password)
        try await session.upload(fileURL: job.fileURL, to: remotePath) { sent in
            written.serverHasFile()
            if sent > 0, throttle.shouldReport(sent) {
                continuation.yield(.progress(id: id, UploadProgress(bytesSent: sent, totalBytes: total)))
            }
        }
        return remotePath
    }

    /// Sends a folder and everything in it. Returns the folder's path on the server.
    private func transferFolder(
        _ job: Job,
        to target: ServerConfig,
        config: ServerConfig,
        password: String,
        session: any ServerSession,
        written: WrittenFile
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

        let parent = RemotePath.normalizedDirectory(target.remoteDirectory)
        let name = job.fileURL.lastPathComponent
        var finalName = name
        if settings.loadPreferences().conflictPolicy == .keepBoth {
            let taken = Set(try await session.listEntries(atPath: parent).map(\.name))
            var index = 0
            while taken.contains(finalName), index < 1000 {
                index += 1
                finalName = RemoteFileName.numberedFolder(name, index: index)
            }
        }
        let root = Self.join(parent, finalName)
        try await Self.ensureFolder(root, session: session)

        // Folders are made as the files going into them come up, not all in front: a folder with thousands of
        // subfolders starts sending, and can be cancelled, right away. Each one is made once, outermost first.
        var made: Set<String> = []

        let total = tree.totalBytes
        let throttle = ProgressThrottle(interval: progressInterval, total: total)
        let continuation = self.continuation
        let id = job.id
        var sentBefore: Int64 = 0
        for file in tree.files {
            try Task.checkCancellation()
            for folder in LocalTree.folders(containing: file.relativePath) {
                try await Self.make(folder, under: root, made: &made, session: session)
            }
            let remotePath = Self.join(root, file.relativePath)
            written.willUpload(to: remotePath, on: config, password: password)
            let base = sentBefore
            try await Self.wrapped(file.relativePath) {
                try await session.upload(fileURL: file.url, to: remotePath) { sent in
                    written.serverHasFile()
                    let overall = base + sent
                    if sent > 0, throttle.shouldReport(overall) {
                        continuation.yield(.progress(id: id, UploadProgress(bytesSent: overall, totalBytes: total)))
                    }
                }
            }
            sentBefore += file.size
        }
        // Folders with no files in them (and nothing but such folders inside) are still part of the folder.
        for folder in tree.directories {
            try await Self.make(folder, under: root, made: &made, session: session)
        }
        return root
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
        } catch let error as UploaderError {
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

    /// Starts tracking a new file. A folder upload calls this once per file.
    func willUpload(to remotePath: String, on config: ServerConfig, password: String) {
        lock.withLock {
            target = Leftover(remotePath: remotePath, config: config, password: password)
            created = false
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
