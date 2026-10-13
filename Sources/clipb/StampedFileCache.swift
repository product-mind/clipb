import Foundation

/// Holds a file's bytes until its mtime or size changes. Main thread only.
final class StampedFileCache {
    private let url: URL
    private var stamp: (date: Date, size: Int)?
    private var cached: Data?
    private(set) var loads = 0

    init(url: URL) {
        self.url = url
    }

    /// nil when the file is missing or unreadable; the next call tries again.
    func data() -> Data? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            stamp = nil
            cached = nil
            return nil
        }
        // Stat before reading: an edit in between only costs one extra reload.
        let fresh = (date: attrs[.modificationDate] as? Date ?? .distantPast, size: attrs[.size] as? Int ?? 0)
        if let stamp, stamp == fresh, let cached { return cached }
        loads += 1
        guard let data = try? Data(contentsOf: url) else {
            stamp = nil
            cached = nil
            return nil
        }
        stamp = fresh
        cached = data
        return data
    }
}
