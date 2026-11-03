import Testing
@testable import clipb

@Suite struct TypingChunksTests {
    @Test func splitsIntoTwentyUnitChunks() {
        let chunks = Paste.typingChunks(String(repeating: "a", count: 45))
        #expect(chunks.map(\.count) == [20, 20, 5])
    }

    @Test func neverSplitsASurrogatePair() {
        let text = String(repeating: "a", count: 19) + "😀b"
        let chunks = Paste.typingChunks(text)
        #expect(chunks.map(\.count) == [19, 3])
        #expect(chunks.map { String(decoding: $0, as: UTF16.self) }.joined() == text)
    }

    @Test func lineBreaksBecomeSpaces() {
        let chunks = Paste.typingChunks("a\nb\r\nc")
        #expect(chunks.map { String(decoding: $0, as: UTF16.self) }.joined() == "a b c")
    }

    @Test func czechKeepsItsDiacritics() {
        let chunks = Paste.typingChunks("Příliš žluťoučký kůň")
        #expect(chunks.map { String(decoding: $0, as: UTF16.self) }.joined() == "Příliš žluťoučký kůň")
    }
}
