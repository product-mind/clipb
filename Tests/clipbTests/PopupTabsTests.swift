import Testing
@testable import clipb

@Suite struct PopupTabsTests {
    @Test func uncategorizedFirstThenSortedTags() {
        let h = ClipboardHistory()
        h.push("a")
        h.push("z1", tag: "zeta")
        h.push("d1", tag: "dictation")
        let tabs = PopupTabs.make(from: h)
        #expect(tabs.map(\.title) == [PopupTabs.uncategorizedTitle, "dictation", "zeta"])
        #expect(tabs.map(\.tag) == [nil, "dictation", "zeta"])
        #expect(tabs[1].entries.map(\.value) == ["d1"])
    }

    @Test func onlyUncategorizedTabWhenNoTags() {
        let h = ClipboardHistory()
        h.push("a")
        #expect(PopupTabs.make(from: h).count == 1)
    }

    @Test func initialTabPrefersUncategorized() {
        let h = ClipboardHistory()
        h.push("a")
        h.push("d", tag: "dictation")
        #expect(PopupTabs.initialIndex(of: PopupTabs.make(from: h)) == 0)
    }

    @Test func initialTabSkipsEmptyUncategorized() {
        let h = ClipboardHistory()
        h.push("d", tag: "dictation")
        #expect(PopupTabs.initialIndex(of: PopupTabs.make(from: h)) == 1)
    }

    @Test func tabNavigationWraps() {
        #expect(PopupTabs.index(from: 0, by: 1, count: 3) == 1)
        #expect(PopupTabs.index(from: 2, by: 1, count: 3) == 0)
        #expect(PopupTabs.index(from: 0, by: -1, count: 3) == 2)
        #expect(PopupTabs.index(from: 0, by: 1, count: 0) == 0)
    }
}

@Suite struct PopupTabSourceSearchTests {
    @Test func searchMatchesTheSourceApp() {
        let h = ClipboardHistory()
        h.push("alpha", source: "Slack")
        h.push("beta", source: "Safari")
        h.push("gamma")
        let tabs = PopupTabs.make(from: h)
        #expect(PopupTabs.matchCounts(in: tabs, query: "slack") == [1])
        #expect(PopupTabs.matchCounts(in: tabs, query: "safari") == [1])
    }

    @Test func obfuscatedEntryMatchesItsSourceNotItsValue() {
        let h = ClipboardHistory()
        h.push("abcdSECRET", source: "1Password")
        h.toggleObfuscation(at: 0)
        let tabs = PopupTabs.make(from: h)
        #expect(PopupTabs.matchCounts(in: tabs, query: "1password") == [1])
        #expect(PopupTabs.matchCounts(in: tabs, query: "SECRET") == [0])
    }
}

@Suite struct PopupTabMatchCountTests {
    @Test func countsMatchesPerTab() {
        let h = ClipboardHistory()
        h.push("alpha")
        h.push("beta")
        h.push("alpine link", tag: "link")
        let tabs = PopupTabs.make(from: h)
        #expect(PopupTabs.matchCounts(in: tabs, query: "") == [2, 1])
        #expect(PopupTabs.matchCounts(in: tabs, query: "al") == [1, 1])
        #expect(PopupTabs.matchCounts(in: tabs, query: "zzz") == [0, 0])
    }

    @Test func obfuscatedEntriesMatchTheirMaskNotTheirValue() {
        let h = ClipboardHistory()
        h.push("abcdSECRET")
        h.toggleObfuscation(at: 0)
        let tabs = PopupTabs.make(from: h)
        #expect(PopupTabs.matchCounts(in: tabs, query: "abcd") == [1])
        #expect(PopupTabs.matchCounts(in: tabs, query: "secret") == [0])
    }
}
