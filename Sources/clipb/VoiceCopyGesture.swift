import Foundation

/// Hold Cmd+C or Cmd+V to dictate (SPEC §2.13). Pure state machine: the caller
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
    }

    enum State: Equatable { case idle, pressed(Key), recording(Key) }

    enum Action: Equatable {
        case none
        /// Play the start cue, open the mic, and schedule
        /// `holdElapsed(generation:)` after `holdThreshold`.
        case begin(Key, generation: Int)
        /// The press is a hold: this recording will be transcribed.
        case confirm(Key)
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

    /// Cmd came up: ends whichever press is active.
    mutating func commandReleased() -> Action {
        switch state {
        case .idle: return .none
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
    mutating func otherKey() -> Action {
        guard case .pressed(let key) = state else { return .none }
        state = .idle
        return .tap(key)
    }
}
