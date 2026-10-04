import Foundation

/// What pressing a shortcut comes to, decided from what the Mac reports.
public enum ShortcutOutcome: Equatable, Sendable {
    /// Upload these files and folders as they are.
    case upload([URL])
    /// The clipboard held something that isn't a file (an image, some text): write it to a file of this name, then
    /// upload that.
    case stage(name: String, data: Data)
    /// Nothing to upload. Say why.
    case notice(String)
}

/// The words for the notices a shortcut can end in.
public enum ShortcutNotice {
    public static let noServer = "Set up your server first."
    public static let nothingSelected = "Nothing selected in Finder"
    public static let finderNotInFront = "Finder isn't in front. Select the files there first."
    public static let finderNotAllowed = "DropUp isn't allowed to read the Finder selection. Allow it in System Settings > Privacy & Security > Automation."
    public static let finderFailed = "Couldn't read the Finder selection."
    public static let clipboardEmpty = "The clipboard has nothing to upload."
    public static let clipboardNotSaved = "Couldn't save the clipboard as a file."
    public static let noScreenshot = "No screenshot from the last 10 minutes"
    public static let screenshotFolderUnreadable = "DropUp can't read the screenshot folder. Allow it in System Settings > Privacy & Security > Files & Folders."
}
