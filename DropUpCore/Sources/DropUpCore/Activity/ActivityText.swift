import Foundation

/// Short phrases for the popover, kept here so they are tested.
public enum ActivityText {
    /// `3 s left`, `2 min left`, `1 h 5 min left`. Nil when the estimate is unknown or absurd.
    public static func timeLeft(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0, seconds < 24 * 3600 else { return nil }
        let total = Int(seconds.rounded(.up))
        if total < 60 { return "\(max(total, 1)) s left" }
        if total < 3600 { return "\(Int((Double(total) / 60).rounded(.up))) min left" }
        let hours = total / 3600
        let minutes = (total % 3600 + 59) / 60
        return minutes == 0 ? "\(hours) h left" : "\(hours) h \(minutes) min left"
    }

    /// `Uploading 2 of 3` for the section header, counting the files of the current batch.
    public static func uploadingHeader(_ activity: UploadActivity) -> String {
        let total = activity.batchTotal
        return "Uploading \(min(activity.batchDone + 1, total)) of \(total)"
    }

    /// `2 uploaded · 1 failed` for the finished section header.
    public static func finishedSummary(_ activity: UploadActivity) -> String {
        var uploaded = 0, failed = 0
        for item in activity.finished {
            switch item.state {
            case .succeeded: uploaded += 1
            case .failed: failed += 1
            default: break
            }
        }
        var parts: [String] = []
        if uploaded > 0 { parts.append("\(uploaded) uploaded") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }
}
