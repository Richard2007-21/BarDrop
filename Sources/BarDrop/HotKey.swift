import Carbon

/// Globaler Tastaturkurzbefehl über die Carbon-API (braucht keine Bedienungshilfen-Freigabe).
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    /// false, wenn die Kombination schon von einer anderen App belegt ist
    private(set) var registered = false

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            hotKey.action()
            return noErr
        }, 1, &spec, userData, &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x4244_5250), id: 1) // "BDRP"
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        registered = status == noErr
        if status != noErr {
            // Meist belegt eine andere App dieselbe Tastenkombination
            Log.edge.error("Kurzbefehl nicht verfügbar (\(status, privacy: .public))")
            Diagnostics.shared.failure("hotkey", "Kurzbefehl nicht verfügbar OSStatus=\(status)")
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
