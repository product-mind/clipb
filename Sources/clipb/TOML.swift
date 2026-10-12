import Foundation

/// Minimal TOML subset: `[table]` headers, `key = value` lines with string,
/// integer or boolean values, and `#` comments. Entries keep file order,
/// which first-match-wins routing depends on.
enum TOML {
    enum Value: Equatable {
        case string(String)
        case int(Int)
        case bool(Bool)
    }

    struct Table {
        var name: String
        var entries: [(key: String, value: Value)] = []
    }

    struct ParseError: Error, CustomStringConvertible {
        let line: Int
        let message: String
        var description: String { "line \(line): \(message)" }
    }

    /// Entries before the first header land in a table named "".
    static func parse(_ text: String) throws -> [Table] {
        var tables = [Table(name: "")]
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (n, rawLine) in lines.enumerated() {
            var scanner = Scanner(Array(rawLine), line: n + 1)
            scanner.skipSpaces()
            if scanner.atEnd || scanner.peek == "#" { continue }

            if scanner.peek == "[" {
                tables.append(Table(name: try scanner.header()))
            } else {
                let key = try scanner.key()
                scanner.skipSpaces()
                try scanner.expect("=")
                scanner.skipSpaces()
                let value = try scanner.value()
                tables[tables.count - 1].entries.append((key, value))
            }
            scanner.skipSpaces()
            if !scanner.atEnd && scanner.peek != "#" {
                throw scanner.error("unexpected text after value")
            }
        }
        return tables
    }

    private struct Scanner {
        let chars: [Character]
        let line: Int
        var i = 0

        init(_ chars: [Character], line: Int) {
            self.chars = chars
            self.line = line
        }

        var atEnd: Bool { i >= chars.count }
        var peek: Character { chars[i] }

        func error(_ message: String) -> ParseError { ParseError(line: line, message: message) }

        mutating func skipSpaces() {
            while !atEnd, peek == " " || peek == "\t" || peek == "\r" { i += 1 }
        }

        mutating func expect(_ c: Character) throws {
            guard !atEnd, peek == c else { throw error("expected '\(c)'") }
            i += 1
        }

        mutating func header() throws -> String {
            i += 1
            guard !atEnd, peek != "[" else { throw error("array tables are not supported") }
            var name = ""
            while !atEnd, peek != "]" {
                name.append(peek)
                i += 1
            }
            try expect("]")
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { throw error("empty table name") }
            return trimmed
        }

        mutating func key() throws -> String {
            if !atEnd, peek == "\"" || peek == "'" { return try quoted() }
            var key = ""
            while !atEnd, peek.isLetter || peek.isNumber || peek == "_" || peek == "-" || peek == "." {
                key.append(peek)
                i += 1
            }
            guard !key.isEmpty else { throw error("expected a key") }
            return key
        }

        mutating func value() throws -> Value {
            guard !atEnd else { throw error("missing value") }
            if peek == "\"" || peek == "'" { return .string(try quoted()) }
            var word = ""
            while !atEnd, peek != "#", peek != " ", peek != "\t", peek != "\r" {
                word.append(peek)
                i += 1
            }
            switch word {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default:
                if let n = Int(word.replacingOccurrences(of: "_", with: "")) { return .int(n) }
                throw error("unsupported value '\(word)'")
            }
        }

        /// Basic strings (with escapes) and literal 'strings'.
        mutating func quoted() throws -> String {
            let quote = peek
            i += 1
            var out = ""
            while !atEnd {
                let c = peek
                i += 1
                if c == quote { return out }
                guard c == "\\", quote == "\"" else {
                    out.append(c)
                    continue
                }
                guard !atEnd else { break }
                let escaped = peek
                i += 1
                switch escaped {
                case "\"", "\\": out.append(escaped)
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                default: throw error("unsupported escape '\\\(escaped)'")
                }
            }
            throw error("unterminated string")
        }
    }
}
