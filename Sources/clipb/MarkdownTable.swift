import Foundation

/// Markdown pipe tables in the editor (SPEC §2.12, MODAL.md): find the table
/// at a location, re-pad its columns to the longest cell while keeping the
/// caret in its cell, and insert tables, rows and columns. Pure, tested.
/// Widths count Characters; offsets and ranges are UTF-16, like NSString.
enum MarkdownTable {
    /// Narrowest column: `---` is the shortest separator GitHub accepts.
    static let minimumWidth = 3

    /// A caret inside a table: which cell, and how far into its content.
    struct Caret: Equatable {
        var row: Int
        var column: Int
        var offset: Int
    }

    /// The table's lines with contents trimmed; the separator row keeps its
    /// `:` alignment marks.
    struct Model: Equatable {
        var rows: [[String]]
        var separator: Int?
        var trailingNewline: Bool

        var columns: Int { rows.map(\.count).max() ?? 0 }
    }

    // MARK: Finding a table

    /// The whole lines of the table around `location`, or nil when that line
    /// is not a table row (`|…`). Never inside a code block.
    static func blockRange(in text: String, at location: Int) -> NSRange? {
        let ns = text as NSString
        let at = min(max(location, 0), ns.length)
        var start = ns.lineRange(for: NSRange(location: at, length: 0))
        guard isTableLine(ns.substring(with: start)), !Markdown.isInsideFence(in: text, at: at) else { return nil }
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
        return NSRange(location: start.location, length: NSMaxRange(end) - start.location)
    }

