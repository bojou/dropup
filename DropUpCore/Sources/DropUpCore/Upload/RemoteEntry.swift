import Foundation

/// One item inside a folder on the server, as the Browse window shows it.
public struct RemoteEntry: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case folder
        case file
        /// A symbolic link. The listing can't say what it points to, so the browser tries it as a folder.
        case link
    }

    public var name: String
    public var kind: Kind
    /// Bytes, for files and links. Nil when the server didn't say.
    public var size: Int64?
    public var modified: Date?

    public var id: String { name }
    public var isHidden: Bool { name.hasPrefix(".") }

    public init(name: String, kind: Kind, size: Int64? = nil, modified: Date? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
    }

    /// Folders first, then files and links, each group in Finder order (so `file2` comes before `file10`).
    public static func sorted(_ entries: [RemoteEntry]) -> [RemoteEntry] {
        entries.sorted { a, b in
            let aFolder = a.kind == .folder
            if aFolder != (b.kind == .folder) { return aFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
