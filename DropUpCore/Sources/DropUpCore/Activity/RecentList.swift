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
    }

    public var fileName: String
    public var totalBytes: Int64
    public var outcome: Outcome
    /// The remote path of an upload that went through, or the message of one that failed.
    public var detail: String
    public var finishedAt: Date

    public init(fileName: String, totalBytes: Int64, outcome: Outcome, detail: String, finishedAt: Date) {
        self.fileName = fileName
        self.totalBytes = totalBytes
        self.outcome = outcome
        self.detail = detail
        self.finishedAt = finishedAt
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
            trim(toRecent: policy.limit)
        } else {
            removeFinished { _ in true }
        }
        // The icon's failure mark is not touched here: it belongs to the upload that failed, not to the list.
    }

    /// When the next finished upload is due to be removed under `lifetime`, or nil if none ever will be.
    public func nextRecentExpiry(lifetime: TimeInterval?) -> Date? {
        guard let lifetime else { return nil }
        return items.compactMap { $0.state.isFinished ? $0.finishedAt?.addingTimeInterval(lifetime) : nil }.min()
    }

    /// The finished uploads, newest first, in the form that is kept between launches.
    public var storedFinished: [StoredUpload] {
        items.compactMap { item in
            guard let finishedAt = item.finishedAt else { return nil }
            switch item.state {
            case .succeeded(let remotePath):
                return StoredUpload(fileName: item.fileName, totalBytes: item.totalBytes, outcome: .succeeded, detail: remotePath, finishedAt: finishedAt)
            case .failed(let message):
                return StoredUpload(fileName: item.fileName, totalBytes: item.totalBytes, outcome: .failed, detail: message, finishedAt: finishedAt)
            case .cancelled:
                return StoredUpload(fileName: item.fileName, totalBytes: item.totalBytes, outcome: .cancelled, detail: "", finishedAt: finishedAt)
            case .waiting, .uploading:
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
            case .cancelled:
                item.state = .cancelled
            }
            items.append(item)
        }
    }

    private mutating func removeFinished(where shouldRemove: (Item) -> Bool) {
        items.removeAll { $0.state.isFinished && shouldRemove($0) }
    }
}
