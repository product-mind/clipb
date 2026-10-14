import Carbon.HIToolbox

/// A global Cmd+Shift+<key> hotkey via the Carbon hotkey API.
final class HotKey {
    var handler: (() -> Void)?

    private let keyCode: Int
    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    /// Cmd+Shift+V: the history popup.
    static func history() -> HotKey { HotKey(keyCode: kVK_ANSI_V, id: 1) }
    /// Cmd+Shift+X: cut the selection and pick a pipe.
    static func pipe() -> HotKey { HotKey(keyCode: kVK_ANSI_X, id: 2) }

    private init(keyCode: Int, id: UInt32) {
        self.keyCode = keyCode
        self.id = id
    }

    func register() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                var pressed = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressed
                )
                // Every handler sees every hotkey; pass the others' on.
                guard pressed.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
                hotKey.handler?()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        let hotKeyID = EventHotKeyID(signature: fourCC("CLPB"), id: id)
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        devLog("hotkey \(id): register status=\(status)")
    }
}

private func fourCC(_ s: String) -> OSType {
    var result: OSType = 0
    for byte in s.utf8 {
        result = (result << 8) + OSType(byte)
    }
    return result
}
