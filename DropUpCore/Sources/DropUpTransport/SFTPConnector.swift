import Citadel
import Crypto
import DropUpCore
import Foundation
import NIOCore
import NIOSSH

/// SFTP over SSH, using Citadel. It signs in with the password, or with a private key file when the config says so
/// (`ServerConfig.loginMethod`); the `password` it is given is then the key's passphrase, empty for a key without one.
///
/// Host keys are trusted on first use: the first key a server presents is remembered in `hostKeys`,
/// and a different key later fails the connection with `UploaderError.hostKeyChanged`.
public struct SFTPConnector: ServerConnector {
    private let hostKeys: any HostKeyStore
    private let connectTimeout: Int64

    public init(hostKeys: any HostKeyStore, connectTimeout: Int64 = 15) {
        self.hostKeys = hostKeys
        self.connectTimeout = connectTimeout
    }

    public func connect(to config: ServerConfig, password: String) async throws -> any ServerSession {
        let validator = TrustOnFirstUseValidator(hostKeys: hostKeys, hostID: config.hostKeyID)
        let username = config.username
        // A key that can't be used is reported before anything is sent to the server.
        let key = config.usesKey ? try SSHKeyLoader.load(username: username, keyFile: config.keyFilePath, passphrase: password) : nil
        let method: SSHAuthenticationMethod = key?.method ?? .passwordBased(username: username, password: password)
        var settings = SSHClientSettings(
            host: config.host,
            port: config.port,
            authenticationMethod: { method },
            hostKeyValidator: .custom(validator)
        )
        settings.connectTimeout = .seconds(connectTimeout)
        // How much the server may send before it waits to hear from us, per channel. The library's default, 128 KB, is
        // what limits downloads: on a link with a 30 ms round trip that is about 2 MB/s however fast the line is.
        settings.protocolOptions = [.maximumPacketSize(Self.receiveWindow)]
        let finalSettings = settings

        let client: SSHClient
        do {
            client = try await withTimeout(seconds: Double(connectTimeout) + 15) {
                try await SSHClient.connect(to: finalSettings)
            }
        } catch {
            if let fingerprint = validator.rejectedFingerprint {
                throw UploaderError.hostKeyChanged(fingerprint: fingerprint)
            }
            throw Self.map(error, key: key)
        }

        do {
            let sftp = try await client.openSFTP()
            return SFTPSession(ssh: client, sftp: sftp)
        } catch {
            try? await client.close()
            throw UploaderError.connectionFailed("The server accepted SSH but doesn't offer SFTP.")
        }
    }

    /// 4 MB. The library uses one number for the window and for the largest packet it takes; servers send packets of a
    /// few dozen KB anyway.
    static let receiveWindow = 4 << 20

    /// `key` is what the login used, when it signed in with a key: a refusal then says the key was refused, not the password.
    static func map(_ error: Error, key: SSHKeyLoader.Loaded? = nil) -> Error {
        switch error {
        case let error as UploaderError:
            return error
        case is CancellationError:
            return error
        case SSHClientError.allAuthenticationOptionsFailed, SSHClientError.unsupportedPasswordAuthentication:
            if let key { return UploaderError.keyRejected(rsa: key.isRSA) }
            return UploaderError.authenticationFailed
        case let error as IOError:
            return UploaderError.connectionFailed(error.localizedDescription)
        case let error as ChannelError:
            if case .connectTimeout = error { return UploaderError.timedOut }
            return UploaderError.connectionFailed(String(describing: error))
        default:
            return UploaderError.connectionFailed(String(describing: error))
        }
    }
}

/// Accepts and remembers the first host key seen for a server, then insists on it.
final class TrustOnFirstUseValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let hostKeys: any HostKeyStore
    private let hostID: String
    private let lock = NSLock()
    private var _rejectedFingerprint: String?

    init(hostKeys: any HostKeyStore, hostID: String) {
        self.hostKeys = hostKeys
        self.hostID = hostID
    }

    /// Set when the server presented a key that doesn't match the trusted one.
    var rejectedFingerprint: String? { lock.withLock { _rejectedFingerprint } }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = String(openSSHPublicKey: hostKey)
        guard let trusted = hostKeys.trustedKey(for: hostID) else {
            hostKeys.trust(presented, for: hostID)
            validationCompletePromise.succeed(())
            return
        }
        if Self.sameKey(trusted, presented) {
            validationCompletePromise.succeed(())
        } else {
            let fingerprint = HostKeyFingerprint.sha256(openSSHKey: presented) ?? "an unknown key"
            lock.withLock { _rejectedFingerprint = fingerprint }
            validationCompletePromise.fail(UploaderError.hostKeyChanged(fingerprint: fingerprint))
        }
    }

    /// Compares key type and key data, ignoring any trailing comment.
    static func sameKey(_ a: String, _ b: String) -> Bool {
        a.split(separator: " ").prefix(2) == b.split(separator: " ").prefix(2)
    }
}

