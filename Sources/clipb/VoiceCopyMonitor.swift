import AppKit
import Carbon.HIToolbox

/// Feeds key events to `VoiceCopyGesture` (SPEC §2.13). Passive NSEvent
/// monitors only: nothing is swallowed or delayed, so if ClipB hangs, Cmd+C
/// still copies. Global monitors need Accessibility, which ClipB already holds.
final class VoiceCopyMonitor {
    /// Key-down: cue and mic, before we know whether it is a tap or a hold.
    var onBegin: (() -> Void)?
    /// The press passed the hold threshold.
    var onConfirm: (() -> Void)?
    /// `held` is the time from key-down to release.
    var onStop: ((_ held: TimeInterval) -> Void)?
    /// A tap, an aborted press, or Esc.
    var onDiscard: (() -> Void)?

    private var gesture = VoiceCopyGesture()
    private var pressedAt = Date()
    private var monitors: [Any] = []

    func start() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in
            self?.handle($0)
        }) {
            monitors.append(global)
        }
        // ClipB's own panels (popup, editor) receive keys locally.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] in
            self?.handle($0)
            return $0
        }) {
            monitors.append(local)
        }
    }

    private func handle(_ event: NSEvent) {
        let action: VoiceCopyGesture.Action
        switch event.type {
        case .keyDown where event.keyCode == UInt16(kVK_ANSI_C):
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            action = gesture.cDown(commandOnly: modifiers == .command, isRepeat: event.isARepeat)
        case .keyDown where event.keyCode == UInt16(kVK_Escape):
            action = gesture.escape()
        case .keyDown:
            action = gesture.otherKey()
        case .keyUp where event.keyCode == UInt16(kVK_ANSI_C):
            action = gesture.released()
        case .flagsChanged where !event.modifierFlags.contains(.command):
            action = gesture.released()
        default:
            return
        }
        perform(action)
    }

    private func perform(_ action: VoiceCopyGesture.Action) {
        switch action {
        case .none:
            break
        case .begin(let generation):
            pressedAt = Date()
            onBegin?()
            DispatchQueue.main.asyncAfter(deadline: .now() + VoiceCopyGesture.holdThreshold) { [weak self] in
                guard let self else { return }
                self.perform(self.gesture.holdElapsed(generation: generation))
            }
        case .confirm:
            onConfirm?()
        case .stop:
            onStop?(Date().timeIntervalSince(pressedAt))
        case .discard:
            onDiscard?()
        }
    }
}
