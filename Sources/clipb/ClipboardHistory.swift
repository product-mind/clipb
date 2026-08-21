import Foundation

struct ClipEntry: Equatable {
    var value: String
    var obfuscated: Bool = false
}

/// In-memory clipboard history, most-recent-first. Main-thread only.
final class ClipboardHistory {
    static let capacity = 100
    static let menuTruncateLength = 20
    static let popupTruncateLength = 60
    static let obfuscateShowLength = 4

    private(set) var entries: [ClipEntry] = []

    /// Adds a value to the front. Duplicates move to the front instead,
    /// keeping their obfuscation state. Returns true if a new entry was added.
    @discardableResult
    func push(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }

        if let i = entries.firstIndex(where: { $0.value == value }) {
            let entry = entries.remove(at: i)
            entries.insert(entry, at: 0)
            return false
        }

        entries.insert(ClipEntry(value: value), at: 0)
        if entries.count > Self.capacity {
            entries.removeLast(entries.count - Self.capacity)
        }
        return true
    }

    func index(of value: String) -> Int? {
        entries.firstIndex { $0.value == value }
    }

    func delete(at index: Int) {
        guard entries.indices.contains(index) else { return }
        entries.remove(at: index)
    }

    func toggleObfuscation(at index: Int) {
        guard entries.indices.contains(index) else { return }
        entries[index].obfuscated.toggle()
    }

    func clear() {
        entries.removeAll()
    }
}