/// An open SFTP channel. Uploads pipeline several write requests, because Citadel waits for
/// each write's status before the next and a single request at a time is slow on high-latency links.
final class SFTPSession: ServerSession, @unchecked Sendable {
    private let ssh: SSHClient
    private let sftp: SFTPClient

    /// SFTP servers commonly cap a single write at 32 KB (OpenSSH accepts up to 256 KB).
    private static let writeSize = 32_000
    /// 64 writes keep 2 MB on the way, about what an OpenSSH server takes before it answers. With 16 (512 KB) an upload
    /// over a 100 ms round trip went no faster than 4.8 MB/s.
    private static let writesInFlight = 64

    /// Requests on one SFTP channel are answered by number, so several files can go at once over the one connection.
    /// A folder of small files is then not held up by the round trips each file needs to open and close.
    var concurrentTransfers: Int { 8 }

    init(ssh: SSHClient, sftp: SFTPClient) {
        self.ssh = ssh
        self.sftp = sftp
    }

    func fileExists(atPath path: String) async throws -> Bool {
        do {
            let attributes = try await sftp.getAttributes(at: path)
            if let permissions = attributes.permissions {
                return permissions & 0o170000 != 0o040000
            }
            return true
        } catch let status as SFTPMessage.Status where status.errorCode == .noSuchFile {
            return false
        } catch {
            throw Self.map(error)
        }
    }

