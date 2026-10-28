import Foundation
import Testing
@testable import clipb

private func pipe(_ id: String, name: String? = nil) -> PipeCommand {
    PipeCommand(id: id, name: name ?? id, command: "cat", hotkey: nil)
}

@Suite struct PipeStripTests {
    @Test func optionsAreTheFirstNinePipesNumberedFromOne() {
        let strip = PipeStrip(pipes: (1...12).map { pipe("p\($0)") })
        #expect(strip.pipes.count == PipeStrip.maxOptions)
        #expect(strip.options.map(\.digit) == Array(1...PipeStrip.maxOptions))
        #expect(strip.options.first?.label == "p1")
        #expect(strip.options.last?.label == "p9")
    }

    @Test func optionsAreLabeledWithThePipeNames() {
        let strip = PipeStrip(pipes: [pipe("en", name: "English"), pipe("quote", name: "Quote")])
        #expect(strip.options == [
            PipeStrip.Option(digit: 1, label: "English"),
            PipeStrip.Option(digit: 2, label: "Quote"),
        ])
    }

    @Test func aDigitMapsToItsPipe() {
        let strip = PipeStrip(pipes: [pipe("en"), pipe("quote")])
        #expect(strip.pipe(forDigit: 1)?.id == "en")
        #expect(strip.pipe(forDigit: 2)?.id == "quote")
    }

    @Test func aDigitWithoutAnOptionIsIgnored() {
        let strip = PipeStrip(pipes: [pipe("en")])
        #expect(strip.pipe(forDigit: 0) == nil)
        #expect(strip.pipe(forDigit: 2) == nil)
        #expect(strip.pipe(forDigit: 9) == nil)
        #expect(strip.pipe(forDigit: 1)?.id == "en")
    }

    @Test func noPipesMeansNoStrip() {
        let strip = PipeStrip(pipes: [])
        #expect(!strip.isAvailable)
        #expect(strip.options.isEmpty)
        #expect(strip.pipe(forDigit: 1) == nil)
    }

    @Test func runningLabelUsesThePipeName() {
        #expect(PipeStrip.runningLabel(for: pipe("en", name: "English")) == "Running English…")
    }
}
