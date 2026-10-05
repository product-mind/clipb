import Foundation

struct ClipEntry: Equatable {
    var value: String
    var obfuscated: Bool = false
    /// nil = uncategorized.
    var tag: String? = nil
}

/// In-memory clipboard history, most-recent-first within each tag.
/// Main-thread only.
final class ClipboardHistory {
    static let capacity = 100
    static let protectedCount = 10
    static let byteBudget = 64 * 1024 * 1024
    static let menuTruncateLength = 20
    static let popupTruncateLength = 60
    static let obfuscateShowLength = 4

    private let capacity: Int
    private let protectedCount: Int
    private let byteBudget: Int
    private var lists: [String?: [ClipEntry]] = [:]

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
    var tags: [String] { lists.keys.compactMap { $0 }.sorted() }

    func entries(for tag: String?) -> [ClipEntry] {
        lists[Self.normalize(tag)] ?? []
    }

    /// Adds a value to the front of its tag's list. Duplicates within the
    /// tag move to the front instead, keeping their obfuscation state.
    /// Returns true if a new entry was added.
    @discardableResult
    func push(_ raw: String, tag: String? = nil) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let tag = Self.normalize(tag)

        var list = lists[tag] ?? []
        let isNew: Bool
        if let i = list.firstIndex(where: { $0.value == value }) {
            list.insert(list.remove(at: i), at: 0)
            isNew = false
        } else {
            list.insert(ClipEntry(value: value, tag: tag), at: 0)
            isNew = true
        }
        if list.count > capacity {
            list.removeLast(list.count - capacity)
        }
        lists[tag] = list

        if isNew { evictOverBudget() }
        return isNew
    }

    func index(of value: String, tag: String? = nil) -> Int? {
        entries(for: tag).firstIndex { $0.value == value }
    }

    func delete(at index: Int, tag: String? = nil) {
        mutate(tag) { list in
            guard list.indices.contains(index) else { return }
            list.remove(at: index)
        }
    }

    func toggleObfuscation(at index: Int, tag: String? = nil) {
        mutate(tag) { list in
            guard list.indices.contains(index) else { return }
            list[index].obfuscated.toggle()
        }
    }

    func clear() {
        lists.removeAll()
    }

    func clear(tag: String?) {
        lists[Self.normalize(tag)] = nil
    }

    private func mutate(_ tag: String?, _ body: (inout [ClipEntry]) -> Void) {
        let tag = Self.normalize(tag)
        guard var list = lists[tag] else { return }
        body(&list)
        lists[tag] = list.isEmpty ? nil : list
    }

    /// Never trims a value. Drops the largest entry outside every tag's
    /// protected newest-N window until the total fits; the budget is soft
    /// because protected entries are never evicted.
    private func evictOverBudget() {
        var total = lists.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.value.utf8.count } }
        while total > byteBudget {
            var victim: (tag: String?, index: Int, bytes: Int)?
            for tag in lists.keys.sorted(by: { ($0 ?? "") < ($1 ?? "") }) {
                let list = lists[tag]!
                for i in list.indices where i >= protectedCount {
                    let bytes = list[i].value.utf8.count
                    // >= prefers the older entry within a tag on equal size.
                    if bytes >= (victim?.bytes ?? 0) { victim = (tag, i, bytes) }
                }
            }
            guard let victim else { return }
            mutate(victim.tag) { $0.remove(at: victim.index) }
            total -= victim.bytes
        }
    }

    private static func normalize(_ tag: String?) -> String? {
        guard let trimmed = tag?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
