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
