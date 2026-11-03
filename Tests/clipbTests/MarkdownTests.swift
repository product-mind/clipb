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
        #expect(has(text, .codeBlock, "# not a heading\n"))
        #expect(!kinds(text).contains { if case .heading = $0.0 { true } else { false } })
        #expect(!kinds(text).contains { $0.0 == .bold })
    }

    @Test func slacksOneLineBlockClosesOnItsOwnLine() {
        let text = "```ls -la```\n# Title"
        #expect(has(text, .codeBlock, "```ls -la```\n"))
        #expect(has(text, .heading(1), "# Title"))
    }

    @Test func onlyTheMatchingFenceCloses() {
        let text = "~~~\n```\nstill code\n~~~\nafter **b**"
        #expect(has(text, .codeBlock, "still code\n"))
        #expect(has(text, .bold, "**b**"))
    }

    @Test func inlineCodeSpansSeveralWords() {
        #expect(has("run `git commit -m x` now", .code, "`git commit -m x`"))
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

    // MARK: continueList

    private func enter(_ text: String, at caret: Int? = nil) -> String? {
        let at = caret ?? (text as NSString).length
        guard let (edit, selection) = Markdown.continueList(in: text, selection: NSRange(location: at, length: 0)) else { return nil }
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        // Mark the caret with | to check where it lands.
        return result.replacingCharacters(in: selection, with: "|")
    }

    @Test func dashAndStarItemsContinue() {
        #expect(enter("- milk") == "- milk\n- |")
        #expect(enter("  * eggs") == "  * eggs\n  * |")
    }

    @Test func numbersCountUpKeepingTheDelimiter() {
        #expect(enter("1. one") == "1. one\n2. |")
        #expect(enter("9) nine") == "9) nine\n10) |")
    }

    @Test func checkboxesContinueUnchecked() {
        #expect(enter("- [x] done") == "- [x] done\n- [ ] |")
    }

    @Test func quotesContinue() {
        #expect(enter("> said") == "> said\n> |")
    }

    @Test func anEmptyItemEndsTheList() {
        #expect(enter("- a\n- ") == "- a\n|")
        #expect(enter("2. ") == "|")
        #expect(enter("- [ ] ") == "|")
    }

    @Test func textAfterTheCaretMovesIntoTheNewItem() {
        #expect(enter("- milk eggs", at: 6) == "- milk\n- | eggs")
    }

    @Test func plainLinesAndTheMarkerItselfGetANormalNewline() {
        #expect(enter("hello") == nil)
        #expect(enter("-no space") == nil)
        #expect(enter("- milk", at: 1) == nil)
        #expect(Markdown.continueList(in: "- milk", selection: NSRange(location: 2, length: 2)) == nil)
    }

    // MARK: fences while typing

    private func type(_ char: String, into text: String) -> String? {
        let end = (text as NSString).length
        guard let (edit, selection) = Markdown.autoCloseFence(in: text, selection: NSRange(location: end, length: 0), typed: char) else { return nil }
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        return result.replacingCharacters(in: selection, with: "|")
    }

    @Test func theThirdBacktickAddsTheClosingFence() {
        #expect(type("`", into: "``") == "```\n|\n```\n")
        #expect(type("`", into: "intro\n  ``") == "intro\n  ```\n  |\n  ```\n")
    }

    @Test func noExtraNewlineWhenTextFollows() {
        let text = "``\nafter" as NSString
        let (edit, selection) = Markdown.autoCloseFence(in: text as String, selection: NSRange(location: 2, length: 0), typed: "`")!
        let result = text.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        #expect(result.replacingCharacters(in: selection, with: "|") == "```\n|\n```\nafter")
    }

    @Test func noAutoCloseWhenItClosesABlockOrIsNotAFence() {
        #expect(type("`", into: "```\ncode\n``") == nil)
        #expect(type("`", into: "a ``") == nil)
        #expect(type("`", into: "`") == nil)
        #expect(type("x", into: "``") == nil)
    }

    @Test func insideAFenceListsDoNotContinue() {
        #expect(Markdown.continueList(in: "```\n- a", selection: NSRange(location: 7, length: 0)) == nil)
        #expect(Markdown.isInsideFence(in: "```\nx\n```\nafter", at: 12) == false)
        #expect(Markdown.isInsideFence(in: "```ls```\nafter", at: 10) == false)
    }

    @Test func fenceMarkersAreTheirOwnKindAndTheLanguageIsNot() {
        #expect(has("```swift\nlet x\n```", .fence, "```"))
        #expect(!has("```swift\nlet x\n```", .syntax, "```swift"))
    }

    // MARK: toggleCode

    private func code(_ text: String, _ selection: NSRange) -> (String, NSRange) {
        let (edit, selected) = Markdown.toggleCode(in: text, selection: selection)
        return ((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement), selected)
    }

    @Test func wordsOnOneLineGetSingleBackticks() {
        let (result, selection) = code("say hello world", NSRange(location: 4, length: 11))
        #expect(result == "say `hello world`")
        #expect(selection == NSRange(location: 5, length: 11))
    }

    @Test func severalLinesAreFenced() {
        let (result, selection) = code("a\nb", NSRange(location: 0, length: 3))
        #expect(result == "```\na\nb\n```")
        #expect(selection == NSRange(location: 4, length: 3))
    }

    @Test func fencingTakesWholeLinesAndKeepsWhatFollows() {
        let (result, _) = code("x\nab\ncd\nz", NSRange(location: 3, length: 3))
        #expect(result == "x\n```\nab\ncd\n```\nz")
        let (trailing, _) = code("a\nb\n", NSRange(location: 0, length: 4))
        #expect(trailing == "```\na\nb\n```\n")
    }

    @Test func fencedLinesUnfence() {
        let (result, selection) = code("```\na\nb\n```", NSRange(location: 4, length: 3))
        #expect(result == "a\nb")
        #expect(selection == NSRange(location: 0, length: 3))
        let (followed, _) = code("```\na\nb\n```\nz", NSRange(location: 4, length: 3))
        #expect(followed == "a\nb\nz")
    }

    @Test func inlineBackticksDrawLikeFences() {
        #expect(has("run `ls` now", .fence, "`"))
    }
}
