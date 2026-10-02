import Foundation

/// What the menubar icon should show.
public enum MenubarState: Equatable, Sendable {
    case idle
    /// `fraction` is overall progress across every file in the current batch, 0...1.
    case uploading(fraction: Double)
    /// Everything in the last batch went through. Shown briefly, then back to idle.
    case succeeded
    /// Something failed and the user hasn't looked yet.
    case failed
}

/// Folds `UploadEvent`s into the list the popover shows and the state the icon shows.
/// A plain value type with no UI, so the whole thing is unit tested.
public struct UploadActivity: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case waiting
        case uploading
        case succeeded(remotePath: String)
        case failed(message: String)
        case cancelled

        public var isFinished: Bool {
            switch self {
            case .waiting, .uploading: false
            case .succeeded, .failed, .cancelled: true
            }
        }
    }

    public struct Item: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var fileName: String
        public var totalBytes: Int64
        public var bytesSent: Int64 = 0
        public var state: State = .waiting
        public var finishedAt: Date?

        public var fraction: Double {
            UploadProgress(bytesSent: bytesSent, totalBytes: totalBytes).fraction
        }

        /// A folder is sent as one item, named with a trailing `/`.
        public var isFolder: Bool { fileName.hasSuffix("/") }

        /// Lower-case extension for the file badge, e.g. `PNG`. Empty when there is none, and for a folder.
        public var badge: String {
            guard !isFolder else { return "" }
            let ext = (fileName as NSString).pathExtension
            return String(ext.prefix(4)).uppercased()
        }
    }

    /// Newest first among finished items; waiting and running items keep their drop order.
    public private(set) var items: [Item] = []
    public private(set) var hasUnseenFailure = false

    // Speed is measured over a short sliding window of cumulative bytes sent.
    private var batchIDs: Set<UUID> = []
    private var bytesFinished: Int64 = 0
    private var samples: [(time: Date, bytes: Int64)] = []
    private static let speedWindow: TimeInterval = 3

    public init() {}

    // MARK: Derived state

    public var waiting: [Item] { items.filter { $0.state == .waiting } }
    public var running: [Item] { items.filter { $0.state == .uploading } }
    public var active: [Item] { items.filter { !$0.state.isFinished } }
    public var finished: [Item] { items.filter { $0.state.isFinished } }
    /// Files dropped since the queue was last idle, and how many of them have finished.
    public var batchItems: [Item] { items.filter { batchIDs.contains($0.id) } }
    public var batchTotal: Int { items.filter { batchIDs.contains($0.id) }.count }
    public var batchDone: Int { items.filter { batchIDs.contains($0.id) && $0.state.isFinished }.count }
    public var isBusy: Bool { items.contains { !$0.state.isFinished } }

    /// Overall progress across the current batch: every file dropped since the queue was last idle,
    /// finished ones counting as complete, so the ring never jumps backwards when a file completes.
    public var overallFraction: Double {
        let batch = items.filter { batchIDs.contains($0.id) }
        // An empty file still counts as one byte so it moves the ring.
        let total = batch.reduce(Int64(0)) { $0 + max($1.totalBytes, 1) }
        guard total > 0 else { return 0 }
        let done = batch.reduce(Int64(0)) { sum, item in
            item.state.isFinished ? sum + max(item.totalBytes, 1) : sum + min(item.bytesSent, max(item.totalBytes, 1))
        }
        return min(1, max(0, Double(done) / Double(total)))
    }

    public func menubarState(now: Date = Date(), successFlash: TimeInterval = 2) -> MenubarState {
        if isBusy { return .uploading(fraction: overallFraction) }
        if hasUnseenFailure { return .failed }
        if let last = items.compactMap(\.finishedAt).max(),
           now.timeIntervalSince(last) < successFlash,
           items.contains(where: { if case .succeeded = $0.state { true } else { false } }) {
            return .succeeded
        }
        return .idle
    }

    /// Bytes per second over the last few seconds, or nil before there is enough data.
    public func speed(now: Date = Date()) -> Double? {
        guard isBusy else { return nil }
        let recent = samples.filter { now.timeIntervalSince($0.time) <= Self.speedWindow }
        guard let first = recent.first, let last = recent.last, last.time > first.time else { return nil }
        let rate = Double(last.bytes - first.bytes) / last.time.timeIntervalSince(first.time)
        return rate > 0 ? rate : nil
    }

    /// Seconds left for the whole batch at the current speed.
    public func secondsRemaining(now: Date = Date()) -> Double? {
        guard let speed = speed(now: now) else { return nil }
        let left = active.reduce(Int64(0)) { $0 + max($1.totalBytes - $1.bytesSent, 0) }
        return Double(left) / speed
    }

    // MARK: Events

    public mutating func apply(_ event: UploadEvent, now: Date = Date()) {
        switch event {
        case .queued(let id, let fileName, let totalBytes):
            if !isBusy {
                // A new batch begins: restart the ring and the speed measurement.
                batchIDs = []
                samples = []
                bytesFinished = 0
            }
            batchIDs.insert(id)
            // Active items stay in drop order after the already-active ones; finished go below.
            let firstFinished = items.firstIndex { $0.state.isFinished } ?? items.endIndex
            items.insert(Item(id: id, fileName: fileName, totalBytes: totalBytes), at: firstFinished)

        case .started(let id):
            update(id) { $0.state = .uploading }

        case .progress(let id, let progress):
            update(id) {
                $0.bytesSent = progress.bytesSent
                if progress.totalBytes > 0 { $0.totalBytes = progress.totalBytes }
            }
            recordSample(now)

        case .succeeded(let id, let remotePath):
            update(id) {
                $0.bytesSent = $0.totalBytes
                $0.state = .succeeded(remotePath: remotePath)
            }
            finish(id, now)

        case .failed(let id, let failure):
            update(id) { $0.state = .failed(message: failure.displayMessage) }
            hasUnseenFailure = true
            finish(id, now)

        case .cancelled(let id):
            update(id) { $0.state = .cancelled }
            finish(id, now)
        }
    }

    /// Call when the user opens the popover: the red dot has done its job.
    public mutating func markFailuresSeen() {
        hasUnseenFailure = false
    }

    public mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        batchIDs.remove(id)
    }

    /// Removes finished items. With `failuresToo` false, failed ones stay so they can be retried.
    public mutating func clearFinished(failuresToo: Bool = true) {
        items.removeAll { item in
            guard item.state.isFinished else { return false }
            if case .failed = item.state, !failuresToo { return false }
            return true
        }
        if !items.contains(where: { if case .failed = $0.state { true } else { false } }) {
            hasUnseenFailure = false
        }
    }

    /// Keeps only the newest `limit` finished items.
    public mutating func trim(toRecent limit: Int) {
        var kept = 0
        items.removeAll { item in
            guard item.state.isFinished else { return false }
            kept += 1
            return kept > max(limit, 0)
        }
    }

    // MARK: Helpers

    private mutating func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    /// Moves a just-finished item to the top of the finished section (newest first).
    private mutating func finish(_ id: UUID, _ now: Date) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.finishedAt = now
        bytesFinished += item.totalBytes
        recordSample(now)
        let firstFinished = items.firstIndex { $0.state.isFinished } ?? items.endIndex
        items.insert(item, at: firstFinished)
    }

    private mutating func recordSample(_ now: Date) {
        let sent = bytesFinished + active.reduce(Int64(0)) { $0 + $1.bytesSent }
        if let last = samples.last, last.bytes == sent, now.timeIntervalSince(last.time) < 0.2 { return }
        samples.append((now, sent))
        samples.removeAll { now.timeIntervalSince($0.time) > Self.speedWindow * 2 }
    }

    public static func == (lhs: UploadActivity, rhs: UploadActivity) -> Bool {
        lhs.items == rhs.items && lhs.hasUnseenFailure == rhs.hasUnseenFailure
    }
}
