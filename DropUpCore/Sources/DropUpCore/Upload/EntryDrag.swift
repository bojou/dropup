import Foundation

/// What one row of the Browse window carries while it is dragged: which server and folder it came from, and what it is.
///
/// It travels as a plain string so SwiftUI needs no custom file type. The prefix lets a drop tell it from any other text,
/// and the server key keeps a drag from one server from being dropped on a window showing another.
public struct EntryDrag: Codable, Sendable, Equatable {
    public var server: String
    public var folder: String
    public var name: String
    public var isFolder: Bool

    public init(server: String, folder: String, name: String, isFolder: Bool) {
        self.server = server
        self.folder = RemotePath.normalizedDirectory(folder)
        self.name = name
        self.isFolder = isFolder
    }

    private static let prefix = "dropup-entry:"

    public var text: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return Self.prefix + String(decoding: data, as: UTF8.self)
    }

    /// The drag a string stands for, or nil for any other text.
    public init?(text: String) {
        guard text.hasPrefix(Self.prefix),
              let decoded = try? JSONDecoder().decode(Self.self, from: Data(text.dropFirst(Self.prefix.count).utf8))
        else { return nil }
        self = decoded
    }

    /// The entry as the listing shows it, for the move and delete commands, which only need the name and the kind.
    public var entry: RemoteEntry {
        RemoteEntry(name: name, kind: isFolder ? .folder : .file)
    }
}
