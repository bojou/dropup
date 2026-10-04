import Foundation

/// The pasteboard, as far as Upload from Clipboard needs it. The image and the text are read only when asked for.
public protocol ClipboardReading {
    /// Files and folders copied in Finder.
    func fileURLs() -> [URL]
    /// An image on the clipboard, as PNG data.
    func imagePNG() -> Data?
    func text() -> String?
}

/// Upload from Clipboard.
public enum ClipboardPlanner {
    /// Files copied in Finder come first (several are allowed, folders too), then an image, then plain text.
    public static func plan(_ clipboard: some ClipboardReading, now: Date, timeZone: TimeZone = .current) -> ShortcutOutcome {
        let files = clipboard.fileURLs()
        if !files.isEmpty { return .upload(files) }
        if let png = clipboard.imagePNG(), !png.isEmpty {
            return .stage(name: fileName(extension: "png", at: now, in: timeZone), data: png)
        }
        if let text = clipboard.text(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .stage(name: fileName(extension: "txt", at: now, in: timeZone), data: Data(text.utf8))
        }
        return .notice(ShortcutNotice.clipboardEmpty)
    }

    /// `Clipboard 2026-10-04 09.36.12.png`: dots in the time, because a colon can't be in a file name on a Mac.
    public static func fileName(extension fileExtension: String, at date: Date, in timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Clipboard \(formatter.string(from: date)).\(fileExtension)"
    }
}
