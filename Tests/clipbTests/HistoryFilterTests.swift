import Foundation
import Testing
@testable import clipb

private func merged(_ history: ClipboardHistory) -> [PopupEntry] {
    HistoryFilter.merged(from: history)
}

private func values(_ entries: [PopupEntry]) -> [String] {
    entries.map(\.entry.value)
}

@Suite struct HistoryFilterMergeTests {
    @Test func mergedListIsGloballyNewestFirst() {
        let h = ClipboardHistory()
        h.push("old")
        h.push("tagged", tag: "en")
        h.push("new")
        #expect(values(merged(h)) == ["new", "tagged", "old"])
        #expect(merged(h).map(\.tag) == [nil, "en", nil])
    }

    @Test func mergedOrderFollowsAMoveToTheFront() {
        let h = ClipboardHistory()
        h.push("a", tag: "en")
        h.push("b")
        h.push("a", tag: "en")
        #expect(values(merged(h)) == ["a", "b"])
    }

    @Test func mergedIncludesEveryTag() {
        let h = ClipboardHistory()
        h.push("en1", tag: "en")
        h.push("quote1", tag: "quote")
        #expect(Set(values(merged(h))) == ["en1", "quote1"])
    }
}

@Suite struct HistoryFilterQueryTests {
    private func history() -> ClipboardHistory {
        let h = ClipboardHistory()
        h.push("alpha", tag: "en")
        h.push("quoted line", tag: "quote", source: "Safari")
        h.push("beta", source: "Slack")
        return h
    }

    @Test func hashTokenMatchesTheTagFuzzily() {
        let h = history()
        #expect(values(HistoryFilter.filtered(merged(h), query: "#q")) == ["quoted line"])
        #expect(values(HistoryFilter.filtered(merged(h), query: "#QUOTE")) == ["quoted line"])
    }

    @Test func hashTokenMatchesTheSourceFuzzily() {
        let h = history()
        #expect(values(HistoryFilter.filtered(merged(h), query: "#saf")) == ["quoted line"])
        #expect(values(HistoryFilter.filtered(merged(h), query: "#sl")) == ["beta"])
    }

    @Test func multipleHashTokensAreAnded() {
        let h = history()
        #expect(values(HistoryFilter.filtered(merged(h), query: "#quote #saf")) == ["quoted line"])
        #expect(HistoryFilter.filtered(merged(h), query: "#quote #sl").isEmpty)
    }

    @Test func hashTokenExcludesUntaggedAndSourcelessRows() {
        let h = ClipboardHistory()
        h.push("plain")
        #expect(HistoryFilter.filtered(merged(h), query: "#en").isEmpty)
    }

    @Test func bareHashKeepsOnlyTaggedOrSourcedRows() {
        let h = ClipboardHistory()
        h.push("plain")
        h.push("tagged", tag: "en")
        h.push("sourced", source: "Slack")
        #expect(values(HistoryFilter.filtered(merged(h), query: "#")) == ["sourced", "tagged"])
    }

    @Test func plainTextFuzziesTheTitle() {
        let h = history()
        #expect(values(HistoryFilter.filtered(merged(h), query: "bet")) == ["beta"])
        #expect(HistoryFilter.filtered(merged(h), query: "zzz").isEmpty)
    }

    @Test func plainWordStillMatchesTheSource() {
        let h = history()
        #expect(values(HistoryFilter.filtered(merged(h), query: "slack")) == ["beta"])
    }

    @Test func hashTokenAndTextCombine() {
        let h = history()
        #expect(values(HistoryFilter.filtered(merged(h), query: "#en alp")) == ["alpha"])
        #expect(values(HistoryFilter.filtered(merged(h), query: "#saf quoted")) == ["quoted line"])
        #expect(HistoryFilter.filtered(merged(h), query: "#en beta").isEmpty)
    }

    @Test func onlyHashTokensKeepRecencyOrder() {
        let h = ClipboardHistory()
        h.push("first", tag: "en")
        h.push("second", tag: "quote")
        h.push("third", tag: "en")
        #expect(values(HistoryFilter.filtered(merged(h), query: "#en")) == ["third", "first"])
    }

    @Test func obfuscatedEntryMatchesItsMaskNotItsValue() {
        let h = ClipboardHistory()
        h.push("abcdSECRET", source: "1Password")
        h.toggleObfuscation(at: 0)
        let entries = merged(h)
        #expect(values(HistoryFilter.filtered(entries, query: "abcd")) == ["abcdSECRET"])
        #expect(values(HistoryFilter.filtered(entries, query: "1password")) == ["abcdSECRET"])
        #expect(HistoryFilter.filtered(entries, query: "secret").isEmpty)
    }
}

@Suite struct HistoryFilterNonTextTests {
    @Test func imageEntriesPassThroughMergedAndFilter() {
        let h = ClipboardHistory()
        h.push(ClipEntry(value: "[image]", source: "Safari", image: Data([1])))
        h.push("plain text")
        #expect(values(HistoryFilter.filtered(merged(h), query: "")) == ["plain text", "[image]"])
        #expect(values(HistoryFilter.filtered(merged(h), query: "#saf")) == ["[image]"])
        #expect(HistoryFilter.filtered(merged(h), query: "#en").isEmpty)
    }

    @Test func fileEntriesPassThroughMerged() {
        let h = ClipboardHistory()
        h.push(ClipEntry(
            value: "[file] Report.pdf",
            fileURLs: [URL(fileURLWithPath: "/tmp/Report.pdf")]
        ))
        #expect(values(HistoryFilter.filtered(merged(h), query: "report")) == ["[file] Report.pdf"])
    }
}

@Suite struct HistoryFilterPillTests {
    @Test func pillsShowTagFirstThenSource() {
        let entry = ClipEntry(value: "x", tag: "en", source: "pi")
        #expect(HistoryFilter.pills(for: entry) == ["#en", "#pi"])
    }

    @Test func pillsOmitMissingValues() {
        #expect(HistoryFilter.pills(for: ClipEntry(value: "x")) == [])
        #expect(HistoryFilter.pills(for: ClipEntry(value: "x", source: "Safari")) == ["#Safari"])
    }

    @Test func obfuscatedRowsKeepTheirPills() {
        let entry = ClipEntry(value: "abcdSECRET", obfuscated: true, tag: "en")
        #expect(HistoryFilter.pills(for: entry) == ["#en"])
    }
}
