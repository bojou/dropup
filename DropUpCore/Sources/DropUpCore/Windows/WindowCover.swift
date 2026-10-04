import Foundation

/// A window as the window server lists it. `frame` is in screen coordinates with the origin at the top left.
public struct StackedWindow: Sendable, Equatable {
    public var number: Int
    public var ownerProcess: Int32
    public var frame: CGRect

    public init(number: Int, ownerProcess: Int32, frame: CGRect) {
        self.number = number
        self.ownerProcess = ownerProcess
        self.frame = frame
    }
}

/// Whether one of the app's windows is out of sight behind other apps' windows.
///
/// When the window that has the keyboard closes, macOS gives the keyboard to the next of the app's windows and brings it
/// to the front, however many other apps' windows it was buried under. The app uses this to tell which windows should
/// not be handed the keyboard at that moment, so that closing a window brings nothing forward.
public enum WindowCover {
    /// `stack` lists the windows on screen from front to back. A window is covered when a window of another app, above
    /// it, overlaps it, and also when it is not on screen at all (it is on another desktop). An empty stack means the
    /// window list could not be read, and then nothing is called covered.
    public static func isCovered(windowNumber: Int, frame: CGRect, ownProcess: Int32, stack: [StackedWindow]) -> Bool {
        if stack.isEmpty { return false }
        for other in stack {
            if other.number == windowNumber { return false }
            if other.ownerProcess != ownProcess, overlaps(other.frame, frame) { return true }
        }
        return true
    }

    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let shared = a.intersection(b)
        return !shared.isNull && shared.width > 0 && shared.height > 0
    }
}
