import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum Paste {
    /// Prompts for Accessibility permission on first run.
    static func ensureAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Simulates Cmd+V in the frontmost application. Returns false without
    /// Accessibility permission — the value is on the clipboard either way.
    @discardableResult
    static func simulateCmdV() -> Bool {
        simulateCommand(kVK_ANSI_V)
    }

    /// Simulates Cmd+X in the frontmost application. False without Accessibility permission.
    static func simulateCmdX() -> Bool {
        simulateCommand(kVK_ANSI_X)
    }

    /// Calls `done` once Shift and `key` are up, or at `deadline`. A Cmd+<key> sent
    /// while they are still held reaches the app as Cmd+Shift+<key> and does nothing.
    static func afterHotKeyReleased(key: Int, until deadline: Date, done: @escaping () -> Void) {
        let shiftDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskShift)
        let keyDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key))
        if (!shiftDown && !keyDown) || Date() >= deadline { return done() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            afterHotKeyReleased(key: key, until: deadline, done: done)
        }
    }

    /// UTF-16 units per synthetic key event: the most a CGEvent carries.
    static let typingChunk = 20

    /// The text as key-event payloads: at most `typingChunk` units each, never
    /// splitting a surrogate pair. Line breaks become spaces: typed, a newline
    /// is Return, which sends the message in Slack and runs it in a terminal.
    static func typingChunks(_ text: String) -> [[UInt16]] {
        let flat = text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let units = Array(flat.utf16)
        var chunks: [[UInt16]] = []
        var start = 0
        while start < units.count {
            var end = min(start + typingChunk, units.count)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            chunks.append(Array(units[start..<end]))
            start = end
        }
        return chunks
    }

    /// Types `text` into the focused field as synthetic keystrokes, never
    /// touching the clipboard (SPEC §2.13). Independent of the keyboard
    /// layout. False without Accessibility permission.
    static func type(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        // A private source: modifiers still physically held (Cmd from the
        // hold) don't merge into the typed characters.
        let source = CGEventSource(stateID: .privateState)
        for var chunk in typingChunks(text) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return false }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.setIntegerValueField(.eventSourceUserData, value: PasteKeyTap.syntheticMarker)
            up.setIntegerValueField(.eventSourceUserData, value: PasteKeyTap.syntheticMarker)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    /// Calls `done` once Command, Option, Control and Shift are all up, or at
    /// `deadline`: typed characters must not arrive as shortcuts.
    static func afterModifiersReleased(until deadline: Date, done: @escaping () -> Void) {
        let held = CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        if held.isEmpty || Date() >= deadline { return done() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            afterModifiersReleased(until: deadline, done: done)
        }
    }

    private static func simulateCommand(_ key: Int) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(key)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // PasteKeyTap lets ClipB's own Cmd+V through instead of holding it back.
        down.setIntegerValueField(.eventSourceUserData, value: PasteKeyTap.syntheticMarker)
        up.setIntegerValueField(.eventSourceUserData, value: PasteKeyTap.syntheticMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
