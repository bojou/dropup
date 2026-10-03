import Foundation

/// What it takes to carry on an upload that was interrupted: where it comes from, where it was going and how far it got.
///
/// It is kept with the upload's row in Recent, so it survives quitting DropUp, a crash and a restart. What the server
/// holds is the truth about how much arrived, so no byte count is kept here: a resumed upload asks the server.
public struct ResumePoint: Codable, Equatable, Sendable {
    /// The file or folder on this Mac.
    public var sourcePath: String
    public var isFolder: Bool
    /// The folder a drop in Browse sent it to. Nil for the saved upload folder.
    public var directory: String?
    /// The server it was going to, with the login but not the password. Nil until the upload started.
    public var config: ServerConfig?
    /// Where it went on the server, under the name it ended up with (`photo-1.png`, say): the file, or the folder.
    public var remotePath: String?
    public var totalBytes: Int64
    /// A file's modified date when it was sent, to tell later whether it was changed. Nil for a folder.
    public var sourceModified: Date?
    /// The server holds the file that is being sent (for a folder, the one named by `currentFile`), and it is
    /// this upload's own. Until then `remotePath` may be a name that was free, or a file that was there before.
    public var created: Bool
    /// A folder: how many files, counted in the order they are sent, were done when this was noted.
    public var finishedFiles: Int
    /// A folder: a stamp of the names and sizes of its files (`LocalTree.fingerprint`).
    public var fingerprint: String?
    /// A folder: the file being sent, as its path inside the folder.
    public var currentFile: String?

    public init(
        sourcePath: String,
        isFolder: Bool,
        directory: String? = nil,
        config: ServerConfig? = nil,
        remotePath: String? = nil,
        totalBytes: Int64 = 0,
        sourceModified: Date? = nil,
        created: Bool = false,
        finishedFiles: Int = 0,
        fingerprint: String? = nil,
        currentFile: String? = nil
    ) {
        self.sourcePath = sourcePath
        self.isFolder = isFolder
        self.directory = directory
        self.config = config
        self.remotePath = remotePath
        self.totalBytes = totalBytes
        self.sourceModified = sourceModified
        self.created = created
        self.finishedFiles = finishedFiles
        self.fingerprint = fingerprint
        self.currentFile = currentFile
    }

    /// The name the row shows: the file's, or the folder's with a `/` after it.
    public var fileName: String {
        URL(fileURLWithPath: sourcePath).lastPathComponent + (isFolder ? "/" : "")
    }

    public var sourceURL: URL { URL(fileURLWithPath: sourcePath, isDirectory: isFolder) }

    /// Where the file that may be half sent is on the server, or nil when this upload has not made one.
    public var partialPath: String? {
        guard created, let remotePath else { return nil }
        guard isFolder else { return remotePath }
        guard let currentFile else { return nil }
        return remotePath == "/" ? "/" + currentFile : remotePath + "/" + currentFile
    }

    /// Whether anything of this upload is on the server already: a file that is partly or fully there.
    public var hasProgress: Bool { created || finishedFiles > 0 }

    /// Whether a file on this Mac is the one that was sent: the same size, and the same modified date to the millisecond.
    func matches(size: Int64, modified: Date?) -> Bool {
        guard size == totalBytes else { return false }
        guard let sourceModified, let modified else { return true }
        return abs(sourceModified.timeIntervalSince(modified)) < 0.001
    }
}
