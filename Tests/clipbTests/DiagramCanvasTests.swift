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
        guard case .boxes(let ids) = editor.canvas.selection, ids.count == 1 else {
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

    @Test func aClickOnEmptySpacePutsACaretADoubleClickMakesABox() throws {
        let editor = try editor(twoBoxes)
        let original = editor.string
        editor.canvas.press(at: C(x: 10, y: 8))
        editor.canvas.pressEnded(at: C(x: 10, y: 8))
        #expect(editor.string == original)
        #expect(editor.canvas.selection == .free(C(x: 10, y: 8), home: 10))
        editor.canvas.press(at: C(x: 10, y: 8), clicks: 2)
        editor.canvas.pressEnded(at: C(x: 10, y: 8))
        #expect(editor.canvas.insert("New"))
        #expect(try drawing(in: editor).boxes.contains { $0.text == ["New"] })
    }

    @Test func aDoubleClickedBoxLeftEmptyGoesAway() throws {
        let editor = try editor(twoBoxes)
        let original = editor.string
        editor.canvas.press(at: C(x: 10, y: 8), clicks: 2)
        editor.canvas.pressEnded(at: C(x: 10, y: 8))
        #expect(editor.string != original)
        editor.canvas.endEditing()
        #expect(editor.string == original)
    }

    @Test func clickingIntoTextPutsTheCaretThere() throws {
        let editor = try editor(twoBoxes)
        // "Client" starts at column 2 of row 1: the click lands after "Cli".
        drag(editor, from: C(x: 5, y: 1), through: [])
        guard case .text(_, _, let caret) = editor.canvas.selection else {
            Issue.record("a click in the text edits it")
            return
        }
        #expect(caret.column == 3)
        #expect(editor.canvas.insert("X"))
        #expect(try drawing(in: editor).boxes.contains { $0.text == ["CliXent"] })
        // One step back: between "Cli" and "X".
        #expect(editor.canvas.command(#selector(NSResponder.moveLeft(_:))))
        #expect(editor.canvas.insert("Y"))
        #expect(try drawing(in: editor).boxes.contains { $0.text == ["CliYXent"] })
    }

    @Test func clickingAnEdgePicksTheBoxAndArrowKeysMoveIt() throws {
        let editor = try editor(twoBoxes)
        drag(editor, from: C(x: 0, y: 1), through: [])
        guard case .boxes(let ids) = editor.canvas.selection, ids.count == 1 else {
            Issue.record("an edge click picks the box")
            return
        }
        #expect(editor.canvas.command(#selector(NSResponder.moveDown(_:))))
        #expect(try drawing(in: editor).boxes.contains { $0.text == ["Client"] && $0.y == 1 })
    }

    @Test func aDragOnEmptySpacePicksBoxesThatMoveTogether() throws {
        let editor = try editor(twoBoxes)
        let api = twoBoxes.boxes[1]
        // From below-left of everything to inside the API box's row.
        drag(editor, from: C(x: 0, y: 6), through: [C(x: 10, y: 4), C(x: api.x + 2, y: 1)])
        guard case .boxes(let ids) = editor.canvas.selection, ids.count == 2 else {
            Issue.record("the rectangle picks both boxes: \(String(describing: editor.canvas.selection))")
            return
        }
        drag(editor, from: C(x: 2, y: 1), through: [C(x: 2, y: 3), C(x: 2, y: 5)])
        let d = try drawing(in: editor)
        #expect(d.boxes.allSatisfy { $0.y == 4 }, "\(editor.string)")
        #expect(d.arrows.count == 1)
    }

    @Test func anEdgeDraggedOntoAnotherBoxMakesAnArrow() throws {
        var three = twoBoxes
        three.boxes.append(box(3, 0, 8, ["DB"]))
        let editor = try editor(three)
        let db = try drawing(in: editor).boxes.first { $0.text == ["DB"] }!
        // From the left edge of Client down onto DB.
        drag(editor, from: C(x: 0, y: 1), through: [C(x: 0, y: 4), C(x: db.x + 2, y: db.y + 1)])
        let d = try drawing(in: editor)
        #expect(d.arrows.count == 2, "\(editor.string)")
        let client = d.boxes.first { $0.text == ["Client"] }!
        #expect(client.x == 0 && client.y == 0, "the box stays put")
        #expect(d.arrows.contains { $0.from == client.id && $0.to == d.boxes.first { $0.text == ["DB"] }!.id })
    }

    // MARK: Box zones (MODAL.md)

    @Test func theSideHandlesAreTheMiddleOfEachSide() {
        let handles = Set(DiagramCanvas.handles(of: .init(x: 0, y: 0, width: 10, height: 3)))
        #expect(handles == [C(x: 4, y: 0), C(x: 5, y: 0), C(x: 4, y: 2), C(x: 5, y: 2), C(x: 0, y: 1), C(x: 9, y: 1)])
    }

    @Test func aClickInsideOffTheTextPutsTheCaretAtTheEnd() throws {
        let editor = try editor(twoBoxes)
        // Column 1 of row 1: the padding before "Client".
        drag(editor, from: C(x: 1, y: 1), through: [])
        guard case .text(_, _, let caret) = editor.canvas.selection else {
            Issue.record("a click inside the box edits its text: \(String(describing: editor.canvas.selection))")
            return
        }
        #expect(caret.column == 6)
    }

    @Test func draggingTheBorderOffTheHandlesMovesEvenOverAnotherBox() throws {
        var three = twoBoxes
        three.boxes.append(box(3, 0, 8, ["DB"]))
        let editor = try editor(three)
        // The top edge at column 1 is border, not a handle: it moves the box.
        drag(editor, from: C(x: 1, y: 0), through: [C(x: 1, y: 2), C(x: 1, y: 4)])
        let d = try drawing(in: editor)
        #expect(d.arrows.count == 1, "no new arrow: \(editor.string)")
        #expect(d.boxes.contains { $0.text == ["Client"] && $0.y == 4 }, "\(editor.string)")
    }

    @Test func aHandleDroppedOnEmptySpaceMakesNothing() throws {
        let editor = try editor(twoBoxes)
        let original = editor.string
        drag(editor, from: C(x: 0, y: 1), through: [C(x: 0, y: 4), C(x: 3, y: 6)])
        #expect(editor.string == original)
    }

    // MARK: Double-click styles (docs/ascii-diagram-style-guide.md)

    private func doubleClick(_ editor: EditorTextView, at c: C) {
        editor.canvas.press(at: c)
        editor.canvas.pressEnded(at: c)
        editor.canvas.press(at: c, clicks: 2)
        editor.canvas.pressEnded(at: c)
    }

    @Test func doubleClickingABorderCyclesTheBoxStyle() throws {
        let editor = try editor(twoBoxes)
        doubleClick(editor, at: C(x: 1, y: 0))
        #expect(try drawing(in: editor).boxes.first { $0.text == ["Client"] }?.style == .heavy, "\(editor.string)")
        doubleClick(editor, at: C(x: 1, y: 0))
        #expect(try drawing(in: editor).boxes.first { $0.text == ["Client"] }?.style == .double, "\(editor.string)")
    }

    @Test func doubleClickingALineCyclesItsStyleAndItsHeadTheHeads() throws {
        let editor = try editor(twoBoxes)
        let path = try #require(D.render(try drawing(in: editor)).paths.values.first)
        doubleClick(editor, at: path[path.count / 2])
        #expect(try drawing(in: editor).arrows.first?.line == .heavy, "\(editor.string)")
        let head = try #require(D.render(try drawing(in: editor)).paths.values.first?.last)
        doubleClick(editor, at: head)
        let d = try drawing(in: editor)
        #expect(d.arrows.count == 1)
        let from = d.arrows.first?.from
        #expect(d.boxes.first { $0.id == from }?.text == ["API"], "backward now: \(editor.string)")
    }

    // MARK: Hand-drawn art, edited in place

    static let gateways = #"""
INTERNET                          GATEWAYS                         BACKENDS
                                                                   [internal-only S2S tokens]

                                                                    ┌────────────────────┐
 ┌───────────────────────────┐     ┌────────────────────────┐   ┌──▶│ auth               │
 │ Partner's backends        │────▶│ oms-api [1]            │───┤   ├────────────────────┤
 │ [secret key → API token]  │     └────────────────────────┘   ├──▶│ core [2]           │
 └───────────────────────────┘         ▲                        │   ├────────────────────┤
                                       │                        ├──▶│ bpn-api            │
 ┌───────────────────────────┐         │                        │   ├────────────────────┤
 │ Partner's websites        │─────────┘                        ├──▶│ waas               │
 │ [publishable key]         │                                  │   ├────────────────────┤
 └───────────────────────────┘                                  ├──▶│ indexer            │
                                                                │   ├────────────────────┤
 ┌───────────────────────────┐     ┌────────────────────────┐   ├──▶│ analytics          │
 │ Dashboard                 │────▶│ Dashboard BFF proxy    │   │   ├────────────────────┤
 │ [user session token]      │     └────────────┬───────────┘   ├──▶│ audit              │
 └───────────────────────────┘                  ▼               │   ├────────────────────┤
                                   ┌────────────────────────┐   ├──▶│ events             │
                                   │ dashboard-api          │───┤   ├────────────────────┤
                                   └────────────────────────┘   ├──▶│ webhooks           │
                                                                │   ├────────────────────┤
 ┌───────────────────────────┐     ┌────────────────────────┐   ├──▶│ capture            │
 │ Backoffice                │────▶│ backoffice-api         │───┤   ├────────────────────┤
 │ [bck session token]       │     └────────────────────────┘   └──▶│ files              │
 └───────────────────────────┘                                      └────────────────────┘

 [1] currently api-gateway
 [2] currently omsx-api
"""#

    private func artEditor() -> EditorTextView {
        let editor = EditorTextView()
        editor.string = before + "```\n" + Self.gateways + "\n```\n" + after
        #expect(editor.canvas.begin(at: (before as NSString).length + 4))
        return editor
    }

    /// The art between the fences, with the text around the block checked.
    private func art(in editor: EditorTextView, sourceLocation: SourceLocation = #_sourceLocation) throws -> AsciiArt.Scene {
        let text = editor.string
        #expect(text.hasPrefix(before + "```\n"), sourceLocation: sourceLocation)
        #expect(text.hasSuffix("\n```\n" + after), "\(text)", sourceLocation: sourceLocation)
        let inner = String(text.dropFirst(before.count + 4).dropLast(after.count + 5))
        return try #require(AsciiArt.scan(inner), "no scan:\n\(inner)", sourceLocation: sourceLocation)
    }

    /// Where a box's text starts in the fixture: its first cell.
    private func cell(of word: String) throws -> C {
        let lines = Self.gateways.components(separatedBy: "\n")
        let y = try #require(lines.firstIndex { $0.contains(word) })
        let x = try #require(lines[y].range(of: word)).lowerBound
        return C(x: lines[y].distance(from: lines[y].startIndex, to: x), y: y)
    }

    @Test func handDrawnArtIsADrawing() throws {
        let editor = artEditor()
        let scene = try art(in: editor)
        #expect(scene.boxes.count == 9)
        drag(editor, from: try cell(of: "oms-api"), through: [])
        guard case .text = editor.canvas.selection else {
            Issue.record("a click on a hand-drawn box selects it")
            return
        }
    }

    @Test func draggingAHandDrawnBoxKeepsTheRestAsDrawn() throws {
        let editor = artEditor()
        let start = try cell(of: "Dashboard BFF")
        // One cell left: its arrow from Dashboard gets one shorter.
        drag(editor, from: start, through: [C(x: start.x - 1, y: start.y)])
        let scene = try art(in: editor)
        #expect(scene.boxes.count == 9)
        let lines = editor.string.components(separatedBy: "\n")
        let row = try #require(lines.first { $0.contains("Dashboard BFF proxy") })
        #expect(row.range(of: "Dashboard BFF").map { row.distance(from: row.startIndex, to: $0.lowerBound) } == start.x - 1, "\(editor.string)")
        for kept in ["INTERNET                          GATEWAYS                         BACKENDS",
                     "                                                                   [internal-only S2S tokens]",
                     " [1] currently api-gateway", " [2] currently omsx-api"] {
            #expect(lines.contains(kept), "\(editor.string)")
        }
    }

    @Test func typingIntoAHandDrawnBoxRenamesIt() throws {
        let editor = artEditor()
        let waas = try cell(of: "waas")
        drag(editor, from: C(x: waas.x + 4, y: waas.y), through: [])
        #expect(editor.canvas.insert("-v2"))
        #expect(editor.string.contains("waas-v2"))
        #expect(try art(in: editor).boxes.count == 9)
        // Edited text sits centered in its compartment.
        let row = try #require(editor.string.components(separatedBy: "\n").first { $0.contains("waas-v2") })
        let inside = row.split(separator: "│", omittingEmptySubsequences: false).first { $0.contains("waas-v2") }.map(Array.init) ?? []
        let before = inside.prefix { $0 == " " }.count, after = inside.reversed().prefix { $0 == " " }.count
        #expect(abs(before - after) <= 1, "\(before) spaces before, \(after) after")
    }
}
