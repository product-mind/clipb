import Foundation
import Testing
@testable import clipb

@Suite struct PipeOptionsRowTests {
    @Test func optionTitlePutsTheKeyAfterTheName() {
        #expect(PipeOptionsRow.optionTitle(name: "English", digit: 1) == "English  ⌘1")
    }

    @Test func optionTitleShowsTheChordWhenThePipeOwnsOne() {
        #expect(PipeOptionsRow.optionTitle(name: "English", digit: 1, chord: "⌘⇧E") == "English  ⌘⇧E")
        // An unbound pipe keeps its digit, even when it is not the first.
        #expect(PipeOptionsRow.optionTitle(name: "Quote", digit: 2, chord: nil) == "Quote  ⌘2")
    }

    @Test func optionTitleUsesTheOptionDigit() {
        #expect(PipeOptionsRow.optionTitle(name: "Quote", digit: 3) == "Quote  ⌘3")
        #expect(PipeOptionsRow.optionTitle(name: "Quote", digit: 9) == "Quote  ⌘9")
    }
}
