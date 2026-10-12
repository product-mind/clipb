import Testing
@testable import clipb

@Suite struct LinksTests {
    @Test func acceptsASingleWebURL() {
        #expect(Links.webURL(in: "https://github.com/golang-cz/clipb")?.host == "github.com")
        #expect(Links.webURL(in: "  http://localhost:3000/a\n")?.port == 3000)
    }

    @Test func rejectsEverythingElse() {
        #expect(Links.webURL(in: "see https://github.com") == nil)
        #expect(Links.webURL(in: "https://a.com https://b.com") == nil)
        #expect(Links.webURL(in: "ftp://example.com/x") == nil)
        #expect(Links.webURL(in: "mailto:me@example.com") == nil)
        #expect(Links.webURL(in: "github.com/x") == nil)
        #expect(Links.webURL(in: "") == nil)
    }
}
