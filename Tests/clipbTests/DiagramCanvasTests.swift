import AppKit
import Testing
@testable import clipb

/// Mouse gestures on a drawing, driven cell by cell through the same calls
/// the editor's mouse loop makes (`press`, `pressMoved`, `pressEnded`).
@MainActor
@Suite struct DiagramCanvasTests {
    typealias D = AsciiDiagram
    typealias C = AsciiDiagram.Cell

    private func box(_ id: Int, _ x: Int, _ y: Int, _ text: [String]) -> D.Box {
        D.fitted(D.Box(id: id, x: x, y: y, width: 0, height: 0, text: text))
    }

    private var twoBoxes: D.Diagram {
        D.Diagram(boxes: [box(1, 0, 0, ["Client"]), box(2, 24, 0, ["API"])],
                  arrows: [D.Arrow(id: 1, from: 1, to: 2, label: ["calls"])])
    }

    private let before = "Some text\n\n"
    private let after = "\nMore text\n"

    private func document(_ d: D.Diagram) -> String {
        before + "```\n" + D.render(d).text + "\n```\n" + after
    }

    /// An editor holding the drawing, with a session on it.
    private func editor(_ d: D.Diagram) throws -> EditorTextView {
        let editor = EditorTextView()
        editor.string = document(d)
        #expect(editor.canvas.begin(at: (before as NSString).length + 4))
        return editor
    }

    /// The document still holds exactly one drawing and the text around it.
    private func drawing(in editor: EditorTextView, sourceLocation: SourceLocation = #_sourceLocation) throws -> D.Diagram {
        let text = editor.string
        #expect(text.hasPrefix(before + "```\n"), sourceLocation: sourceLocation)
        #expect(text.hasSuffix("\n```\n" + after), "\(text)", sourceLocation: sourceLocation)
        let inner = String(text.dropFirst(before.count + 4).dropLast(after.count + 5))
        let d = try #require(D.parse(inner), "no parse:\n\(text)", sourceLocation: sourceLocation)
        #expect(text == document(d), sourceLocation: sourceLocation)
        return d
    }

    private func drag(_ editor: EditorTextView, from start: C, through cells: [C]) {
        editor.canvas.press(at: start)
        for c in cells { editor.canvas.pressMoved(to: c) }
        editor.canvas.pressEnded(at: cells.last ?? start)
    }

    @Test func movingABoxRewritesTheBlockInPlace() throws {
        let editor = try editor(twoBoxes)
        // Down and to the right, one cell at a time, then back up a little:
        // every preview changes the block's length.
        let path = (1...8).map { C(x: 2 + $0, y: 1 + $0) } + [C(x: 10, y: 6), C(x: 11, y: 5)]
        drag(editor, from: C(x: 2, y: 1), through: path)
        let d = try drawing(in: editor)
        let client = try #require(d.boxes.first { $0.text == ["Client"] })
        #expect(client.x == 9 && client.y == 4)
        #expect(d.arrows.count == 1)
        guard case .box = editor.canvas.selection else {
            Issue.record("the moved box stays selected")
            return
        }
    }

    @Test func manyDragsInARowKeepOneDrawing() throws {
        let editor = try editor(twoBoxes)
        var at = C(x: 2, y: 1)
        for step in [(0, 6), (10, 0), (-4, -3), (3, 8), (-9, -11)] {
            let to = C(x: max(0, at.x + step.0), y: max(0, at.y + step.1))
            let path = (1...6).map { k in C(x: at.x + (to.x - at.x) * k / 6, y: at.y + (to.y - at.y) * k / 6) }
            drag(editor, from: at, through: path)
            _ = try drawing(in: editor)
            let client = try #require(try drawing(in: editor).boxes.first { $0.text == ["Client"] })
            at = C(x: client.x + 2, y: client.y + 1)
        }
    }

    @Test func dragThatEndsWhereItStartedChangesNothing() throws {
        let editor = try editor(twoBoxes)
        let original = editor.string
        drag(editor, from: C(x: 2, y: 1), through: [C(x: 3, y: 2), C(x: 6, y: 5), C(x: 2, y: 1)])
        #expect(editor.string == original)
    }

    @Test func resizingFromACorner() throws {
        let editor = try editor(twoBoxes)
        let client = twoBoxes.boxes[0]
        let corner = C(x: client.x + client.width - 1, y: client.y + client.height - 1)
        drag(editor, from: corner, through: (1...4).map { C(x: corner.x + $0, y: corner.y + $0) })
        let resized = try #require(try drawing(in: editor).boxes.first { $0.text == ["Client"] })
        #expect(resized.width == client.width + 4 && resized.height == client.height + 4)
    }

    @Test func draggingOnEmptySpaceMakesASizedBox() throws {
        let editor = try editor(twoBoxes)
        drag(editor, from: C(x: 2, y: 6), through: (1...10).map { C(x: 2 + $0 * 2, y: 6 + $0 / 3) })
        let d = try drawing(in: editor)
        #expect(d.boxes.count == 3)
        let made = try #require(d.boxes.first { $0.y == 6 })
        #expect(made.x == 2 && made.width == 21 && made.height == 4)
    }

    @Test func pullingAnArrowToEmptySpaceMakesABoxAndTypingNamesIt() throws {
        let editor = try editor(twoBoxes)
        let api = twoBoxes.boxes[1]
        let side = C(x: api.x + 3, y: api.y + api.height - 1)
        drag(editor, from: side, through: (1...6).map { C(x: side.x, y: side.y + $0) })
        #expect(editor.canvas.insert("DB"))
        let d = try drawing(in: editor)
        #expect(d.boxes.count == 3)
        let db = try #require(d.boxes.first { $0.text == ["DB"] })
        let parsedAPI = try #require(d.boxes.first { $0.text == ["API"] })
        #expect(d.arrows.contains { $0.from == parsedAPI.id && $0.to == db.id })
    }

    @Test func clickingEmptySpaceMakesABox() throws {
        let editor = try editor(twoBoxes)
        drag(editor, from: C(x: 10, y: 8), through: [])
        #expect(editor.canvas.insert("New"))
        #expect(try drawing(in: editor).boxes.contains { $0.text == ["New"] })
    }
}
