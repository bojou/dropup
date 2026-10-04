import Foundation

/// A file in the screenshot folder.
public struct ScreenshotCandidate: Equatable, Sendable {
    public var url: URL
    public var created: Date
    /// What macOS recorded about it when it was saved (its "is a screen capture" mark), or nil when there is none.
    public var isScreenCapture: Bool?

    public init(url: URL, created: Date, isScreenCapture: Bool?) {
        self.url = url
        self.created = created
        self.isScreenCapture = isScreenCapture
    }
}

/// Upload Latest Screenshot.
public enum ScreenshotPicker {
    /// A screenshot older than this is not "the latest": it is more likely a forgotten one.
    public static let window: TimeInterval = 600
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif"]

    /// The newest screenshot made in the last `window` seconds. macOS's own mark decides what a screenshot is, which
    /// also works when the names are in another language; where a file has no mark, the name starting with
    /// "Screenshot" does.
    public static func latest(in candidates: [ScreenshotCandidate], now: Date) -> ScreenshotCandidate? {
        candidates
            .filter { isScreenshot($0) && now.timeIntervalSince($0.created) <= window && $0.created.timeIntervalSince(now) <= 60 }
            .max { $0.created < $1.created }
    }

    public static func plan(_ candidates: [ScreenshotCandidate], now: Date) -> ShortcutOutcome {
        guard let latest = latest(in: candidates, now: now) else { return .notice(ShortcutNotice.noScreenshot) }
        return .upload([latest.url])
    }

    private static func isScreenshot(_ candidate: ScreenshotCandidate) -> Bool {
        guard imageExtensions.contains(candidate.url.pathExtension.lowercased()) else { return false }
        if let mark = candidate.isScreenCapture { return mark }
        return candidate.url.lastPathComponent.hasPrefix("Screenshot")
    }
}
