import Foundation
import Testing
@testable import clipb

@Suite struct InsertRuleTests {
    private func insert(_ text: String, _ pattern: String, _ target: String) -> String {
        ConfigRuleWriter.insertRule(into: text, pattern: pattern, target: target)
    }

    @Test func replacesTargetOfSamePatternKeepingComment() {
        let out = insert("[router]\n# keep\n\"a.com\" = \"safari\"   # note\n\"*\" = \"ask\"\n", "a.com", "chrome:me@x.com")
        #expect(out == "[router]\n# keep\n\"a.com\" = \"chrome:me@x.com\"   # note\n\"*\" = \"ask\"\n")
    }

    @Test func replacesBareKeyAndSingleQuotedValue() {
        #expect(insert("[router]\na.com = 'safari' # c\n", "a.com", "chrome") == "[router]\na.com = \"chrome\" # c\n")
    }

    @Test func insertsBeforeCatchAllAfterItsComment() {
        let out = insert("[router]\n\"b.com\" = \"safari\"\n# everything else\n\"*\" = \"safari\"\n", "a.com", "chrome")
        #expect(out == "[router]\n\"b.com\" = \"safari\"\n# everything else\n\"a.com\" = \"chrome\"\n\"*\" = \"safari\"\n")
    }

    @Test func appendsAfterLastRuleWithoutCatchAll() {
        let out = insert("[router]\n\"b.com\" = \"safari\"\n\n[profiles]\nwork = \"chrome:w\"\n", "a.com", "chrome")
        #expect(out == "[router]\n\"b.com\" = \"safari\"\n\"a.com\" = \"chrome\"\n\n[profiles]\nwork = \"chrome:w\"\n")
    }

    @Test func insertsAfterHeaderWhenRouterHasNoRules() {
        #expect(insert("[router]\n[profiles]\n", "a.com", "chrome") == "[router]\n\"a.com\" = \"chrome\"\n[profiles]\n")
    }

    @Test func addsRouterSectionWhenMissing() {
        #expect(insert("[profiles]\nwork = \"chrome:w\"\n", "a.com", "chrome")
            == "[profiles]\nwork = \"chrome:w\"\n\n[router]\n\"a.com\" = \"chrome\"\n")
    }

    @Test func emptyFileGetsRouterSection() {
        #expect(insert("", "a.com", "chrome") == "[router]\n\"a.com\" = \"chrome\"\n")
    }

    @Test func addsMissingTrailingNewlineAndKeepsCRLF() {
        #expect(insert("[router]\r\n\"b.com\" = \"x\"", "a.com", "chrome")
            == "[router]\r\n\"b.com\" = \"x\"\r\n\"a.com\" = \"chrome\"\r\n")
    }

    @Test func commentsAndOtherSectionsStayByteForByte() {
        let text = """
        # top comment

        [pipe]
        shortcut = "cmd+shift+x"

        [router]
        # work
        "*.corp" = "work"
        # catch
        "*" = "personal"

        [profiles]
        # alias
        work = "chrome:w"

        """
        let expected = """
        # top comment

        [pipe]
        shortcut = "cmd+shift+x"

        [router]
        # work
        "*.corp" = "work"
        # catch
        "x.com" = "safari"
        "*" = "personal"

        [profiles]
        # alias
        work = "chrome:w"

        """
        #expect(insert(text, "x.com", "safari") == expected)
    }

    @Test func rewrittenConfigRoutesTheLinkItWasMadeFor() throws {
        let link = URL(string: "https://sso.corp.example/oauth/authorize?state=1")!
        let pattern = try #require(RememberOptions.build(for: link).last?.pattern)
        let text = "[profiles]\nwork = \"chrome:w@x.com\"\n[router]\n\"*\" = \"safari\"\n"

        let config = try RouterConfig(toml: insert(text, pattern, "work"))

        #expect(config.rules.map(\.pattern) == [pattern, "*"])
        #expect(config.target(for: link) == RouteTarget(browser: "chrome", profile: "w@x.com"))
    }
}

@Suite struct TargetStringTests {
    private let localState = Data("""
    {"profile":{"info_cache":{
      "Default":{"user_name":"me@polygon.technology","name":"Polygon"},
      "Profile 4":{"user_name":"","name":"Anet"},
      "Profile 5":{"user_name":"","name":"  "}
    }}}
    """.utf8)

    private func chrome(_ folder: String) -> ChooserOption {
        ChooserOption(label: folder, browser: "chrome", profileFolder: folder)
    }

    @Test func emailIsPreferred() {
        #expect(ConfigRuleWriter.targetString(for: chrome("Default"), localState: localState, aliases: [:])
            == "chrome:me@polygon.technology")
    }

    @Test func displayNameIsTheFallback() {
        #expect(ConfigRuleWriter.targetString(for: chrome("Profile 4"), localState: localState, aliases: [:])
            == "chrome:Anet")
    }

    @Test func folderIsTheLastResort() {
        #expect(ConfigRuleWriter.targetString(for: chrome("Profile 5"), localState: localState, aliases: [:])
            == "chrome:Profile 5")
        #expect(ConfigRuleWriter.targetString(for: chrome("Default"), localState: nil, aliases: [:])
            == "chrome:Default")
    }

    @Test func safariIsPlain() {
        #expect(ConfigRuleWriter.targetString(for: ChooserOptions.safari, localState: localState, aliases: [:]) == "safari")
    }

    @Test func existingAliasIsReused() {
        let aliases = ["work": "chrome:me@polygon.technology"]
        #expect(ConfigRuleWriter.targetString(for: chrome("Default"), localState: localState, aliases: aliases) == "work")
    }

    @Test func aliasMustMatchExactly() {
        let aliases = ["work": "chrome:ME@polygon.technology"]
        #expect(ConfigRuleWriter.targetString(for: chrome("Default"), localState: localState, aliases: aliases)
            == "chrome:me@polygon.technology")
    }
}

@Suite struct RememberWriteTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipb-remember-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func missingConfigIsCreated() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("clipb.toml")

        try ConfigRuleWriter.remember(pattern: "a.com", option: ChooserOptions.safari, localState: nil, at: file)

        #expect(try String(contentsOf: file, encoding: .utf8) == "[router]\n\"a.com\" = \"safari\"\n")
    }

    @Test func writeGoesThroughSymlinkAndKeepsIt() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("dotfiles.toml")
        let link = dir.appendingPathComponent("clipb.toml")
        try "[router]\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)

        try ConfigRuleWriter.remember(pattern: "a.com", option: ChooserOptions.safari, localState: nil, at: link)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(try String(contentsOf: real, encoding: .utf8) == "[router]\n\"a.com\" = \"safari\"\n")
    }

    @Test func unparsableConfigIsLeftAlone() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("clipb.toml")
        let original = "[router]\n\"a.com\" = "
        try original.write(to: file, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try ConfigRuleWriter.remember(pattern: "b.com", option: ChooserOptions.safari, localState: nil, at: file)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
    }
}
