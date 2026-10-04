import Foundation
import Testing
@testable import DropUpCore

/// Reading what a private key file says about itself: its kind, and whether it is encrypted.
/// The files are built here, byte by byte, in the layout `ssh-keygen` writes: no real key is kept in the repository.
struct OpenSSHKeyInfoTests {
    private func string(_ bytes: [UInt8]) -> [UInt8] {
        var length = UInt32(bytes.count).bigEndian
        return withUnsafeBytes(of: &length) { Array($0) } + bytes
    }

    private func string(_ text: String) -> [UInt8] { string(Array(text.utf8)) }

    /// An `openssh-key-v1` container with the given pieces. The key material is filler.
    private func container(
        algorithm: String = "ssh-ed25519", cipher: String = "none", kdf: String = "none", keys: UInt32 = 1
    ) -> [UInt8] {
        var count = keys.bigEndian
        let publicKey = string(string(algorithm) + string(Array(repeating: 7, count: 32)))
        return Array("openssh-key-v1\0".utf8) + string(cipher) + string(kdf) + string([])
            + withUnsafeBytes(of: &count) { Array($0) } + publicKey + string(Array(repeating: 9, count: 96))
    }

    private func file(
        _ bytes: [UInt8], newline: String = "\n", begin: String = "-----BEGIN OPENSSH PRIVATE KEY-----",
        end: String = "-----END OPENSSH PRIVATE KEY-----"
    ) -> String {
        let base64 = Data(bytes).base64EncodedString()
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let next = base64.index(index, offsetBy: 70, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<next]))
            index = next
        }
        return ([begin] + lines + [end]).joined(separator: newline) + newline
    }

    // MARK: Kinds

    @Test(arguments: [
        ("ssh-ed25519", "ed25519", true), ("ssh-rsa", "RSA", true), ("ssh-dss", "DSA", false),
        ("ecdsa-sha2-nistp256", "ECDSA", false), ("ecdsa-sha2-nistp384", "ECDSA", false), ("ecdsa-sha2-nistp521", "ECDSA", false),
        ("sk-ssh-ed25519@openssh.com", "security key (ed25519-sk)", false), ("sk-ecdsa-sha2-nistp256@openssh.com", "security key (ecdsa-sk)", false),
    ])
    func readsTheKind(algorithm: String, name: String, supported: Bool) throws {
        let info = try OpenSSHKeyInfo.read(file(container(algorithm: algorithm)))

        #expect(info.algorithm == algorithm)
        #expect(info.kindName == name)
        #expect(info.isSupported == supported)
        #expect(!info.isEncrypted)
        #expect(info.isEncryptionSupported)
    }

    @Test func anUnknownAlgorithmIsNamedAsItIs() throws {
        let info = try OpenSSHKeyInfo.read(file(container(algorithm: "ssh-future")))
        #expect(info.kindName == "ssh-future")
        #expect(!info.isSupported)
    }

    // MARK: Encryption

    @Test(arguments: ["aes256-ctr", "aes128-ctr"])
    func aPassphraseWithACipherThatCanBeOpened(cipher: String) throws {
        let info = try OpenSSHKeyInfo.read(file(container(cipher: cipher, kdf: "bcrypt")))

        #expect(info.isEncrypted)
        #expect(info.cipher == cipher)
        #expect(info.keyDerivation == "bcrypt")
        #expect(info.isEncryptionSupported)
    }

    @Test(arguments: ["aes256-gcm@openssh.com", "chacha20-poly1305@openssh.com", "aes256-cbc"])
    func aCipherThatCannotBeOpenedIsToldApartFromAWrongPassphrase(cipher: String) throws {
        let info = try OpenSSHKeyInfo.read(file(container(cipher: cipher, kdf: "bcrypt")))

        #expect(info.isEncrypted)
        #expect(!info.isEncryptionSupported)
    }

    @Test func aKeyDerivationOtherThanBcryptCannotBeOpened() throws {
        let info = try OpenSSHKeyInfo.read(file(container(cipher: "aes256-ctr", kdf: "scrypt")))
        #expect(!info.isEncryptionSupported)
    }

    // MARK: Files as they come

    @Test func windowsLineEndingsAndSurroundingBlanksAreMadePlain() throws {
        let plain = try OpenSSHKeyInfo.read(file(container()))
        let windows = try OpenSSHKeyInfo.read("\u{FEFF}" + file(container(), newline: "\r\n") + "\r\n\r\n")
        let padded = try OpenSSHKeyInfo.read("\n\n  " + file(container()) + "  \n\n")

        #expect(windows.canonicalText == plain.canonicalText)
        #expect(padded.canonicalText == plain.canonicalText)
        #expect(plain.canonicalText.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        #expect(plain.canonicalText.hasSuffix("-----END OPENSSH PRIVATE KEY-----\n"))
        #expect(!plain.canonicalText.contains("\r"))
    }

    // MARK: What is not a key

    @Test(arguments: [
        "",
        "hello\n",
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f me@host\n",
        "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\n-----END RSA PRIVATE KEY-----\n",
        "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkq\n-----END PRIVATE KEY-----\n",
        "-----BEGIN EC PRIVATE KEY-----\nMHcCAQEE\n-----END EC PRIVATE KEY-----\n",
        "PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\n",
        "-----BEGIN SSH2 ENCRYPTED PRIVATE KEY-----\nabcd\n-----END SSH2 ENCRYPTED PRIVATE KEY-----\n",
    ])
    func otherFormatsAreNotAnOpenSSHKey(text: String) {
        #expect(throws: OpenSSHKeyInfo.Problem.notAnOpenSSHKey) { try OpenSSHKeyInfo.read(text) }
    }

    @Test func aKeyThatIsCutOffIsDamaged() {
        let whole = file(container())
        let cut = String(whole.prefix(whole.count / 2))
        #expect(throws: OpenSSHKeyInfo.Problem.damaged) { try OpenSSHKeyInfo.read(cut) }
        #expect(throws: OpenSSHKeyInfo.Problem.damaged) { try OpenSSHKeyInfo.read("-----BEGIN OPENSSH PRIVATE KEY-----\n") }
    }

    @Test func aContainerWithNothingInsideIsDamagedNotACrash() {
        #expect(throws: OpenSSHKeyInfo.Problem.damaged) { try OpenSSHKeyInfo.read(file([])) }
        #expect(throws: OpenSSHKeyInfo.Problem.damaged) { try OpenSSHKeyInfo.read(file(Array("openssh-key-v1\0".utf8))) }
        #expect(throws: OpenSSHKeyInfo.Problem.damaged) { try OpenSSHKeyInfo.read(file(Array("something else entirely".utf8))) }
        #expect(throws: OpenSSHKeyInfo.Problem.damaged) { try OpenSSHKeyInfo.read("-----BEGIN OPENSSH PRIVATE KEY-----\n!!!!\n-----END OPENSSH PRIVATE KEY-----\n") }
    }

    @Test func aLengthThatPointsPastTheEndIsDamagedNotACrash() {
        var bytes = container()
        // The cipher name claims to be four gigabytes long.
        let at = Array("openssh-key-v1\0".utf8).count
        bytes.replaceSubrange(at..<at + 4, with: [0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: OpenSSHKeyInfo.Problem.damaged) { try OpenSSHKeyInfo.read(file(bytes)) }
    }

    @Test func moreThanOneKeyInAFileIsNotOneDropUpCanUse() {
        #expect(throws: OpenSSHKeyInfo.Problem.damaged) { try OpenSSHKeyInfo.read(file(container(keys: 2))) }
        #expect(throws: OpenSSHKeyInfo.Problem.damaged) { try OpenSSHKeyInfo.read(file(container(keys: 0))) }
    }

    @Test func aFileFarBiggerThanAnyKeyIsNotRead() {
        let huge = String(repeating: "A", count: OpenSSHKeyInfo.maximumSize + 1)
        #expect(throws: OpenSSHKeyInfo.Problem.notAnOpenSSHKey) { try OpenSSHKeyInfo.read(huge) }
    }
}
