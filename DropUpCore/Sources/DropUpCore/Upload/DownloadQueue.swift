import Foundation

/// One file to fetch from the server.
public struct RemoteDownload: Sendable, Equatable {
    public var remotePath: String
    /// Bytes, when the listing said. Only used for progress.
    public var size: Int64?

    public init(remotePath: String, size: Int64? = nil) {
        self.remotePath = remotePath
        self.size = size
    }

    public var fileName: String { (remotePath as NSString).lastPathComponent }
}

public enum DownloadEvent: Sendable, Equatable {
    case queued(id: UUID, fileName: String, totalBytes: Int64)
    case started(id: UUID)
    case progress(id: UUID, UploadProgress)
    /// `localURL` is where the file ended up, which differs from the server's name when that name was taken.
    case succeeded(id: UUID, localURL: URL)
    case failed(id: UUID, message: String)
    case cancelled(id: UUID)
}

/// Downloads files one at a time and reports what happens on `events`.
///
/// Each file is written next to its final place under a temporary name and moved into position when it
/// is complete, so a cancelled or failed download never leaves a half-written file under the real name.
/// A name that is already taken in the folder gets a number, like uploads do, so nothing is overwritten.
/// One server session is reused for consecutive files and closed when the queue runs dry.
public actor DownloadQueue {
    public nonisolated let events: AsyncStream<DownloadEvent>
    private nonisolated let continuation: AsyncStream<DownloadEvent>.Continuation

    private let connectors: any ConnectorFactory
    private let fileManager: FileManager
    private let progressInterval: TimeInterval

    private struct Job {
        let id: UUID
        let file: RemoteDownload
        let config: ServerConfig
        let password: String
        let directory: URL
    }

    private struct OpenSession {
        let config: ServerConfig
        let password: String
        let session: any ServerSession
    }

    private var pending: [Job] = []
    private var worker: Task<Void, Never>?
    private var active: (id: UUID, task: Task<URL, any Error>)?
    private var cancelledIDs: Set<UUID> = []
    private var openSession: OpenSession?

    public init(
        connectors: any ConnectorFactory,
        fileManager: FileManager = .default,
        progressInterval: TimeInterval = 0.1
    ) {
        self.connectors = connectors
        self.fileManager = fileManager
        self.progressInterval = progressInterval
        let (stream, continuation) = AsyncStream.makeStream(of: DownloadEvent.self)
        self.events = stream
        self.continuation = continuation
    }

    /// Adds files to the end of the queue and returns their ids, in order.
    /// - Parameters:
    ///   - config: the server to fetch from. It is kept with the job, so later changes in Settings don't redirect it.
    ///   - directory: the local folder to save into.
    @discardableResult
    public func enqueue(_ files: [RemoteDownload], from config: ServerConfig, password: String, into directory: URL) -> [UUID] {
        let jobs = files.map { Job(id: UUID(), file: $0, config: config, password: password, directory: directory) }
        for job in jobs {
            pending.append(job)
            continuation.yield(.queued(id: job.id, fileName: job.file.fileName, totalBytes: job.file.size ?? 0))
        }
        if worker == nil, !pending.isEmpty {
            worker = Task { await self.drain() }
        }
        return jobs.map(\.id)
    }

    /// Cancels a waiting or running download. Does nothing for finished or unknown ids.
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
            // The session was stopped mid-transfer and is in an unknown state. The transfer removed its temporary file.
            await closeSession()
            if case .success(let url) = result {
                // The cancel came after the file was already in place, and the user asked for it not to be.
                try? fileManager.removeItem(at: url)
            }
            continuation.yield(.cancelled(id: job.id))
            return
        }
        switch result {
        case .success(let url):
            continuation.yield(.succeeded(id: job.id, localURL: url))
        case .failure(let error):
            await closeSession()
            continuation.yield(.failed(id: job.id, message: Self.message(for: error)))
        }
    }

    private func transfer(_ job: Job) async throws -> URL {
        let session = try await session(for: job.config, password: job.password)
        let name = job.file.fileName
        let temporary = job.directory.appendingPathComponent(".\(name).\(job.id.uuidString.prefix(8)).dropup-part")
        let total = job.file.size ?? 0
        let throttle = ProgressThrottle(interval: progressInterval, total: total)
        let continuation = self.continuation
        let id = job.id
        do {
            try await session.download(remotePath: job.file.remotePath, to: temporary) { received in
                if throttle.shouldReport(received) {
                    continuation.yield(.progress(id: id, UploadProgress(bytesSent: received, totalBytes: total)))
                }
            }
            try Task.checkCancellation()
            let destination = freeURL(for: name, in: job.directory)
            try fileManager.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    /// `photo.png`, or `photo-1.png`, `photo-2.png`… when the folder already has that name.
    private func freeURL(for name: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(name)
        var index = 0
        while fileManager.fileExists(atPath: candidate.path), index < 10_000 {
            index += 1
            candidate = directory.appendingPathComponent(RemoteFileName.numbered(name, index: index))
        }
        return candidate
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

    /// A message for the person, for any error a download can end with. Local file problems read as the system words them.
    static func message(for error: any Error) -> String {
        if let error = error as? UploaderError { return error.errorDescription ?? "\(error)" }
        if error is CancellationError { return "Cancelled." }
        return error.localizedDescription
    }
}
