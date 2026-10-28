import Testing
@testable import clipb

@Suite struct ClipboardHistoryTests {
    @Test func sharedCapacityIsOneThousand() {
        #expect(ClipboardHistory.capacity == 1000)
    }

    @Test func pushAddsToFront() {
        let h = ClipboardHistory()
        #expect(h.push("first"))
        #expect(h.push("second"))
        #expect(h.entries.map(\.value) == ["second", "first"])
    }

    @Test func recencyIsGlobalAcrossTags() {
        let h = ClipboardHistory()
        h.push("a")
        h.push("b", tag: "t")
        h.push("c")
        #expect(h.allEntries.map(\.value) == ["c", "b", "a"])
        #expect(h.entries.map(\.value) == ["c", "a"])
        #expect(h.entries(for: "t").map(\.value) == ["b"])
    }

    @Test func duplicateMovesToFrontAndKeepsObfuscation() {
        let h = ClipboardHistory()
        h.push("secret")
        h.push("other", tag: "t")
        h.toggleObfuscation(at: 0)

        #expect(!h.push("secret"))
        #expect(h.allEntries.map(\.value) == ["secret", "other"])
        #expect(h.allEntries[0].obfuscated)
        #expect(h.allEntries.count == 2)
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

    @Test func capDropsTheGloballyOldest() {
        let h = ClipboardHistory(capacity: 1000)
        h.push("first")
        for i in 0..<1000 { h.push("v\(i)", tag: "t") }
        #expect(h.allEntries.count == 1000)
        #expect(h.allEntries.first?.value == "v999")
        #expect(!h.allEntries.contains { $0.value == "first" })
    }

    @Test func capSpansTags() {
        let h = ClipboardHistory(capacity: 4)
        h.push("u0")
        h.push("u1")
        h.push("t0", tag: "t")
        h.push("t1", tag: "t")
        h.push("t2", tag: "t")
        #expect(h.allEntries.count == 4)
        #expect(!h.allEntries.contains { $0.value == "u0" })
        #expect(h.entries(for: "t").map(\.value) == ["t2", "t1", "t0"])
        #expect(h.entries.map(\.value) == ["u1"])
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

    @Test func tagsAreFiltersOfTheSharedList() {
        let h = ClipboardHistory()
        h.push("a")
        h.push("b", tag: "dictation")
        #expect(h.entries.map(\.value) == ["a"])
        #expect(h.entries(for: "dictation").map(\.value) == ["b"])
        #expect(h.tags == ["dictation"])
    }

    @Test func tagsListIsSorted() {
        let h = ClipboardHistory()
        h.push("a", tag: "zeta")
        h.push("b", tag: "alpha")
        h.push("c")
        #expect(h.tags == ["alpha", "zeta"])
    }

    @Test func sameValueInDifferentTagsIsNotADuplicate() {
        let h = ClipboardHistory()
        #expect(h.push("x"))
        #expect(h.push("x", tag: "t"))
        #expect(!h.push("x", tag: "t"))
        #expect(h.allEntries.count == 2)
        #expect(h.tags == ["t"])
    }

    @Test func blankTagMeansUncategorized() {
        let h = ClipboardHistory()
        h.push("a", tag: "  ")
        #expect(h.entries.map(\.value) == ["a"])
        #expect(h.tags.isEmpty)
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

    @Test func scopedDeleteAndObfuscateHitTheRightTag() {
        let h = ClipboardHistory()
        h.push("x")
        h.push("x", tag: "t")
        h.push("y", tag: "t")

        h.toggleObfuscation(at: 1, tag: "t")
        #expect(h.entries(for: "t")[1].obfuscated)
        #expect(!h.entries[0].obfuscated)

        h.delete(at: 1, tag: "t")
        #expect(h.entries(for: "t").map(\.value) == ["y"])
        #expect(h.entries.map(\.value) == ["x"])
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
        h.push(String(repeating: "L", count: 10), tag: "t") // oldest large
        h.push("keep-u")
        h.push("tail", tag: "t")                              // protected
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
