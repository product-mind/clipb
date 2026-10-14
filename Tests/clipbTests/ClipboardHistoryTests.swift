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

    @Test func tagsKeepSeparateHistories() {
        let h = ClipboardHistory()
        h.push("a")
        h.push("b", tag: "dictation")
        #expect(h.entries.map(\.value) == ["a"])
        #expect(h.entries(for: "dictation").map(\.value) == ["b"])
        #expect(h.tags == ["dictation"])
    }

    @Test func sameValueInDifferentTagsIsNotADuplicate() {
        let h = ClipboardHistory()
        #expect(h.push("x"))
        #expect(h.push("x", tag: "t"))
        #expect(!h.push("x", tag: "t"))
    }

    @Test func blankTagMeansUncategorized() {
        let h = ClipboardHistory()
        h.push("a", tag: "  ")
        #expect(h.entries.map(\.value) == ["a"])
        #expect(h.tags.isEmpty)
    }

    @Test func capacityIsPerTag() {
        let h = ClipboardHistory(capacity: 2)
        for i in 0..<3 { h.push("u\(i)") }
        for i in 0..<3 { h.push("t\(i)", tag: "t") }
        #expect(h.entries.map(\.value) == ["u2", "u1"])
        #expect(h.entries(for: "t").map(\.value) == ["t2", "t1"])
    }

    @Test func clearTagLeavesOthersAlone() {
        let h = ClipboardHistory()
        h.push("a")
        h.push("b", tag: "t")
        h.clear(tag: "t")
        #expect(h.entries(for: "t").isEmpty)
        #expect(h.tags.isEmpty)
        #expect(h.entries.map(\.value) == ["a"])
    }

    @Test func deleteAndObfuscateTargetTheGivenTag() {
        let h = ClipboardHistory()
        h.push("a")
        h.push("b", tag: "t")
        h.toggleObfuscation(at: 0, tag: "t")
        #expect(h.entries(for: "t")[0].obfuscated)
        #expect(!h.entries[0].obfuscated)
        h.delete(at: 0, tag: "t")
        #expect(h.tags.isEmpty)
    }

    @Test func budgetEvictsLargestOutsideProtectedWindow() {
        let h = ClipboardHistory(protectedCount: 1, byteBudget: 10)
        h.push(String(repeating: "L", count: 8)) // large, oldest
        h.push("mid")
        h.push("new")                            // protected
        #expect(h.entries.map(\.value) == ["new", "mid"])
    }

    @Test func protectedEntriesSurviveEvenOverBudget() {
        let h = ClipboardHistory(protectedCount: 2, byteBudget: 4)
        h.push(String(repeating: "A", count: 50))
        h.push(String(repeating: "B", count: 50))
        #expect(h.entries.count == 2)
    }

    @Test func evictionNeverAltersSurvivingValues() {
        let h = ClipboardHistory(protectedCount: 1, byteBudget: 20)
        h.push("old")
        h.push(String(repeating: "x", count: 15))
        h.push("new")
        #expect(h.entries.map(\.value) == ["new", "old"])
    }

    @Test func budgetSpansTags() {
        let h = ClipboardHistory(protectedCount: 1, byteBudget: 12)
        h.push("keep-u")
        h.push(String(repeating: "L", count: 10), tag: "t")
        h.push("tail", tag: "t")
        #expect(h.entries(for: "t").map(\.value) == ["tail"])
        #expect(h.entries.map(\.value) == ["keep-u"])
    }
}

@Suite struct ClipboardHistorySourceTests {
    @Test func recordsTheSourceApp() {
        let h = ClipboardHistory()
        h.push("a", source: "Safari")
        #expect(h.entries[0].source == "Safari")
    }

    @Test func duplicateTakesTheNewSource() {
        let h = ClipboardHistory()
        h.push("a", source: "Safari")
        h.push("b")
        h.push("a", source: "Slack")
        #expect(h.entries.map(\.value) == ["a", "b"])
        #expect(h.entries[0].source == "Slack")
    }

    @Test func duplicateWithoutSourceKeepsTheOldOne() {
        let h = ClipboardHistory()
        h.push("a", source: "Safari")
        h.push("a")
        #expect(h.entries[0].source == "Safari")
    }
}
