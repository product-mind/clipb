import Foundation

/// One `[pipe.<id>]` table: a shell command the cut text is piped through.
struct PipeCommand: Equatable {
    /// The `<id>` of `[pipe.<id>]`; also the history tag its output is filed under.
    var id: String
    var name: String
    var command: String
    /// Optional single letter, bound to a global Cmd+Shift+<letter> chord (§2.10).
    var hotkey: String?
    /// Seconds before the command is killed. 0 means no scheduled kill at all.
    var timeout: TimeInterval = Pipes.defaultTimeout
}

/// A pipe bound to a global chord: a letter, the pipe that owns it.
struct PipeHotKey: Equatable {
    /// Lowercase: the chord is always Cmd+Shift+<letter>.
    var letter: String
    var pipe: PipeCommand
}

enum Pipes {
    /// Digit keys 1-9 pick a pipe, so the CHOOSER offers only the first nine.
    static let maxPipes = ChooserOptions.maxOptions
    static let tablePrefix = "pipe."
    /// Ten minutes: long enough for an interactive pipe, short enough to not leak a hung command.
    static let defaultTimeout: TimeInterval = 600
    /// The chords the built-in hotkeys own: Cmd+Shift+V, X, C and I.
    static let reservedHotkeys: Set<String> = ["v", "x", "c", "i"]

    /// Folds A-Z to a-z and leaves every other scalar alone. Never `lowercased()`:
    /// a locale-aware fold turns "I" into "ı", which would quietly unbind the chord.
    static func asciiLowercased(_ text: String) -> String {
        var folded = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let isUpper = (0x41...0x5A).contains(scalar.value)
            folded.append(isUpper ? UnicodeScalar(scalar.value + 0x20)! : scalar)
        }
        return String(folded)
    }

    /// The pipes a `hotkey` letter binds to a real chord, in file order. The first
    /// pipe in file order keeps a letter two pipes share; a reserved letter is
    /// skipped case-insensitively, and so is a letter no key can send. Registered
    /// once at launch, so a changed `hotkey` applies on the next launch.
    static func hotkeys(_ pipes: [PipeCommand], reserved: Set<String> = reservedHotkeys) -> [PipeHotKey] {
        var used = Set(reserved.map { asciiLowercased($0) })
        var bound: [PipeHotKey] = []
        for pipe in pipes {
            guard let letter = pipe.hotkey.map({ asciiLowercased($0) }), letter.count == 1,
                  letter.allSatisfy({ $0.isASCII && $0.isLetter }),
                  used.insert(letter).inserted else { continue }
            bound.append(PipeHotKey(letter: letter, pipe: pipe))
        }
        return bound
    }

    struct ConfigError: Error, CustomStringConvertible {
        let description: String
    }

    /// All `[pipe.<id>]` tables in file order, untruncated: the chooser applies
    /// `maxPipes` itself, and a pipe past the ninth still parses.
    /// `run` is required; `name` defaults to the id, `timeout` to `defaultTimeout`.
    static func parse(_ tables: [TOML.Table]) throws -> [PipeCommand] {
        var pipes: [PipeCommand] = []
        for table in tables where table.name.hasPrefix(tablePrefix) {
            let id = String(table.name.dropFirst(tablePrefix.count))
            var name = id
            var command: String?
            var hotkey: String?
            var timeout = defaultTimeout
            for (key, value) in table.entries {
                // `editor` was the old pipe flag; the Cmd+Shift+I hotkey replaced it (§2.12), so ignore any value.
                if key == "editor" { continue }
                if key == "timeout" {
                    guard case .int(let seconds) = value else {
                        throw ConfigError(description: "[\(table.name)] timeout must be a whole number of seconds (0 = no limit)")
                    }
                    guard seconds >= 0 else {
                        throw ConfigError(description: "[\(table.name)] timeout cannot be negative (0 = no limit)")
                    }
                    timeout = TimeInterval(seconds)
                    continue
                }
                guard case .string(let text) = value else {
                    throw ConfigError(description: "[\(table.name)] \(key) must be a string")
                }
                switch key {
                case "name": name = text
                case "run": command = text
                case "hotkey":
                    guard text.count == 1, text.allSatisfy({ $0.isASCII && $0.isLetter }) else {
                        throw ConfigError(description: "[\(table.name)] hotkey must be a single letter")
                    }
                    hotkey = text
                default: continue
                }
            }
            guard let command, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ConfigError(description: "[\(table.name)] needs run = \"<command>\"")
            }
            pipes.append(PipeCommand(id: id, name: name, command: command, hotkey: hotkey, timeout: timeout))
        }
        return pipes
    }

    /// A missing config file means no pipes.
    static func load(from url: URL = RouterConfig.defaultPath) throws -> [PipeCommand] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try parse(TOML.parse(String(contentsOf: url, encoding: .utf8)))
    }

    enum Outcome: Equatable {
        /// Replace the cut text with the command's output.
        case paste(String)
        /// Success with no output: the text stays cut (a sink, e.g. a to-do file).
        case keepCut
        /// Failure: put the original text back.
        case restore
    }

    /// What a pipe reads on stdin: the text's bytes, an image's PNG bytes, or
    /// the file URLs one per line. Pipes are text programs, so a file ref is
    /// its URL string, never the file's bytes.
    static func stdin(for entry: ClipEntry) -> Data {
        if let image = entry.image { return image }
        if let urls = entry.fileURLs {
            return Data(urls.map(\.absoluteString).joined(separator: "\n").utf8)
        }
        return Data(entry.value.utf8)
    }

    /// `status` is nil when the command never ran to completion (launch failure, timeout, cancel).
    static func outcome(status: Int32?, stdout: Data) -> Outcome {
        guard status == 0, let text = String(data: stdout, encoding: .utf8) else { return .restore }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .keepCut }
        // Commands end their output with a newline that was never part of the selection.
        var output = Substring(text)
        while output.last?.isNewline == true { output = output.dropLast() }
        return .paste(String(output))
    }
}
