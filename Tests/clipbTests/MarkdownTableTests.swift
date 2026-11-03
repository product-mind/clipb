import Foundation
import Testing
@testable import clipb

@Suite struct MarkdownTableTests {
    private func applied(_ text: String, _ edit: EditorText.Edit?) -> String {
        guard let edit else { return text }
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    /// Text with `^` marking the caret → (text, caret).
    private func caret(_ marked: String) -> (String, Int) {
        let location = (marked as NSString).range(of: "^").location
        return (marked.replacingOccurrences(of: "^", with: ""), location)
    }

    private func marked(_ text: String, _ location: Int) -> String {
        (text as NSString).replacingCharacters(in: NSRange(location: location, length: 0), with: "^")
    }

    // MARK: new tables

    @Test func anEmptyTableHasAHeaderAndItsSeparator() {
        #expect(MarkdownTable.empty(rows: 2, columns: 3) == "|     |     |     |\n| --- | --- | --- |\n|     |     |     |")
        #expect(MarkdownTable.empty(rows: 1, columns: 1) == "|     |\n| --- |")
    }

    @Test func insertingOnAnEmptyLinePutsTheCaretInTheFirstCell() {
        let (edit, selection) = MarkdownTable.insert(rows: 1, columns: 2, in: "", selection: NSRange(location: 0, length: 0))
        let result = applied("", edit)
        #expect(result == "|     |     |\n| --- | --- |")
        #expect(selection.location == 2)
    }

    @Test func insertingAfterTextKeepsBlankLinesAround() {
        let text = "intro\nafter"
        let (edit, selection) = MarkdownTable.insert(rows: 1, columns: 1, in: text, selection: NSRange(location: 2, length: 0))
        #expect(applied(text, edit) == "intro\n\n|     |\n| --- |\n\nafter")
        #expect(marked(applied(text, edit), selection.location) == "intro\n\n| ^    |\n| --- |\n\nafter")
    }

    // MARK: live alignment

    @Test func typingWidensTheColumnAndKeepsTheCaret() {
        let (text, at) = caret("| ab^ | b   |\n| --- | --- |\n| c   | d   |")
        let result = MarkdownTable.liveAligned(in: text, caret: at)
        let aligned = applied(text, result?.edit)
        #expect(aligned == "| ab  | b   |\n| --- | --- |\n| c   | d   |" || result == nil)
        let (longer, at2) = caret("| abcd^ | b   |\n| --- | --- |\n| c   | d   |")
        let grown = MarkdownTable.liveAligned(in: longer, caret: at2)
        #expect(grown.map { marked(applied(longer, $0.edit), $0.caret) }
            == "| abcd^ | b   |\n| ---- | --- |\n| c    | d   |")
    }

    @Test func deletingShrinksTheColumn() {
        let (text, at) = caret("| ab^   | b   |\n| ----- | --- |\n| c     | d   |")
        let result = MarkdownTable.liveAligned(in: text, caret: at)
        #expect(result.map { marked(applied(text, $0.edit), $0.caret) }
            == "| ab^  | b   |\n| --- | --- |\n| c   | d   |")
    }

    @Test func aSpaceTypedAfterAWordSurvives() {
        let (text, at) = caret("| abcd ^| b   |\n| ---- | --- |")
        let result = MarkdownTable.liveAligned(in: text, caret: at)
        let after = result.map { marked(applied(text, $0.edit), $0.caret) } ?? marked(text, at)
        #expect(after.contains("abcd ^"))
    }

    @Test func noSeparatorRowNoLiveAlignment() {
        let (text, at) = caret("| Name^")
        #expect(MarkdownTable.liveAligned(in: text, caret: at) == nil)
    }

    @Test func aPipeTypedInACellSplitsIt() {
        let (text, at) = caret("| a|^ |\n| --- |")
        let result = MarkdownTable.liveAligned(in: text, caret: at)
        #expect(result.map { marked(applied(text, $0.edit), $0.caret) } == "| a   | ^    |\n| --- | --- |")
    }

    @Test func insideACodeBlockIsNotATable() {
        let text = "```\n| a |\n| - |\n```"
        #expect(MarkdownTable.blockRange(in: text, at: 6) == nil)
    }

    // MARK: rows, columns, Tab

    @Test func addRowGoesUnderTheCaretsRow() {
        let (text, at) = caret("| a^   |\n| --- |\n| b   |")
        let result = MarkdownTable.addRow(in: text, at: at)
        #expect(result.map { marked(applied(text, $0.edit), $0.selection.location) }
            == "| a   |\n| --- |\n| ^    |\n| b   |")
    }

    @Test func addColumnGoesRightOfTheCaretsColumn() {
        let (text, at) = caret("| a^   | c   |\n| :-- | --- |")
        let result = MarkdownTable.addColumn(in: text, at: at)
        #expect(result.map { marked(applied(text, $0.edit), $0.selection.location) }
            == "| a   | ^    | c   |\n| :-- | --- | --- |")
    }

    @Test func thePlusButtonsAddAtTheEnd() {
        let (text, at) = caret("| a^   | c   |\n| --- | --- |\n| b   | d   |")
        let column = MarkdownTable.addColumn(in: text, at: at, atEnd: true)
        #expect(column.map { marked(applied(text, $0.edit), $0.selection.location) }
            == "| a   | c   | ^    |\n| --- | --- | --- |\n| b   | d   |     |")
        let row = MarkdownTable.addRow(in: text, at: at, atEnd: true)
        #expect(row.map { marked(applied(text, $0.edit), $0.selection.location) }
            == "| a   | c   |\n| --- | --- |\n| b   | d   |\n| ^    |     |")
    }

    @Test func tabMovesToTheNextCellSkippingTheSeparator() {
        let (text, at) = caret("| a^   | bb  |\n| --- | --- |\n| c   | d   |")
        let next = MarkdownTable.moveCell(in: text, at: at, backward: false)
        #expect(next.map { marked(applied(text, $0.edit), $0.selection.location) }
            == "| a   | bb^  |\n| --- | --- |\n| c   | d   |")
        let (fromB, at2) = caret("| a   | bb^  |\n| --- | --- |\n| c   | d   |")
        let down = MarkdownTable.moveCell(in: fromB, at: at2, backward: false)
        #expect(down.map { marked(applied(fromB, $0.edit), $0.selection.location) }
            == "| a   | bb  |\n| --- | --- |\n| c^   | d   |")
        let (fromC, at3) = caret("| a   | bb  |\n| --- | --- |\n| c^   | d   |")
        let up = MarkdownTable.moveCell(in: fromC, at: at3, backward: true)
        #expect(up.map { marked(applied(fromC, $0.edit), $0.selection.location) }
            == "| a   | bb^  |\n| --- | --- |\n| c   | d   |")
    }

    @Test func tabInTheLastCellAddsARow() {
        let (text, at) = caret("| a   |\n| --- |\n| b^   |")
        let result = MarkdownTable.moveCell(in: text, at: at, backward: false)
        #expect(result.map { marked(applied(text, $0.edit), $0.selection.location) }
            == "| a   |\n| --- |\n| b   |\n| ^    |")
    }
}
