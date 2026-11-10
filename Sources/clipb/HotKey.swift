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
    /// Cmd+Shift+C: screencapture to a file, path to clipboard.
    static func shot() -> HotKey { HotKey(keyCode: kVK_ANSI_C, id: 3) }
    /// Cmd+Shift+I: edit the selection and paste the result back.
    static func editor() -> HotKey { HotKey(keyCode: kVK_ANSI_I, id: 4) }

    /// The key code for one ASCII letter, case-insensitively; nil for anything
    /// else. A pipe's `hotkey` is always Cmd+Shift+<letter>, so a letter is a key.
    static func keyCode(forLetter letter: String) -> Int? {
        // ASCII-only fold: `lowercased()` is locale-sensitive and would lose "I".
        let lower = Pipes.asciiLowercased(letter)
        guard lower.count == 1, let scalar = lower.unicodeScalars.first,
              (0x61...0x7A).contains(scalar.value) else { return nil }
        return letterKeyCodes[Int(scalar.value - 0x61)]
    }

    /// Built-in chords use ids 1-4; the pipes' chords start at 100.
    init(keyCode: Int, id: Int) {
        self.keyCode = keyCode
        self.id = UInt32(id)
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

/// The ANSI key codes for `a`-`z`, in alphabetical order: index 0 is `a`.
private let letterKeyCodes: [Int] = [
    kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
    kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
    kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
    kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z,
]

private func fourCC(_ s: String) -> OSType {
    var result: OSType = 0
    for byte in s.utf8 {
        result = (result << 8) + OSType(byte)
    }
    return result
}
