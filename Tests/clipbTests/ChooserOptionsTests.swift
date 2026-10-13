import Foundation
import Testing
@testable import clipb

@Suite struct ChooserOptionsTests {
    private func localState(_ cache: String) -> Data {
        Data("{\"profile\":{\"info_cache\":{\(cache)}}}".utf8)
    }

    @Test func defaultFirstThenSortedByFolder() {
        let options = ChooserOptions.build(localState: localState("""
            "Profile 2":{"name":"Polygon"},
            "Default":{"name":"Personal"},
            "Profile 1":{"name":"Side"}
            """))
        #expect(options.map(\.profileFolder) == ["Default", "Profile 1", "Profile 2", nil])
        #expect(options.map(\.label) == ["Personal", "Side", "Polygon", "Safari"])
        #expect(options.allSatisfy { $0.browser == "chrome" || $0.browser == "safari" })
    }

    @Test func missingOrEmptyNameFallsBackToFolder() {
        let options = ChooserOptions.build(localState: localState("""
            "Default":{"user_name":"me@example.com"},
            "Profile 4":{"name":"   "}
            """))
        #expect(options.map(\.label) == ["Default", "Profile 4", "Safari"])
    }

    @Test func capsAtNineWithSafariLast() {
        let cache = (1...12).map { "\"Profile \($0)\":{\"name\":\"P\($0)\"}" }.joined(separator: ",")
        let options = ChooserOptions.build(localState: localState(cache))
        #expect(options.count == ChooserOptions.maxOptions)
        #expect(options.last == ChooserOptions.safari)
        #expect(options.dropLast().allSatisfy { $0.browser == "chrome" })
    }

    @Test func invalidOrMissingJSONLeavesOnlySafari() {
        #expect(ChooserOptions.build(localState: nil) == [ChooserOptions.safari])
        #expect(ChooserOptions.build(localState: Data("nope".utf8)) == [ChooserOptions.safari])
        #expect(ChooserOptions.build(localState: Data("{\"profile\":{}}".utf8)) == [ChooserOptions.safari])
        #expect(ChooserOptions.build(localState: Data()) == [ChooserOptions.safari])
    }

    @Test func digitKeysMapToOptionsInRange() {
        #expect(ChooserOptions.index(forKey: "1", optionCount: 3) == 0)
        #expect(ChooserOptions.index(forKey: "3", optionCount: 3) == 2)
        #expect(ChooserOptions.index(forKey: "4", optionCount: 3) == nil)
        #expect(ChooserOptions.index(forKey: "9", optionCount: 9) == 8)
        #expect(ChooserOptions.index(forKey: "0", optionCount: 9) == nil)
        #expect(ChooserOptions.index(forKey: "a", optionCount: 9) == nil)
        #expect(ChooserOptions.index(forKey: "12", optionCount: 9) == nil)
        #expect(ChooserOptions.index(forKey: "", optionCount: 9) == nil)
    }
}

@Suite struct RememberOptionsTests {
    private func patterns(_ link: String) -> [String?] {
        RememberOptions.build(for: URL(string: link)!).map(\.pattern)
    }

    @Test func firstOptionSavesNothing() {
        #expect(RememberOptions.build(for: URL(string: "https://a.example.com/x")!).first == RememberOptions.dontRemember)
    }

    @Test func subdomainGivesHostThenParent() {
        #expect(patterns("https://a.b.example.com/x") == [nil, "a.b.example.com", "*.example.com"])
    }

    @Test func twoLabelHostHasNoParent() {
        #expect(patterns("https://example.com/login") == [nil, "example.com"])
    }

    @Test func publicSuffixHasNoParent() {
        #expect(patterns("https://shop.example.co.uk/") == [nil, "shop.example.co.uk"])
        #expect(patterns("https://x.example.com.au/") == [nil, "x.example.com.au"])
    }

    @Test func ipAddressHasNoParent() {
        #expect(patterns("http://192.168.1.10/a") == [nil, "192.168.1.10"])
    }

    @Test func nonDefaultPortJoinsTheHost() {
        #expect(patterns("http://localhost:6679/x") == [nil, "localhost:6679"])
        #expect(patterns("https://a.example.com:8443/x") == [nil, "a.example.com:8443", "*.example.com"])
    }

    @Test func defaultPortIsLeftOut() {
        #expect(patterns("https://example.com:443/") == [nil, "example.com"])
    }

    @Test func oneSegmentPathGivesNoFolderRule() {
        #expect(patterns("https://glean.com/login") == [nil, "glean.com"])
    }

    @Test func twoSegmentPathGivesFolderRule() {
        #expect(patterns("https://glean.com/oauth/authorize") == [nil, "glean.com", "https://glean.com/oauth/*"])
    }

    @Test func folderRuleKeepsSchemeAndPort() {
        #expect(patterns("http://localhost:6679/api/v1/x") == [nil, "localhost:6679", "http://localhost:6679/api/*"])
    }

    @Test func queryAndFragmentNeverLeak() {
        let link = URL(string: "https://x.glean.com/oauth/authorize?code=SECRET123&state=1#frag456")!
        let options = RememberOptions.build(for: link)
        #expect(options.contains { $0.pattern == "https://x.glean.com/oauth/*" })
        for pattern in options.compactMap(\.pattern) {
            #expect(!pattern.contains("SECRET123"))
            #expect(!pattern.contains("?"))
            #expect(!pattern.contains("#"))
            #expect(Router.matches(pattern, link))
        }
    }
}
