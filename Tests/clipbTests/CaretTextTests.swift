import Testing
@testable import clipb

@Suite struct CaretTextTests {
    @Test func startsAtTheEndAndClampsAPlacement() {
        #expect(CaretText(["ab", "cde"]).line == 1)
        #expect(CaretText(["ab", "cde"]).column == 3)
        let placed = CaretText(["ab", "cde"], line: 0, column: 9)
        #expect(placed.line == 0 && placed.column == 2)
        #expect(CaretText([]).lines == [""])
    }

    @Test func typingAndNewlinesSplitAtTheCaret() {
        var t = CaretText(["hello"], line: 0, column: 2)
        t.insert("XY")
        #expect(t.lines == ["heXYllo"] && t.column == 4)
        t.newline()
        #expect(t.lines == ["heXY", "llo"] && t.line == 1 && t.column == 0)
        t.insert("a\nb")
        #expect(t.lines == ["heXY", "a", "bllo"] && t.line == 2 && t.column == 1)
    }

    @Test func backspaceJoinsLinesAndStopsAtTheStart() {
        var t = CaretText(["ab", "cd"], line: 1, column: 0)
        let joined = t.backspace()
        #expect(joined)
        #expect(t.lines == ["abcd"] && t.column == 2)
        t.place(line: 0, column: 0)
        let atStart = t.backspace()
        #expect(!atStart)
        t.end()
        t.deleteForward()
        #expect(t.lines == ["abcd"])
        t.home()
        t.deleteForward()
        #expect(t.lines == ["bcd"])
    }

    @Test func arrowsCrossLineEnds() {
        var t = CaretText(["ab", "c"], line: 0, column: 2)
        t.right()
        #expect(t.line == 1 && t.column == 0)
        t.left()
        #expect(t.line == 0 && t.column == 2)
        t.down()
        #expect(t.line == 1 && t.column == 1)
        t.down()
        #expect(t.column == 1)
        t.up()
        #expect(t.line == 0 && t.column == 1)
        t.up()
        #expect(t.column == 0)
    }

    @Test func deleteWordBackward() {
        var t = CaretText(["oms api  "])
        t.deleteWordBackward()
        #expect(t.lines == ["oms "])
    }
}
