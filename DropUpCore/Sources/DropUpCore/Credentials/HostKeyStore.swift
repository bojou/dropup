import Foundation

/// Remembers SFTP server host keys (trust on first use).
/// Keys are OpenSSH public key strings (`ssh-ed25519 AAAA…`), keyed by `host:port`.
public protocol HostKeyStore: Sendable {
    func trustedKey(for hostID: String) -> String?
    func trust(_ key: String, for hostID: String)
    func forget(hostID: String)
}

extension ServerConfig {
    /// Identifies the server in a `HostKeyStore`.
    public var hostKeyID: String { "\(host.lowercased()):\(port)" }
}

/// Production store. Host keys are public, so `UserDefaults` is fine.
public final class UserDefaultsHostKeyStore: HostKeyStore, @unchecked Sendable {
    // UserDefaults is documented as thread-safe; the lock keeps read-modify-write atomic.
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "knownHostKeys") {
        self.defaults = defaults
        self.key = key
    }

    public func trustedKey(for hostID: String) -> String? {
        lock.withLock { all()[hostID] }
    }

    public func trust(_ hostKey: String, for hostID: String) {
        lock.withLock {
            var keys = all()
            keys[hostID] = hostKey
            defaults.set(keys, forKey: key)
        }
    }

    public func forget(hostID: String) {
        lock.withLock {
            var keys = all()
            keys.removeValue(forKey: hostID)
            defaults.set(keys, forKey: key)
        }
    }

    private func all() -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
