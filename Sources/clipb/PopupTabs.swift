import Foundation

/// One tab of the hotkey popup: the uncategorized list or a single tag.
struct PopupTab: Equatable {
    var tag: String?
    var title: String
    var entries: [ClipEntry]
}

enum PopupTabs {
    static let uncategorizedTitle = "Clipboard"

    /// Uncategorized first, then one tab per tag, sorted by name.
    static func make(from history: ClipboardHistory) -> [PopupTab] {
        var tabs = [PopupTab(tag: nil, title: uncategorizedTitle, entries: history.entries)]
        for tag in history.tags {
            tabs.append(PopupTab(tag: tag, title: tag, entries: history.entries(for: tag)))
        }
        return tabs
    }

    /// The default tab is the first one with entries, preferring uncategorized.
    static func initialIndex(of tabs: [PopupTab]) -> Int {
        tabs.firstIndex { !$0.entries.isEmpty } ?? 0
    }

    /// Wraps around, so Tab on the last tab goes to the first.
    static func index(from index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }
}
