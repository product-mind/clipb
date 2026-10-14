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

    /// Calls `done` once Shift and X are up, or at `deadline`. A Cmd+X sent while
    /// they are still held reaches the app as Cmd+Shift+X and cuts nothing.
    static func afterPipeHotKeyReleased(until deadline: Date, done: @escaping () -> Void) {
        let shiftDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskShift)
        let xDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_ANSI_X))
        if (!shiftDown && !xDown) || Date() >= deadline { return done() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            afterPipeHotKeyReleased(until: deadline, done: done)
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
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
