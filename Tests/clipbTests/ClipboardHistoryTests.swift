import Testing
@testable import clipb

@Suite struct ClipboardHistoryTests {
    @Test func pushAddsToFront() {
        let h = ClipboardHistory()
        #expect(h.push("first"))
        #expect(h.push("second"))
        #expect(h.entries.map(\.value) == ["second", "first"])
    }

    @Test func duplicateMovesToFrontAndKeepsObfuscation() {
        let h = ClipboardHistory()
        h.push("secret")
        h.push("other")
        h.toggleObfuscation(at: 1)

        #expect(!h.push("secret"))
        #expect(h.entries.map(\.value) == ["secret", "other"])
        #expect(h.entries[0].obfuscated)
        #expect(h.entries.count == 2)
    }

    @Test func trimsWhitespaceAndDedupesTrimmed() {
        let h = ClipboardHistory()
        h.push("value")
        #expect(!h.push("  value \n"))
        #expect(h.entries.map(\.value) == ["value"])
    }

    @Test func ignoresEmptyAndWhitespaceOnly() {
        let h = ClipboardHistory()
        #expect(!h.push(""))
        #expect(!h.push("   \n\t "))
        #expect(h.entries.isEmpty)
    }

    @Test func evictsOldestBeyondCapacity() {
        let h = ClipboardHistory()
        for i in 0...ClipboardHistory.capacity {
            h.push("value-\(i)")
        }
        #expect(h.entries.count == ClipboardHistory.capacity)
        #expect(h.entries.first?.value == "value-\(ClipboardHistory.capacity)")
        #expect(h.index(of: "value-0") == nil)
    }

    @Test func delete() {
        let h = ClipboardHistory()
        h.push("a")
        h.push("b")
        h.delete(at: 1)
        #expect(h.entries.map(\.value) == ["b"])
        h.delete(at: 5) // out of range is a no-op
        #expect(h.entries.count == 1)
    }

    @Test func clear() {
        let h = ClipboardHistory()
        h.push("a")
        h.push("b")
        h.clear()
        #expect(h.entries.isEmpty)
    }

    @Test func toggleObfuscation() {
        let h = ClipboardHistory()
        h.push("secret")
        h.toggleObfuscation(at: 0)
        #expect(h.entries[0].obfuscated)
        h.toggleObfuscation(at: 0)
        #expect(!h.entries[0].obfuscated)
    }
}
