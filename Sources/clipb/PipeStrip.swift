import Foundation

/// The pipe strip of the hotkey popup: option 0 is a plain paste, then the
/// first nine configured pipes in file order. Pure state, so it is testable
/// without a panel: which options exist, which one is selected, what the
/// strip renders.
struct PipeStrip: Equatable {
    static let plainLabel = "paste"
    static let separator = " │ "
    static let maxOptions = Pipes.maxPipes

    /// One rendered chunk of the strip. Selected chunks are drawn highlighted.
    struct Segment: Equatable {
        var text: String
        var selected: Bool
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

    var labels: [String] { pipes.isEmpty ? [] : [Self.plainLabel] + pipes.map(\.id) }

    /// `0 paste │ 1 en │ 2 quote`
    var renderedLabel: String { segments.map(\.text).joined() }

    var segments: [Segment] {
        labels.enumerated().flatMap { index, label -> [Segment] in
            let option = Segment(text: "\(index) \(label)", selected: index == selected)
            guard index > 0 else { return [option] }
            return [Segment(text: Self.separator, selected: false), option]
        }
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
    static func runningLabel(for pipe: PipeCommand) -> String { "Running \(pipe.id)…" }
}
