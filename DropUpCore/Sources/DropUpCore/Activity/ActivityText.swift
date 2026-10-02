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

    /// What the list shows for an upload: its name, or with names hidden a plain word that says what happened to it.
    public static func displayName(of item: UploadActivity.Item, hidingNames: Bool) -> String {
        guard hidingNames else { return item.fileName }
        let thing = item.isFolder ? "folder" : "file"
        if case .succeeded = item.state { return "Uploaded \(thing)" }
        return thing.capitalized
    }

    /// What to tell the user when a batch finishes, or nil when there is nothing to say (everything was cancelled).
    /// With `hidingNames` the notice says how many went through, but not what they were called.
    public static func completionNotice(_ activity: UploadActivity, hidingNames: Bool = false) -> (title: String, body: String)? {
        var uploaded: [UploadActivity.Item] = []
        var failed: [UploadActivity.Item] = []
        for item in activity.batchItems {
            switch item.state {
            case .succeeded: uploaded.append(item)
            case .failed: failed.append(item)
            default: break
            }
        }
        func names(_ items: [UploadActivity.Item], more: Bool = false) -> String {
            hidingNames ? "" : items.prefix(3).map(\.fileName).joined(separator: ", ") + (more ? "…" : "")
        }
        switch (uploaded.count, failed.count) {
        case (0, 0):
            return nil
        case (1, 0):
            return ("Uploaded", hidingNames ? displayName(of: uploaded[0], hidingNames: true) : uploaded[0].fileName)
        case (let count, 0):
            return ("Uploaded \(count) files", names(uploaded, more: count > 3))
        case (0, 1):
            if case .failed(let message) = failed[0].state {
                return ("Upload failed", hidingNames ? message : "\(failed[0].fileName): \(message)")
            }
            return nil
        case (0, let count):
            return ("\(count) uploads failed", names(failed))
        case (let ok, let bad):
            return ("\(ok) uploaded, \(bad) failed", names(failed))
        }
    }
}
