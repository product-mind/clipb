import Foundation

/// Hold Cmd+C to dictate (SPEC §2.13). Pure state machine: the caller feeds it
/// key events and the hold timer, and acts on the returned action. It only
/// observes; Cmd+C always reaches the frontmost app untouched.
///
/// Every press begins at once (cue + mic) so the first word is never clipped.
/// A release before `holdThreshold` was a plain copy: the audio is discarded.
/// A hold past it is dictation, whether or not the copy itself copied
/// something: editors that copy the current line on an empty selection must
/// still dictate, and a real copy is already in history.
struct VoiceCopyGesture {
    static let holdThreshold: TimeInterval = 0.2

    enum State: Equatable { case idle, pressed, recording }

    enum Action: Equatable {
        case none
        /// Play the start cue, open the mic, and schedule
        /// `holdElapsed(generation:)` after `holdThreshold`.
        case begin(generation: Int)
        /// The press is a hold: this recording will be transcribed.
        case confirm
        /// Transcribe what was recorded.
        case stop
        /// Throw the recording away (a tap, an aborted press, or Esc).
        case discard
    }

    private(set) var state: State = .idle
    private var generation = 0

    /// C key-down. `commandOnly`: Cmd is held and Shift, Option and Control are
    /// not (Cmd+Shift+C is the screencapture hotkey).
    mutating func cDown(commandOnly: Bool, isRepeat: Bool) -> Action {
        guard !isRepeat, state == .idle, commandOnly else { return .none }
        state = .pressed
        generation += 1
        return .begin(generation: generation)
    }

    /// The hold timer fired. A timer from an earlier press is stale and ignored.
    mutating func holdElapsed(generation: Int) -> Action {
        guard state == .pressed, generation == self.generation else { return .none }
        state = .recording
        return .confirm
    }

    /// C released, or Cmd released: either ends the press.
    mutating func released() -> Action {
        switch state {
        case .idle: return .none
        case .pressed: state = .idle; return .discard
        case .recording: state = .idle; return .stop
        }
    }

    mutating func escape() -> Action {
        guard state != .idle else { return .none }
        state = .idle
        return .discard
    }

    /// Any other key-down. Before the threshold it means a chord in progress
    /// (Cmd+C, Cmd+V typed fast), not a hold; while recording it is ignored.
    mutating func otherKey() -> Action {
        guard state == .pressed else { return .none }
        state = .idle
        return .discard
    }
}
