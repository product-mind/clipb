import Testing
@testable import clipb

@Suite struct VoiceConfigTests {
    private func parse(_ toml: String) throws -> VoiceConfig {
        try VoiceConfig(tables: TOML.parse(toml))
    }

    @Test func missingSectionUsesBuiltInThenDefault() throws {
        #expect(try parse("[router]\n\"*\" = \"ask\"\n").microphones == ["built-in", "default"])
    }

    @Test func readsMicrophonesInOrder() throws {
        let config = try parse("""
            [voice]
            microphones = ["Shure MV7", 'MacBook Pro Microphone', "default",]  # trailing comma ok
            """)
        #expect(config.microphones == ["Shure MV7", "MacBook Pro Microphone", "default"])
    }

    @Test func languagesDefaultToWhispersGuess() throws {
        #expect(try parse("[voice]\n").languages.isEmpty)
        #expect(try parse("[voice]\nlanguages = [\"en\", \" CS \"]\n").languages == ["en", "cs"])
        #expect(try parse("[voice]\nlanguages = [\"Czech\"]\n").languages == ["cs"])
        #expect(throws: VoiceConfig.ConfigError.self) { try parse("[voice]\nlanguages = [\"klingon\"]\n") }
        #expect(throws: VoiceConfig.ConfigError.self) { try parse("[voice]\nlanguages = \"en\"\n") }
    }

    @Test func theLikeliestConfiguredLanguageWins() {
        #expect(Transcript.bestLanguage(["en", "cs"], probabilities: ["en": 0.1, "cs": 0.3]) == "cs")
        #expect(Transcript.bestLanguage(["en", "cs"], probabilities: [:]) == "en")
        #expect(Transcript.bestLanguage([], probabilities: [:]) == nil)
    }

    @Test func rightOptionIsOffUnlessTurnedOn() throws {
        #expect(try parse("[voice]\n").rightOption == false)
        #expect(try parse("[voice]\nright_option = true\n").rightOption == true)
        #expect(throws: VoiceConfig.ConfigError.self) { try parse("[voice]\nright_option = \"yes\"\n") }
    }

    @Test func rejectsANonListOrEmptyList() {
        #expect(throws: VoiceConfig.ConfigError.self) { try parse("[voice]\nmicrophones = \"built-in\"\n") }
        #expect(throws: VoiceConfig.ConfigError.self) { try parse("[voice]\nmicrophones = []\n") }
    }

    @Test func tomlArraysMustBeStringsOnOneLine() {
        #expect(throws: TOML.ParseError.self) { try TOML.parse("x = [1, 2]") }
        #expect(throws: TOML.ParseError.self) { try TOML.parse("x = [\"a\",\n\"b\"]") }
        #expect(throws: TOML.ParseError.self) { try TOML.parse("x = [\"a\" \"b\"]") }
        #expect((try? TOML.parse("x = [ ]"))?.first?.entries.first?.value == .strings([]))
    }
}

@Suite struct MicsCommandTests {
    @Test func marksTheChosenMicAndTagsKeywords() {
        let laptop = Microphone(id: 5, name: "MacBook Pro Microphone", builtIn: true, hasInput: true)
        let airPods = Microphone(id: 7, name: "AirPods Pro", builtIn: false, hasInput: true)
        let out = MicsCommand.render(inputs: [airPods, laptop], defaultID: 7, chosen: laptop,
                                     preferences: ["built-in", "default"])
        #expect(out == """
              AirPods Pro  (system default)
            * MacBook Pro Microphone  (built-in)

            * = voice copy records from it: first connected of [voice] microphones = ["built-in", "default"]
            """)
    }

    @Test func saysSoWhenNothingMatches() {
        let out = MicsCommand.render(inputs: [], defaultID: nil, chosen: nil, preferences: ["Shure MV7"])
        #expect(out.contains("no input devices"))
        #expect(out.contains("No match"))
    }
}
