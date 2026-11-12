import Foundation

/// Hold Cmd+C or Cmd+V to dictate, or press F5 to start and again to stop
/// (SPEC §2.13). Pure state machine: the caller
/// feeds it key events and the hold timer, and acts on the returned action.
///
/// Every press begins at once (cue + mic) so the first word is never clipped.
/// A release before `holdThreshold` is a tap: the plain copy or paste. A hold
/// past it is dictation, whether or not the copy itself copied something:
/// editors that copy the current line on an empty selection must still
/// dictate, and a real copy is already in history.
struct VoiceCopyGesture {
    static let holdThreshold: TimeInterval = 0.2

    enum Key: Equatable {
        /// Cmd+C: only observed; the copy always happens.
        case copy
        /// Cmd+V: held back by `PasteKeyTap`; a tap is replayed as a paste.
        case paste
        /// Right Option alone (`[voice] right_option`): a hold pastes like a
        /// Cmd+V hold. A tap does nothing; any other key or modifier during
        /// the press makes it an Option chord (typing ⌥e) and cancels it.
        case option
        /// F5 (fn+F5 on a Mac keyboard): no hold. One press starts the take,
        /// the next ends it; it lands in the dictation editor like Cmd+C.
        case toggle

        /// The take lands in the dictation editor, not typed into the field.
        var opensEditor: Bool { self == .copy || self == .toggle }
    }

    enum State: Equatable { case idle, pressed(Key), recording(Key) }

    enum Action: Equatable {
        case none
        /// Play the start cue, open the mic, and schedule
        /// `holdElapsed(generation:)` after `holdThreshold`.
        case begin(Key, generation: Int)
        /// The press is a hold: this recording will be transcribed.
        case confirm(Key)
        /// `begin` and `confirm` at once: a toggle has no tap to tell apart.
        case start(Key)
        /// Transcribe what was recorded.
        case stop(Key)
        /// Released (or another key pressed) before the threshold: discard the
        /// audio and do the plain copy or paste.
        case tap(Key)
        /// Esc: discard the audio, do nothing else.
        case cancel(Key)
    }

    private(set) var state: State = .idle
    private var generation = 0

    /// `commandOnly`: Cmd is held and Shift, Option and Control are not
    /// (Cmd+Shift+C and Cmd+Shift+V are ClipB hotkeys).
    mutating func keyDown(_ key: Key, commandOnly: Bool, isRepeat: Bool) -> Action {
        guard !isRepeat, state == .idle, commandOnly else { return .none }
        state = .pressed(key)
        generation += 1
        return .begin(key, generation: generation)
    }

    /// F5: starts a take when idle, ends the toggle's own take. A hold of
    /// another key in progress ignores it.
    mutating func togglePressed() -> Action {
        switch state {
        case .idle:
            state = .recording(.toggle)
            generation += 1
            return .start(.toggle)
        case .recording(.toggle):
            state = .idle
            return .stop(.toggle)
        default:
            return .none
        }
    }

    /// The hold timer fired. A timer from an earlier press is stale and ignored.
    mutating func holdElapsed(generation: Int) -> Action {
        guard case .pressed(let key) = state, generation == self.generation else { return .none }
        state = .recording(key)
        return .confirm(key)
    }

    /// The pressed key came up. Another key's release is ignored.
    mutating func keyUp(_ key: Key) -> Action {
        switch state {
        case .pressed(key): state = .idle; return .tap(key)
        case .recording(key): state = .idle; return .stop(key)
        default: return .none
        }
    }

    /// Cmd came up: ends whichever Cmd press is active.
    mutating func commandReleased() -> Action {
        switch state {
        case .idle, .pressed(.option), .recording(.option), .pressed(.toggle), .recording(.toggle): return .none
        case .pressed(let key): state = .idle; return .tap(key)
        case .recording(let key): state = .idle; return .stop(key)
        }
    }

    mutating func escape() -> Action {
        switch state {
        case .idle: return .none
        case .pressed(let key), .recording(let key): state = .idle; return .cancel(key)
        }
    }

    /// Any other key-down. Before the threshold it means a chord in progress
    /// (Cmd+C, Cmd+V typed fast), not a hold; while recording it is ignored.
    /// For Right Option it is an Option chord, before or after the threshold.
    mutating func otherKey() -> Action {
        switch state {
        case .pressed(.option), .recording(.option):
            state = .idle
            return .cancel(.option)
        case .pressed(let key):
            state = .idle
            return .tap(key)
        default:
            return .none
        }
    }
}
