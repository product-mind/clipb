import Foundation
import Testing
@testable import clipb

private func pipe(_ id: String, name: String? = nil) -> PipeCommand {
    PipeCommand(id: id, name: name ?? id, command: "cat", hotkey: nil)
}

@Suite struct PipeStripTests {
    @Test func optionsArePasteThenTheFirstNinePipes() {
        let strip = PipeStrip(pipes: (1...12).map { pipe("p\($0)") })
        #expect(strip.count == PipeStrip.maxOptions + 1)
        #expect(strip.options.map(\.digit) == Array(0...PipeStrip.maxOptions))
        #expect(strip.labels == ["paste", "p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8", "p9"])
        #expect(strip.pipes.count == PipeStrip.maxOptions)
    }

    @Test func optionsAreLabeledWithThePipeNames() {
        let strip = PipeStrip(pipes: [pipe("en", name: "English"), pipe("quote", name: "Quote")])
        #expect(strip.labels == ["paste", "English", "Quote"])
        #expect(strip.options.map(\.label) == ["paste", "English", "Quote"])
    }

    @Test func selectionStartsAtThePlainPaste() {
        let strip = PipeStrip(pipes: [pipe("en")])
        #expect(strip.selected == 0)
        #expect(strip.pipe(at: 0) == nil)
        #expect(strip.pipe(at: 1)?.id == "en")
    }

    @Test func aDigitSelectsItsOption() {
        var strip = PipeStrip(pipes: [pipe("en"), pipe("quote")])
        let picked = strip.select(digit: 2)
        #expect(picked)
        #expect(strip.selected == 2)
        #expect(strip.pipe(at: strip.selected)?.id == "quote")
    }

    @Test func aDigitBeyondTheOptionsIsIgnored() {
        var strip = PipeStrip(pipes: [pipe("en")])
        let tooBig = strip.select(digit: 9)
        let tooBig2 = strip.select(digit: 2)
        #expect(!tooBig)
        #expect(!tooBig2)
        #expect(strip.selected == 0)
        let plain = strip.select(digit: 0)
        let only = strip.select(digit: 1)
        #expect(plain)
        #expect(only)
    }

    @Test func noPipesMeansNoStrip() {
        let strip = PipeStrip(pipes: [])
        #expect(!strip.isAvailable)
        #expect(strip.count == 0)
        #expect(strip.labels.isEmpty)
        #expect(strip.options.isEmpty)
        #expect(strip.pipe(at: 0) == nil)
        #expect(strip.pipe(at: 1) == nil)
        var mutable = strip
        let picked = mutable.select(digit: 0)
        #expect(!picked)
        #expect(mutable.selected == 0)
    }

    @Test func runningLabelUsesThePipeName() {
        #expect(PipeStrip.runningLabel(for: pipe("en", name: "English")) == "Running English…")
    }
}
