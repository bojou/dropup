import Foundation

/// Why an item dragged out of the Browse window could not be fetched.
public struct DragExportError: Error, Equatable, Sendable, LocalizedError {
    public var message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Fetches an item from the server when something dragged out of the Browse window is dropped on the Mac.
///
/// Dragging only starts a promise: nothing is downloaded until a drop target asks for the file. The item then comes
/// down into a folder of its own inside `parent` (a file keeps its name, a folder arrives as a folder) and the caller
/// hands that location to the drop target, which copies it to where it was dropped. It uses a download queue of its
/// own, so a drag never waits behind the downloads in the window, and it follows the same rules: links are left out,
/// and nothing is left behind when it fails or is cancelled.
public actor DragExport {
    private let queue: DownloadQueue
    private let parent: URL
    private var fileManager: FileManager { .default }
    private var finished: [UUID: Result<URL, any Error>] = [:]
    private var waiting: [UUID: CheckedContinuation<URL, any Error>] = [:]
    private var progressHandlers: [UUID: @Sendable (UploadProgress) -> Void] = [:]

    /// - Parameter parent: the local folder to fetch into. Each fetch makes a folder of its own inside it.
    public init(
        connectors: any ConnectorFactory,
        parent: URL = FileManager.default.temporaryDirectory.appendingPathComponent("DropUp-drag", isDirectory: true)
    ) {
        queue = DownloadQueue(connectors: connectors)
        self.parent = parent
        Task { [weak self, events = queue.events] in
            for await event in events {
                await self?.handle(event)
            }
        }
    }

    /// Downloads `item` and returns where it is. `progress` receives the bytes fetched so far and the total, once known.
    /// Cancelling the calling task stops the download and removes what was fetched.
    public func fetch(
        _ item: RemoteDownload,
        from config: ServerConfig,
        password: String,
        progress: @escaping @Sendable (UploadProgress) -> Void = { _ in }
    ) async throws -> URL {
        let folder = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let id = await queue.enqueue([item], from: config, password: password, into: folder)[0]
            progressHandlers[id] = progress
            return try await withTaskCancellationHandler {
                try await result(for: id)
            } onCancel: {
                Task { await self.cancel(id) }
            }
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    /// Removes everything fetched so far. Call when the window closes or the app quits.
    public func removeFetchedFiles() {
        try? fileManager.removeItem(at: parent)
    }

    private func cancel(_ id: UUID) async {
        await queue.cancel(id)
    }

    private func result(for id: UUID) async throws -> URL {
        if let done = finished.removeValue(forKey: id) { return try done.get() }
        return try await withCheckedThrowingContinuation { waiting[id] = $0 }
    }

    private func handle(_ event: DownloadEvent) {
        switch event {
        case .progress(let id, let update):
            progressHandlers[id]?(update)
        case .succeeded(let id, let url):
            resolve(id, .success(url))
        case .failed(let id, let message):
            resolve(id, .failure(DragExportError(message: message)))
        case .cancelled(let id):
            resolve(id, .failure(CancellationError()))
        case .queued, .started:
            break
        }
    }

    private func resolve(_ id: UUID, _ result: Result<URL, any Error>) {
        progressHandlers[id] = nil
        if let waiter = waiting.removeValue(forKey: id) {
            waiter.resume(with: result)
        } else {
            finished[id] = result
        }
    }
}
