import Foundation
import Testing
@testable import clipb

@Suite struct TOMLTests {
    @Test func parsesTablesAndKeepsOrder() throws {
        let tables = try TOML.parse("""
        # comment
        top = 1
        [router]
        "b.com" = "x"   # trailing
        'a.com' = "y"
        [other]
        on = true
        """)
        #expect(tables.map(\.name) == ["", "router", "other"])
        #expect(tables[1].entries.map(\.key) == ["b.com", "a.com"])
        #expect(tables[1].entries.map(\.value) == [.string("x"), .string("y")])
        #expect(tables[0].entries[0].value == .int(1))
        #expect(tables[2].entries[0].value == .bool(true))
    }

    @Test func hashInsideStringIsNotAComment() throws {
        let tables = try TOML.parse(#"k = "a # b""#)
        #expect(tables[0].entries[0].value == .string("a # b"))
    }

    @Test func rejectsBrokenLines() {
        #expect(throws: TOML.ParseError.self) { try TOML.parse("k = ") }
        #expect(throws: TOML.ParseError.self) { try TOML.parse(#"k = "open"#) }
        #expect(throws: TOML.ParseError.self) { try TOML.parse(#"k = "a" junk"#) }
        #expect(throws: TOML.ParseError.self) { try TOML.parse("[[arr]]") }
    }
}

@Suite struct RouterTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test func plainDomainMatchesSubdomainsOnly() {
        #expect(Router.matches("linkedin.com", url("https://www.linkedin.com/in/x")))
        #expect(Router.matches("linkedin.com", url("https://linkedin.com")))
        #expect(!Router.matches("linkedin.com", url("https://notlinkedin.com")))
    }

    @Test func hostGlobNeedsASubdomain() {
        #expect(Router.matches("*.oddin.dev", url("https://a.oddin.dev/x")))
        #expect(!Router.matches("*.oddin.dev", url("https://oddin.dev/x")))
    }

    @Test func urlPatternMatchesPrefix() {
        #expect(Router.matches("https://github.com/golang-cz/*", url("https://github.com/golang-cz/clipb/pull/1")))
        #expect(Router.matches("https://github.com/golang-cz/*", url("https://GitHub.com/Golang-CZ/x")))
        #expect(!Router.matches("https://github.com/golang-cz/*", url("https://github.com/other/x")))
    }

    @Test func portPatternComparesHostAndPort() {
        #expect(Router.matches("localhost:6679", url("http://localhost:6679/a")))
        #expect(!Router.matches("localhost:6679", url("http://localhost:3000/a")))
    }

    @Test func bareStarMatchesEverything() {
        #expect(Router.matches("*", url("https://example.com")))
    }

    @Test func firstMatchWins() throws {
        let config = try RouterConfig(toml: """
        [router]
        "https://github.com/golang-cz/*" = "chrome:work"
        "github.com" = "chrome:other"
        "*" = "safari"
        """)
        #expect(config.target(for: url("https://github.com/golang-cz/x")) == RouteTarget(browser: "chrome", profile: "work"))
        #expect(config.target(for: url("https://github.com/foo/x")) == RouteTarget(browser: "chrome", profile: "other"))
        #expect(config.target(for: url("https://example.com")) == RouteTarget(browser: "safari", profile: nil))
    }

    @Test func noMatchIsNil() throws {
        let config = try RouterConfig(toml: "[router]\n\"a.com\" = \"safari\"")
        #expect(config.target(for: url("https://b.com")) == nil)
    }

    @Test func aliasExpandsBeforeSplitting() throws {
        let config = try RouterConfig(toml: """
        [profiles]
        "chrome:personal" = "chrome:me@example.com"
        [router]
        "*" = "chrome:personal"
        """)
        #expect(config.target(for: url("https://x.com")) == RouteTarget(browser: "chrome", profile: "me@example.com"))
    }

