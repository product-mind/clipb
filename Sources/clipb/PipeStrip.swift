import Foundation

/// The pipe buttons of the popup's bottom bar and the Cmd+Shift+X chooser:
/// each configured pipe is one option, its digit being its 1-based position,
/// and pressing a digit or clicking a button runs it at once. Pure state, so
/// the digit mapping is testable without a panel.
struct PipeStrip: Equatable {
    static let maxOptions = Pipes.maxPipes

    /// One option: the digit key that runs it and its label.
    struct Option: Equatable {
        var digit: Int
        var label: String
    }

    /// Never more than nine: digit keys 1-9 run the options.
    private(set) var pipes: [PipeCommand]

    init(pipes: [PipeCommand]) {
        self.pipes = Array(pipes.prefix(Self.maxOptions))
    }

    var isAvailable: Bool { !pipes.isEmpty }

    /// Pipes render under their `name`, not their id; digit = index + 1.
    var options: [Option] {
        pipes.enumerated().map { Option(digit: $0.offset + 1, label: $0.element.name) }
    }

    /// The pipe a digit runs; nil when no option has that digit.
    func pipe(forDigit digit: Int) -> PipeCommand? {
        guard pipes.indices.contains(digit - 1) else { return nil }
        return pipes[digit - 1]
    }

    /// What the button row and the chooser header show while a pipe runs.
    static func runningLabel(for pipe: PipeCommand) -> String { "Running \(pipe.name)…" }
}
