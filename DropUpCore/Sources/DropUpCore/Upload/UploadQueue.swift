import Foundation

public enum UploadFailure: Error, Equatable, Sendable {
    /// No valid server config saved yet; the app should open onboarding.
    case notConfigured
    /// The Keychain has no password for the configured server.
    case missingPassword
    /// The dropped item is missing, unreadable, or a folder.
    case unsupportedItem
    /// The transfer failed; the message is suitable for display.
    case transfer(String)
}

extension UploadFailure {
    public var displayMessage: String {
        switch self {
        case .notConfigured: "Set up your server first."
        case .missingPassword: "No password saved for this server. Add it in Settings."
        case .unsupportedItem: "Only files can be uploaded, not folders."
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

/// Uploads dropped files one at a time and reports what happens on `events`.
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

    private struct Job {
        let id: UUID
        let fileURL: URL
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

    /// - Parameter progressInterval: minimum seconds between `.progress` events per file.
    ///   The final progress event of a file is always sent.
    public init(
        settings: any SettingsStore,
        credentials: any CredentialStore,
        connectors: any ConnectorFactory,
        fileManager: FileManager = .default,
        progressInterval: TimeInterval = 0.1
    ) {
        self.settings = settings
        self.credentials = credentials
        self.connectors = connectors
        self.fileManager = fileManager
        self.progressInterval = progressInterval
        let (stream, continuation) = AsyncStream.makeStream(of: UploadEvent.self)
        self.events = stream
        self.continuation = continuation
    }

    /// Adds files to the end of the queue and returns their ids, in order.
    @discardableResult
    public func enqueue(_ fileURLs: [URL]) -> [UUID] {
        let jobs = fileURLs.map { Job(id: UUID(), fileURL: $0) }
        for job in jobs {
            pending.append(job)
            continuation.yield(.queued(id: job.id, fileName: job.fileURL.lastPathComponent, totalBytes: size(of: job.fileURL)))
        }
        if worker == nil, !pending.isEmpty {
            worker = Task { await self.drain() }
        }
        return jobs.map(\.id)
    }

    /// Cancels a waiting or running upload. Does nothing for finished or unknown ids.
    public func cancel(_ id: UUID) {
        if let index = pending.firstIndex(where: { $0.id == id }) {
            pending.remove(at: index)
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
        let task = Task { try await self.transfer(job) }
        active = (job.id, task)
        let result = await task.result
        active = nil

        if cancelledIDs.remove(job.id) != nil {
            // The session is mid-transfer and in an unknown state.
            await closeSession()
            continuation.yield(.cancelled(id: job.id))
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

    private func transfer(_ job: Job) async throws -> String {
        guard let config = settings.loadServerConfig(), config.isValid else {
            throw UploadFailure.notConfigured
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: job.fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isReadableFile(atPath: job.fileURL.path)
        else {
            throw UploadFailure.unsupportedItem
        }
        guard let password = try? credentials.password(for: config.credentialKey) else {
            throw UploadFailure.missingPassword
        }

        let session = try await session(for: config, password: password)
        let remotePath = try await RemoteFileName.resolve(
            fileName: job.fileURL.lastPathComponent,
            in: config,
            policy: settings.loadPreferences().conflictPolicy,
            session: session
        )
        let total = size(of: job.fileURL)
        let throttle = ProgressThrottle(interval: progressInterval, total: total)
        let continuation = self.continuation
        let id = job.id
        try await session.upload(fileURL: job.fileURL, to: remotePath) { sent in
            if throttle.shouldReport(sent) {
                continuation.yield(.progress(id: id, UploadProgress(bytesSent: sent, totalBytes: total)))
            }
        }
        return remotePath
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
