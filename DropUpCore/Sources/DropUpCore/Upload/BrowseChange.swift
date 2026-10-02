import Foundation

/// One item that changed place. `from` is where it was and `to` where it is now, both full paths.
public struct ItemMove: Sendable, Equatable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }

    var flipped: ItemMove { ItemMove(from: to, to: from) }
}

/// What a copy made, so it can be taken back or made again.
public struct CopyRecord: Sendable, Equatable {
    /// The items that were copied, as they were listed.
    public var sources: [RemoteEntry]
    /// The folder they were copied from and the folder they went into.
    public var from: String
    public var to: String
    /// Every file and folder the copy created, in the order it created them.
    public var files: [String]
    public var folders: [String]

    public init(sources: [RemoteEntry], from: String, to: String, files: [String], folders: [String]) {
        self.sources = sources
        self.from = from
        self.to = to
        self.files = files
        self.folders = folders
    }
}

/// A change to the server that Undo can take back and Redo can do again.
/// Deleting is not here: nothing that is deleted on a server can be brought back.
public enum BrowseChange: Sendable, Equatable {
    case madeFolder(String)
    case renamed(ItemMove)
    case moved([ItemMove])
    case copied(CopyRecord)

    /// What to call it in a tooltip: "Undo Move “a.txt”".
    public var title: String {
        switch self {
        case .madeFolder:
            "New Folder"
        case .renamed:
            "Rename"
        case .moved(let moves):
            moves.count == 1 ? "Move “\(RemotePath.lastComponent(of: moves[0].to))”" : "Move \(moves.count) Items"
        case .copied(let record):
            record.sources.count == 1 ? "Copy “\(record.sources[0].name)”" : "Copy \(record.sources.count) Items"
        }
    }

    /// The folder where the change is to be seen once it has been done, or done again.
    public var folderWhenDone: String {
        switch self {
        case .madeFolder(let path): RemotePath.parent(of: path)
        case .renamed(let move): RemotePath.parent(of: move.to)
        case .moved(let moves): RemotePath.parent(of: moves.first?.to ?? "/")
        case .copied(let record): record.to
        }
    }

    /// The folder where the change is to be seen once it has been taken back.
    public var folderWhenUndone: String {
        switch self {
        case .madeFolder(let path): RemotePath.parent(of: path)
        case .renamed(let move): RemotePath.parent(of: move.from)
        case .moved(let moves): RemotePath.parent(of: moves.first?.from ?? "/")
        case .copied(let record): record.to
        }
    }
}

extension RemotePath {
    /// The name of the last step of a path: `/a/b.txt` → `b.txt`.
    public static func lastComponent(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? "/"
    }
}
