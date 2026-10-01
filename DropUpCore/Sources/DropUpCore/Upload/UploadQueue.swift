import Foundation

public enum UploadFailure: Error, Equatable, Sendable {
    /// No valid server config saved yet; the app should open onboarding.
    case notConfigured
    /// The Keychain has no password for the configured server.
    case missingPassword
    /// The dropped item is missing, unreadable, or a folder.
    case unsupportedItem
    /// The uploader threw; the message is suitable for display.
    case transfer(String)
}

public enum UploadEvent: Sendable, Equatable {
    case queued(id: UUID, fileName: String)
    case started(id: UUID)
    case progress(id: UUID, UploadProgress)
    case succeeded(id: UUID, remotePath: String)
    case failed(id: UUID, UploadFailure)
}

/// Uploads dropped files one at a time and reports what happens on `events`.
///
/// The queue reads settings and credentials at the moment each upload starts,
/// so edits made in Settings apply to the next file without restarting anything.
public actor UploadQueue {
    public nonisolated let events: AsyncStream<UploadEvent>
    private nonisolated let continuation: AsyncStream<UploadEvent>.Continuation

    private let settings: any SettingsStore
    private let credentials: any CredentialStore
    private let uploaderFactory: any UploaderFactory
    private let fileManager: FileManager

    private struct Job {
        let id: UUID
        let fileURL: URL
    }

    private var pending: [Job] = []
    private var worker: Task<Void, Never>?

    public init(
        settings: any SettingsStore,
        credentials: any CredentialStore,
        uploaderFactory: any UploaderFactory = DefaultUploaderFactory(),
        fileManager: FileManager = .default
    ) {
        self.settings = settings
        self.credentials = credentials
        self.uploaderFactory = uploaderFactory
        self.fileManager = fileManager
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
            continuation.yield(.queued(id: job.id, fileName: job.fileURL.lastPathComponent))
        }
        if worker == nil, !pending.isEmpty {
            worker = Task { await self.drain() }
        }
        return jobs.map(\.id)
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

    private func drain() async {
        while !pending.isEmpty {
            let job = pending.removeFirst()
            await process(job)
        }
        worker = nil
    }

    private func process(_ job: Job) async {
        continuation.yield(.started(id: job.id))
        do {
            let request = try makeRequest(for: job)
            let uploader = uploaderFactory.uploader(for: request.config.transferProtocol)
            let continuation = self.continuation
            try await uploader.upload(request) { progress in
                continuation.yield(.progress(id: job.id, progress))
            }
            continuation.yield(.succeeded(id: job.id, remotePath: request.remotePath))
        } catch let failure as UploadFailure {
            continuation.yield(.failed(id: job.id, failure))
        } catch {
            continuation.yield(.failed(id: job.id, .transfer(String(describing: error))))
        }
    }

    private func makeRequest(for job: Job) throws -> UploadRequest {
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
        return UploadRequest(
            fileURL: job.fileURL,
            remotePath: config.remotePath(forFileNamed: job.fileURL.lastPathComponent),
            config: config,
            password: password
        )
    }
}
