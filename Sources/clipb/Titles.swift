import Foundation

/// Rendering of history entries into menu titles.
enum Titles {
    static func menuTitle(for entry: ClipEntry) -> String {
        title(for: entry, maxBytes: ClipboardHistory.menuTruncateLength)
    }

    static func popupTitle(for entry: ClipEntry) -> String {
        title(for: entry, maxBytes: ClipboardHistory.popupTruncateLength)
    }

    static func title(for entry: ClipEntry, maxBytes: Int) -> String {
        if let image = entry.image {
            return imageTitle(image)
        }
        if entry.obfuscated {
            return obfuscated(entry.value, cap: maxBytes)
        }
        var title = entry.value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\0", with: "")
        if title.utf8.count > maxBytes {
            title = truncateUTF8(title, maxBytes: maxBytes) + "... (\(entry.value.count) chars)"
        }
        return title
    }

    /// `[image] 1200×800`, parsed from the PNG's IHDR header; `[image]` alone
    /// when the bytes are not a readable PNG.
    static func imageTitle(_ data: Data) -> String {
        guard let dims = pngDimensions(data) else { return ClipboardCapture.imageValue }
        return "\(ClipboardCapture.imageValue) \(dims.width)×\(dims.height)"
    }

    /// Width and height from a PNG's IHDR chunk, or nil when the header is
    /// missing. Pure byte parsing, no image decode.
    static func pngDimensions(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data.prefix(24))
        guard bytes.count >= 24,
              bytes[0...7].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
              bytes[12...15].elementsEqual(Array("IHDR".utf8))
        else { return nil }
        let width = bytes[16..<20].reduce(0) { $0 << 8 | Int($1) }
        let height = bytes[20..<24].reduce(0) { $0 << 8 | Int($1) }
        return (width, height)
    }

    /// Chooser header for the cut entry: an image or file shows its title,
    /// text is flattened and truncated with its length.
    static func pipeHeader(for entry: ClipEntry, maxBytes: Int) -> String {
        if entry.image != nil || entry.fileURLs != nil {
            return title(for: entry, maxBytes: maxBytes)
        }
        return pipeHeader(for: entry.value, maxBytes: maxBytes)
    }

    /// Chooser header for the cut text: one line, truncated, with its length
    /// when it was cut.
    static func pipeHeader(for text: String, maxBytes: Int) -> String {
        let line = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\0", with: "")
        guard line.utf8.count > maxBytes else { return line }
        return truncateUTF8(line, maxBytes: maxBytes) + "… (\(text.count) chars)"
    }

    /// Notice title for a run that failed, timed out, or was cancelled.
    static func failedPipeTitle(_ name: String, note: String) -> String {
        "Pipe \(name) failed — \(note)"
    }

    /// The command succeeded; only the paste-out missed focus.
    static func pipePasteMissedTitle(_ name: String) -> String {
        "Pipe \(name) — output is on the clipboard"
    }

    /// The editor's save succeeded; only the paste-out missed focus.
    static func editorPasteMissedTitle() -> String {
        "Editor — output is on the clipboard"
    }

    /// The lines under a pipe-failure title: the command, how it ended, the
    /// tail of its stderr. An obfuscated entry's stderr is dropped: the command
    /// may echo its input, which must never reach the screen.
    static func failedPipeDetail(command: String, status: Int32?, stderr: String, obfuscated: Bool = false) -> String {
        var lines = ["$ " + ellipsized(command, maxBytes: 100)]
        lines.append(status.map { "exit \($0)" } ?? "no exit code — Esc, timeout, or launch failure")
        let text = obfuscated ? "" : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            // Errors print at the end, so a long traceback keeps its last lines.
            lines += text
                .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .suffix(3)
                .map { ellipsized(String($0), maxBytes: 120) }
        }
        return lines.joined(separator: "\n")
    }

    /// Truncated to maxBytes of UTF-8, with an ellipsis when it was cut.
    private static func ellipsized(_ s: String, maxBytes: Int) -> String {
        s.utf8.count > maxBytes ? truncateUTF8(s, maxBytes: maxBytes) + "…" : s
    }

    /// Compact elapsed time for the dev build's uptime label, e.g. "2h 13m".
    static func uptime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (days, hours, minutes, secs) = (total / 86400, total % 86400 / 3600, total % 3600 / 60, total % 60)
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }

    /// First few characters shown, the rest starred, capped at `cap`.
    static func obfuscated(_ value: String, cap: Int) -> String {
        let shown = String(value.prefix(ClipboardHistory.obfuscateShowLength))
        let stars = max(0, min(value.count, cap) - shown.count)
        return shown + String(repeating: "*", count: stars)
    }

    /// Truncates to at most maxBytes of UTF-8 without splitting a character.
    static func truncateUTF8(_ s: String, maxBytes: Int) -> String {
        guard s.utf8.count > maxBytes else { return s }
        var i = s.utf8.index(s.utf8.startIndex, offsetBy: maxBytes)
        while i > s.startIndex, String.Index(i, within: s) == nil {
            i = s.utf8.index(before: i)
        }
        guard let end = String.Index(i, within: s) else { return "" }
        return String(s[..<end])
    }
}
