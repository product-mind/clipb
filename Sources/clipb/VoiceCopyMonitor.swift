import AppKit
import Carbon.HIToolbox

/// Feeds key events to `VoiceCopyGesture` (SPEC §2.13).
///
/// Cmd+C, Esc, other keys and Cmd's release come from passive NSEvent
/// monitors: nothing is swallowed or delayed, so if ClipB hangs, Cmd+C still
/// copies. Plain Cmd+V comes from `PasteKeyTap`, which holds it back; a tap is
/// replayed through `onTap(.paste)`. Global monitors and the tap need
/// Accessibility, which ClipB already holds.
final class VoiceCopyMonitor {
    typealias Key = VoiceCopyGesture.Key

    /// Key-down: cue and mic, before we know whether it is a tap or a hold.
    var onBegin: ((Key) -> Void)?
    /// The press passed the hold threshold.
    var onConfirm: ((Key) -> Void)?
    /// `held` is the time from key-down to release.
    var onStop: ((Key, _ held: TimeInterval) -> Void)?
    /// A short press: discard the audio; for `.paste`, replay the paste.
    var onTap: ((Key) -> Void)?
    /// Esc: discard the audio.
    var onCancel: ((Key) -> Void)?

    private var gesture = VoiceCopyGesture()
    /// A press is in progress (pressed or recording).
    var isPressed: Bool { gesture.state != .idle }
    /// An F5 take is recording: the next F5 ends it.
    var isToggleRecording: Bool { gesture.state == .recording(.toggle) }
    private var lastToggle = Date.distantPast
    private var pressedAt = Date()
    private var monitors: [Any] = []
    private let pasteTap = PasteKeyTap()
    /// Asked on every Right Option press: `[voice] right_option`.
    var rightOptionEnabled: () -> Bool = { false }
    /// NX_DEVICELALTKEYMASK / NX_DEVICERALTKEYMASK: which Option is down.
    private static let leftOptionBit: UInt = 0x20
    private static let rightOptionBit: UInt = 0x40

    func start() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in
            self?.handle($0)
        }) {
            monitors.append(global)
        }
        // ClipB's own panels (popup, editor) receive keys locally.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self else { return event }
            // Esc during a take in ClipB's own editor cancels the take only;
            // the editor must not also treat it as save-and-close.
            let cancelsTake = event.type == .keyDown && event.keyCode == UInt16(kVK_Escape) && gesture.state != .idle
            handle(event)
            return cancelsTake ? nil : event
        }) {
            monitors.append(local)
        }
        pasteTap.onDown = { [weak self] isRepeat in self?.pasteDown(isRepeat: isRepeat) }
        pasteTap.onDictationKey = { [weak self] in self?.togglePressed() }
        pasteTap.onUp = { [weak self] in
            guard let self else { return }
            perform(gesture.keyUp(.paste))
        }
        pasteTap.start()
    }

    /// F5's hotkey fired. A second press within 300 ms is a bounce or a key
    /// repeat, not a deliberate stop.
    func togglePressed() {
        let now = Date()
        guard now.timeIntervalSince(lastToggle) > 0.3 else { return }
        lastToggle = now
        perform(gesture.togglePressed())
    }

    private func pasteDown(isRepeat: Bool) {
        // A Cmd+C still under the threshold was a plain copy; Cmd+V starts fresh.
        if !isRepeat, case .pressed(.copy) = gesture.state { perform(gesture.otherKey()) }
        perform(gesture.keyDown(.paste, commandOnly: true, isRepeat: isRepeat))
    }

    private func handle(_ event: NSEvent) {
        let action: VoiceCopyGesture.Action
        switch event.type {
        case .keyDown where event.keyCode == UInt16(kVK_ANSI_C):
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            action = gesture.keyDown(.copy, commandOnly: modifiers == .command, isRepeat: event.isARepeat)
        case .keyDown where event.keyCode == UInt16(kVK_Escape):
            action = gesture.escape()
        case .keyDown where event.isARepeat:
            return
        case .keyDown:
            action = gesture.otherKey()
        case .keyUp where event.keyCode == UInt16(kVK_ANSI_C):
            action = gesture.keyUp(.copy)
        case .flagsChanged where event.keyCode == UInt16(kVK_RightOption):
            let raw = event.modifierFlags.rawValue
            if raw & Self.rightOptionBit != 0 {
                let others = event.modifierFlags.intersection([.command, .shift, .control])
                let alone = others.isEmpty && raw & Self.leftOptionBit == 0
                guard gesture.state == .idle, alone, rightOptionEnabled() else {
                    action = gesture.otherKey()
                    break
                }
                action = gesture.keyDown(.option, commandOnly: true, isRepeat: false)
            } else {
                action = gesture.keyUp(.option)
            }
        case .flagsChanged where gesture.state == .pressed(.option) || gesture.state == .recording(.option):
            // Another modifier joined Right Option: an Option chord, not dictation.
            action = gesture.otherKey()
        case .flagsChanged where !event.modifierFlags.contains(.command):
            action = gesture.commandReleased()
        default:
            return
        }
        perform(action)
    }

    private func perform(_ action: VoiceCopyGesture.Action) {
        switch action {
        case .none:
            break
        case .begin(let key, let generation):
            pressedAt = Date()
            onBegin?(key)
            DispatchQueue.main.asyncAfter(deadline: .now() + VoiceCopyGesture.holdThreshold) { [weak self] in
                guard let self else { return }
                self.perform(self.gesture.holdElapsed(generation: generation))
            }
        case .confirm(let key):
            onConfirm?(key)
        case .start(let key):
            pressedAt = Date()
            onBegin?(key)
            onConfirm?(key)
        case .stop(let key):
            onStop?(key, Date().timeIntervalSince(pressedAt))
        case .tap(let key):
            onTap?(key)
        case .cancel(let key):
            onCancel?(key)
        }
    }
}
