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
final class PasteKeyTap {
    /// Stamped into `eventSourceUserData` of every key event ClipB posts.
    static let syntheticMarker: Int64 = 0x434C_5042 // "CLPB"

    /// Main thread.
    var onDown: ((_ isRepeat: Bool) -> Void)?
    /// Main thread.
    var onUp: (() -> Void)?

    private var tap: CFMachPort?
    /// Tap thread only: a held-back key-down whose key-up must go too.
    private var holding = false

    /// False without Accessibility; Cmd+V then stays a plain paste.
    @discardableResult
    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
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
}
