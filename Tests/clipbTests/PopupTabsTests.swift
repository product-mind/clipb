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
