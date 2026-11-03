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
        var inFence = false

        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            let body = ns.substring(with: line)
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                lines.append(Span(kind: .codeBlock, range: line))
                syntax.append(Span(kind: .syntax, range: line))
                inFence.toggle()
                return
            }
            if inFence {
                lines.append(Span(kind: .codeBlock, range: line))
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

    private static func inlineSpans(in ns: NSString, line: NSRange, spans: inout [Span], syntax: inout [Span]) {
        // Code first: nothing inside backticks is bold or italic.
        var code: [NSRange] = []
        for m in matches(inlineCode, in: ns, range: line) {
            code.append(m.range)
            spans.append(Span(kind: .code, range: m.range))
            syntax.append(Span(kind: .syntax, range: NSRange(location: m.range.location, length: m.range(at: 1).length)))
            syntax.append(Span(kind: .syntax, range: NSRange(location: NSMaxRange(m.range) - m.range(at: 1).length, length: m.range(at: 1).length)))
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
        guard selection.length == 0 else { return nil }
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

    /// The table around the caret with its columns padded to one width, so
    /// it reads as a grid in the monospaced editor. Nil when the caret is not
    /// in a table or it is already aligned.
    static func alignedTable(in text: String, selection: NSRange) -> EditorText.Edit? {
        let ns = text as NSString
        var start = ns.lineRange(for: NSRange(location: min(selection.location, ns.length), length: 0))
        guard isTableLine(ns.substring(with: start)) else { return nil }
        var end = start
        while start.location > 0 {
            let previous = ns.lineRange(for: NSRange(location: start.location - 1, length: 0))
            guard isTableLine(ns.substring(with: previous)) else { break }
            start = previous
        }
        while NSMaxRange(end) < ns.length {
            let next = ns.lineRange(for: NSRange(location: NSMaxRange(end), length: 0))
            guard isTableLine(ns.substring(with: next)) else { break }
            end = next
        }
        let block = NSRange(location: start.location, length: NSMaxRange(end) - start.location)
        let original = ns.substring(with: block)
        let trailingNewline = original.hasSuffix("\n")
        let rows = original.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let cells = rows.map(splitRow)
        let columns = cells.map(\.count).max() ?? 0
        let separatorRows = Set(cells.indices.filter { cells[$0].allSatisfy(isSeparatorCell) })
        var widths = [Int](repeating: 3, count: columns)
        for (i, row) in cells.enumerated() where !separatorRows.contains(i) {
            for (c, cell) in row.enumerated() { widths[c] = max(widths[c], cell.count) }
        }
        let lines = cells.enumerated().map { i, row -> String in
            let padded = (0..<columns).map { c -> String in
                let cell = c < row.count ? row[c] : ""
                if separatorRows.contains(i) {
                    let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
                    let dashes = String(repeating: "-", count: widths[c] - (left ? 1 : 0) - (right ? 1 : 0))
                    return (left ? ":" : "") + dashes + (right ? ":" : "")
                }
                return cell + String(repeating: " ", count: widths[c] - cell.count)
            }
            return "| " + padded.joined(separator: " | ") + " |"
        }
        let aligned = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        guard aligned != original else { return nil }
        return EditorText.Edit(range: block, replacement: aligned)
    }

    private static func isTableLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    }

    private static func isSeparatorCell(_ cell: String) -> Bool {
        !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" } && cell.contains("-")
    }

    /// `| a | b |` → ["a", "b"]. Escaped `\|` stays inside its cell.
    private static func splitRow(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in body {
            if ch == "|", !escaped {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
            escaped = ch == "\\" && !escaped
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
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
