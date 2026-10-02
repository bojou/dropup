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
        sorted(entries, by: .name, ascending: true)
    }

    public enum SortKey: String, Sendable, CaseIterable {
        case name, size, modified
    }

    /// Folders stay on top whichever way the list is sorted. Within folders, and within files, `key` decides the order;
    /// ties and missing values fall back to the name, so the order never jumps around between reloads.
    public static func sorted(_ entries: [RemoteEntry], by key: SortKey, ascending: Bool) -> [RemoteEntry] {
        entries.sorted { a, b in
            let aFolder = a.kind == .folder
            if aFolder != (b.kind == .folder) { return aFolder }
            let byName = a.name.localizedStandardCompare(b.name)
            let primary: ComparisonResult
            switch key {
            case .name:
                primary = byName
            case .size:
                primary = compare(a.size ?? -1, b.size ?? -1)
            case .modified:
                primary = compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
            }
            switch primary {
            case .orderedAscending: return ascending
            case .orderedDescending: return !ascending
            case .orderedSame: return byName == .orderedAscending
            }
        }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}
