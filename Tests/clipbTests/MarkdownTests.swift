import Foundation
import Testing
@testable import clipb

@Suite struct MarkdownTests {
    private func kinds(_ text: String) -> [(Markdown.Kind, String)] {
        let ns = text as NSString
        return Markdown.spans(in: text).map { ($0.kind, ns.substring(with: $0.range)) }
    }

    private func has(_ text: String, _ kind: Markdown.Kind, _ covered: String) -> Bool {
        kinds(text).contains { $0.0 == kind && $0.1 == covered }
    }

    @Test func headingsCarryTheirLevelAndFaintHashes() {
        #expect(has("## Plan", .heading(2), "## Plan"))
        #expect(has("## Plan", .syntax, "##"))
        #expect(!kinds("#hashtag").contains { if case .heading = $0.0 { true } else { false } })
    }

    @Test func inlineEmphasis() {
        let text = "a **bold** and *it* and _it2_ and ~~gone~~"
        #expect(has(text, .bold, "**bold**"))
        #expect(has(text, .italic, "*it*"))
        #expect(has(text, .italic, "_it2_"))
        #expect(has(text, .strike, "~~gone~~"))
        #expect(!has(text, .italic, "*bold*"))
    }

    @Test func snakeCaseIsNotItalic() {
        #expect(!kinds("my_var_name").contains { $0.0 == .italic })
    }

    @Test func nothingIsEmphasisInsideCode() {
        let text = "run `a **b** c` now"
        #expect(has(text, .code, "`a **b** c`"))
        #expect(!kinds(text).contains { $0.0 == .bold })
    }

    @Test func fencedBlocksAreCodeAndSkipInlineRules() {
        let text = "```\n# not a heading\n**x**\n```\nafter"
        #expect(has(text, .codeBlock, "# not a heading"))
        #expect(!kinds(text).contains { if case .heading = $0.0 { true } else { false } })
        #expect(!kinds(text).contains { $0.0 == .bold })
    }

    @Test func quotesListsLinksAndTables() {
        #expect(has("> hi", .quote, "> hi"))
        #expect(has("- item", .listMarker, "-"))
        #expect(has("1. item", .listMarker, "1."))
        #expect(has("see [docs](https://x.y)", .link, "docs"))
        #expect(has("see [docs](https://x.y)", .syntax, "(https://x.y)"))
        #expect(has("| a | b |", .table, "| a | b |"))
        #expect(has("|---|---|", .syntax, "|---|---|"))
    }

    // MARK: toggleWrap

    @Test func wrapsAndUnwrapsTheSelection() {
        let text = "say hello now"
        let (edit, selection) = Markdown.toggleWrap("**", in: text, selection: NSRange(location: 4, length: 5))
        let wrapped = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        #expect(wrapped == "say **hello** now")
        #expect(selection == NSRange(location: 6, length: 5))
        let (undo, back) = Markdown.toggleWrap("**", in: wrapped, selection: selection)
        #expect((wrapped as NSString).replacingCharacters(in: undo.range, with: undo.replacement) == text)
        #expect(back == NSRange(location: 4, length: 5))
    }

    @Test func aSelectionIncludingTheMarkersUnwraps() {
        let (edit, _) = Markdown.toggleWrap("*", in: "*x*", selection: NSRange(location: 0, length: 3))
        #expect(edit.replacement == "x")
    }

    @Test func anEmptySelectionGetsAPairWithTheCaretInside() {
        let (edit, selection) = Markdown.toggleWrap("**", in: "ab", selection: NSRange(location: 1, length: 0))
        #expect(edit.replacement == "****")
        #expect(selection == NSRange(location: 3, length: 0))
    }

    // MARK: alignedTable

    @Test func alignsTheTableAroundTheCaret() {
        let text = "intro\n|a|bb|\n|:-|-:|\n|ccc|d|\nafter"
        let edit = Markdown.alignedTable(in: text, selection: NSRange(location: 8, length: 0))
        let result = edit.map { (text as NSString).replacingCharacters(in: $0.range, with: $0.replacement) }
        #expect(result == "intro\n| a   | bb  |\n| :-- | --: |\n| ccc | d   |\nafter")
    }

    @Test func alignedTableIsLeftAlone() {
        let text = "| a   | bb  |\n| --- | --- |\n"
        #expect(Markdown.alignedTable(in: text, selection: NSRange(location: 2, length: 0)) == nil)
    }

    @Test func notInATableDoesNothing() {
        #expect(Markdown.alignedTable(in: "plain\n| a |", selection: NSRange(location: 1, length: 0)) == nil)
    }
}
