import Foundation

/// The pure text rules behind the Cmd+Shift+E editor: line quoting, indent and
/// outdent, case transforms, the word at the caret, and the trim every save
/// runs. Each line rule returns the whole affected range with its replacement,
/// so the view makes one range replacement and the operation is one undo step.
enum EditorText {
    /// A whole-range edit: `replacement` takes the place of `range`.
    struct Edit: Equatable {
        var range: NSRange
        var replacement: String
    }

    /// The indentation widths a space-indented buffer is snapped to.
    static let indentWidths = [2, 4, 8]

    // MARK: Lines

    /// The full lines a selection touches, terminators included.
    static func lineRange(in text: String, selection: NSRange) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(selection.location, 0), length)
        let end = min(max(selection.location + selection.length, location), length)
        return (text as NSString).lineRange(for: NSRange(location: location, length: end - location))
    }

    /// A line span split into lines plus whether it ended in a newline, so a
    /// rejoin neither adds nor drops the buffer's final terminator.
    private static func split(_ span: String) -> (lines: [String], trailingNewline: Bool) {
        guard !span.isEmpty else { return ([""], false) }
        let trailing = span.hasSuffix("\n")
        let body = trailing ? String(span.dropLast()) : span
        return (body.components(separatedBy: "\n"), trailing)
    }

    private static func edit(_ range: NSRange, _ lines: [String], _ trailingNewline: Bool) -> Edit {
        Edit(range: range, replacement: lines.joined(separator: "\n") + (trailingNewline ? "\n" : ""))
    }

    // MARK: Quoting

    /// Toggle `> ` on every selected line: it comes off only when every
    /// non-empty line already carries it, so a mixed selection quotes instead
    /// of half-removing.
    static func toggleQuote(in text: String, selection: NSRange) -> Edit {
        let range = lineRange(in: text, selection: selection)
        let (lines, trailing) = split((text as NSString).substring(with: range))
        let quoted = lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .allSatisfy { $0.hasPrefix("> ") || $0 == ">" }
        let mapped = lines.map { line -> String in
            // Trim turns "> " on a blank line into a bare ">", so both forms come off.
            if quoted {
                if line.hasPrefix("> ") { return String(line.dropFirst(2)) }
                if line.hasPrefix(">") { return String(line.dropFirst(1)) }
                return line
            }
            return "> " + line
        }
        return edit(range, mapped, trailing)
    }

    // MARK: Indent

    /// The buffer's indentation unit: a tab when tab lines are at least as
    /// common as space lines, else the most common leading-space run snapped to
    /// 2/4/8, else four spaces for a buffer with no indentation at all.
    static func indentUnit(in text: String) -> String {
        var tabLines = 0
        var spaceLines = 0
        var runs: [Int: Int] = [:]
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("\t") {
                tabLines += 1
            } else if line.hasPrefix("  ") {
                spaceLines += 1
                runs[line.prefix { $0 == " " }.count, default: 0] += 1
            }
        }
        if tabLines > 0 && tabLines >= spaceLines { return "\t" }
        guard spaceLines > 0 else { return String(repeating: " ", count: 4) }
        // An exact count tie goes to the smaller width: the less aggressive indent.
        let width = runs.max { a, b in
            a.value == b.value ? a.key > b.key : a.value < b.value
        }!.key
        return String(repeating: " ", count: nearestIndentWidth(width))
    }

    // A width between two allowed ones snaps to the nearer, the smaller on a tie.
    private static func nearestIndentWidth(_ width: Int) -> Int {
        indentWidths.min { a, b in
            let da = abs(a - width)
            let db = abs(b - width)
            return da == db ? a < b : da < db
        } ?? 4
    }

    /// One unit on the front of every selected line.
    static func indent(in text: String, selection: NSRange) -> Edit {
        let range = lineRange(in: text, selection: selection)
        let (lines, trailing) = split((text as NSString).substring(with: range))
        let unit = indentUnit(in: text)
        return edit(range, lines.map { unit + $0 }, trailing)
    }

    /// One unit off the front of every selected line, or whatever prefix of it
    /// the line has, so a 2-space line still moves under a 4-space unit.
    static func outdent(in text: String, selection: NSRange) -> Edit {
        let range = lineRange(in: text, selection: selection)
        let (lines, trailing) = split((text as NSString).substring(with: range))
        let unit = indentUnit(in: text)
        return edit(range, lines.map { removing(unit, from: $0) }, trailing)
    }

    private static func removing(_ unit: String, from line: String) -> String {
        var removed = 0
        for (u, l) in zip(unit, line) where u == l { removed += 1 }
        return String(line.dropFirst(removed))
    }

    // MARK: Case

    /// Uppercase the selection, or the word at the caret when nothing is selected.
    static func uppercased(in text: String, selection: NSRange) -> Edit? {
        transform(in: text, selection: selection) { $0.uppercased() }
    }

    /// Lowercase the selection, or the word at the caret when nothing is selected.
    static func lowercased(in text: String, selection: NSRange) -> Edit? {
        transform(in: text, selection: selection) { $0.lowercased() }
    }

    private static func transform(
        in text: String,
        selection: NSRange,
        _ body: (String) -> String
    ) -> Edit? {
        let text = text as NSString
        guard let range = selection.length > 0 ? selection : wordRange(in: text, at: selection.location) else {
            return nil
        }
        return Edit(range: range, replacement: body(text.substring(with: range)))
    }

    /// The run of letters, digits and `_` the caret sits in or touches, so a
    /// caret at a word's edge still transforms that word.
    static func wordRange(in text: NSString, at location: Int) -> NSRange? {
        let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        let caret = min(max(location, 0), text.length)
        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < text.length, let scalar = Unicode.Scalar(text.character(at: index)) else {
                return false
            }
            return word.contains(scalar)
        }
        var start = caret
        var end = caret
        while isWord(end) { end += 1 }
        while isWord(start - 1) { start -= 1 }
        guard start < end else { return nil }
        return NSRange(location: start, length: end - start)
    }

    // MARK: Trim

    /// Trailing spaces and tabs come off every line. Newlines are untouched, so
    /// a buffer with no final newline still has none and vice versa.
    static func trimmed(_ text: String) -> String {
        text.components(separatedBy: "\n").map(trimmingTrailingWhitespace).joined(separator: "\n")
    }

    private static func trimmingTrailingWhitespace(_ line: String) -> String {
        var end = line.endIndex
        while end > line.startIndex {
            let previous = line.index(before: end)
            if line[previous] != " " && line[previous] != "\t" { break }
            end = previous
        }
        return String(line[line.startIndex..<end])
    }

    // MARK: Selection

    /// The selection to restore after `edit`: a range keeps its span, shifted
    /// by the edit's length change, while a bare caret keeps its line and
    /// column, moved past any indentation the edit added.
    static func restoredSelection(edit: Edit, oldText: String, selection: NSRange) -> NSRange {
        let newLength = (edit.replacement as NSString).length
        let newEnd = edit.range.location + newLength
        if selection.length > 0 {
            let delta = newLength - edit.range.length
            let start = min(max(selection.location, edit.range.location), newEnd)
            let end = min(selection.location + selection.length + delta, newEnd)
            return NSRange(location: start, length: max(0, end - start))
        }
        let oldSpan = (oldText as NSString).substring(with: edit.range) as NSString
        let newSpan = edit.replacement as NSString
        let caret = min(max(selection.location - edit.range.location, 0), oldSpan.length)
        let line = lineNumber(in: oldSpan, at: caret)
        let oldWidth = lineLength(in: oldSpan, line: line)
        let newWidth = lineLength(in: newSpan, line: line)
        let column = caret - lineStartOffset(in: oldSpan, line: line) + newWidth - oldWidth
        let location = edit.range.location + lineStartOffset(in: newSpan, line: line) + min(max(column, 0), newWidth)
        return NSRange(location: location, length: 0)
    }

    private static func lineNumber(in text: NSString, at location: Int) -> Int {
        var line = 0
        var index = 0
        while index < location, let next = newline(in: text, from: index, to: location) {
            line += 1
            index = next + 1
        }
        return line
    }

    private static func lineStartOffset(in text: NSString, line: Int) -> Int {
        var found = 0
        var index = 0
        while found < line, let next = newline(in: text, from: index, to: text.length) {
            found += 1
            index = next + 1
        }
        return index
    }

    private static func lineLength(in text: NSString, line: Int) -> Int {
        let start = lineStartOffset(in: text, line: line)
        guard start < text.length else { return 0 }
        guard let next = newline(in: text, from: start, to: text.length) else { return text.length - start }
        return next - start
    }

    private static func newline(in text: NSString, from index: Int, to limit: Int) -> Int? {
        guard index < limit else { return nil }
        let found = text.range(of: "\n", options: [], range: NSRange(location: index, length: limit - index))
        return found.location == NSNotFound ? nil : found.location
    }
}
