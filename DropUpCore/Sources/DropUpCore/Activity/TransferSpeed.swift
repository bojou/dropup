import Foundation

/// How fast a transfer goes: bytes per second over the last few seconds, worked out from the running total of bytes
/// moved, noted as it grows. Uploads measure their whole batch with it, each download its own file or folder.
public struct TransferSpeed: Equatable, Sendable {
    private struct Sample: Equatable, Sendable {
        let time: Date
        let bytes: Int64
    }

    private var samples: [Sample] = []
    private static let window: TimeInterval = 3

    public init() {}

    /// Notes that `bytes` have been moved in all by `now`.
    public mutating func record(_ bytes: Int64, at now: Date) {
        if let last = samples.last, last.bytes == bytes, now.timeIntervalSince(last.time) < 0.2 { return }
        samples.append(Sample(time: now, bytes: bytes))
        samples.removeAll { now.timeIntervalSince($0.time) > Self.window * 2 }
    }

    /// Bytes per second over the last few seconds, or nil before there is enough data or when nothing has moved lately.
    public func bytesPerSecond(now: Date) -> Double? {
        let recent = samples.filter { now.timeIntervalSince($0.time) <= Self.window }
        guard let first = recent.first, let last = recent.last, last.time > first.time else { return nil }
        let rate = Double(last.bytes - first.bytes) / last.time.timeIntervalSince(first.time)
        return rate > 0 ? rate : nil
    }

    /// Seconds until `bytesLeft` more have moved at the current speed.
    public func secondsRemaining(_ bytesLeft: Int64, now: Date) -> Double? {
        guard let speed = bytesPerSecond(now: now) else { return nil }
        return Double(max(bytesLeft, 0)) / speed
    }
}
