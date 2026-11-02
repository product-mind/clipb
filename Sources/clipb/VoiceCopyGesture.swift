import Foundation

/// Hold Cmd+C to dictate (SPEC §2.13). Pure state machine: the caller feeds it
/// key events and the hold timer, and acts on the returned action. It only
/// observes; Cmd+C always reaches the frontmost app untouched.
///
/// A press held past `holdThreshold` starts recording, whether or not the copy
/// itself copied something: editors that copy the current line on an empty
/// selection must still dictate, and a real copy is already in history.
struct VoiceCopyGesture {
    static let holdThreshold: TimeInterval = 0.2

    enum State: Equatable { case idle, pressed, recording }

    enum Action: Equatable {
        case none
        /// Schedule `holdElapsed(generation:)` after `holdThreshold`.
        case armTimer(generation: Int)
        case start
        case stop
        case cancel
    }

    private(set) var state: State = .idle
    private var generation = 0

    /// C key-down. `commandOnly`: Cmd is held and Shift, Option and Control are
    /// not (Cmd+Shift+C is the screencapture hotkey).
    mutating func cDown(commandOnly: Bool, isRepeat: Bool) -> Action {
        guard !isRepeat, state == .idle, commandOnly else { return .none }
        state = .pressed
        generation += 1
        return .armTimer(generation: generation)
    }

    /// The hold timer fired. A timer from an earlier press is stale and ignored.
    mutating func holdElapsed(generation: Int) -> Action {
        guard state == .pressed, generation == self.generation else { return .none }
        state = .recording
        return .start
    }

    /// C released, or Cmd released: either ends the hold.
    mutating func released() -> Action {
        switch state {
        case .idle: return .none
        case .pressed: state = .idle; return .none
        case .recording: state = .idle; return .stop
        }
    }

    mutating func escape() -> Action {
        switch state {
        case .idle: return .none
        case .pressed: state = .idle; return .none
        case .recording: state = .idle; return .cancel
        }
    }

    /// Any other key-down. Before the threshold it means a chord in progress
    /// (Cmd+C, Cmd+V typed fast), not a hold; while recording it is ignored.
    mutating func otherKey() -> Action {
        if state == .pressed { state = .idle }
        return .none
    }
}
