import Testing
@testable import clipb

@Suite struct TitlesTests {
    @Test func uptimeUsesTheTwoLargestUnits() {
        #expect(Titles.uptime(5) == "5s")
        #expect(Titles.uptime(125) == "2m 5s")
        #expect(Titles.uptime(2 * 3600 + 13 * 60 + 40) == "2h 13m")
        #expect(Titles.uptime(3 * 86400 + 4 * 3600) == "3d 4h")
        #expect(Titles.uptime(-3) == "0s")
    }

    @Test func shortValueUnchanged() {
        let entry = ClipEntry(value: "hello")
        #expect(Titles.menuTitle(for: entry) == "hello")
    }

    @Test func truncationAppendsCharCount() {
        let entry = ClipEntry(value: String(repeating: "a", count: 30))
        #expect(Titles.menuTitle(for: entry) == String(repeating: "a", count: 20) + "... (30 chars)")
    }

    @Test func newlinesFlattenedInTitle() {
        let entry = ClipEntry(value: "line one\r\nline two")
        #expect(Titles.popupTitle(for: entry) == "line one line two")
    }

    @Test func truncateUTF8DoesNotSplitDiacritics() {
        // "é" is 2 bytes; cutting at 2 lands mid-character.
        #expect(Titles.truncateUTF8("héllo", maxBytes: 2) == "h")
        #expect(Titles.truncateUTF8("héllo", maxBytes: 3) == "hé")
    }

    @Test func truncateUTF8DoesNotSplitEmoji() {
        // "🐴" is 4 bytes at offset 2; cutting at 4 lands mid-emoji.
        #expect(Titles.truncateUTF8("ab🐴cd", maxBytes: 4) == "ab")
        #expect(Titles.truncateUTF8("ab🐴cd", maxBytes: 6) == "ab🐴")
    }

    @Test func nonASCIIRoundTripsWhenShort() {
        let value = "Příliš žluťoučký 🐴"
        let entry = ClipEntry(value: value)
        #expect(Titles.popupTitle(for: entry) == value)
    }

    @Test func obfuscatedShowsPrefixAndStars() {
        let entry = ClipEntry(value: "supersecret", obfuscated: true)
        #expect(Titles.menuTitle(for: entry) == "supe*******")
    }

    @Test func obfuscatedCappedAtTruncateLength() {
        let entry = ClipEntry(value: String(repeating: "x", count: 100), obfuscated: true)
        #expect(Titles.menuTitle(for: entry) == "xxxx" + String(repeating: "*", count: 16))
        #expect(Titles.popupTitle(for: entry) == "xxxx" + String(repeating: "*", count: 56))
    }

    @Test func obfuscatedShorterThanPrefixLength() {
        let entry = ClipEntry(value: "ab", obfuscated: true)
        #expect(Titles.menuTitle(for: entry) == "ab")
    }

    @Test func nulBytesStripped() {
        let entry = ClipEntry(value: "a\0b")
        #expect(Titles.menuTitle(for: entry) == "ab")
    }
}
