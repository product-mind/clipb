import Foundation
import Testing
@testable import clipb

@Suite struct EditDocumentTests {
    private let art = "┌──┐\n│ a│\n└──┘"

    @Test func parseWantsExactlyOnePath() {
        #expect(EditDocument.parse(["a.txt"]) == "a.txt")
        #expect(EditDocument.parse([]) == nil)
        #expect(EditDocument.parse(["a", "b"]) == nil)
        #expect(EditDocument.parse([""]) == nil)
    }

    @Test func aBareDrawingIsWrapped() {
        let doc = EditDocument(fileContent: art + "\n")
        #expect(doc.wrapped)
        #expect(doc.shown == "```\n\(art)\n```")
    }

    @Test func wrapperIsStrippedOnSaveKeepingTheNewlineHabit() {
        let withNewline = EditDocument(fileContent: art + "\n")
        #expect(withNewline.fileText(forShown: withNewline.shown) == art + "\n")
        let without = EditDocument(fileContent: art)
        #expect(without.fileText(forShown: without.shown) == art)
        #expect(without.fileText(forShown: "```\n┌┐\n```") == "┌┐")
    }

    @Test func editsInsideTheWrapperSurvive() {
        let doc = EditDocument(fileContent: art)
        #expect(doc.fileText(forShown: "```\n┌─┐\n└─┘\n```") == "┌─┐\n└─┘")
    }

    @Test func aBrokenWrapperIsWrittenAsShown() {
        let doc = EditDocument(fileContent: art)
        #expect(doc.fileText(forShown: "┌──┐\n```") == "┌──┐\n```")
        #expect(doc.fileText(forShown: "```\n┌──┐") == "```\n┌──┐")
    }

    @Test func fencedOrPlainContentIsLeftAlone() {
        for content in ["```\n\(art)\n```\n", "just text\n", ""] {
            let doc = EditDocument(fileContent: content)
            #expect(!doc.wrapped)
            #expect(doc.shown == content)
            #expect(doc.fileText(forShown: "x") == "x")
        }
        #expect(EditDocument(fileContent: nil).shown == "")
    }

    @Test func closeSavesOnlyAChangedBuffer() {
        #expect(!EditDocument.shouldSaveOnClose(shown: "a", lastSaved: "a"))
        #expect(EditDocument.shouldSaveOnClose(shown: "ab", lastSaved: "a"))
    }
}
