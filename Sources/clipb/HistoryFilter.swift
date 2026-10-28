import Foundation

/// One row of the popup's flat list: the entry and the tag it lives under,
/// which the delete and obfuscate callbacks need to find it again.
struct PopupEntry: Equatable {
    var tag: String?
    var entry: ClipEntry
}

/// The popup's merged entry list and its `#tag`-aware search. Pure, so the
/// query syntax is testable without a panel.
enum HistoryFilter {
    /// Every entry across all tags, globally newest-first — not one tag after
    /// another, so recency order survives the merged list.
    static func merged(from history: ClipboardHistory) -> [PopupEntry] {
        history.allEntries.map { PopupEntry(tag: $0.tag, entry: $0) }
    }

    /// What a non-`#` query matches: the title (masked for obfuscated entries)
    /// plus the source app, so `slack` finds entries copied from Slack.
    static func matchText(for entry: ClipEntry) -> String {
        let text = entry.obfuscated ? Titles.popupTitle(for: entry) : entry.value
        guard let source = entry.source else { return text }
        return text + " " + source
    }

    /// The pills a row shows: the tag first, then the source app. A nil value
    /// is omitted. Pills are names, never values, so obfuscated rows keep them.
    static func pills(for entry: ClipEntry) -> [String] {
        [entry.tag, entry.source].compactMap { $0.map { "#\($0)" } }
    }

    /// `#token` filters by tag or source, fuzzily; several `#` tokens AND.
    /// The remaining text fuzzies the title and source, ranked best first.
    static func filtered(_ entries: [PopupEntry], query: String) -> [PopupEntry] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let hashTokens = tokens.filter { $0.hasPrefix("#") }.map { String($0.dropFirst()) }
        let text = tokens.filter { !$0.hasPrefix("#") }.joined(separator: " ")

        let matched = entries.filter { entry in
            hashTokens.allSatisfy { matchesSourceOrTag($0, entry) }
                && FuzzyMatch.matches(query: text, in: matchText(for: entry.entry))
        }
        // An empty text query keeps the input's recency order.
        return FuzzyMatch.rank(matched, query: text) { matchText(for: $0.entry) }
    }

    private static func matchesSourceOrTag(_ token: String, _ entry: PopupEntry) -> Bool {
        if let tag = entry.entry.tag, FuzzyMatch.matches(query: token, in: tag) { return true }
        if let source = entry.entry.source, FuzzyMatch.matches(query: token, in: source) { return true }
        return false
    }
}
