import Testing
@testable import clipb

@Suite struct FuzzyMatchTests {
    @Test func emptyQueryMatchesEverythingWithZeroScore() {
        #expect(FuzzyMatch.score(query: "", in: "anything") == 0)
        #expect(FuzzyMatch.score(query: "", in: "") == 0)
    }

    @Test func exactSubstringMatches() {
        #expect(FuzzyMatch.score(query: "hello", in: "hello world") != nil)
    }

    @Test func caseInsensitive() {
        #expect(FuzzyMatch.score(query: "HELLO", in: "hello world") != nil)
        #expect(FuzzyMatch.score(query: "hello", in: "HELLO WORLD") != nil)
    }

    @Test func outOfOrderCharactersDoNotMatch() {
        #expect(FuzzyMatch.score(query: "olleh", in: "hello") == nil)
    }

    @Test func missingCharacterDoesNotMatch() {
        #expect(FuzzyMatch.score(query: "xyz", in: "hello") == nil)
    }

    @Test func scatteredSubsequenceStillMatches() {
        #expect(FuzzyMatch.score(query: "hlo", in: "hello") != nil)
    }

    @Test func consecutiveMatchScoresHigherThanScattered() {
        let consecutive = FuzzyMatch.score(query: "hel", in: "hello")!
        let scattered = FuzzyMatch.score(query: "hlo", in: "hello")!
        #expect(consecutive > scattered)
    }

    @Test func queryLongerThanTextDoesNotMatch() {
        #expect(FuzzyMatch.score(query: "helloworld", in: "hello") == nil)
    }

    // MARK: - Ranking

    private func ranked(_ query: String, _ texts: [String]) -> [String] {
        FuzzyMatch.rank(texts, query: query) { $0 }
    }

    @Test func wholeQueryAsSubstringBeatsScatteredMatch() {
        // Greedy left-to-right matching would pick the scattered a-b-c here.
        #expect(ranked("abc", ["a_b_c", "xx abc"]) == ["xx abc", "a_b_c"])
    }

    @Test func contiguousMatchLaterInTextBeatsScatteredMatchEarlier() {
        #expect(ranked("abc", ["axbxc and more", "zzzzzzzzzz abc"]).first == "zzzzzzzzzz abc")
    }

    @Test func longerContiguousRunRanksFirst() {
        // Both contain "hel"; only the second also contains "hello".
        #expect(ranked("hello", ["h e l l o", "say hello"]) == ["say hello", "h e l l o"])
        #expect(ranked("hell", ["hel lo", "hello"]).first == "hello")
    }

    @Test func wordStartBeatsMidWord() {
        #expect(ranked("fb", ["xfxbx", "foo_bar"]) == ["foo_bar", "xfxbx"])
    }

    @Test func equalScoresKeepOriginalOrder() {
        #expect(ranked("abc", ["abc", "abc", "abc"]) == ["abc", "abc", "abc"])
        #expect(ranked("abc", ["1 abc", "2 abc"]) == ["1 abc", "2 abc"])
    }

    @Test func nonMatchesAreDropped() {
        #expect(ranked("xyz", ["hello", "world"]).isEmpty)
    }

    @Test func emptyQueryKeepsEverythingInOrder() {
        #expect(ranked("", ["b", "a"]) == ["b", "a"])
    }

    @Test func matchBeyondTheAlignmentWindowStillMatches() {
        let text = String(repeating: "x", count: 5_000) + "needle"
        #expect(FuzzyMatch.score(query: "needle", in: text) != nil)
    }
}

@Suite struct FuzzyMatchesTests {
    @Test func matchesAgreesWithScore() {
        for (query, text) in [("", "x"), ("hlo", "Hello"), ("olh", "hello"), ("é", "Příliš")] {
            #expect(FuzzyMatch.matches(query: query, in: text) == (FuzzyMatch.score(query: query, in: text) != nil))
        }
    }
}
