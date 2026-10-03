#if canImport(Network)
import DropUpCore
import Foundation
import Network

/// Opens plain TCP connections with Network.framework.
public struct NetworkByteStreamOpener: ByteStreamOpener {
    private let connectTimeout: Double

    public init(connectTimeout: Double = 15) {
        self.connectTimeout = connectTimeout
    }

    public func open(host: String, port: Int) async throws -> any ByteStream {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
            throw UploaderError.connectionFailed("Port \(port) is not valid.")
        }
        let stream = NetworkByteStream(connection: NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp))
        do {
            try await withTimeout(seconds: connectTimeout) { try await stream.start() }
        } catch {
            stream.cancel()
            throw error
        }
        return stream
    }
}

/// A `ByteStream` over an `NWConnection`. Cancelling the calling task cancels the connection.
final class NetworkByteStream: ByteStream, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "app.dropup.network")

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() async throws {
        let connection = self.connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = ResumeOnce(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        once.resume(with: .success(()))
                    case .waiting(let error), .failed(let error):
                        // `.waiting` means unreachable right now (DNS failure, refused, no route).
                        // Fail fast instead of waiting for the network to change.
                        once.resume(with: .failure(UploaderError.connectionFailed(Self.describe(error))))
                    case .cancelled:
                        once.resume(with: .failure(CancellationError()))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func send(_ data: Data) async throws {
        let connection = self.connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: UploaderError.connectionFailed(Self.describe(error)))
                    } else {
                        continuation.resume()
                    }
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func receive(maxLength: Int) async throws -> Data {
        let connection = self.connection
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { content, _, isComplete, error in
                    if let content, !content.isEmpty {
                        continuation.resume(returning: content)
                    } else if let error {
                        if case .posix(let code) = error, code == .ENODATA {
                            // Network.framework sometimes reports the peer's clean close as
                            // "No message available on STREAM" instead of a completed receive.
                            continuation.resume(returning: Data())
                        } else {
                            continuation.resume(throwing: UploaderError.connectionFailed(Self.describe(error)))
                        }
                    } else {
                        // No data and no error: the peer finished sending (isComplete).
                        _ = isComplete
                        continuation.resume(returning: Data())
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func close() async {
        if connection.state == .ready {
            let connection = self.connection
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // An empty final message flushes queued data and half-closes (FIN).
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    continuation.resume()
                })
            }
        }
        connection.cancel()
    }

    func cancel() {
        connection.cancel()
    }

    func abort() {
        connection.cancel()
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code) where code == .ECONNREFUSED:
            return "The server refused the connection. Check the host and port."
        case .posix(let code) where code == .ETIMEDOUT:
            return "The connection timed out."
        case .dns:
            return "The server name could not be found."
        default:
            return error.localizedDescription
        }
    }
}

/// Resumes a continuation at most once, since `NWConnection` can report several terminal states.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<T, Error>) {
        let continuation: CheckedContinuation<T, Error>? = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}
#endif
