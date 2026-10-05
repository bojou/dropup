import DropUpCore
import Foundation
#if canImport(Network)
import DropUpTransport
#endif
#if canImport(Glibc)
import Glibc
#endif

/// The opener the integration tests use. On macOS it is the real `NetworkByteStreamOpener`, so CI
/// exercises the shipping FTP transport. Linux has no Network.framework, so there a small blocking-socket
/// opener stands in; it lets the FTP protocol code be checked against a real server from any machine.
/// `connectTimeout` replaces the macOS opener's own time limit for making a connection.
func makeByteStreamOpener(connectTimeout: Double? = nil) -> any ByteStreamOpener {
    #if canImport(Network)
    connectTimeout.map { NetworkByteStreamOpener(connectTimeout: $0) } ?? NetworkByteStreamOpener()
    #else
    PosixByteStreamOpener()
    #endif
}

#if !canImport(Network)
struct PosixByteStreamOpener: ByteStreamOpener {
    func open(host: String, port: Int) async throws -> any ByteStream {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else {
                    continuation.resume(throwing: UploaderError.connectionFailed("The server name could not be found."))
                    return
                }
                defer { freeaddrinfo(result) }
                let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
                guard fd >= 0, connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
                    if fd >= 0 { Glibc.close(fd) }
                    continuation.resume(throwing: UploaderError.connectionFailed("The server refused the connection."))
                    return
                }
                continuation.resume(returning: PosixByteStream(fd: fd))
            }
        }
    }
}

final class PosixByteStream: ByteStream, @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "posix-stream")

    init(fd: Int32) { self.fd = fd }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                var offset = 0
                while offset < data.count {
                    let written = data[offset...].withUnsafeBytes { Glibc.send(self.fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
                    if written <= 0 {
                        continuation.resume(throwing: UploaderError.connectionFailed("send failed"))
                        return
                    }
                    offset += written
                }
                continuation.resume()
            }
        }
    }

    func receive(maxLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                var buffer = [UInt8](repeating: 0, count: maxLength)
                let count = recv(self.fd, &buffer, maxLength, 0)
                if count < 0 {
                    continuation.resume(throwing: UploaderError.connectionFailed("receive failed"))
                } else {
                    continuation.resume(returning: Data(buffer[..<count]))
                }
            }
        }
    }

    private let lock = NSLock()
    private var isClosed = false

    func close() async {
        let first = lock.withLock { () -> Bool in
            defer { isClosed = true }
            return !isClosed
        }
        guard first else { return }
        shutdown(fd, Int32(SHUT_WR))
        Glibc.close(fd)
    }

    /// Ends both directions at once, which also wakes a send or receive that another thread is blocked in.
    func abort() {
        let first = lock.withLock { () -> Bool in
            defer { isClosed = true }
            return !isClosed
        }
        guard first else { return }
        shutdown(fd, Int32(SHUT_RDWR))
        Glibc.close(fd)
    }
}
#endif