    static func isTableLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    }

    // MARK: Parsing

    /// The raw cells of one line: UTF-16 ranges between unescaped pipes. Text
    /// before the first pipe is not a cell; text after the last one is, once
    /// it holds something (typing there adds a column).
    static func cellRanges(of line: String) -> [NSRange] {
        let ns = line as NSString
        var pipes: [Int] = []
        var escaped = false
        for i in 0..<ns.length {
            let ch = ns.character(at: i)
            if ch == 124, !escaped { pipes.append(i) }
            escaped = ch == 92 && !escaped
        }
        guard let first = pipes.first else { return [] }
        var ranges: [NSRange] = []
        for (a, b) in zip(pipes, pipes.dropFirst()) {
            ranges.append(NSRange(location: a + 1, length: b - a - 1))
        }
        let tailStart = (pipes.last ?? first) + 1
        let tail = NSRange(location: tailStart, length: ns.length - tailStart)
        if !ns.substring(with: tail).trimmingCharacters(in: .whitespaces).isEmpty || ranges.isEmpty {
            ranges.append(tail)
        }
        return ranges
    }

    /// The model of `block` (a table's whole lines). With `caret` (relative
    /// to the block), also where it sits; its cell keeps the spaces typed up
    /// to the caret, so a space at the end of a word survives the re-pad.
    static func model(of block: String, caret: Int? = nil) -> (Model, Caret?) {
        let trailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if trailingNewline { lines.removeLast() }
        var rows: [[String]] = []
        var found: Caret?
        var lineStart = 0
        for (index, line) in lines.enumerated() {
            let ns = line as NSString
            let ranges = cellRanges(of: line)
            var cells: [String] = []
            for (c, range) in ranges.enumerated() {
                let raw = ns.substring(with: range)
                let leading = raw.prefix { $0 == " " || $0 == "\t" }
                let leadingLength = (String(leading) as NSString).length
                var content = raw.trimmingCharacters(in: .whitespaces)
                if let caret, found == nil {
                    let local = caret - lineStart
                    let isLast = c == ranges.count - 1
                    let inside = local >= range.location && local <= NSMaxRange(range)
                    let past = isLast && local > NSMaxRange(range) && local <= ns.length
                    let before = c == 0 && local >= 0 && local < range.location
                    if inside || past || before {
                        let contentLength = (content as NSString).length
                        var offset = inside ? local - range.location - leadingLength : (before ? 0 : contentLength)
                        offset = max(0, offset)
                        if offset > contentLength {
                            // Spaces typed after the content: kept up to the caret.
                            content += String(repeating: " ", count: offset - contentLength)
                        }
                        found = Caret(row: index, column: c, offset: offset)
                    }
                }
                cells.append(content)
            }
            rows.append(cells)
            lineStart += ns.length + 1
        }
        let separator = rows.firstIndex { row in !row.isEmpty && row.allSatisfy(isSeparatorCell) }
        return (Model(rows: rows, separator: separator, trailingNewline: trailingNewline), found)
    }

    static func isSeparatorCell(_ cell: String) -> Bool {
        !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" } && cell.contains("-")
    }

    // MARK: Rendering

    /// The aligned text and, per row and column, the range of the content
    /// inside it (relative to the text).
    static func render(_ model: Model) -> (text: String, cells: [[NSRange]]) {
        let columns = model.columns
        var widths = [Int](repeating: minimumWidth, count: columns)
        for (i, row) in model.rows.enumerated() where i != model.separator {
            for (c, cell) in row.enumerated() { widths[c] = max(widths[c], cell.count) }
        }
        var text = ""
        var cells: [[NSRange]] = []
        for (i, row) in model.rows.enumerated() {
            var line = "|"
            var ranges: [NSRange] = []
            for c in 0..<columns {
                let cell = c < row.count ? row[c] : ""
                let content: String
                if i == model.separator {
                    let left = cell.hasPrefix(":"), right = cell.count > 1 && cell.hasSuffix(":")
                    let dashes = String(repeating: "-", count: widths[c] - (left ? 1 : 0) - (right ? 1 : 0))
                    content = (left ? ":" : "") + dashes + (right ? ":" : "")
                } else {
                    content = cell
                }
                line += " "
                let start = (text as NSString).length + (line as NSString).length
                ranges.append(NSRange(location: start, length: (content as NSString).length))
                line += content + String(repeating: " ", count: max(0, widths[c] - content.count)) + " |"
            }
            text += line
            if i < model.rows.count - 1 || model.trailingNewline { text += "\n" }
            cells.append(ranges)
        }
        return (text, cells)
    }

    // MARK: Editing

    /// The table at the caret, re-padded. Nil when not in a table or already
    /// aligned.
    static func aligned(in text: String, selection: NSRange) -> EditorText.Edit? {
        guard let block = blockRange(in: text, at: selection.location) else { return nil }
        let original = (text as NSString).substring(with: block)
        let rendered = render(model(of: original).0).text
        return rendered == original ? nil : EditorText.Edit(range: block, replacement: rendered)
    }

    /// While typing: the table re-padded with the caret in the same cell at
    /// the same spot. Only a real table (one with its `---` row), so typing
    /// the first `|` of a header is left alone. Nil when nothing changes.
    static func liveAligned(in text: String, caret: Int) -> (edit: EditorText.Edit, caret: Int)? {
        guard let block = blockRange(in: text, at: caret) else { return nil }
        let original = (text as NSString).substring(with: block)
        let (model, at) = model(of: original, caret: caret - block.location)
        guard model.separator != nil, let at else { return nil }
        let (rendered, cells) = render(model)
        let location = block.location + caretLocation(at, in: cells, model: model)
        guard rendered != original else { return nil }
        return (EditorText.Edit(range: block, replacement: rendered), location)
    }

    private static func caretLocation(_ caret: Caret, in cells: [[NSRange]], model: Model) -> Int {
        let range = cells[caret.row][caret.column]
        let offset = caret.row == model.separator ? min(caret.offset, range.length) : caret.offset
        return range.location + offset
    }

    /// An empty table: `rows` includes the header, then the `---` row.
    static func empty(rows: Int, columns: Int) -> String {
        let columns = max(1, columns)
        var lines = [[String]](repeating: [String](repeating: "", count: columns), count: max(1, rows))
        lines.insert([String](repeating: "---", count: columns), at: 1)
        return render(Model(rows: lines, separator: 1, trailingNewline: false)).text
    }

    /// A new table at the caret: on its own lines, a blank line between it
    /// and text around it, caret in the first header cell.
    static func insert(rows: Int, columns: Int, in text: String, selection: NSRange) -> (edit: EditorText.Edit, selection: NSRange) {
        let ns = text as NSString
        let line = ns.lineRange(for: NSRange(location: min(selection.location, ns.length), length: 0))
        var content = line
        if content.length > 0, ns.character(at: NSMaxRange(content) - 1) == 10 { content.length -= 1 }
        let lineIsEmpty = ns.substring(with: content).trimmingCharacters(in: .whitespaces).isEmpty
        let table = empty(rows: rows, columns: columns)
        let range: NSRange
        var before = ""
        if lineIsEmpty {
            range = content
            if content.location > 0, ns.substring(with: ns.lineRange(for: NSRange(location: content.location - 1, length: 0)))
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                before = "\n"
            }
        } else {
            range = NSRange(location: NSMaxRange(content), length: 0)
            before = "\n\n"
        }
        // GitHub runs a table on into the next non-blank line: keep one blank.
        let nextLine = NSMaxRange(line) < ns.length ? ns.substring(with: ns.lineRange(for: NSRange(location: NSMaxRange(line), length: 0))) : ""
        let after = nextLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n"
        let replacement = before + table + after
        // "| " then the first header cell.
        let caret = range.location + (before as NSString).length + 2
        return (EditorText.Edit(range: range, replacement: replacement), NSRange(location: caret, length: 0))
    }

    /// One empty row under the caret's row (under the `---` row when the
    /// caret is in the header), or at the bottom with `atEnd` (the `+`
    /// button). Caret in its first cell.
    static func addRow(in text: String, at location: Int, atEnd: Bool = false) -> (edit: EditorText.Edit, selection: NSRange)? {
        edit(in: text, at: location) { model, caret in
            let below = atEnd ? model.rows.count : max(caret.row, model.separator ?? caret.row) + 1
            model.rows.insert([String](repeating: "", count: model.columns), at: below)
            return Caret(row: below, column: 0, offset: 0)
        }
    }

    /// One empty column right of the caret's column, or last with `atEnd`
    /// (the `+` button). Caret in it on the same row.
    static func addColumn(in text: String, at location: Int, atEnd: Bool = false) -> (edit: EditorText.Edit, selection: NSRange)? {
        edit(in: text, at: location) { model, caret in
            let columns = model.columns
            let at = atEnd ? columns : caret.column + 1
            for i in model.rows.indices {
                while model.rows[i].count < columns { model.rows[i].append("") }
                model.rows[i].insert(i == model.separator ? "---" : "", at: at)
            }
            return Caret(row: caret.row, column: at, offset: 0)
        }
    }

    /// Tab: the end of the next cell's content (Shift+Tab: the previous one),
    /// skipping the `---` row. Tab in the last cell adds a row. Nil outside
    /// a table.
    static func moveCell(in text: String, at location: Int, backward: Bool) -> (edit: EditorText.Edit?, selection: NSRange)? {
        guard let block = blockRange(in: text, at: location) else { return nil }
        let original = (text as NSString).substring(with: block)
        let (model, found) = model(of: original, caret: location - block.location)
        guard let caret = found else { return nil }
        let columns = model.columns
        var row = caret.row, column = caret.column
        repeat {
            column += backward ? -1 : 1
            if column >= columns { column = 0; row += 1 }
            if column < 0 { column = columns - 1; row -= 1 }
        } while row == model.separator
        if row < 0 { return (nil, NSRange(location: location, length: 0)) }
        if row >= model.rows.count { return addRow(in: text, at: location).map { ($0.edit, $0.selection) } }
        var aligned = model
        // The caret's own typed trailing spaces go: it is leaving the cell.
        aligned.rows[caret.row] = aligned.rows[caret.row].map { $0.trimmingCharacters(in: .whitespaces) }
        let (rendered, cells) = render(aligned)
        let range = cells[row][column]
        let target = block.location + NSMaxRange(range)
        let edit = rendered == original ? nil : EditorText.Edit(range: block, replacement: rendered)
        return (edit, NSRange(location: target, length: 0))
    }

    private static func edit(
        in text: String, at location: Int, _ change: (inout Model, Caret) -> Caret
    ) -> (edit: EditorText.Edit, selection: NSRange)? {
        guard let block = blockRange(in: text, at: location) else { return nil }
        let original = (text as NSString).substring(with: block)
        var (model, found) = model(of: original, caret: location - block.location)
        let caret = found ?? Caret(row: 0, column: max(0, model.columns - 1), offset: 0)
        let target = change(&model, caret)
        let (rendered, cells) = render(model)
        let at = block.location + caretLocation(target, in: cells, model: model)
        return (EditorText.Edit(range: block, replacement: rendered), NSRange(location: at, length: 0))
    }
}
