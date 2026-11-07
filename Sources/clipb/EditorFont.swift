import AppKit

/// The editor's monospaced font: `[editor] font` in clipb.toml, else the
/// family Ghostty is set to (the user asked for their terminal's font), else
/// the system monospace. A family without a bold face gets a stroked bold, so
/// bold text keeps the same advance and the column grid holds.
enum EditorFont {
    /// Point size: ⌘+ / ⌘- step it, ⌘0 resets. Remembered across launches in
    /// UserDefaults (a number, never text), shared by every editor.
    static let defaultSize: CGFloat = 13
    static let sizeRange: ClosedRange<CGFloat> = 9...36
    static let sizeChanged = Notification.Name("ClipBEditorFontSizeChanged")
    private static let sizeKey = "EditorFontSize"

    static var size: CGFloat {
        let stored = UserDefaults.standard.double(forKey: sizeKey)
        return stored > 0 ? clampedSize(CGFloat(stored)) : defaultSize
    }

    static func clampedSize(_ size: CGFloat) -> CGFloat {
        min(max(size.rounded(), sizeRange.lowerBound), sizeRange.upperBound)
    }

    /// Steps the size by `delta` points (0: back to the default); every open
    /// editor repaints.
    static func step(_ delta: CGFloat) {
        let next = delta == 0 ? defaultSize : clampedSize(size + delta)
        guard next != size || delta == 0 else { NSSound.beep(); return }
        if next == defaultSize {
            UserDefaults.standard.removeObject(forKey: sizeKey)
        } else {
            UserDefaults.standard.set(Double(next), forKey: sizeKey)
        }
        NotificationCenter.default.post(name: sizeChanged, object: nil)
    }

    /// Set by `EditorConfig.apply` each time an editor opens.
    static var family: String? = ghostty

    /// Ghostty's family, read once per process.
    static let ghostty: String? = {
        let paths = [
            "Library/Application Support/com.mitchellh.ghostty/config.ghostty",
            "Library/Application Support/com.mitchellh.ghostty/config",
            ".config/ghostty/config.ghostty",
            ".config/ghostty/config",
        ]
        let home = FileManager.default.homeDirectoryForCurrentUser
        for path in paths {
            guard let text = try? String(contentsOf: home.appendingPathComponent(path), encoding: .utf8) else { continue }
            if let name = ghosttyFamily(in: text), installed(name) { return name }
        }
        return nil
    }()

    /// The last `font-family = …` in a Ghostty config; an empty value resets
    /// the list, as in Ghostty. Pure, tested.
    static func ghosttyFamily(in config: String) -> String? {
        var found: String?
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            guard line[..<eq].trimmingCharacters(in: .whitespaces) == "font-family" else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            // Ghostty keeps the first family as primary; later ones are fallbacks.
            if value.isEmpty { found = nil } else if found == nil { found = value }
        }
        return found
    }

    static func installed(_ name: String) -> Bool {
        NSFont(name: name, size: 13) != nil || NSFontManager.shared.availableFontFamilies.contains(name)
    }

    /// The font for `size` and `weight`, plus the stroke that fakes a weight
    /// the family lacks (nil when the real face exists).
    static func font(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        attributes(ofSize: size, weight: weight)[.font] as! NSFont
    }

    static func attributes(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> [NSAttributedString.Key: Any] {
        guard let family, let regular = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
                ?? NSFont(name: family, size: size) else {
            return [.font: NSFont.monospacedSystemFont(ofSize: size, weight: weight)]
        }
        guard weight > .regular else { return [.font: regular] }
        let bold = NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
        if bold.fontName != regular.fontName { return [.font: bold] }
        // Negative stroke: fill and outline, so the glyph thickens in place.
        return [.font: regular, .strokeWidth: weight >= .bold ? -4.0 : -2.5]
    }
}

/// `[editor]` in ~/.config/clipb.toml. Pure parse, tested; read each time an
/// editor opens, so edits apply without a restart.
struct EditorConfig: Equatable {
    /// A font family or PostScript name; nil or "": Ghostty's, else the system's.
    var font: String?
    /// The Markdown look an editor starts with (⌘⇧M flips it for the session).
    var markdown = MarkdownPainter.onByDefault

    struct ConfigError: Error, CustomStringConvertible {
        let description: String
    }

    init() {}

    init(tables: [TOML.Table]) throws {
        for table in tables where table.name == "editor" {
            for (key, value) in table.entries {
                switch (key, value) {
                case ("font", .string(let name)):
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    font = trimmed.isEmpty ? nil : trimmed
                case ("markdown", .bool(let on)):
                    markdown = on
                case ("font", _):
                    throw ConfigError(description: "[editor] font must be a string, e.g. \"Monaco\"")
                case ("markdown", _):
                    throw ConfigError(description: "[editor] markdown must be true or false")
                default:
                    throw ConfigError(description: "[editor] unknown key \"\(key)\"; known: font, markdown")
                }
            }
        }
    }

    static func load(from url: URL = RouterConfig.defaultPath) -> (config: EditorConfig, error: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (EditorConfig(), nil) }
        do {
            return (try EditorConfig(tables: TOML.parse(String(contentsOf: url, encoding: .utf8))), nil)
        } catch {
            return (EditorConfig(), "\(error)")
        }
    }

    /// The `markdown` value last applied: ⌘⇧M lasts the session, until the
    /// config's value itself changes.
    private static var appliedMarkdown: Bool?

    /// Reads the config and sets the font and Markdown look for the editor
    /// about to open. Returns the config error, if any (defaults then apply).
    @discardableResult
    static func apply() -> String? {
        let (config, error) = load()
        if let name = config.font, EditorFont.installed(name) {
            EditorFont.family = name
        } else {
            EditorFont.family = EditorFont.ghostty
        }
        if appliedMarkdown != config.markdown {
            appliedMarkdown = config.markdown
            EditorTextView.markdownLook = config.markdown
        }
        if let name = config.font, !EditorFont.installed(name) {
            return "[editor] font \"\(name)\" is not installed"
        }
        return error
    }
}
