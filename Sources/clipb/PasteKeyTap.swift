import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Holds back plain Cmd+V so a hold can dictate (SPEC §2.13). Without it, the
/// app would paste the old clipboard at key-down and again on every key
/// repeat, before anything was said. ClipB replays a tap as a synthetic
/// Cmd+V, so a plain paste lands at key-up instead of key-down.
///
/// The tap runs on its own thread so a busy main thread never stalls typing:
/// it only decides "plain Cmd+V or not" and forwards to main. Every other
/// key, ClipB's own synthetic events (`syntheticMarker`) and Cmd+Shift+V pass
/// untouched. If the callback ever stalls, macOS disables the tap and keys
/// flow again; it is re-enabled on the next event.
///
/// It also takes the 🎤 key (F5 on a Mac keyboard, key code 176) for
/// dictation on/off: both its key-down and key-up are swallowed, so the app
/// in front never sees it. Special keys macOS sends as system-defined events
/// are only logged by code (dev log), never touched.
final class PasteKeyTap {
    /// Stamped into `eventSourceUserData` of every key event ClipB posts.
    static let syntheticMarker: Int64 = 0x434C_5042 // "CLPB"
    /// The 🎤 Dictation key: plain F5 on Apple keyboards since 2021.
    static let dictationKeyCode: Int64 = 0xB0
    /// NX_SYSDEFINED: media, brightness and other special keys.
    private static let systemDefined = CGEventType(rawValue: 14)!

    /// Main thread.
    var onDown: ((_ isRepeat: Bool) -> Void)?
    /// Main thread.
    var onUp: (() -> Void)?
    /// Main thread: the 🎤 key went down (not a key repeat).
    var onDictationKey: (() -> Void)?

    private var tap: CFMachPort?
    /// Tap thread only: a held-back key-down whose key-up must go too.
    private var holding = false

    /// False without Accessibility; Cmd+V then stays a plain paste.
    @discardableResult
    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << Self.systemDefined.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<PasteKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            devLog("voice: Cmd+V tap unavailable (Accessibility?)")
            return false
        }
        self.tap = tap
        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "clipb.paste-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == Self.systemDefined {
            logSpecialKey(event)
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.keyboardEventKeycode) == Self.dictationKeyCode,
           event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker {
            if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                DispatchQueue.main.async { [weak self] in self?.onDictationKey?() }
            }
            return nil
        }
        guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_V),
              event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker
        else { return Unmanaged.passUnretained(event) }

        switch type {
        case .keyDown:
            let modifiers = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
            guard modifiers == .maskCommand else { return Unmanaged.passUnretained(event) }
            holding = true
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            DispatchQueue.main.async { [weak self] in self?.onDown?(isRepeat) }
            return nil
        case .keyUp where holding:
            holding = false
            DispatchQueue.main.async { [weak self] in self?.onUp?() }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Which special key went down, by code only: tells where a keyboard's
    /// 🎤 key arrives if not as key code 176.
    private func logSpecialKey(_ event: CGEvent) {
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return }
        let code = (ns.data1 & 0xFFFF_0000) >> 16
        let down = (ns.data1 & 0xFF00) >> 8 == 0xA
        if down { devLog("tap: special key \(code) down") }
    }
}
