import Foundation
import Testing
@testable import clipb

@Suite struct StampedFileCacheTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("clipb-stamp-\(UUID().uuidString).json")
    }

    @Test func readsOnceUntilTheFileChanges() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try "one".write(to: url, atomically: true, encoding: .utf8)
        let cache = StampedFileCache(url: url)

        #expect(cache.data() == Data("one".utf8))
        #expect(cache.data() == Data("one".utf8))
        #expect(cache.loads == 1)

        try "three".write(to: url, atomically: true, encoding: .utf8)
        #expect(cache.data() == Data("three".utf8))
        #expect(cache.loads == 2)
    }

    @Test func missingFileIsNilAndRecovers() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = StampedFileCache(url: url)
        #expect(cache.data() == nil)

        try "back".write(to: url, atomically: true, encoding: .utf8)
        #expect(cache.data() == Data("back".utf8))
    }
}
