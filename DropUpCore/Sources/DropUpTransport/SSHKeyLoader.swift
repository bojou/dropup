import Citadel
import Crypto
import DropUpCore
import Foundation

/// Opens an OpenSSH private key file to sign in with.
///
/// The file stays where it is and is read each time a connection is made; the key is never copied, saved or logged.
/// Everything that can be wrong with it is told apart, so the message says which: the file can't be read, it isn't a
/// key DropUp can read, it is a kind DropUp can't sign in with, it needs a passphrase, or the passphrase is wrong.
enum SSHKeyLoader {
    struct Loaded {
        let method: SSHAuthenticationMethod
        let isRSA: Bool
    }

    static func load(username: String, keyFile path: String?, passphrase: String) throws -> Loaded {
        let info = try read(keyFile: path)
        guard info.isSupported else { throw UploaderError.keyTypeUnsupported(info.kindName) }
        guard info.isEncryptionSupported else { throw UploaderError.keyCipherUnsupported(info.cipher) }
        if info.isEncrypted, passphrase.isEmpty { throw UploaderError.keyNeedsPassphrase }
        // A key that has no passphrase is opened with none, whatever else is saved.
        let decryptionKey = info.isEncrypted ? Data(passphrase.utf8) : nil
        do {
            if info.isEd25519 {
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: info.canonicalText, decryptionKey: decryptionKey)
                return Loaded(method: .ed25519(username: username, privateKey: key), isRSA: false)
            }
            let key = try Insecure.RSA.PrivateKey(sshRsa: info.canonicalText, decryptionKey: decryptionKey)
            return Loaded(method: .rsa(username: username, privateKey: key), isRSA: true)
        } catch {
            // The file was a well-formed key, so one that won't open with its passphrase has the wrong one.
            throw info.isEncrypted ? UploaderError.keyPassphraseWrong : UploaderError.keyFormatUnsupported
        }
    }

    /// The kind of key in the file and whether it is encrypted, without opening it.
    static func read(keyFile path: String?) throws -> OpenSSHKeyInfo {
        var isFolder: ObjCBool = false
        guard let path, !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue,
              let handle = FileHandle(forReadingAtPath: path)
        else { throw UploaderError.keyFileUnreadable }
        defer { try? handle.close() }
        // One byte more than a key can be, to tell a huge file from one that just fits, without reading the whole thing.
        guard let data = try? handle.read(upToCount: OpenSSHKeyInfo.maximumSize + 1) else {
            throw UploaderError.keyFileUnreadable
        }
        guard data.count <= OpenSSHKeyInfo.maximumSize, let text = String(data: data, encoding: .utf8) else {
            throw UploaderError.keyFormatUnsupported
        }
        do {
            return try OpenSSHKeyInfo.read(text)
        } catch {
            throw UploaderError.keyFormatUnsupported
        }
    }
}
