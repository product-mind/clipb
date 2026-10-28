import Foundation
import Testing
@testable import clipb

@Suite struct PipeOptionsRowTests {
    @Test func optionTitlePutsTheKeyAfterTheName() {
        #expect(PipeOptionsRow.optionTitle(name: "English", digit: 1) == "English  ⌘1")
    }

    @Test func optionTitleUsesTheOptionDigit() {
        #expect(PipeOptionsRow.optionTitle(name: "Quote", digit: 3) == "Quote  ⌘3")
        #expect(PipeOptionsRow.optionTitle(name: "Quote", digit: 9) == "Quote  ⌘9")
    }
}
