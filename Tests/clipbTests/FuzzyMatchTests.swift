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
}
