import Foundation

/// The pipe strip of the hotkey popup: option 0 is a plain paste, then the
/// first nine configured pipes in file order. Pure state, so it is testable
/// without a panel: which options exist, which one is selected, what the
/// strip renders.
struct PipeStrip: Equatable {
    static let plainLabel = "paste"
    static let maxOptions = Pipes.maxPipes
    static let hint = "0-9 select · Enter applies · Esc closes"

    /// One row of the strip: the digit key that picks it and its label.
    struct Option: Equatable {
        var digit: Int
        var label: String
    }

    /// Never more than nine: digit keys 0-9 pick the options.
    private(set) var pipes: [PipeCommand]
    private(set) var selected = 0

    init(pipes: [PipeCommand]) {
        self.pipes = Array(pipes.prefix(Self.maxOptions))
    }

    var isAvailable: Bool { !pipes.isEmpty }

    /// Option 0 is the plain paste; 0 when no pipes are configured.
    var count: Int { pipes.isEmpty ? 0 : pipes.count + 1 }

    /// `["paste", "Fix English", "Quote"]` — pipes render under their `name`, not their id.
    var labels: [String] { pipes.isEmpty ? [] : [Self.plainLabel] + pipes.map(\.name) }

    var options: [Option] {
        labels.enumerated().map { Option(digit: $0.offset, label: $0.element) }
    }

    /// The pipe an option runs; option 0 is the plain paste, so nil.
    func pipe(at index: Int) -> PipeCommand? {
        guard isAvailable, index > 0, pipes.indices.contains(index - 1) else { return nil }
        return pipes[index - 1]
    }

    /// True when the digit picked an option; false when none has that digit.
    mutating func select(digit: Int) -> Bool {
        guard isAvailable, (0..<count).contains(digit) else { return false }
        selected = digit
        return true
    }

    /// What the strip shows while a pipe runs.
    static func runningLabel(for pipe: PipeCommand) -> String { "Running \(pipe.name)…" }
}
