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
    /// The server it was going to, with the login but not the password. It is the one saved when the upload was
    /// dropped, and the upload keeps it. Nil only for a row saved by a version before that.
    public var config: ServerConfig?
    /// Where it went on the server, under the name it ended up with (`photo-1.png`, say): the file, or the folder.
    public var remotePath: String?
    public var totalBytes: Int64
    /// A file's modified date when it was sent, to tell later whether it was changed. Nil for a folder.
    public var sourceModified: Date?
    /// The server holds the file that is being sent (for a folder, the one named by `currentFile`), and it is
    /// this upload's own. Until then `remotePath` may be a name that was free, or a file that was there before.
    public var created: Bool
    /// A folder: how many files, counted in the order they are sent, were done when this was noted. Several files go
    /// at once and finish in any order, so this counts the files up to the first one that wasn't done.
    public var finishedFiles: Int
    /// A folder: a stamp of the names and sizes of its files (`LocalTree.fingerprint`).
    public var fingerprint: String?
    /// A folder: the first of the files being sent, as its path inside the folder.
    public var currentFile: String?
    /// A folder: how many files, counted in the order they are sent, had been started. Those from `finishedFiles` up to
    /// here are done, except the ones in `sendingFiles`. Nil in a note from before several files went at once: then
    /// only `currentFile` was being sent.
    public var startedFiles: Int?
    /// A folder: every file being sent when this was noted, in the order they are sent.
    public var sendingFiles: [String]?
    /// A folder: the ones of `sendingFiles` the server holds part of, which are this upload's own.
    public var partialFiles: [String]?

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
        currentFile: String? = nil,
        startedFiles: Int? = nil,
        sendingFiles: [String]? = nil,
        partialFiles: [String]? = nil
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
        self.startedFiles = startedFiles
        self.sendingFiles = sendingFiles
        self.partialFiles = partialFiles
    }

    /// The name the row shows: the file's, or the folder's with a `/` after it.
    public var fileName: String {
        URL(fileURLWithPath: sourcePath).lastPathComponent + (isFolder ? "/" : "")
    }

    public var sourceURL: URL { URL(fileURLWithPath: sourcePath, isDirectory: isFolder) }

    /// Where the file that may be half sent is on the server, or nil when this upload has not made one. A folder can
    /// have several: this is the first of `partialPaths`.
    public var partialPath: String? { partialPaths.first }

    /// Where the files that may be half sent are on the server: the file, or for a folder each of the files it was in
    /// the middle of that the server holds. Empty when this upload has not made one.
    public var partialPaths: [String] {
        guard let remotePath else { return [] }
        guard isFolder else { return created ? [remotePath] : [] }
        return heldFiles.map { remotePath == "/" ? "/" + $0 : remotePath + "/" + $0 }
    }

    /// A folder: the files being sent, from a note of either kind.
    var inFlightFiles: [String] {
        sendingFiles ?? currentFile.map { [$0] } ?? []
    }

    /// A folder: the files being sent that the server holds part of, from a note of either kind.
    var heldFiles: [String] {
        if let partialFiles { return partialFiles }
        return created ? currentFile.map { [$0] } ?? [] : []
    }

    /// Whether anything of this upload is on the server already: a file that is partly or fully there.
    public var hasProgress: Bool {
        created || finishedFiles > 0 || !heldFiles.isEmpty || (startedFiles ?? 0) > inFlightFiles.count + finishedFiles
    }

    /// Whether a file on this Mac is the one that was sent: the same size, and the same modified date to the millisecond.
    func matches(size: Int64, modified: Date?) -> Bool {
        guard size == totalBytes else { return false }
        guard let sourceModified, let modified else { return true }
        return abs(sourceModified.timeIntervalSince(modified)) < 0.001
    }
}
