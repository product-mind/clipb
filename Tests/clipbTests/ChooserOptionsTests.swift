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
