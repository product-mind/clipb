import Foundation

/// One `[pipe.<id>]` table: a shell command the cut text is piped through.
struct PipeCommand: Equatable {
    /// The `<id>` of `[pipe.<id>]`; also the history tag its output is filed under.
    var id: String
    var name: String
    var command: String
    /// Optional single letter, parsed and unused since Cmd+Shift+C became the screencapture (§2.11).
    var hotkey: String?
}

enum Pipes {
    /// Digit keys 1-9 pick a pipe, so the CHOOSER offers only the first nine.
    static let maxPipes = ChooserOptions.maxOptions
    static let tablePrefix = "pipe."
    static let timeout: TimeInterval = 30

    struct ConfigError: Error, CustomStringConvertible {
        let description: String
    }

    /// All `[pipe.<id>]` tables in file order, untruncated: the chooser applies
    /// `maxPipes` itself, and a pipe past the ninth still parses.
    /// `run` is required; `name` defaults to the id.
    static func parse(_ tables: [TOML.Table]) throws -> [PipeCommand] {
        var pipes: [PipeCommand] = []
        for table in tables where table.name.hasPrefix(tablePrefix) {
            let id = String(table.name.dropFirst(tablePrefix.count))
            var name = id
            var command: String?
            var hotkey: String?
            for (key, value) in table.entries {
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
            pipes.append(PipeCommand(id: id, name: name, command: command, hotkey: hotkey))
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
