#if canImport(Network)
import DropUpCore
import Foundation
import Network

/// Watches the Mac's network with `NWPathMonitor`, only while an upload waits to try again.
public struct PathNetworkWatch: NetworkWatch {
    public init() {}

    public func waitUntilBack() async {
        let monitor = NWPathMonitor()
        let wait = PathWait()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                wait.set(continuation)
                monitor.pathUpdateHandler = { path in wait.update(usable: path.status == .satisfied) }
                monitor.start(queue: DispatchQueue(label: "app.dropup.network-watch"))
            }
        } onCancel: {
            wait.end()
        }
        monitor.cancel()
    }
}

/// Ends the wait once: at the first update after the one that says how things stand right now that can reach a network
/// (the network came back, or another one took over), or at a cancel. Either can come before the continuation is there.
private final class PathWait: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var ended = false
    private var sawFirst = false

    func set(_ continuation: CheckedContinuation<Void, Never>) {
        let now = lock.withLock {
            if ended { return true }
            self.continuation = continuation
            return false
        }
        if now { continuation.resume() }
    }

    func update(usable: Bool) {
        let first = lock.withLock {
            defer { sawFirst = true }
            return !sawFirst
        }
        if !first, usable { end() }
    }

    func end() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            ended = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}
#endif
