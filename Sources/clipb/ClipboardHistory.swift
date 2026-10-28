import Foundation

struct ClipEntry: Equatable {
    var value: String
    var obfuscated: Bool = false
    /// nil = uncategorized.
    var tag: String? = nil
    /// Name of the app it was copied from; nil when unknown.
    var source: String? = nil
}

/// In-memory clipboard history, one shared array globally most-recent-first.
/// Main-thread only.
final class ClipboardHistory {
    static let capacity = 1000
    static let protectedCount = 10
    static let byteBudget = 64 * 1024 * 1024
    static let menuTruncateLength = 20
    static let popupTruncateLength = 60
    static let obfuscateShowLength = 4

    private let capacity: Int
    private let protectedCount: Int
    private let byteBudget: Int
    private var items: [ClipEntry] = []

    init(
        capacity: Int = ClipboardHistory.capacity,
        protectedCount: Int = ClipboardHistory.protectedCount,
        byteBudget: Int = ClipboardHistory.byteBudget
    ) {
        self.capacity = capacity
        self.protectedCount = protectedCount
        self.byteBudget = byteBudget
    }

    /// Uncategorized entries, newest first.
    var entries: [ClipEntry] { entries(for: nil) }

    /// Tags that currently hold entries, sorted by name.
    var tags: [String] { Array(Set(items.compactMap(\.tag))).sorted() }

    func entries(for tag: String?) -> [ClipEntry] {
        let tag = Self.normalize(tag)
        return items.filter { $0.tag == tag }
    }

    /// Every entry across all tags, globally newest-first.
    var allEntries: [ClipEntry] { items }

    /// Adds a value to the front. A duplicate of the same (value, tag) pair
    /// moves to the front instead, keeping its obfuscation state; a non-nil
    /// `source` replaces theirs. Same value under another tag is a new entry.
    /// Returns true if a new entry was added.
    @discardableResult
    func push(_ raw: String, tag: String? = nil, source: String? = nil) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let tag = Self.normalize(tag)

        let isNew: Bool
        if let i = items.firstIndex(where: { $0.value == value && $0.tag == tag }) {
            var entry = items.remove(at: i)
            if let source { entry.source = source }
            items.insert(entry, at: 0)
            isNew = false
        } else {
            items.insert(ClipEntry(value: value, tag: tag, source: source), at: 0)
            isNew = true
        }
        if items.count > capacity {
            items.removeLast(items.count - capacity)
        }

        if isNew { evictOverBudget() }
        return isNew
    }

    /// Position within the tag's filtered list, not the shared array.
    func index(of value: String, tag: String? = nil) -> Int? {
        entries(for: tag).firstIndex { $0.value == value }
    }

    func delete(at index: Int, tag: String? = nil) {
        guard let global = globalIndex(scoped: index, tag: tag) else { return }
        items.remove(at: global)
    }

    func toggleObfuscation(at index: Int, tag: String? = nil) {
        guard let global = globalIndex(scoped: index, tag: tag) else { return }
        items[global].obfuscated.toggle()
    }

    func clear() {
        items.removeAll()
    }

    func clear(tag: String?) {
        let tag = Self.normalize(tag)
        items.removeAll { $0.tag == tag }
    }

    /// Maps a tag-scoped index to the shared array. Safe because dedupe keeps
    /// (value, tag) unique, so the filtered order matches the array order.
    private func globalIndex(scoped index: Int, tag: String?) -> Int? {
        guard index >= 0 else { return nil }
        let tag = Self.normalize(tag)
        var seen = 0
        for (i, item) in items.enumerated() where item.tag == tag {
            if seen == index { return i }
            seen += 1
        }
        return nil
    }

    /// Never trims a value. Drops the largest entry outside the protected
    /// newest window until the total fits; the budget is soft because
    /// protected entries are never evicted.
    private func evictOverBudget() {
        var total = items.reduce(0) { $0 + $1.value.utf8.count }
        while total > byteBudget {
            guard items.count > protectedCount else { return }
            var victim: (index: Int, bytes: Int)?
            for i in protectedCount..<items.count {
                let bytes = items[i].value.utf8.count
                // >= prefers the older entry on equal size.
                if bytes >= (victim?.bytes ?? 0) { victim = (i, bytes) }
            }
            guard let victim else { return }
            items.remove(at: victim.index)
            total -= victim.bytes
        }
    }

    private static func normalize(_ tag: String?) -> String? {
        guard let trimmed = tag?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
