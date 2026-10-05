import Foundation

/// A window of the app to put back behind a window of another app: `window` goes directly below `below`.
public struct StackRestore: Sendable, Equatable {
    public var window: Int
    public var below: Int

    public init(window: Int, below: Int) {
        self.window = window
        self.below = below
    }
}

/// Keeps the app's windows where they were in the stack of all windows on screen.
///
/// Opening, reopening or closing a window must bring forward only the window that was asked for. macOS has several ways
/// of bringing others forward on its own (activating the app, handing the keyboard to the next window, and more), so
/// the app does not rely on stopping each of them: it notes the stack before it acts and puts back whatever moved in
/// front of a window of another app that was in front of it.
public enum WindowStack {
    /// The windows of this app that were behind a window of another app before and are in front of it now, none of
    /// them in `allowed` (the ones that were asked for), each with the window it goes directly below. `before` and
    /// `now` list the windows on screen from front to back. The list is in the order to apply: backmost first, so
    /// that windows put behind the same window keep their order among themselves.
    ///
    /// A window of another app that is gone from `now` is no longer a reason to keep anything behind it. A window that
    /// is in only one of the two lists, or that was in front of everything of another app to begin with, is left alone.
    public static func restores(before: [StackedWindow], now: [StackedWindow], ownProcess: Int32, allowed: Set<Int>) -> [StackRestore] {
        var positionNow: [Int: Int] = [:]
        for (index, window) in now.enumerated() { positionNow[window.number] = index }

        var result: [(position: Int, restore: StackRestore)] = []
        for (index, window) in before.enumerated() where window.ownerProcess == ownProcess && !allowed.contains(window.number) {
            guard let own = positionNow[window.number] else { continue }
            // The windows of other apps that were in front of it, and are still on screen.
            let coverers = before[..<index].filter { $0.ownerProcess != ownProcess && positionNow[$0.number] != nil }
            guard !coverers.isEmpty else { continue }
            // It has moved if any of them is no longer in front of it.
            guard coverers.contains(where: { positionNow[$0.number]! > own }) else { continue }
            // Directly behind the one of them that is furthest back now: then it is behind all of them again.
            let furthestBack = coverers.max { positionNow[$0.number]! < positionNow[$1.number]! }!
            result.append((index, StackRestore(window: window.number, below: furthestBack.number)))
        }
        return result.sorted { $0.position > $1.position }.map(\.restore)
    }
}
