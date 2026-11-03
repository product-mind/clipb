import Foundation

/// A few lines of text with a caret: the title of a box or the label of an
/// arrow while it is being typed into on the drawing canvas. Pure, so the
/// keys are tested without a window. Columns count Characters.
struct CaretText: Equatable {
    var lines: [String]
    var line: Int
    var column: Int

    init(_ lines: [String], line: Int = .max, column: Int = .max) {
        self.lines = lines.isEmpty ? [""] : lines
        self.line = 0
        self.column = 0
        place(line: line, column: column)
    }

    var isEmpty: Bool { lines.allSatisfy(\.isEmpty) }

    /// Puts the caret as near as possible to a line and column.
    mutating func place(line: Int, column: Int) {
        self.line = min(max(0, line), lines.count - 1)
        self.column = min(max(0, column), lines[self.line].count)
    }

    private func index(_ column: Int) -> String.Index {
        lines[line].index(lines[line].startIndex, offsetBy: column)
    }

    /// Typed text at the caret; a newline in it splits the line.
    mutating func insert(_ typed: String) {
        let pieces = typed.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        for (k, piece) in pieces.enumerated() {
            if k > 0 { newline() }
            lines[line].insert(contentsOf: piece, at: index(column))
            column += piece.count
        }
    }

    mutating func newline() {
        let rest = String(lines[line][index(column)...])
        lines[line].removeSubrange(index(column)...)
        lines.insert(rest, at: line + 1)
        line += 1
        column = 0
    }

    /// False when there is nothing before the caret.
    @discardableResult
    mutating func backspace() -> Bool {
        if column > 0 {
            lines[line].remove(at: index(column - 1))
            column -= 1
            return true
        }
        guard line > 0 else { return false }
        let joined = lines.remove(at: line)
        line -= 1
        column = lines[line].count
        lines[line] += joined
        return true
    }

    mutating func deleteForward() {
        if column < lines[line].count {
            lines[line].remove(at: index(column))
        } else if line + 1 < lines.count {
            lines[line] += lines.remove(at: line + 1)
        }
    }

    /// The word before the caret, and the spaces after it.
    mutating func deleteWordBackward() {
        guard column > 0 else {
            backspace()
            return
        }
        let chars = Array(lines[line])
        var start = column
        while start > 0, chars[start - 1] == " " { start -= 1 }
        while start > 0, chars[start - 1] != " " { start -= 1 }
        lines[line].removeSubrange(index(start)..<index(column))
        column = start
    }

    mutating func left() {
        if column > 0 {
            column -= 1
        } else if line > 0 {
            line -= 1
            column = lines[line].count
        }
    }

    mutating func right() {
        if column < lines[line].count {
            column += 1
        } else if line + 1 < lines.count {
            line += 1
            column = 0
        }
    }

    mutating func up() {
        guard line > 0 else { return column = 0 }
        place(line: line - 1, column: column)
    }

    mutating func down() {
        guard line + 1 < lines.count else { return column = lines[line].count }
        place(line: line + 1, column: column)
    }

    mutating func home() { column = 0 }
    mutating func end() { column = lines[line].count }
}
