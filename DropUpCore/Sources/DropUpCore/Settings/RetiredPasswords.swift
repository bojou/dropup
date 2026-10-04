import Foundation

/// The Keychain passwords of servers that were replaced in Settings.
///
/// Switching to another server doesn't move the uploads that were dropped for the old one: waiting ones, a running
/// one that has to reconnect, and paused, interrupted or failed ones that are resumed or retried all go on to the
/// server they were dropped for, and removing an interrupted one has to log in there to take the half-sent file away.
/// So the old password stays in the Keychain for as long as one of them needs it, and goes when none does.
public struct RetiredPasswords: Equatable, Sendable {
    /// The credential keys of servers that were replaced and whose password is still kept. Saved by the caller, so the
    /// list survives a quit.
    public private(set) var keys: Set<String>

    public init(keys: Set<String> = []) {
        self.keys = keys
    }

    /// Notes that `previous`, the server that was saved, has been replaced by `current`. Replacing a server with
    /// itself, or having none before, retires nothing.
    public mutating func retire(_ previous: ServerConfig?, replacedBy current: ServerConfig) {
        guard let previous, previous.credentialKey != current.credentialKey else { return }
        keys.insert(previous.credentialKey)
    }

    /// Deletes the password of every retired server that nothing needs, and returns whether `keys` changed, which is
    /// when it has to be saved again.
    ///
    /// A server that was switched back to is the saved one again and stops being retired, with its password kept. One
    /// that the Keychain won't give up now stays retired, to be tried again at the next call.
    /// - Parameters:
    ///   - current: the saved server.
    ///   - items: the uploads listed. Those that can run again (`UploadActivity.Item.canRunAgain`) need the password of
    ///     the server they were dropped for.
    @discardableResult
    public mutating func settle(current: ServerConfig?, items: [UploadActivity.Item], credentials: any CredentialStore) -> Bool {
        guard !keys.isEmpty else { return false }
        let needed = Set(items.filter(\.canRunAgain).compactMap { $0.resume?.config?.credentialKey })
        let plan = Self.plan(retired: keys, current: current?.credentialKey, needed: needed)
        var remaining = plan.stillRetired
        for key in plan.remove {
            do { try credentials.removePassword(for: key) } catch { remaining.insert(key) }
        }
        let changed = remaining != keys
        keys = remaining
        return changed
    }

    /// What to do with the retired keys, as sets: the pure part of `settle`.
    public struct Plan: Equatable, Sendable {
        /// The keys whose passwords can be deleted now.
        public var remove: Set<String>
        /// The keys still to come back to later.
        public var stillRetired: Set<String>
    }

    public static func plan(retired: Set<String>, current: String?, needed: Set<String>) -> Plan {
        var remove: Set<String> = []
        var still: Set<String> = []
        for key in retired where key != current {
            if needed.contains(key) { still.insert(key) } else { remove.insert(key) }
        }
        return Plan(remove: remove, stillRetired: still)
    }
}
