import Foundation
import Testing
@testable import clipb

/// The pure editor rules: quoting, indent and outdent, case, and the trim
/// every save runs. Table-driven, one case per rule.
struct EditorTextTests {
    private func applying(_ edit: EditorText.Edit, to text: String) -> String {
        (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    // MARK: Quoting

    @Test("Quote toggles > on and off over whole lines", arguments: [
        (input: "a\nb", selection: NSRange(location: 0, length: 3), expected: "> a\n> b"),
        (input: "> a\n> b", selection: NSRange(location: 0, length: 7), expected: "a\nb"),
        (input: "> a\nb", selection: NSRange(location: 0, length: 5), expected: "> > a\n> b"),
        (input: "> a\n\n> b", selection: NSRange(location: 0, length: 8), expected: "a\n\nb"),
        (input: "a\nb\nc", selection: NSRange(location: 2, length: 0), expected: "a\n> b\nc"),
        (
            input: "hello world\n\nhow are you?",
            selection: NSRange(location: 0, length: 24),
            expected: "> hello world\n> \n> how are you?"
        ),
        (input: "a\n   \nb", selection: NSRange(location: 0, length: 7), expected: "> a\n>    \n> b"),
        (input: "> a\n>\n> b", selection: NSRange(location: 0, length: 9), expected: "a\n\nb"),
        (input: "", selection: NSRange(location: 0, length: 0), expected: ""),
    ])
    func quoting(_ c: (input: String, selection: NSRange, expected: String)) {
        #expect(applying(EditorText.toggleQuote(in: c.input, selection: c.selection), to: c.input) == c.expected)
    }

    // MARK: Indent

    @Test("Indent infers the buffer's unit", arguments: [
        (input: "a\nb", expected: "    a\n    b"),
        (input: "  a\n  b", expected: "    a\n    b"),
        (input: "    a\n    b", expected: "        a\n        b"),
        (input: "\ta\nb", expected: "\t\ta\n\tb"),
        (input: "  a\n    b", expected: "    a\n      b"),
    ])
    func indent(_ c: (input: String, expected: String)) {
        let selection = NSRange(location: 0, length: (c.input as NSString).length)
        #expect(applying(EditorText.indent(in: c.input, selection: selection), to: c.input) == c.expected)
    }

    @Test("Outdent removes one unit or the line's partial prefix", arguments: [
        (input: "    a\n    b\n  c", expected: "a\nb\nc"),
        (input: "\ta\n  b", expected: "a\n  b"),
        (input: "a\nb", expected: "a\nb"),
    ])
    func outdent(_ c: (input: String, expected: String)) {
        let selection = NSRange(location: 0, length: (c.input as NSString).length)
        #expect(applying(EditorText.outdent(in: c.input, selection: selection), to: c.input) == c.expected)
    }

    @Test("A mid-line selection expands to whole lines", arguments: [
        (input: "foo\nbar", selection: NSRange(location: 1, length: 1), indent: true, expected: "    foo\nbar"),
        (input: "    foo\n    bar", selection: NSRange(location: 6, length: 1), indent: false, expected: "foo\n    bar"),
    ])
    func midLineSelection(_ c: (input: String, selection: NSRange, indent: Bool, expected: String)) {
        let edit = c.indent
            ? EditorText.indent(in: c.input, selection: c.selection)
            : EditorText.outdent(in: c.input, selection: c.selection)
        #expect(applying(edit, to: c.input) == c.expected)
    }

    @Test("Unit inference ties go the documented way", arguments: [
        (input: "  a\n\tb", expected: "\t"),
        (input: "  a\n    b", expected: "  "),
        (input: "   a\n   b", expected: "  "),
        (input: "     a\n     b", expected: "    "),
        (input: "      a", expected: "    "),
        (input: "a", expected: "    "),
    ])
    func unitInference(_ c: (input: String, expected: String)) {
        #expect(EditorText.indentUnit(in: c.input) == c.expected)
    }

    // MARK: Case

    @Test("Case transforms the selection, or the word at the caret", arguments: [
        (input: "hello world", selection: NSRange(location: 0, length: 5), upper: true, expected: "HELLO world"),
        (input: "HELLO World", selection: NSRange(location: 6, length: 5), upper: false, expected: "HELLO world"),
        (input: "hello world", selection: NSRange(location: 3, length: 0), upper: true, expected: "HELLO world"),
        (input: "hello world", selection: NSRange(location: 5, length: 0), upper: true, expected: "HELLO world"),
        (input: "hello world", selection: NSRange(location: 6, length: 0), upper: true, expected: "hello WORLD"),
        (input: "hello", selection: NSRange(location: 0, length: 0), upper: true, expected: "HELLO"),
        (input: "hello", selection: NSRange(location: 5, length: 0), upper: true, expected: "HELLO"),
        (input: "HELLO", selection: NSRange(location: 5, length: 0), upper: false, expected: "hello"),
    ])
    func casing(_ c: (input: String, selection: NSRange, upper: Bool, expected: String)) {
        let edit = c.upper
            ? EditorText.uppercased(in: c.input, selection: c.selection)
            : EditorText.lowercased(in: c.input, selection: c.selection)
        #expect(edit.map { applying($0, to: c.input) } == c.expected)
    }

    @Test("A caret with no word transforms nothing")
    func caseWithoutWord() {
        #expect(EditorText.uppercased(in: "", selection: NSRange(location: 0, length: 0)) == nil)
        #expect(EditorText.uppercased(in: "   ", selection: NSRange(location: 1, length: 0)) == nil)
    }

    // MARK: Trim

    @Test("Trim removes trailing whitespace and nothing else", arguments: [
        (input: "a  \nb\t\nc", expected: "a\nb\nc"),
        (input: "a  ", expected: "a"),
        (input: "a\n", expected: "a\n"),
        (input: "x  \n   \ny", expected: "x\n\ny"),
        (input: "  \n\t\n", expected: "\n\n"),
        (input: "\n", expected: "\n"),
        (input: "", expected: ""),
    ])
    func trim(_ c: (input: String, expected: String)) {
        #expect(EditorText.trimmed(c.input) == c.expected)
    }

    // MARK: Selection

    @Test("A caret keeps its column through an indent")
    func restoredCaret() {
        let text = "a\nb"
        let edit = EditorText.indent(in: text, selection: NSRange(location: 0, length: 3))
        let restored = EditorText.restoredSelection(edit: edit, oldText: text, selection: NSRange(location: 0, length: 0))
        #expect(restored == NSRange(location: 4, length: 0))
    }

    @Test("A caret past the first line keeps its column through an indent")
    func restoredCaretOnLaterLine() {
        let text = "a\nb"
        let edit = EditorText.indent(in: text, selection: NSRange(location: 0, length: 3))
        let restored = EditorText.restoredSelection(edit: edit, oldText: text, selection: NSRange(location: 3, length: 0))
        #expect(restored == NSRange(location: 11, length: 0))
    }

    @Test("A range selection keeps its span through a quote toggle")
    func restoredRange() {
        let text = "a\nb"
        let edit = EditorText.toggleQuote(in: text, selection: NSRange(location: 0, length: 3))
        let restored = EditorText.restoredSelection(edit: edit, oldText: text, selection: NSRange(location: 0, length: 3))
        #expect(restored == NSRange(location: 0, length: 7))
    }
}

@Suite struct DictationInsertionTests {
    @Test func spacesATakeAwayFromAWord() {
        #expect(EditorText.dictationInsertion("and more.", into: "First part.", at: NSRange(location: 11, length: 0)) == " and more.")
    }

    @Test func noSpaceAtTheStartAfterASpaceOrNewline() {
        #expect(EditorText.dictationInsertion("Hi.", into: "", at: NSRange(location: 0, length: 0)) == "Hi.")
        #expect(EditorText.dictationInsertion("Hi.", into: "a ", at: NSRange(location: 2, length: 0)) == "Hi.")
        #expect(EditorText.dictationInsertion("Hi.", into: "a\n", at: NSRange(location: 2, length: 0)) == "Hi.")
    }

    @Test func replacingASelectionLooksBeforeIt() {
        #expect(EditorText.dictationInsertion("new", into: "old word", at: NSRange(location: 4, length: 4)) == "new")
    }
}
