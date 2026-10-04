import Carbon.HIToolbox
import DropUpCore

/// Registers system-wide keys with Carbon's `RegisterEventHotKey`. It needs no permission, and nothing runs in the
/// background: the system calls in only when a registered key is pressed, even while DropUp has no window.
@MainActor
final class CarbonHotKeys: HotKeyRegistrar {
    /// Marks DropUp's keys among the system's: "DRUP".
    private static let signature: OSType = 0x4452_5550
    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 0
    private var eventHandler: EventHandlerRef?

    func register(_ combo: KeyCombo, handler: @escaping @MainActor () -> Void) -> Result<HotKeyToken, HotKeyFailure> {
        guard installEventHandler() else { return .failure(.unavailable) }
        nextID += 1
        let id = EventHotKeyID(signature: Self.signature, id: nextID)
        var created: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(combo.keyCode), Self.carbonModifiers(combo.modifiers), id, GetEventDispatcherTarget(), 0, &created)
        guard status == noErr, let reference = created else {
            // eventHotKeyExistsErr: another app, or another key of this one, already has this combination.
            return .failure(status == -9878 ? .takenByAnotherApp : .unavailable)
        }
        references[id.id] = reference
        handlers[id.id] = handler
        return .success(HotKeyToken(id: Int(id.id)))
    }

    func unregister(_ token: HotKeyToken) {
        let id = UInt32(token.id)
        if let reference = references.removeValue(forKey: id) { UnregisterEventHotKey(reference) }
        handlers[id] = nil
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installEventHandler() -> Bool {
        if eventHandler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetEventDispatcherTarget(), hotKeyPressed, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler
        )
        return status == noErr
    }

    private static func carbonModifiers(_ modifiers: KeyModifiers) -> UInt32 {
        var result = 0
        if modifiers.contains(.control) { result |= controlKey }
        if modifiers.contains(.option) { result |= optionKey }
        if modifiers.contains(.shift) { result |= shiftKey }
        if modifiers.contains(.command) { result |= cmdKey }
        return UInt32(result)
    }
}

/// The system's call when a registered key is pressed. It only works out which key it was and hands over to the main queue.
private func hotKeyPressed(_ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr else { return status }
    let keys = Unmanaged<CarbonHotKeys>.fromOpaque(userData).takeUnretainedValue()
    let id = hotKeyID.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated { keys.fire(id) }
    }
    return noErr
}
