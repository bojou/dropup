import Foundation
import Observation
import DropUpCore

/// The downloads started from the Browse window. They live here, not in the window, so they carry on if it closes.
@MainActor
@Observable
final class DownloadModel {
    struct Item: Identifiable, Equatable {
        enum State: Equatable {
            case waiting
            case downloading
            case done(URL)
            case failed(String)
            case cancelled
        }

        let id: UUID
        var fileName: String
        var totalBytes: Int64
        var receivedBytes: Int64 = 0
        var state = State.waiting

        var fraction: Double {
            totalBytes > 0 ? min(1, max(0, Double(receivedBytes) / Double(totalBytes))) : 0
        }

        var isFinished: Bool {
            switch state {
            case .waiting, .downloading: false
            case .done, .failed, .cancelled: true
            }
        }
    }

    private(set) var items: [Item] = []

    var isBusy: Bool { items.contains { !$0.isFinished } }

    /// Called once when everything started together has finished, with the files that arrived and the ones that failed.
    @ObservationIgnored var onRunFinished: ((_ done: [Item], _ failed: [Item]) -> Void)?

    @ObservationIgnored private let queue: DownloadQueue
    @ObservationIgnored private var run: Set<UUID> = []
    private static let finishedToKeep = 20

    init(connectors: any ConnectorFactory) {
        queue = DownloadQueue(connectors: connectors)
        Task { @MainActor [weak self, events = queue.events] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    /// Fetches `entries`, which sit in the server folder `folder`, into `directory` on this Mac.
    func download(_ entries: [RemoteEntry], in folder: String, from browse: BrowseModel, to directory: URL) {
        let files = entries.map {
            RemoteDownload(remotePath: RemotePath.appending($0.name, to: folder), size: $0.size, isFolder: $0.kind == .folder)
        }
        guard !files.isEmpty else { return }
        let config = browse.config
        let password = browse.password
        Task { await queue.enqueue(files, from: config, password: password, into: directory) }
    }

    func cancel(_ id: UUID) {
        Task { await queue.cancel(id) }
    }

    func cancelAll() {
        Task { await queue.cancelAll() }
    }

    func clearFinished() {
        items.removeAll { $0.isFinished }
    }

    private func handle(_ event: DownloadEvent) {
        switch event {
        case .queued(let id, let fileName, let totalBytes):
            if !isBusy { run = [] }
            run.insert(id)
            items.append(Item(id: id, fileName: fileName, totalBytes: totalBytes))
        case .started(let id):
            update(id) { $0.state = .downloading }
        case .progress(let id, let progress):
            update(id) {
                $0.receivedBytes = progress.bytesSent
                if progress.totalBytes > 0 { $0.totalBytes = progress.totalBytes }
            }
        case .succeeded(let id, let url):
            update(id) {
                $0.receivedBytes = max($0.receivedBytes, $0.totalBytes)
                $0.state = .done(url)
            }
        case .failed(let id, let message):
            update(id) { $0.state = .failed(message) }
        case .cancelled(let id):
            update(id) { $0.state = .cancelled }
        }
        guard !isBusy, !run.isEmpty else { return }
        let finished = items.filter { run.contains($0.id) }
        run = []
        trim()
        let done = finished.filter { if case .done = $0.state { true } else { false } }
        let failed = finished.filter { if case .failed = $0.state { true } else { false } }
        if !done.isEmpty || !failed.isEmpty { onRunFinished?(done, failed) }
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    /// Keeps the newest few finished downloads, so the list can't grow without end.
    private func trim() {
        var finished = items.filter(\.isFinished).count
        items.removeAll { item in
            guard item.isFinished, finished > Self.finishedToKeep else { return false }
            finished -= 1
            return true
        }
    }
}