    @Test func unknownSectionsAreIgnoredAndNonStringRulesRejected() throws {
        _ = try RouterConfig(toml: "[pipe]\nshortcut = \"cmd+shift+x\"\n[clipboard]\nitems = 100")
        #expect(throws: RouterConfig.ConfigError.self) { try RouterConfig(toml: "[router]\n\"a.com\" = 1") }
    }

    @Test func browserNames() {
        #expect(Browsers.resolve("Chrome")?.bundleID == "com.google.Chrome")
        #expect(Browsers.resolve("org.example.Browser")?.bundleID == "org.example.Browser")
        #expect(Browsers.resolve("nope") == nil)
    }
}

@Suite struct ChromiumProfilesTests {
    private let localState = Data("""
    {"profile":{"info_cache":{
      "Default":{"user_name":"me@polygon.technology","name":"Polygon"},
      "Profile 4":{"user_name":"me@golang.cz","name":"golang.cz"},
      "Profile 5":{"user_name":"","name":"Anet"}
    }}}
    """.utf8)

    @Test func matchesEmailThenNameThenFolder() {
        #expect(ChromiumProfiles.folder(for: "ME@golang.cz", localState: localState) == "Profile 4")
        #expect(ChromiumProfiles.folder(for: "Anet", localState: localState) == "Profile 5")
        #expect(ChromiumProfiles.folder(for: "default", localState: localState) == "Default")
        #expect(ChromiumProfiles.folder(for: "nobody@x.com", localState: localState) == nil)
    }

    @Test func garbageIsNil() {
        #expect(ChromiumProfiles.folder(for: "a", localState: Data("nope".utf8)) == nil)
    }
}

@Suite struct ExampleConfigTests {
    private func routed(_ s: String) throws -> RouteTarget? {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("examples/config.toml")
        return try RouterConfig.load(from: path).target(for: URL(string: s)!)
    }

    @Test func exampleRoutesThroughAliases() throws {
        #expect(try routed("https://github.com/my-org/clipb")?.profile == "you@work.example")
        #expect(try routed("https://wiki.corp.example/x")?.profile == "you@work.example")
        #expect(try routed("https://www.youtube.com/watch?v=1")?.profile == "you@gmail.example")
        #expect(try routed("https://unlisted.example/")?.profile == "you@gmail.example")
    }
}

@Suite struct RouterConfigCacheTests {
    private func tempFile(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipb-cache-\(UUID().uuidString).toml")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func parsesOnceUntilTheFileChanges() throws {
        let url = try tempFile("[router]\n\"a.com\" = \"safari\"")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = RouterConfigCache(url: url)

        #expect(try cache.current().rules.count == 1)
        #expect(try cache.current().rules.count == 1)
        #expect(cache.loads == 1)

        try "[router]\n\"a.com\" = \"safari\"\n\"b.com\" = \"safari\"".write(to: url, atomically: true, encoding: .utf8)
        #expect(try cache.current().rules.count == 2)
        #expect(cache.loads == 2)
    }

    @Test func sameSizeEditWithNewMtimeReloads() throws {
        let url = try tempFile("[router]\n\"a.com\" = \"safari\"")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = RouterConfigCache(url: url)
        _ = try cache.current()

        try "[router]\n\"b.com\" = \"safari\"".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
        #expect(try cache.current().rules.first?.pattern == "b.com")
    }

    @Test func missingFileThrowsAndRecovers() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipb-missing-\(UUID().uuidString).toml")
        let cache = RouterConfigCache(url: url)
        #expect(throws: (any Error).self) { try cache.current() }

        try "[router]\n\"a.com\" = \"safari\"".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try cache.current().rules.count == 1)
    }

    @Test func brokenConfigIsCachedUntilFixed() throws {
        let url = try tempFile("[router]\n\"a.com\" = ")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = RouterConfigCache(url: url)
        #expect(throws: (any Error).self) { try cache.current() }
        #expect(throws: (any Error).self) { try cache.current() }
        #expect(cache.loads == 1)
    }
}
