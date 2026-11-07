import Testing
@testable import clipb

@Suite struct EditorFontTests {
    @Test func readsGhosttyFamily() {
        #expect(EditorFont.ghosttyFamily(in: "# c\nfont-family = Monaco\nfont-size = 15\n") == "Monaco")
        #expect(EditorFont.ghosttyFamily(in: "font-family = \"JetBrains Mono\"") == "JetBrains Mono")
    }

    @Test func firstFamilyIsPrimaryAndEmptyResets() {
        #expect(EditorFont.ghosttyFamily(in: "font-family = A\nfont-family = B") == "A")
        #expect(EditorFont.ghosttyFamily(in: "font-family = A\nfont-family =\nfont-family = C") == "C")
        #expect(EditorFont.ghosttyFamily(in: "#font-family = A\nfont-size = 3") == nil)
    }
}

@Suite struct EditorConfigTests {
    private func parse(_ toml: String) throws -> EditorConfig {
        try EditorConfig(tables: TOML.parse(toml))
    }

    @Test func defaultsWithoutSection() throws {
        #expect(try parse("[voice]\nright_option = true\n") == EditorConfig())
        #expect(EditorConfig().font == nil)
        #expect(EditorConfig().markdown)
    }

    @Test func readsFontAndMarkdown() throws {
        let config = try parse("[editor]\nfont = \"Monaco\"\nmarkdown = false\n")
        #expect(config.font == "Monaco")
        #expect(!config.markdown)
    }

    @Test func emptyFontMeansDefault() throws {
        #expect(try parse("[editor]\nfont = \"\"\n").font == nil)
    }

    @Test func rejectsWrongTypesAndUnknownKeys() {
        #expect(throws: EditorConfig.ConfigError.self) { try parse("[editor]\nmarkdown = \"yes\"\n") }
        #expect(throws: EditorConfig.ConfigError.self) { try parse("[editor]\nstyle = \"markdown\"\n") }
    }
}

@Suite struct EditorFontSizeTests {
    @Test func sizeIsWholePointsWithinRange() {
        #expect(EditorFont.clampedSize(13.4) == 13)
        #expect(EditorFont.clampedSize(2) == EditorFont.sizeRange.lowerBound)
        #expect(EditorFont.clampedSize(200) == EditorFont.sizeRange.upperBound)
    }
}
