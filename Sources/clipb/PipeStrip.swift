import Foundation

/// The pipe buttons of the popup's bottom bar and the Cmd+Shift+X chooser:
/// each configured pipe is one option, its digit being its 1-based position,
/// and pressing a digit or clicking a button runs it at once. Pure state, so
/// the digit mapping is testable without a panel.
struct PipeStrip: Equatable {
    static let maxOptions = Pipes.maxPipes

    /// One option: the digit key that runs it, its label, and the chord it owns.
    struct Option: Equatable {
        var digit: Int
        var label: String
        /// `⌘⇧E` only when the pipe's `hotkey` really registered a chord: nil
        /// when it has none, or lost its letter to a reserved one or a duplicate.
        var chord: String? = nil
    }

    /// Never more than nine: digit keys 1-9 run the options.
    private(set) var pipes: [PipeCommand]
    /// The chord each pipe owns, by its index in the configured list:
    /// `Pipes.hotkeys`' verdict, never a second guess at which letters are taken.
    /// Indexed, not keyed by id, because two `[pipe.<id>]` tables may share an id.
    private let chords: [Int: String]

    init(pipes: [PipeCommand]) {
        self.pipes = Array(pipes.prefix(Self.maxOptions))
        var chords: [Int: String] = [:]
        for binding in Pipes.hotkeys(pipes) {
            if let index = pipes.firstIndex(of: binding.pipe), index < Self.maxOptions {
                chords[index] = binding.letter
            }
        }
        self.chords = chords
    }

    var isAvailable: Bool { !pipes.isEmpty }

    /// Pipes render under their `name`, not their id; digit = index + 1.
    var options: [Option] {
        pipes.enumerated().map {
            Option(
                digit: $0.offset + 1,
                label: $0.element.name,
                chord: chords[$0.offset].map(Self.chordLabel(letter:))
            )
        }
    }

    /// The suffix a bound pipe's button shows: the chord it owns, in caps.
    static func chordLabel(letter: String) -> String { keySymbol + shiftSymbol + letter.uppercased() }

    static let keySymbol = "⌘"
    static let shiftSymbol = "⇧"

    /// The pipe a digit runs; nil when no option has that digit.
    func pipe(forDigit digit: Int) -> PipeCommand? {
        guard pipes.indices.contains(digit - 1) else { return nil }
        return pipes[digit - 1]
    }

    /// What the button row and the chooser header show while a pipe runs.
    static func runningLabel(for pipe: PipeCommand) -> String { "Running \(pipe.name)…" }
}
