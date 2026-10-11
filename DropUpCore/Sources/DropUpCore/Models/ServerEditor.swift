import Foundation

/// The Connection settings while they are open: the form, and the server as it was last saved. There is no Save
/// button. Each finished edit (a field left or Return pressed in it, a choice made, another tab, the window closed) is
/// saved when it leaves the form complete and different from what is saved. An edit only counts as finished once the
/// person moves on, never at each key, so a half-typed host is never saved.
public struct ServerEditor: Sendable {
    public var draft: ServerDraft
    /// The server as last saved; nil before there is one.
    public private(set) var saved: ServerConfig?
    private var savedSecret: String

    /// The form for the saved server. `secret` is its password, or its key's passphrase.
    public init(saved config: ServerConfig?, secret: String) {
        draft = config.map { ServerDraft(config: $0, password: secret) } ?? ServerDraft()
        saved = config
        savedSecret = secret
    }

    /// Whether the form holds something that is not saved, complete or not.
    public var hasChanges: Bool { draft.config != saved || draft.secret != savedSecret }

    /// What to save now that an edit is finished: nil when the form is as saved, or when it is not complete. An
    /// incomplete form then shows what is missing or wrong if `showingProblems`, and keeps it until it is saved.
    public mutating func finishEdit(showingProblems: Bool = true) -> (config: ServerConfig, secret: String)? {
        guard hasChanges else { return nil }
        guard draft.isValid else {
            if showingProblems { draft.showProblems = true }
            return nil
        }
        return (draft.config, draft.secret)
    }

    /// Notes that `config` and `secret`, from `finishEdit`, were saved. The next mistake shows once its edit is finished.
    public mutating func didSave(_ config: ServerConfig, secret: String) {
        saved = config
        savedSecret = secret
        draft.showProblems = false
    }

    /// Takes in a server saved somewhere else while the form is open, such as a folder picked in Change Folder. A form
    /// with edits of its own keeps them; one without shows the new server, so a later edit doesn't put the old one back.
    public mutating func savedElsewhere(_ config: ServerConfig?, secret: String) {
        guard config != saved else { return }
        if !hasChanges {
            draft = config.map { ServerDraft(config: $0, password: secret) } ?? ServerDraft()
        }
        saved = config
        savedSecret = secret
    }
}
