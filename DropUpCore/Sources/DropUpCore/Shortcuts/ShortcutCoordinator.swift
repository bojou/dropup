import Foundation

public enum HotKeyFailure: Error, Equatable, Sendable {
    /// Another app has this key.
    case takenByAnotherApp
    case unavailable
}

public struct HotKeyToken: Hashable, Sendable {
    public let id: Int
    public init(id: Int) { self.id = id }
}

/// Whatever turns a key combination into a call, system wide.
@MainActor
public protocol HotKeyRegistrar: AnyObject {
    func register(_ combo: KeyCombo, handler: @escaping @MainActor () -> Void) -> Result<HotKeyToken, HotKeyFailure>
    func unregister(_ token: HotKeyToken)
}

/// Keeps the registered keys in step with the settings: an action that is on has its key, one that is off has none,
/// and a key that was changed is moved. Registering is all there is to it: nothing runs while no key is pressed.
@MainActor
public final class ShortcutCoordinator {
    private let registrar: any HotKeyRegistrar
    private let perform: @MainActor (ShortcutAction) -> Void
    private var registered: [ShortcutAction: (combo: KeyCombo, token: HotKeyToken)] = [:]
    private var wanted: [(action: ShortcutAction, combo: KeyCombo)] = []
    private var isPaused = false

    /// The actions whose key could not be registered, and why.
    public private(set) var failures: [ShortcutAction: HotKeyFailure] = [:]

    public init(registrar: any HotKeyRegistrar, perform: @escaping @MainActor (ShortcutAction) -> Void) {
        self.registrar = registrar
        self.perform = perform
    }

    /// Makes the registered keys match `settings`.
    public func apply(_ settings: ShortcutSettings) {
        wanted = settings.active
        reconcile()
    }

    /// Lets go of every key while the recorder listens, so pressing one there records it instead of running it.
    public func pause() {
        isPaused = true
        reconcile()
    }

    public func resume() {
        isPaused = false
        reconcile()
    }

    private func reconcile() {
        let target: [ShortcutAction: KeyCombo] = isPaused ? [:] : Dictionary(uniqueKeysWithValues: wanted.map { ($0.action, $0.combo) })
        for (action, entry) in registered where target[action] != entry.combo {
            registrar.unregister(entry.token)
            registered[action] = nil
        }
        failures = failures.filter { target[$0.key] != nil }
        for action in ShortcutAction.allCases {
            guard let combo = target[action], registered[action] == nil else { continue }
            let result = registrar.register(combo) { [weak self] in self?.perform(action) }
            switch result {
            case .success(let token):
                registered[action] = (combo, token)
                failures[action] = nil
            case .failure(let failure):
                failures[action] = failure
            }
        }
    }
}
