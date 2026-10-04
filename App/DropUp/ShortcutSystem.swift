import AppKit
import ApplicationServices
import DropUpCore

// What the shortcuts read from the Mac. The decisions about it are in DropUpCore and tested there; these only ask the
// system, so they can be seen working only on a Mac.

/// The clipboard.
struct SystemClipboard: ClipboardReading {
    private var board: NSPasteboard { .general }

    /// Files and folders copied in Finder.
    func fileURLs() -> [URL] {
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        // A file reference (file:///.file/id=...) as the path it stands for.
        return urls.map { ($0 as NSURL).filePathURL ?? $0 }
    }

    /// A picture copied from a screenshot, an app or a web page, as PNG.
    func imagePNG() -> Data? {
        if let png = board.data(forType: .png) { return png }
        guard let tiff = board.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    func text() -> String? {
        board.string(forType: .string)
    }
}

/// What macOS lets DropUp do with Finder.
enum AutomationAccess: Equatable {
    case unknown
    case granted
    /// The user said no, or took it back in System Settings.
    case denied
    /// macOS has not asked yet.
    case notAsked

    /// Asks macOS. With `asking`, it shows the system's "DropUp wants to control Finder" prompt when it hasn't been
    /// answered yet, and doesn't return until the user has answered, so call it away from the main thread.
    static func current(asking: Bool) -> AutomationAccess {
        let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        let status = AEDeterminePermissionToAutomateTarget(finder.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), asking)
        switch status {
        case 0: return .granted // noErr
        case -1743: return .denied // errAEEventNotPermitted
        case -1744: return .notAsked // errAEEventWouldRequireUserConsent
        default: return .unknown // for example Finder isn't running
        }
    }
}

/// The files and folders selected in Finder, asked of Finder itself.
struct FinderSelection: FinderSelectionReading {
    var finderIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }

    func selection() throws -> [URL] {
        // The timeout keeps a stuck Finder from holding DropUp for the two minutes AppleScript waits by default.
        let source = """
        with timeout of 4 seconds
            tell application id "com.apple.finder"
                set picked to selection as alias list
                set found to {}
                repeat with item_ in picked
                    set end of found to POSIX path of item_
                end repeat
                return found
            end tell
        end timeout
        """
        guard let script = NSAppleScript(source: source) else { throw FinderSelectionError.failed("The script could not be made.") }
        var problem: NSDictionary?
        let result = script.executeAndReturnError(&problem)
        if let problem {
            // -1743 is errAEEventNotPermitted: the Automation permission was refused.
            if (problem[NSAppleScript.errorNumber] as? Int) == -1743 { throw FinderSelectionError.notAllowed }
            throw FinderSelectionError.failed(problem[NSAppleScript.errorMessage] as? String ?? "Unknown error")
        }
        guard result.numberOfItems > 0 else { return [] }
        return (1...result.numberOfItems).compactMap { index in
            result.atIndex(index)?.stringValue.map { URL(fileURLWithPath: $0) }
        }
    }
}

/// The folder macOS saves screenshots in, and what is in it.
enum ScreenshotFolder {
    /// The folder from the Screenshot settings (⇧⌘5 > Options), or the Desktop where none was chosen.
    static func location() -> URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")
        guard let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !path.isEmpty else { return desktop }
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue ? folder : desktop
    }

    /// Whether macOS asks before letting an app look in this folder (Desktop, Documents and Downloads, and what is in them).
    static func needsPermission(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        return ["Desktop", "Documents", "Downloads"].contains { name in
            let protected = (NSHomeDirectory() as NSString).appendingPathComponent(name)
            return path == protected || path.hasPrefix(protected + "/")
        }
    }

    /// The recent image files in the folder with what macOS recorded about each. Throws when the folder can't be read,
    /// which is what a refused Files & Folders permission looks like. Reads nothing but the file list and the
    /// creation dates, and the screenshot mark of the files that could still be "the latest".
    static func candidates(in folder: URL, now: Date = Date()) throws -> [ScreenshotCandidate] {
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        return files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true, let created = values.creationDate else { return nil }
            // Only what the picker could still choose, so a Desktop full of files costs a listing and not a read of each.
            guard abs(now.timeIntervalSince(created)) <= ScreenshotPicker.window + 60 else { return nil }
            return ScreenshotCandidate(url: url, created: created, isScreenCapture: screenCaptureMark(of: url))
        }
    }

    /// macOS marks every screenshot it saves with an extended attribute, whatever language its name is in. Nil when
    /// the file has none (a screenshot made by another tool, or a file that was copied without it).
    private static func screenCaptureMark(of url: URL) -> Bool? {
        let name = "com.apple.metadata:kMDItemIsScreenCapture"
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        guard read == size, let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        return (value as? NSNumber)?.boolValue
    }
}
