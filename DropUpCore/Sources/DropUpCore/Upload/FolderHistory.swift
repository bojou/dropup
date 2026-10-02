import Foundation

/// The folders a Browse window has shown, for Back and Forward buttons that work like Finder's.
public struct FolderHistory: Sendable, Equatable {
    public private(set) var current: String
    private var back: [String] = []
    private var forward: [String] = []

    /// How many folders Back can step through.
    private static let limit = 100

    /// - Parameter includingParents: lets Back climb out of the starting folder, one enclosing folder at a time,
    ///   and Forward come down again. A window that opens in a deep folder would otherwise have nowhere to go back to.
    public init(start: String, includingParents: Bool = false) {
        current = RemotePath.normalizedDirectory(start)
        if includingParents {
            back = RemotePath.trail(to: current).dropLast().map(\.path)
        }
    }

    public var previous: String? { back.last }
    public var next: String? { forward.last }
    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// Moves to a folder the user chose. Whatever Forward could have returned to is dropped, as in Finder.
    /// Visiting the folder already shown changes nothing.
    public mutating func visit(_ path: String) {
        let path = RemotePath.normalizedDirectory(path)
        guard path != current else { return }
        back.append(current)
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        forward.removeAll()
        current = path
    }

    public mutating func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(current)
        current = previous
    }

    public mutating func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(current)
        current = next
    }
}
