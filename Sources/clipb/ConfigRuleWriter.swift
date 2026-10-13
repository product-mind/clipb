import Foundation

/// Saves a chooser pick as a `[router]` rule. The text edit is pure; `remember` does the file I/O.
enum ConfigRuleWriter {
    /// Replaces the target of a rule with the same pattern, else inserts a new rule.
    /// A new rule goes before the catch-all `"*"`, so the catch-all cannot shadow it.
    static func insertRule(into text: String, pattern: String, target: String) -> String {
        let crlf = text.contains("\r\n")
        let eol = crlf ? "\r\n" : "\n"
        var lines = text.components(separatedBy: "\n").map { line in
            crlf && line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        if lines.last == "" { lines.removeLast() }

        var headers: [Int] = []
        var rules: [(index: Int, key: String)] = []
        var inRouter = false
        for (i, line) in lines.enumerated() {
            if let name = tableName(line) {
                inRouter = name == "router"
                if inRouter { headers.append(i) }
                continue
            }
            if inRouter, let entry = ruleEntry(line) { rules.append((i, entry)) }
        }

        if let rule = rules.first(where: { $0.key == pattern }) {
            lines[rule.index] = replacingValue(in: lines[rule.index], with: target) ?? lines[rule.index]
        } else if let catchAll = rules.first(where: { $0.key == "*" }) {
            lines.insert(ruleLine(pattern, target), at: catchAll.index)
        } else if let last = rules.last {
            lines.insert(ruleLine(pattern, target), at: last.index + 1)
        } else if let header = headers.first {
            lines.insert(ruleLine(pattern, target), at: header + 1)
        } else {
            if let end = lines.last, !end.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("")
            }
            lines += ["[router]", ruleLine(pattern, target)]
        }
        return lines.map { $0 + eol }.joined()
    }

    /// The `"browser:profile"` string that a chooser pick should store, reusing a `[profiles]` alias when one matches.
    static func targetString(for option: ChooserOption, localState: Data?, aliases: [String: String]) -> String {
        let spec = profileSpec(for: option, localState: localState)
        if let alias = aliases.filter({ $0.value == spec }).keys.sorted().first { return alias }
        return spec
    }

    /// Writes the rule to `path` (the config by default). A missing file counts as empty;
    /// an unparsable one is left untouched.
    static func remember(pattern: String, option: ChooserOption, localState: Data?,
                         at path: URL = RouterConfig.defaultPath) throws {
        // Resolve symlinks first, so the atomic write does not replace a dotfiles link with a plain file.
        let url = path.resolvingSymlinksInPath()
        var text = ""
        if FileManager.default.fileExists(atPath: url.path) {
            text = try String(contentsOf: url, encoding: .utf8)
        }
        let config = try RouterConfig(toml: text)
        let target = targetString(for: option, localState: localState, aliases: config.aliases)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try insertRule(into: text, pattern: pattern, target: target).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func profileSpec(for option: ChooserOption, localState: Data?) -> String {
        guard let folder = option.profileFolder else { return option.browser }
        let info = chromeInfo(folder: folder, localState: localState)
        // The email is stable across machines; the folder is the last resort.
        return "\(option.browser):\([info.email, info.name].compactMap { $0 }.first ?? folder)"
    }

    private static func chromeInfo(folder: String, localState: Data?) -> (email: String?, name: String?) {
        guard let localState,
              let root = try? JSONSerialization.jsonObject(with: localState) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: [String: Any]],
              let entry = cache[folder] else { return (nil, nil) }
        func field(_ key: String) -> String? {
            let value = (entry[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        return (field("user_name"), field("name"))
    }

    private static func ruleLine(_ pattern: String, _ target: String) -> String {
        "\(quoted(pattern)) = \(quoted(target))"
    }

    /// The key and value of a rule line; nil for comments, blanks and headers.
    private static func ruleEntry(_ line: String) -> String? {
        (try? TOML.parse(line))?.first?.entries.first?.key
    }

    /// `[name]` header text, or nil for other lines. `[[array]]` is not a table.
    private static func tableName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), !trimmed.hasPrefix("[["), let close = trimmed.firstIndex(of: "]") else {
            return nil
        }
        return trimmed[trimmed.index(after: trimmed.startIndex)..<close].trimmingCharacters(in: .whitespaces)
    }

    private static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Swaps only the value token, so the key spelling and any trailing comment survive.
    private static func replacingValue(in line: String, with target: String) -> String? {
        let chars = Array(line)
        guard let range = valueRange(chars) else { return nil }
        return String(chars[..<range.lowerBound]) + quoted(target) + String(chars[range.upperBound...])
    }

    private static func valueRange(_ c: [Character]) -> Range<Int>? {
        var i = 0
        func skipSpaces() { while i < c.count, c[i] == " " || c[i] == "\t" { i += 1 } }
        func skipToken(_ stops: String) { while i < c.count, !stops.contains(c[i]) { i += 1 } }

        skipSpaces()
        guard i < c.count else { return nil }
        if c[i] == "\"" || c[i] == "'" {
            guard let end = quotedEnd(c, from: i) else { return nil }
            i = end
        } else {
            skipToken(" \t=#")
        }
        skipSpaces()
        guard i < c.count, c[i] == "=" else { return nil }
        i += 1
        skipSpaces()
        let start = i
        guard i < c.count else { return nil }
        if c[i] == "\"" || c[i] == "'" {
            guard let end = quotedEnd(c, from: i) else { return nil }
            i = end
        } else {
            skipToken(" \t#")
        }
        return start..<i
    }

    /// Index just past the closing quote of the string that opens at `start`.
    private static func quotedEnd(_ c: [Character], from start: Int) -> Int? {
        let quote = c[start]
        var i = start + 1
        while i < c.count {
            if c[i] == "\\", quote == "\"" {
                i += 2
                continue
            }
            if c[i] == quote { return i + 1 }
            i += 1
        }
        return nil
    }
}
