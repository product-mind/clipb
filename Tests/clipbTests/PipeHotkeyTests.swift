import Carbon.HIToolbox
import Foundation
import Testing
@testable import clipb

@Suite struct PipeHotkeyTests {
    private func pipe(_ id: String, hotkey: String?) -> PipeCommand {
        PipeCommand(id: id, name: id, command: "cat", hotkey: hotkey)
    }

    @Test func bindsEveryHotkeyLetter() {
        let bound = Pipes.hotkeys([pipe("en", hotkey: "e"), pipe("quote", hotkey: "q")])
        #expect(bound == [
            PipeHotKey(letter: "e", pipe: pipe("en", hotkey: "e")),
            PipeHotKey(letter: "q", pipe: pipe("quote", hotkey: "q")),
        ])
    }

    @Test func skipsTheBuiltInChords() {
        let bound = Pipes.hotkeys([
            pipe("history", hotkey: "v"),
            pipe("cut", hotkey: "x"),
            pipe("shot", hotkey: "c"),
            pipe("editor", hotkey: "i"),
        ])
        #expect(bound.isEmpty)
    }

    @Test func aReservedLetterCollidesCaseInsensitively() {
        #expect(Pipes.hotkeys([pipe("quote", hotkey: "C")]).isEmpty)
        #expect(Pipes.hotkeys([pipe("quote", hotkey: "c")]).isEmpty)
        #expect(Pipes.hotkeys([pipe("history", hotkey: "V"), pipe("editor", hotkey: "I")]).isEmpty)
    }

    @Test func eIsFreeForPipes() {
        // The editor chord moved off E, so E binds like any other letter.
        #expect(Pipes.hotkeys([pipe("en", hotkey: "e")]).map(\.letter) == ["e"])
        #expect(Pipes.hotkeys([pipe("en", hotkey: "E")]).map(\.letter) == ["e"])
    }

    @Test func theFirstPipeInFileOrderKeepsTheLetter() {
        let bound = Pipes.hotkeys([
            pipe("first", hotkey: "e"),
            pipe("second", hotkey: "E"),
            pipe("third", hotkey: "e"),
        ])
        #expect(bound.map(\.letter) == ["e"])
        #expect(bound.map(\.pipe.id) == ["first"])
    }

    @Test func pipesWithoutAHotkeyAreNotBound() {
        let bound = Pipes.hotkeys([pipe("en", hotkey: nil), pipe("save", hotkey: "s")])
        #expect(bound.map(\.letter) == ["s"])
    }

    @Test func aCallerCanReserveMoreLetters() {
        #expect(Pipes.hotkeys([pipe("en", hotkey: "e")], reserved: ["e"]).isEmpty)
        #expect(Pipes.hotkeys([pipe("en", hotkey: "e")], reserved: ["V"]).map(\.letter) == ["e"])
    }

    @Test func theLetterFoldsWithoutTheLocale() {
        // `lowercased()` would turn I into ı under a Turkish locale: fold ASCII only.
        #expect(Pipes.asciiLowercased("I") == "i")
        #expect(Pipes.asciiLowercased("C") == "c")
        #expect(Pipes.asciiLowercased("Zz") == "zz")
        #expect(Pipes.asciiLowercased("i") == "i")
        // Non-ASCII letters pass through untouched, so they still bind nothing.
        #expect(Pipes.asciiLowercased("ÉÉ") == "ÉÉ")
        #expect(Pipes.asciiLowercased("ı") == "ı")
    }

    @Test func uppercaseIAndCSkipTheirReservedChords() {
        #expect(Pipes.hotkeys([pipe("editor", hotkey: "I")]).isEmpty)
        #expect(Pipes.hotkeys([pipe("shot", hotkey: "C")]).isEmpty)
        // The Turkish dotless i is not an ASCII letter, so it binds nothing either.
        #expect(Pipes.hotkeys([pipe("turkish", hotkey: "ı")]).isEmpty)
        #expect(Pipes.hotkeys([pipe("turkish", hotkey: "İ")]).isEmpty)
    }

    @Test func skipsLettersNoKeyCanSend() {
        // Parsing rejects these, so only a hand-built pipe reaches the filter.
        #expect(Pipes.hotkeys([pipe("bad", hotkey: "é"), pipe("ok", hotkey: "e")]).map(\.letter) == ["e"])
        #expect(Pipes.hotkeys([pipe("bad", hotkey: "ab")]).isEmpty)
        #expect(Pipes.hotkeys([pipe("bad", hotkey: "1")]).isEmpty)
    }

    @Test func theRealConfigSkipsTheQuotePipesC() throws {
        // ~/.config/clipb.toml as the user has it: the quote pipe's c is the screencapture's.
        let parsed = try Pipes.parse(TOML.parse("""
        [pipe.en]
        name = "Fix English"
        run = "cat"
        [pipe.quote]
        name = "Quote"
        hotkey = "c"
        run = "sed 's/^/> /'"
        [pipe.save]
        name = "Save"
        run = "cat"
        [pipe.turkish]
        name = "Turkish"
        run = "cat"
        [pipe.up]
        hotkey = "u"
        run = "tr a-z A-Z"
        """))
        let bound = Pipes.hotkeys(parsed)
        #expect(bound.map(\.letter) == ["u"])
        #expect(bound.map(\.pipe.id) == ["up"])
    }
}

@Suite struct HotKeyLetterTests {
    @Test func everyLetterHasAKeyCode() {
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            #expect(HotKey.keyCode(forLetter: String(letter)) != nil)
        }
    }

    @Test func lettersMapToTheirOwnKeyCodes() {
        #expect(HotKey.keyCode(forLetter: "a") == kVK_ANSI_A)
        #expect(HotKey.keyCode(forLetter: "c") == kVK_ANSI_C)
        #expect(HotKey.keyCode(forLetter: "e") == kVK_ANSI_E)
        #expect(HotKey.keyCode(forLetter: "i") == kVK_ANSI_I)
        #expect(HotKey.keyCode(forLetter: "v") == kVK_ANSI_V)
        #expect(HotKey.keyCode(forLetter: "x") == kVK_ANSI_X)
        #expect(HotKey.keyCode(forLetter: "z") == kVK_ANSI_Z)
    }

    @Test func uppercaseMapsToTheSameKey() {
        #expect(HotKey.keyCode(forLetter: "E") == kVK_ANSI_E)
        #expect(HotKey.keyCode(forLetter: "Q") == kVK_ANSI_Q)
        // I and C keep their keys whatever the locale's case rules say.
        #expect(HotKey.keyCode(forLetter: "I") == kVK_ANSI_I)
        #expect(HotKey.keyCode(forLetter: "C") == kVK_ANSI_C)
    }

    @Test func anythingButOneAsciiLetterHasNoKeyCode() {
        #expect(HotKey.keyCode(forLetter: "é") == nil)
        #expect(HotKey.keyCode(forLetter: "1") == nil)
        #expect(HotKey.keyCode(forLetter: "") == nil)
        #expect(HotKey.keyCode(forLetter: "ab") == nil)
        #expect(HotKey.keyCode(forLetter: "éa") == nil)
    }
}
