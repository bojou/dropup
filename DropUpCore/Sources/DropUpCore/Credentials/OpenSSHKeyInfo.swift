import Foundation

/// What can be read of an OpenSSH private key file without opening the key: which kind of key it holds and whether a
/// passphrase protects it. Both are written in the clear at the start of the file, so DropUp can say what is wrong
/// (this kind of key isn't supported, a passphrase is needed) before it tries anything.
///
/// Only the container is read. The key material is handed to the SSH library as it is.
public struct OpenSSHKeyInfo: Equatable, Sendable {
    /// The key's algorithm as OpenSSH names it: `ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-nistp256`, `ssh-dss`, and so on.
    public let algorithm: String
    /// Whether the private part is encrypted, which takes a passphrase.
    public let isEncrypted: Bool
    /// The cipher the private part is encrypted with, as OpenSSH names it: `aes256-ctr`, or `none`.
    public let cipher: String
    /// How the passphrase becomes the cipher's key: `bcrypt`, or `none`.
    public let keyDerivation: String
    /// The same file with its line endings and surrounding blanks made plain, for a reader that is strict about them.
    public let canonicalText: String

    /// Why a file isn't an OpenSSH private key.
    public enum Problem: Error, Equatable, Sendable {
        /// Not an OpenSSH private key: another format (PEM, PuTTY), a public key, or something else entirely.
        case notAnOpenSSHKey
        /// Starts like one but is cut off or damaged.
        case damaged
    }

    /// The most a key file can hold. Real ones are a few kilobytes; anything far bigger isn't a key.
    public static let maximumSize = 128 * 1024

    private static let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let end = "-----END OPENSSH PRIVATE KEY-----"
    private static let magic = Array("openssh-key-v1\0".utf8)

    public static func read(_ text: String) throws -> OpenSSHKeyInfo {
        guard text.utf8.count <= maximumSize else { throw Problem.notAnOpenSSHKey }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // A byte order mark in front of the first line is not part of it.
        guard let first = lines.first?.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")), first == begin else {
            throw Problem.notAnOpenSSHKey
        }
        guard lines.last == end, lines.count >= 3 else { throw Problem.damaged }
        let payload = lines.dropFirst().dropLast().joined()
        guard let data = Data(base64Encoded: payload) else { throw Problem.damaged }

        var reader = Reader(bytes: [UInt8](data))
        guard reader.take(magic.count) == magic else { throw Problem.damaged }
        guard let cipherBytes = reader.string(), let kdfBytes = reader.string(), reader.string() != nil,
              reader.integer() == 1, var publicKey = reader.string().map({ Reader(bytes: $0) }),
              let algorithmBytes = publicKey.string(), let algorithm = String(bytes: algorithmBytes, encoding: .utf8)
        else { throw Problem.damaged }

        let cipher = String(decoding: cipherBytes, as: UTF8.self)
        let canonical = ([begin] + lines.dropFirst().dropLast() + [end]).joined(separator: "\n") + "\n"
        return OpenSSHKeyInfo(
            algorithm: algorithm,
            isEncrypted: cipher != "none",
            cipher: cipher,
            keyDerivation: String(decoding: kdfBytes, as: UTF8.self),
            canonicalText: canonical
        )
    }

    /// How the kind of key is shown to a person: `ed25519`, `RSA`, `ECDSA`, `DSA`, or the algorithm's own name.
    public var kindName: String {
        switch algorithm {
        case "ssh-ed25519": "ed25519"
        case "ssh-rsa": "RSA"
        case "ssh-dss": "DSA"
        case _ where algorithm.hasPrefix("ecdsa-"): "ECDSA"
        case _ where algorithm.hasPrefix("sk-ssh-ed25519"): "security key (ed25519-sk)"
        case _ where algorithm.hasPrefix("sk-ecdsa"): "security key (ecdsa-sk)"
        default: algorithm
        }
    }

    public var isEd25519: Bool { algorithm == "ssh-ed25519" }
    public var isRSA: Bool { algorithm == "ssh-rsa" }
    /// The kinds DropUp can sign in with.
    public var isSupported: Bool { isEd25519 || isRSA }
    /// Whether DropUp can open the key's encryption. A key without a passphrase always can be.
    public var isEncryptionSupported: Bool {
        !isEncrypted || (Self.supportedCiphers.contains(cipher) && keyDerivation == "bcrypt")
    }

    /// What `ssh-keygen` uses by default, and the only ciphers the SSH library opens.
    private static let supportedCiphers: Set<String> = ["aes128-ctr", "aes256-ctr"]

    /// Reads the length-prefixed pieces of the container, never beyond the end.
    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, bytes.count - offset >= count else { return nil }
            defer { offset += count }
            return Array(bytes[offset ..< offset + count])
        }

        mutating func integer() -> UInt32? {
            guard let four = take(4) else { return nil }
            return four.reduce(0) { $0 << 8 | UInt32($1) }
        }

        mutating func string() -> [UInt8]? {
            guard let length = integer() else { return nil }
            return take(Int(length))
        }
    }
}
