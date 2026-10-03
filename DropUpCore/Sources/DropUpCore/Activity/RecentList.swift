import Foundation

/// When the popover's Recent list empties itself. Set in Settings > General.
public enum RecentClearMode: String, Codable, CaseIterable, Sendable {
    /// The list lives only while DropUp runs. This is how the list always behaved.
    case onQuit
    /// Nothing clears it; it is kept between launches until the user clears it or the count limit pushes items out.
    case never
    case hour
    case day
    case week
    /// `Preferences.recentClearAmount` of `Preferences.recentClearUnit`.
    case custom
}

public enum RecentClearUnit: String, Codable, CaseIterable, Sendable {
    case minutes, hours, days

    public var seconds: TimeInterval {
        switch self {
        case .minutes: 60
        case .hours: 3_600
        case .days: 86_400
        }
    }
}

/// The two rules that decide what the Recent list keeps, derived from `Preferences`.
public struct RecentPolicy: Equatable, Sendable {
    /// How many finished uploads to keep. Zero keeps none: every finished upload, failed ones included, leaves the
    /// list as soon as the batch is done. The menubar icon, the sound and the notification still tell about a failure.
    public var limit: Int
    /// Finished uploads older than this many seconds are removed. Nil never removes them.
    public var lifetime: TimeInterval?

    public init(limit: Int = 10, lifetime: TimeInterval? = nil) {
        self.limit = limit
        self.lifetime = lifetime
    }
}

/// A finished upload as it is kept between launches.
public struct StoredUpload: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case succeeded, failed, cancelled
        /// Not done when DropUp quit: it was running or waiting, or an earlier launch had already restored it so.
        case interrupted
    }

    public var fileName: String
    public var totalBytes: Int64
    public var outcome: Outcome
    /// The remote path of an upload that went through, or the message of one that failed.
    public var detail: String
    public var finishedAt: Date
    /// What it takes to carry the upload on, for one that was interrupted. Finished uploads have none.
    public var resume: ResumePoint?

    public init(fileName: String, totalBytes: Int64, outcome: Outcome, detail: String, finishedAt: Date, resume: ResumePoint? = nil) {
        self.fileName = fileName
        self.totalBytes = totalBytes
        self.outcome = outcome
        self.detail = detail
        self.finishedAt = finishedAt
        self.resume = resume
    }

    /// Whether this is an upload to carry on rather than one that is over: it stopped with part of it on the server.
    public var isInterrupted: Bool {
        guard let resume else { return false }
        return outcome == .interrupted || (outcome == .failed && resume.hasProgress)
    }
}

/// Keeps the Recent list between launches, for the settings that ask for it.
public protocol RecentStore: Sendable {
    func load() -> [StoredUpload]
    func save(_ uploads: [StoredUpload])
}

/// Production store backed by `UserDefaults`.
public final class UserDefaultsRecentStore: RecentStore, @unchecked Sendable {
    // UserDefaults is documented as thread-safe.
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "recentUploads") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [StoredUpload] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([StoredUpload].self, from: data)) ?? []
    }

    public func save(_ uploads: [StoredUpload]) {
        if uploads.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(uploads) {
            defaults.set(data, forKey: key)
        }
    }
}

extension UploadActivity {
    /// Applies the Recent list rules. A batch in progress is left alone: its items are still being counted and
    /// summed up, and the rules apply when it is done.
    public mutating func applyRecentPolicy(_ policy: RecentPolicy, now: Date) {
        guard !isBusy else { return }
        if let lifetime = policy.lifetime {
            removeFinished { item in
                guard let finished = item.finishedAt else { return false }
                return now.timeIntervalSince(finished) >= lifetime
            }
        }
        if policy.limit > 0 {
            // Interrupted uploads are exempt from the count and the clock: they stay until resumed or removed.
            trim(toRecent: policy.limit)
        } else {
            // Keeping nothing means nothing, an interrupted upload included: with no list there is nothing to resume from.
            items.removeAll { $0.state.isFinished }
        }
        // The icon's failure mark is not touched here: it belongs to the upload that failed, not to the list.
    }

    /// When the next finished upload is due to be removed under `lifetime`, or nil if none ever will be.
    public func nextRecentExpiry(lifetime: TimeInterval?) -> Date? {
        guard let lifetime else { return nil }
        return items.compactMap { $0.state.isFinished && !$0.isResumable ? $0.finishedAt?.addingTimeInterval(lifetime) : nil }.min()
    }

    /// The finished uploads, newest first, in the form that is kept between launches. Interrupted ones are not among them:
    /// `storedInterrupted` has those.
    public var storedFinished: [StoredUpload] {
        items.compactMap { item in
            guard let finishedAt = item.finishedAt, !item.isResumable else { return nil }
            switch item.state {
            case .succeeded(let remotePath):
                return StoredUpload(fileName: item.fileName, totalBytes: item.totalBytes, outcome: .succeeded, detail: remotePath, finishedAt: finishedAt)
            case .failed(let message):
                // Kept with what it takes to send it again, so a relaunch doesn't take the retry away.
                return StoredUpload(fileName: item.fileName, totalBytes: item.totalBytes, outcome: .failed, detail: message, finishedAt: finishedAt, resume: item.resume)
            case .cancelled:
                return StoredUpload(fileName: item.fileName, totalBytes: item.totalBytes, outcome: .cancelled, detail: "", finishedAt: finishedAt)
            case .waiting, .uploading, .interrupted:
                return nil
            }
        }
    }

    /// The uploads that can be carried on, in the form that is kept between launches: the ones that stopped with part of
    /// them on the server, and the ones still running or waiting, which are interrupted if DropUp quits now.
    /// Running and waiting ones only count once they have what it takes to carry on (`Item.resume`).
    public func storedInterrupted(now: Date = Date()) -> [StoredUpload] {
        items.compactMap { item in
            guard let resume = item.resume else { return nil }
            switch item.state {
            case .waiting, .uploading, .interrupted:
                return StoredUpload(fileName: item.fileName, totalBytes: item.totalBytes, outcome: .interrupted, detail: "", finishedAt: item.finishedAt ?? now, resume: resume)
            case .failed(let message):
                guard item.isResumable else { return nil }
                return StoredUpload(fileName: item.fileName, totalBytes: item.totalBytes, outcome: .failed, detail: message, finishedAt: item.finishedAt ?? now, resume: resume)
            case .succeeded, .cancelled:
                return nil
            }
        }
    }

    /// Adds uploads kept from an earlier launch below what is already listed. They don't light the failure badge:
    /// the user has had their chance to see them.
    public mutating func restore(_ uploads: [StoredUpload]) {
        for stored in uploads.sorted(by: { $0.finishedAt > $1.finishedAt }) {
            var item = Item(id: UUID(), fileName: stored.fileName, totalBytes: stored.totalBytes)
            item.finishedAt = stored.finishedAt
            switch stored.outcome {
            case .succeeded:
                item.bytesSent = stored.totalBytes
                item.state = .succeeded(remotePath: stored.detail)
            case .failed:
                item.state = .failed(message: stored.detail)
                item.resume = stored.resume
            case .cancelled:
                item.state = .cancelled
            case .interrupted:
                // Without what it takes to carry on there is nothing to offer, so it is not listed at all.
                guard stored.resume != nil else { continue }
                item.state = .interrupted
                item.resume = stored.resume
            }
            items.append(item)
        }
    }

    private mutating func removeFinished(where shouldRemove: (Item) -> Bool) {
        items.removeAll { $0.state.isFinished && !$0.isResumable && shouldRemove($0) }
    }
}
