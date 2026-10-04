import Foundation

public enum FinderSelectionError: Error, Equatable, Sendable {
    /// macOS has not allowed DropUp to control Finder.
    case notAllowed
    case failed(String)
}

/// Finder's selection, as the system reports it.
public protocol FinderSelectionReading {
    var finderIsFrontmost: Bool { get }
    func selection() throws -> [URL]
}

/// Quick Upload: the files and folders selected in Finder.
public enum QuickUploadPlanner {
    /// Only while Finder is in front, so a selection left over from earlier is never uploaded by mistake.
    public static func plan(_ finder: some FinderSelectionReading) -> ShortcutOutcome {
        guard finder.finderIsFrontmost else { return .notice(ShortcutNotice.finderNotInFront) }
        do {
            let items = try finder.selection()
            return items.isEmpty ? .notice(ShortcutNotice.nothingSelected) : .upload(items)
        } catch FinderSelectionError.notAllowed {
            return .notice(ShortcutNotice.finderNotAllowed)
        } catch {
            return .notice(ShortcutNotice.finderFailed)
        }
    }
}