    func fileSize(atPath path: String) async throws -> Int64? {
        do {
            let attributes = try await sftp.getAttributes(at: path)
            if let permissions = attributes.permissions, permissions & 0o170000 == 0o040000 { return nil }
            guard let size = attributes.size.flatMap({ Int64(exactly: $0) }) else { throw UploaderError.cannotResume }
            return size
        } catch let status as SFTPMessage.Status where status.errorCode == .noSuchFile {
            return nil
        } catch let error as UploaderError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    func listDirectories(atPath path: String) async throws -> [String] {
        let listing: [SFTPMessage.Name]
        do {
            listing = try await sftp.listDirectory(atPath: path)
        } catch {
            throw Self.map(error)
        }
        let names = listing.flatMap(\.components).compactMap { entry -> String? in
            let isDirectory: Bool
            if let permissions = entry.attributes.permissions {
                isDirectory = permissions & 0o170000 == 0o040000
            } else {
                isDirectory = entry.longname.hasPrefix("d")
            }
            guard isDirectory, !entry.filename.hasPrefix(".") else { return nil }
            return entry.filename
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func listEntries(atPath path: String) async throws -> [RemoteEntry] {
        let listing: [SFTPMessage.Name]
        do {
            listing = try await sftp.listDirectory(atPath: path)
        } catch {
            throw Self.map(error)
        }
        let entries = listing.flatMap(\.components).compactMap { entry -> RemoteEntry? in
            guard entry.filename != ".", entry.filename != ".." else { return nil }
            let kind: RemoteEntry.Kind
            if let permissions = entry.attributes.permissions {
                switch permissions & 0o170000 {
                case 0o040000: kind = .folder
                case 0o120000: kind = .link
                case 0o100000: kind = .file
                default: return nil // sockets, devices and pipes
                }
            } else if entry.longname.hasPrefix("d") {
                kind = .folder
            } else {
                kind = entry.longname.hasPrefix("l") ? .link : .file
            }
            return RemoteEntry(
                name: entry.filename,
                kind: kind,
                size: kind == .folder ? nil : entry.attributes.size.flatMap { Int64(exactly: $0) },
                modified: entry.attributes.accessModificationTime?.modificationTime
            )
        }
        return RemoteEntry.sorted(entries)
    }

    func upload(fileURL: URL, to remotePath: String, startingAt offset: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        // A server may handle the writes that were in flight when a connection broke out of order, leaving a gap just
        // before the end of the file. Starting a little earlier writes that stretch again.
        let start = max(0, offset - Int64(Self.writeSize * Self.writesInFlight))
        let file: SFTPFile
        do {
            file = try await sftp.openFile(filePath: remotePath, flags: start == 0 ? [.write, .create, .truncate] : [.write, .create])
        } catch {
            throw Self.map(error)
        }

        progress(start)
        do {
            try handle.seek(toOffset: UInt64(start))
            var position = UInt64(start)
            var sent = start
            try await withThrowingTaskGroup(of: Int.self) { group in
                var inFlight = 0
                while true {
                    try Task.checkCancellation()
                    if inFlight == Self.writesInFlight, let written = try await group.next() {
                        inFlight -= 1
                        sent += Int64(written)
                        progress(sent)
                    }
                    guard let chunk = try handle.read(upToCount: Self.writeSize), !chunk.isEmpty else { break }
                    let at = position
                    position += UInt64(chunk.count)
                    inFlight += 1
                    group.addTask {
                        try await file.write(ByteBuffer(bytes: chunk), at: at)
                        return chunk.count
                    }
                }
                while let written = try await group.next() {
                    sent += Int64(written)
                    progress(sent)
                }
            }
            try await file.close()
        } catch {
            try? await file.close()
            throw Self.map(error)
        }
    }

    /// Reads are pipelined like uploads: a single request at a time is slow on high-latency links. 64 reads of 32 KB
    /// keep 2 MB on the way, half the receive window.
    private static let readSize: UInt32 = 32_000
    private static let readsInFlight = 64

    func download(remotePath: String, to fileURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let file: SFTPFile
        do {
            file = try await sftp.openFile(filePath: remotePath, flags: .read)
        } catch {
            throw Self.map(error)
        }

        do {
            let size = try await file.readAttributes().size
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
            }
            let output = try FileHandle(forWritingTo: fileURL)
            defer { try? output.close() }

            var received: Int64 = 0
            try await withThrowingTaskGroup(of: (UInt64, UInt32, ByteBuffer).self) { group in
                var nextOffset: UInt64 = 0
                var followUps: [(offset: UInt64, length: UInt32)] = []
                var inFlight = 0
                var sawEnd = false
                while true {
                    try Task.checkCancellation()
                    while inFlight < Self.readsInFlight, !sawEnd {
                        let request: (offset: UInt64, length: UInt32)
                        if !followUps.isEmpty {
                            request = followUps.removeFirst()
                        } else if let size, nextOffset >= size {
                            break
                        } else {
                            request = (nextOffset, Self.readSize)
                            nextOffset += UInt64(Self.readSize)
                        }
                        group.addTask { (request.offset, request.length, try await file.read(from: request.offset, length: request.length)) }
                        inFlight += 1
                    }
                    guard inFlight > 0, let (offset, length, data) = try await group.next() else { break }
                    inFlight -= 1
                    let count = data.readableBytes
                    if count == 0 {
                        sawEnd = true
                        continue
                    }
                    try output.seek(toOffset: offset)
                    try output.write(contentsOf: Data(data.readableBytesView))
                    received += Int64(count)
                    progress(received)
                    // A server may answer with less than asked. Ask again for the rest.
                    if count < Int(length), size.map({ offset + UInt64(count) < $0 }) ?? true {
                        followUps.append((offset + UInt64(count), length - UInt32(count)))
                    }
                }
            }
            if let size, received < Int64(size) {
                throw UploaderError.connectionFailed("The file ended early on the server.")
            }
            try await file.close()
        } catch {
            try? await file.close()
            throw error is CocoaError ? error : Self.map(error)
        }
    }

    func deleteFile(atPath remotePath: String) async throws {
        do {
            try await sftp.remove(at: remotePath)
        } catch {
            throw Self.map(error)
        }
    }

    func makeDirectory(atPath path: String) async throws {
        do {
            try await sftp.createDirectory(atPath: path)
        } catch {
            throw Self.map(error)
        }
    }

    func removeDirectory(atPath path: String) async throws {
        do {
            try await sftp.rmdir(at: path)
        } catch {
            throw Self.map(error)
        }
    }

    func rename(from oldPath: String, to newPath: String) async throws {
        do {
            try await sftp.rename(at: oldPath, to: newPath)
        } catch {
            throw Self.map(error)
        }
    }

    func close() async {
        // The connection first: on a dead link, politely closing the SFTP channel would wait for an answer that never
        // comes, and a transfer stuck on that link only lets go once the connection is closed under it.
        try? await ssh.close()
        try? await sftp.close()
    }

    private static func map(_ error: Error) -> Error {
        switch error {
        case let status as SFTPMessage.Status:
            switch status.errorCode {
            case .noSuchFile:
                return UploaderError.serverRejected(code: 2, message: "No such file or folder.")
            case .permissionDenied:
                return UploaderError.serverRejected(code: 3, message: "Permission denied.")
            default:
                return UploaderError.serverRejected(code: Int(status.errorCode.rawValue), message: status.message)
            }
        case SFTPError.connectionClosed:
            return UploaderError.connectionFailed("The connection was lost.")
        default:
            return SFTPConnector.map(error)
        }
    }
}

public enum HostKeyFingerprint {
    /// The `SHA256:…` fingerprint that `ssh-keygen -lf` prints for an OpenSSH public key string.
    public static func sha256(openSSHKey: String) -> String? {
        let fields = openSSHKey.split(separator: " ")
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { return nil }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}
