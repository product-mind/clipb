import Foundation

/// The pure part of `clipb edit <file>` (tested): argument parsing, the
/// wrapper around an unfenced drawing, and when a save writes.
///
/// The editor treats only fenced ``` blocks as drawings. A file that is one
/// bare box drawing (no ``` anywhere, but `┌` in it) is therefore shown
/// wrapped in a fence, and the wrapper is stripped again on save, so the file
/// stays a plain drawing.
struct EditDocument: Equatable {
    static let usage = "usage: clipb edit <file>"
    private static let fence = "```"

    /// The one path, or nil for anything but exactly one argument.
    static func parse(_ args: [String]) -> String? {
        args.count == 1 && !args[0].isEmpty ? args[0] : nil
    }

    /// Whether the file's content got the fence wrapper.
    let wrapped: Bool
    /// What the editor shows.
    let shown: String
    private let trailingNewline: Bool

    /// `fileContent` is nil when the file does not exist yet.
    init(fileContent: String?) {
        let content = fileContent ?? ""
        guard Self.isBareDrawing(content) else {
            wrapped = false
            trailingNewline = false
            shown = content
            return
        }
        wrapped = true
        trailingNewline = content.hasSuffix("\n")
        let body = trailingNewline ? String(content.dropLast()) : content
        shown = "\(Self.fence)\n\(body)\n\(Self.fence)"
    }

    /// No fence at all, but box-drawing art: the editor would not see it.
    static func isBareDrawing(_ content: String) -> Bool {
        !content.contains(fence) && content.contains("┌")
    }

    /// The text to write for what the editor shows now. A wrapped drawing
    /// loses its wrapper; if the edit broke the wrapper (a fence line removed
    /// or text outside it), the text is written as shown, never guessed at.
    func fileText(forShown text: String) -> String {
        guard wrapped else { return text }
        let open = "\(Self.fence)\n", close = "\n\(Self.fence)"
        guard text.hasPrefix(open), text.hasSuffix(close), text.count >= open.count + close.count else { return text }
        let inner = String(text.dropFirst(open.count).dropLast(close.count))
        return trailingNewline ? inner + "\n" : inner
    }

    /// Close and quit write only a changed buffer; Cmd+S always writes, which
    /// is also how a missing file gets created.
    static func shouldSaveOnClose(shown: String, lastSaved: String) -> Bool {
        shown != lastSaved
    }
}
