import Foundation

/// What the menubar icon should show.
public enum MenubarState: Equatable, Sendable {
    case idle
    /// `fraction` is overall progress across every file in the current batch, 0...1.
    case uploading(fraction: Double)
    /// Everything in the last batch went through. Shown briefly, then back to idle.
    case succeeded
    /// Something in the latest batch failed and the user hasn't looked yet. A new batch starts from a clean slate:
    /// the icon shows how the uploads in front of it went, not how an earlier one did.
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
        /// DropUp quit, or crashed, before this one was done. It was restored after a relaunch and waits to be resumed.
        case interrupted
        /// The user paused it. Whatever was sent stays on the server, and it waits to be resumed.
        case paused
        case cancelled

        public var isFinished: Bool {
            switch self {
            case .waiting, .uploading: false
            case .succeeded, .failed, .interrupted, .paused, .cancelled: true
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
        /// What it takes to carry the upload on after an interruption, once the upload has got far enough to have it.
        public var resume: ResumePoint?
        /// The connection is down and DropUp is trying again by itself.
        public var isReconnecting = false
        /// Something to say about this upload besides its progress, such as why it started over.
        public var notice: String?

        /// A stopped upload with part of it on the server, which can be carried on from there. It stays in the list
        /// until it is resumed or removed. An upload that failed before anything was sent keeps its `resume` too, so it
        /// can be sent again after a relaunch, but it is an ordinary failed row otherwise.
        public var isResumable: Bool {
            guard let resume else { return false }
            switch state {
            case .interrupted, .paused: return true
            case .failed: return resume.hasProgress
            default: return false
            }
        }

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
    public internal(set) var items: [Item] = []
    public internal(set) var hasUnseenFailure = false
    /// When the latest upload went through. The icon's brief check mark runs off this, so it still shows when the
    /// Recent list keeps nothing.
    public private(set) var lastSucceededAt: Date?

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
    /// Whether anything in the current batch failed, for choosing which sound to play when it is done.
    public var batchHadFailure: Bool {
        items.contains { item in
            guard batchIDs.contains(item.id), case .failed = item.state else { return false }
            return true
        }
    }
    public var isBusy: Bool { items.contains { !$0.state.isFinished } }

    /// Whether an upload is held by a pause. It is not busy, but the user has it in hand, so the popover goes on
    /// inviting more files, as it does while uploads run.
    public var hasPaused: Bool { items.contains { $0.state == .paused } }

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
        if let last = lastSucceededAt, now.timeIntervalSince(last) < successFlash {
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
                // A new batch begins: restart the ring and the speed measurement. A failure from an earlier batch
                // is not carried over, or every upload after it would show as failed until someone opened the popover.
                batchIDs = []
                samples = []
                bytesFinished = 0
                hasUnseenFailure = false
            }
            batchIDs.insert(id)
            // An upload that is carried on comes back under the id its row had: it takes that row's place.
            items.removeAll { $0.id == id }
            // Active items stay in drop order after the already-active ones; finished go below.
            let firstFinished = items.firstIndex { $0.state.isFinished } ?? items.endIndex
            items.insert(Item(id: id, fileName: fileName, totalBytes: totalBytes), at: firstFinished)

        case .started(let id):
            update(id) { $0.state = .uploading }

        case .progress(let id, let progress):
            update(id) {
                $0.bytesSent = progress.bytesSent
                if progress.totalBytes > 0 { $0.totalBytes = progress.totalBytes }
                $0.isReconnecting = false
            }
            recordSample(now)

        case .resumable(let id, let point):
            update(id) { $0.resume = point }

        case .waitingForConnection(let id):
            update(id) { $0.isReconnecting = true }

        case .restarted(let id, let reason):
            update(id) {
                $0.notice = reason
                $0.bytesSent = 0
            }

        case .succeeded(let id, let remotePath):
            update(id) {
                $0.bytesSent = $0.totalBytes
                $0.state = .succeeded(remotePath: remotePath)
                $0.resume = nil
                $0.notice = nil
                $0.isReconnecting = false
            }
            lastSucceededAt = now
            finish(id, now)

        case .failed(let id, let failure):
            update(id) {
                $0.state = .failed(message: failure.displayMessage)
                $0.isReconnecting = false
            }
            hasUnseenFailure = true
            finish(id, now)

        case .cancelled(let id):
            update(id) {
                $0.state = .cancelled
                $0.resume = nil
                $0.notice = nil
                $0.isReconnecting = false
            }
            finish(id, now)

        case .paused(let id):
            update(id) {
                $0.state = .paused
                $0.notice = nil
                $0.isReconnecting = false
            }
            // A paused upload is not part of what is being sent: the ring, the count and the sound go on without it, and
            // it is no failure. Resuming it queues it again as a new part of the batch.
            batchIDs.remove(id)
            finish(id, now, counting: items.first { $0.id == id }?.bytesSent ?? 0)
        }
    }

    /// Call when the user opens the popover: the red dot has done its job.
    public mutating func markFailuresSeen() {
        hasUnseenFailure = false
    }

    /// Whether `item` can be taken out of the list by itself: it is finished, and no batch is running. During a batch
    /// the finished items are still being counted and summed up, so they stay until it is done. An interrupted upload
    /// from before this batch is not counted in it, so it can go at any time.
    public func canDismiss(_ item: Item) -> Bool {
        guard item.state.isFinished else { return false }
        return !isBusy || (item.isResumable && !batchIDs.contains(item.id))
    }

    /// Takes one finished upload out of the list. Does nothing for an upload that isn't finished or while a batch runs.
    public mutating func dismiss(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), canDismiss(item) else { return }
        remove(id)
    }

    /// Whether Clear would take anything out: interrupted uploads stay until they are resumed or removed one by one.
    public var canClear: Bool { items.contains { $0.state.isFinished && !$0.isResumable } }

    public mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        batchIDs.remove(id)
    }

    /// Removes finished items, except the interrupted ones. With `failuresToo` false, failed ones stay so they can be retried.
    public mutating func clearFinished(failuresToo: Bool = true) {
        items.removeAll { item in
            guard item.state.isFinished, !item.isResumable else { return false }
            if case .failed = item.state, !failuresToo { return false }
            return true
        }
        if !items.contains(where: { if case .failed = $0.state { true } else { false } }) {
            hasUnseenFailure = false
        }
    }

    /// Keeps only the newest `limit` finished items. Interrupted ones are not counted and not removed.
    public mutating func trim(toRecent limit: Int) {
        var kept = 0
        items.removeAll { item in
            guard item.state.isFinished, !item.isResumable else { return false }
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
    private mutating func finish(_ id: UUID, _ now: Date, counting counted: Int64? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.finishedAt = now
        bytesFinished += counted ?? item.totalBytes
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
