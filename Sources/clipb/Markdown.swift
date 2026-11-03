import Foundation

/// Markdown look for the editor (SPEC §2.12). The text stays plain Markdown:
/// this only finds what to style, and the editor paints it. Pure, tested.
enum Markdown {
    enum Kind: Equatable {
        case heading(Int)
        case bold
        case italic
        case strike
        case code
        case codeBlock
        /// A fence's ``` or ~~~: brighter than other markers, so a block's
        /// edges read while typing. The language after it stays plain text.
        case fence
        case quote
        case listMarker
        case link
        case table
        /// `#`, `**`, `` ` ``, `|`, `---`: drawn faint so the words lead.
        case syntax
    }

    struct Span: Equatable {
        var kind: Kind
        var range: NSRange
    }

    /// Spans in paint order: line-level first, inline after, syntax last so
    /// markers stay faint inside bold or headings.
    static func spans(in text: String) -> [Span] {
        let ns = text as NSString
        var lines: [Span] = []
        var inline: [Span] = []
        var syntax: [Span] = []

        var fence: String?

        // Code blocks cover the whole line, newline included, so a block's
        // lines join into one box.
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, line, enclosing, _ in
            let body = ns.substring(with: line)
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            let opener = trimmed.hasPrefix("```") ? "```" : trimmed.hasPrefix("~~~") ? "~~~" : nil
            if let fenceMarker = fence {
                lines.append(Span(kind: .codeBlock, range: enclosing))
                if opener == fenceMarker {
                    syntax.append(Span(kind: .fence, range: fenceRange(in: body, line: line)))
                    fence = nil
                }
                return
            }
            if let opener {
                lines.append(Span(kind: .codeBlock, range: enclosing))
                let length = (trimmed as NSString).length
                if length > 6, trimmed.hasSuffix(opener) {
                    // Slack's one-line block, ```ls -la```: opens and closes here.
                    let start = line.location + (body as NSString).range(of: opener).location
                    let end = line.location + (body as NSString).range(of: opener, options: .backwards).location
                    syntax.append(Span(kind: .fence, range: NSRange(location: start, length: 3)))
                    syntax.append(Span(kind: .fence, range: NSRange(location: end, length: 3)))
                } else {
                    // The language after the fence (```json) is its info
                    // string, not code: drawn with the fence, as GitHub and
                    // VS Code do.
                    let marks = fenceRange(in: body, line: line)
                    syntax.append(Span(kind: .fence, range: NSRange(location: marks.location, length: NSMaxRange(line) - marks.location)))
                    fence = opener
                }
                return
            }
            if let m = firstMatch(heading, in: ns, range: line) {
                let level = m.range(at: 1).length
                lines.append(Span(kind: .heading(level), range: line))
                syntax.append(Span(kind: .syntax, range: m.range(at: 1)))
            } else if let m = firstMatch(quote, in: ns, range: line) {
                lines.append(Span(kind: .quote, range: line))
                syntax.append(Span(kind: .syntax, range: m.range(at: 1)))
            } else if trimmed.hasPrefix("|") {
                lines.append(Span(kind: .table, range: line))
                if firstMatch(tableSeparator, in: ns, range: line) != nil {
                    syntax.append(Span(kind: .syntax, range: line))
                } else {
                    for pipe in matches(tablePipe, in: ns, range: line) {
                        syntax.append(Span(kind: .syntax, range: pipe.range))
                    }
                }
            } else if firstMatch(rule, in: ns, range: line) != nil {
                syntax.append(Span(kind: .syntax, range: line))
            } else if let m = firstMatch(listMarker, in: ns, range: line) {
                lines.append(Span(kind: .listMarker, range: m.range(at: 1)))
            }
            inlineSpans(in: ns, line: line, spans: &inline, syntax: &syntax)
        }
        return lines + inline + syntax
    }

    /// The run of backticks or tildes that opens a fence line.
    private static func fenceRange(in body: String, line: NSRange) -> NSRange {
        let b = body as NSString
        var start = 0
        while start < b.length, b.character(at: start) == 32 || b.character(at: start) == 9 { start += 1 }
        guard start < b.length else { return NSRange(location: line.location, length: 0) }
        let mark = b.character(at: start)
        var end = start
        while end < b.length, b.character(at: end) == mark { end += 1 }
        return NSRange(location: line.location + start, length: end - start)
    }

    /// True when `location` sits inside an open fenced block: below an
    /// opening fence and not past its closing one.
    static func isInsideFence(in text: String, at location: Int) -> Bool {
        let ns = text as NSString
        let lineStart = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0)).location
        var fence: String?
        ns.enumerateSubstrings(in: NSRange(location: 0, length: lineStart), options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            let trimmed = ns.substring(with: line).trimmingCharacters(in: .whitespaces)
            let opener = trimmed.hasPrefix("```") ? "```" : trimmed.hasPrefix("~~~") ? "~~~" : nil
            if let current = fence {
                if opener == current { fence = nil }
            } else if let opener, !((trimmed as NSString).length > 6 && trimmed.hasSuffix(opener)) {
                fence = opener
            }
        }
        return fence != nil
    }

    /// Typing the third backtick of a fence that opens a block (SPEC §2.12):
    /// an empty line and the closing ``` appear below, and the caret moves
    /// onto that empty line, inside the block.
    /// Nil: an ordinary keystroke (not the third, text after the caret, a
    /// selection, or this fence closes a block).
    static func autoCloseFence(in text: String, selection: NSRange, typed: String) -> (edit: EditorText.Edit, selection: NSRange)? {
        guard typed == "`", selection.length == 0 else { return nil }
        let ns = text as NSString
        var lineStart = 0, lineEnd = 0, contentsEnd = 0
        ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: selection.location, length: 0))
        guard selection.location == contentsEnd else { return nil }
        let before = ns.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
        let indent = String(before.prefix { $0 == " " || $0 == "\t" })
        guard before.dropFirst(indent.count) == "``", !isInsideFence(in: text, at: lineStart) else { return nil }
        // ``` / caret line / ``` / then a line to go on with: a newline after
        // the closing fence unless one already follows the caret.
        let trailing = contentsEnd < lineEnd ? "" : "\n"
        let insertion = "`\n" + indent + "\n" + indent + "```" + trailing
        let edit = EditorText.Edit(range: selection, replacement: insertion)
        return (edit, NSRange(location: selection.location + 2 + (indent as NSString).length, length: 0))
    }

    private static func inlineSpans(in ns: NSString, line: NSRange, spans: inout [Span], syntax: inout [Span]) {
        // Code first: nothing inside backticks is bold or italic.
        var code: [NSRange] = []
        for m in matches(inlineCode, in: ns, range: line) {
            code.append(m.range)
            spans.append(Span(kind: .code, range: m.range))
            // Backticks drawn like a fence's, so inline and block code match.
            syntax.append(Span(kind: .fence, range: NSRange(location: m.range.location, length: m.range(at: 1).length)))
            syntax.append(Span(kind: .fence, range: NSRange(location: NSMaxRange(m.range) - m.range(at: 1).length, length: m.range(at: 1).length)))
        }
        func outsideCode(_ r: NSRange) -> Bool { !code.contains { NSIntersectionRange($0, r).length > 0 } }

        let marked: [(NSRegularExpression, Kind, Int)] = [
            (bold, .bold, 2), (strike, .strike, 2), (italic, .italic, 1),
        ]
        for (regex, kind, width) in marked {
            for m in matches(regex, in: ns, range: line) where outsideCode(m.range) {
                let whole = m.range(at: 1)
                spans.append(Span(kind: kind, range: whole))
                syntax.append(Span(kind: .syntax, range: NSRange(location: whole.location, length: width)))
                syntax.append(Span(kind: .syntax, range: NSRange(location: NSMaxRange(whole) - width, length: width)))
            }
        }
        for m in matches(link, in: ns, range: line) where outsideCode(m.range) {
            spans.append(Span(kind: .link, range: m.range(at: 1)))
            syntax.append(Span(kind: .syntax, range: m.range(at: 2)))
        }
    }

    // MARK: Editing

    /// Enter on a list or quote line (SPEC §2.12): continues it. `- a|` →
    /// `- a` + `- |`; `3. a|` → `4. |` (same delimiter); `- [x] a|` → `- [ ] |`;
    /// `> a|` → `> |`. Text after the caret moves into the new item. Enter on
    /// an item with nothing after its marker ends the list: the marker goes,
    /// the line stays. Nil: an ordinary newline (a selection, the caret
    /// inside the marker, or not a list line).
    static func continueList(in text: String, selection: NSRange) -> (edit: EditorText.Edit, selection: NSRange)? {
        guard selection.length == 0, !isInsideFence(in: text, at: selection.location) else { return nil }
        let ns = text as NSString
        let caret = selection.location
        var lineStart = 0, lineEnd = 0, contentsEnd = 0
        ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: caret, length: 0))
        let lineRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
        let line = ns.substring(with: lineRange)
        guard let m = listItem.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
        let l = line as NSString
        let prefixLength = m.range(at: 5).location
        guard caret - lineStart >= prefixLength else { return nil }
        let indent = l.substring(with: m.range(at: 1))
        let marker = l.substring(with: m.range(at: 2))
        let gap = l.substring(with: m.range(at: 3))
        let checkbox = m.range(at: 4).location == NSNotFound ? "" : "[ ] "
        let body = l.substring(with: m.range(at: 5))

        if body.trimmingCharacters(in: .whitespaces).isEmpty {
            // An empty item: Enter ends the list instead of adding another.
            let edit = EditorText.Edit(range: lineRange, replacement: "")
            return (edit, NSRange(location: lineStart, length: 0))
        }
        var next = marker
        if let number = Int(marker.dropLast()), let delimiter = marker.last, delimiter == "." || delimiter == ")" {
            next = "\(number + 1)\(delimiter)"
        }
        let gapForNext = marker.hasPrefix(">") ? gap : (gap.isEmpty ? " " : gap)
        let insertion = "\n" + indent + next + gapForNext + checkbox
        let edit = EditorText.Edit(range: NSRange(location: caret, length: 0), replacement: insertion)
        return (edit, NSRange(location: caret + (insertion as NSString).length, length: 0))
    }

    /// indent, marker (`-`, `*`, `+`, `1.`, `1)`, `>`), gap, optional checkbox, body.
    private static let listItem = regex(#"^(\s*)([-*+]|\d{1,9}[.)]|>+)( +|$)(\[[ xX]\] )?(.*)$"#)

    /// Bold (`**`), italic (`*`) or code (`` ` ``) on the selection: wraps it,
    /// or unwraps it when the markers are already there. An empty selection
    /// gets a marker pair with the caret between.
    static func toggleWrap(_ marker: String, in text: String, selection: NSRange) -> (edit: EditorText.Edit, selection: NSRange) {
        let ns = text as NSString
        let width = (marker as NSString).length
        let before = NSRange(location: selection.location - width, length: width)
        let after = NSRange(location: NSMaxRange(selection), length: width)
        if before.location >= 0, NSMaxRange(after) <= ns.length,
           ns.substring(with: before) == marker, ns.substring(with: after) == marker {
            let outer = NSRange(location: before.location, length: selection.length + 2 * width)
            let edit = EditorText.Edit(range: outer, replacement: ns.substring(with: selection))
            return (edit, NSRange(location: before.location, length: selection.length))
        }
        let selected = ns.substring(with: selection)
        if selected.hasPrefix(marker), selected.hasSuffix(marker), (selected as NSString).length >= 2 * width {
            let inner = (selected as NSString).substring(with: NSRange(location: width, length: (selected as NSString).length - 2 * width))
            return (EditorText.Edit(range: selection, replacement: inner), NSRange(location: selection.location, length: (inner as NSString).length))
        }
        let edit = EditorText.Edit(range: selection, replacement: marker + selected + marker)
        return (edit, NSRange(location: selection.location + width, length: selection.length))
    }

    /// The `<>` code button (SPEC §2.12): a selection inside one line gets
    /// single backticks (toggled, like bold); a selection across lines is
    /// fenced: its whole lines go between ``` lines, or lose them when they
    /// are already fenced. The new selection is the code itself.
    static func toggleCode(in text: String, selection: NSRange) -> (edit: EditorText.Edit, selection: NSRange) {
        let ns = text as NSString
        let selected = ns.substring(with: selection)
        guard selected.contains("\n") else { return toggleWrap("`", in: text, selection: selection) }

        // Whole lines, without the last line's terminator, and never a
        // trailing empty line the selection only touches at its start.
        var end = NSMaxRange(selection)
        if end > selection.location, ns.character(at: end - 1) == 10 { end -= 1 }
        let lines = ns.lineRange(for: NSRange(location: selection.location, length: end - selection.location))
        var body = NSRange(location: lines.location, length: NSMaxRange(lines) - lines.location)
        if body.length > 0, ns.character(at: NSMaxRange(body) - 1) == 10 { body.length -= 1 }

        // The selection is a whole block, fences included: unwrap it.
        let blockLines = ns.substring(with: body).components(separatedBy: "\n")
        if blockLines.count >= 2,
           blockLines[0].trimmingCharacters(in: .whitespaces).hasPrefix("```"),
           blockLines[blockLines.count - 1].trimmingCharacters(in: .whitespaces) == "```" {
            let inner = blockLines.dropFirst().dropLast().joined(separator: "\n")
            return (EditorText.Edit(range: body, replacement: inner),
                    NSRange(location: body.location, length: reclick(inner, followedByNewline: NSMaxRange(body) < ns.length)))
        }
        // Already fenced: the lines right above and below are fences.
        if body.location > 0, NSMaxRange(body) < ns.length {
            let above = ns.lineRange(for: NSRange(location: body.location - 1, length: 0))
            let below = ns.lineRange(for: NSRange(location: NSMaxRange(body) + 1, length: 0))
            let aboveText = ns.substring(with: above).trimmingCharacters(in: .whitespacesAndNewlines)
            let belowText = ns.substring(with: below).trimmingCharacters(in: .whitespacesAndNewlines)
            if aboveText.hasPrefix("```"), belowText == "```" {
                let whole = NSRange(location: above.location, length: NSMaxRange(below) - above.location)
                var inner = ns.substring(with: body)
                if NSMaxRange(below) < ns.length || ns.substring(with: below).hasSuffix("\n") { inner += "\n" }
                return (EditorText.Edit(range: whole, replacement: inner), NSRange(location: above.location, length: body.length))
            }
        }
        let code = ns.substring(with: body)
        let fenced = "```\n" + code + "\n```"
        let edit = EditorText.Edit(range: body, replacement: fenced)
        // The whole block, fences included, stays selected: the next click
        // takes it off again (MODAL.md).
        return (edit, NSRange(location: body.location, length: (fenced as NSString).length))
    }

    /// The selection left after unfencing. One line also takes its newline,
    /// so the next click fences it again instead of adding inline backticks.
    private static func reclick(_ inner: String, followedByNewline: Bool) -> Int {
        let length = (inner as NSString).length
        return !inner.contains("\n") && followedByNewline ? length + 1 : length
    }

    /// The table around the caret with its columns padded to one width, so
    /// it reads as a grid in the monospaced editor. Nil when the caret is not
    /// in a table or it is already aligned.
    static func alignedTable(in text: String, selection: NSRange) -> EditorText.Edit? {
        MarkdownTable.aligned(in: text, selection: selection)
    }

    // MARK: Patterns

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Literal patterns: a failure is a programming error caught by the tests.
        try! NSRegularExpression(pattern: pattern)
    }

    private static let heading = regex(#"^\s{0,3}(#{1,6})\s+\S"#)
    private static let quote = regex(#"^\s{0,3}(>+)"#)
    private static let listMarker = regex(#"^\s*([-*+]|\d+[.)])\s+"#)
    private static let rule = regex(#"^\s{0,3}([-*_])(\s*\1){2,}\s*$"#)
    private static let tableSeparator = regex(#"^\s*\|?(\s*:?-+:?\s*\|)+\s*(:?-+:?\s*)?$"#)
    private static let tablePipe = regex(#"(?<!\\)\|"#)
    private static let inlineCode = regex(#"(`+)(?!`).+?(?<!`)\1(?!`)"#)
    private static let bold = regex(#"(\*\*(?=\S)[^\n]*?(?<=\S)\*\*|__(?=\S)[^\n]*?(?<=\S)__)"#)
    private static let strike = regex(#"(~~(?=\S)[^\n]*?(?<=\S)~~)"#)
    private static let italic = regex(#"((?<![\*\w])\*(?![\s*])[^*\n]*?(?<![\s*])\*(?![\*\w])|(?<![_\w])_(?![\s_])[^_\n]*?(?<![\s_])_(?![_\w]))"#)
    private static let link = regex(#"\[([^\]\n]+)\](\([^)\s]*\))"#)

    private static func firstMatch(_ regex: NSRegularExpression, in ns: NSString, range: NSRange) -> NSTextCheckingResult? {
        regex.firstMatch(in: ns as String, range: range)
    }

    private static func matches(_ regex: NSRegularExpression, in ns: NSString, range: NSRange) -> [NSTextCheckingResult] {
        regex.matches(in: ns as String, range: range)
    }
}
