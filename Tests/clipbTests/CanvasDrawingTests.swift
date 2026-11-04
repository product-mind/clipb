import Foundation
import Testing
@testable import clipb

/// `CanvasDrawing`'s edits that work on either kind of drawing: dragging a
/// line's segment, arrows through chosen sides, free text, normalized text.
@Suite struct CanvasDrawingTests {
    typealias D = AsciiDiagram
    typealias C = AsciiDiagram.Cell

    /// The user's gateways diagram, as the editor holds it.
    private var gateways: CanvasDrawing {
        get throws { CanvasDrawing(try #require(AsciiArt.scan(AsciiArtTests.gateways))) }
    }

    private func lines(_ t: String) -> [String] { t.components(separatedBy: "\n") }

    /// The first cell where `s` appears (by characters).
    private func find(_ s: String, in text: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> C {
        let ls = lines(text)
        let y = try #require(ls.firstIndex { $0.contains(s) }, "no \(s)", sourceLocation: sourceLocation)
        let r = try #require(ls[y].range(of: s), sourceLocation: sourceLocation)
        return C(x: ls[y].distance(from: ls[y].startIndex, to: r.lowerBound), y: y)
    }

    private func char(_ text: String, _ c: C) -> Character {
        let ls = lines(text)
        guard c.y >= 0, c.y < ls.count else { return " " }
        let row = Array(ls[c.y])
        return c.x >= 0 && c.x < row.count ? row[c.x] : " "
    }

    /// `text` with cells overwritten, normalized.
    private func edited(_ text: String, _ writes: [(Int, Int, Character)]) -> String {
        var rows = lines(text).map { Array($0) }
        for (x, y, ch) in writes {
            while rows.count <= y { rows.append([]) }
            while rows[y].count <= x { rows[y].append(" ") }
            rows[y][x] = ch
        }
        return CanvasDrawing.normalized(rows.map { String($0) }.joined(separator: "\n"))
    }

    // MARK: - Segments

    @Test func draggingTheGatewaysRunLeftShortensItsBranch() throws {
        let d = try gateways
        let head = try find("▲", in: d.text)
        let seg = try #require(d.segment(at: head))
        #expect(!seg.horizontal)
        #expect(seg.cells == (0..<4).map { C(x: head.x, y: head.y + $0) })
        #expect(seg.cells.map { char(d.text, $0) } == ["▲", "│", "│", "┘"])
        // A middle cell picks the same run.
        #expect(d.segment(at: C(x: head.x, y: head.y + 2)) == seg)

        let moved = try #require(d.movingSegment(seg, by: -3))
        let x = head.x, y = head.y
        let expected = edited(d.text, [
            (x, y, " "), (x - 3, y, "▲"),
            (x, y + 1, " "), (x - 3, y + 1, "│"),
            (x, y + 2, " "), (x - 3, y + 2, "│"),
            (x, y + 3, " "), (x - 1, y + 3, " "), (x - 2, y + 3, " "), (x - 3, y + 3, "┘"),
        ])
        #expect(moved.text == expected, "\(moved.text)")
        #expect(lines(moved.text)[y + 3].contains("│──────┘ "))
        #expect(moved.isArt)

        // And back: the drawing as it was.
        let back = try #require(moved.segment(at: C(x: x - 3, y: y + 1)))
        #expect(back.cells.count == 4)
        let restored = try #require(moved.movingSegment(back, by: 3))
        #expect(restored.text == d.text)
    }

    @Test func aSegmentCantLeaveItsBoxOrHitAnother() throws {
        let d = try gateways
        let head = try find("▲", in: d.text)
        let seg = try #require(d.segment(at: head))
        // oms-api's bottom side ends 21 cells right of the head: past it, the
        // head would leave the box (or sit on its corner).
        let oms = try #require(d.boxes.first { $0.rect.contains(C(x: head.x, y: head.y - 1)) }).rect
        let toCorner = oms.x + oms.width - 1 - head.x
        #expect(d.movingSegment(seg, by: toCorner - 1) != nil)
        #expect(d.movingSegment(seg, by: toCorner) == nil)
        // Left of the bend the branch would collapse into Partner's websites.
        #expect(d.movingSegment(seg, by: -9) == nil)
    }

    @Test func movingAModelArrowsSegmentMakesArt() throws {
        let a = D.fitted(D.Box(id: 0, x: 0, y: 0, width: 0, height: 0, text: ["A"]))
        let b = D.fitted(D.Box(id: 1, x: 16, y: 8, width: 0, height: 0, text: ["B"]))
        let d = CanvasDrawing(D.Diagram(boxes: [a, b], arrows: [D.Arrow(id: 7, from: 0, to: 1, label: [])]))
        let path = try #require(d.rendered.paths[7])
        let mid = try #require(path.first { char(d.text, $0) == "│" }, "an elbow:\n\(d.text)")
        let seg = try #require(d.segment(at: mid))
        #expect(seg.arrow == 7)
        #expect(!seg.horizontal)
        #expect(seg.cells.count >= 3)

        // Right, the bend would run over the head: the run into B is one cell.
        #expect(d.movingSegment(seg, by: 2) == nil)
        let moved = try #require(d.movingSegment(seg, by: -2), "\(d.text)")
        #expect(moved.isArt)
        for c in seg.cells {
            #expect(char(moved.text, C(x: c.x - 2, y: c.y)) == char(d.text, c), "\(moved.text)")
        }
        let last = try #require(seg.cells.last)
        #expect(lines(moved.text)[last.y].hasSuffix("╰──▶│  B  │"), "\(moved.text)")
        let scene = try #require(AsciiArt.scan(moved.text))
        #expect(scene.links.count == 1)
        #expect(scene.links[0].ends.count == 2)

        let back = try #require(moved.segment(at: C(x: mid.x - 2, y: mid.y)))
        #expect(moved.movingSegment(back, by: 2)?.text == d.text)
    }

    // MARK: - Sides

    /// The sides an arrow leaves its tail box and enters its head box through.
    private func sides(_ d: CanvasDrawing, _ arrow: Int, from: D.Rect, to: D.Rect) throws -> [CanvasDrawing.Side] {
        switch d.kind {
        case .model:
            let path = try #require(d.rendered.paths[arrow])
            return [CanvasDrawing.side(of: path.first!, outside: from), CanvasDrawing.side(of: path.last!, outside: to)]
        case .art(let s):
            let link = try #require(s.links.first { $0.id == arrow })
            let tail = try #require(link.ends.first { !$0.head && s.boxes[$0.box].rect == from })
            let head = try #require(link.ends.first { $0.head && s.boxes[$0.box].rect == to })
            return [CanvasDrawing.side(of: tail.cell, outside: from), CanvasDrawing.side(of: head.cell, outside: to)]
        }
    }

    private var sideBySide: CanvasDrawing {
        let a = D.fitted(D.Box(id: 0, x: 0, y: 2, width: 0, height: 0, text: ["Client"]))
        let b = D.fitted(D.Box(id: 1, x: 24, y: 2, width: 0, height: 0, text: ["API"]))
        return CanvasDrawing(D.Diagram(boxes: [a, b], arrows: []))
    }

    @Test func connectingThroughTheSidesTheLayoutPicksKeepsTheModel() throws {
        let d = sideBySide
        let (next, id) = try #require(d.connecting(0, side: .right, to: 1, side: .left))
        #expect(!next.isArt)
        #expect(try sides(next, id, from: d.rect(of: 0)!, to: d.rect(of: 1)!) == [.right, .left])
        // Only one side asked: the other is the layout's.
        let (one, oneID) = try #require(d.connecting(0, side: .right, to: 1, side: nil))
        #expect(!one.isArt)
        #expect(try sides(one, oneID, from: d.rect(of: 0)!, to: d.rect(of: 1)!) == [.right, .left])
    }

    @Test func connectingThroughOtherSidesDrawsArt() throws {
        let d = sideBySide
        let from = d.rect(of: 0)!, to = d.rect(of: 1)!
        for (fs, ts) in [(CanvasDrawing.Side.bottom, CanvasDrawing.Side.bottom), (.top, .top), (.top, .left), (.bottom, .left)] {
            let (next, id) = try #require(d.connecting(0, side: fs, to: 1, side: ts), "\(fs) -> \(ts)")
            #expect(next.isArt)
            #expect(try sides(next, id, from: from, to: to) == [fs, ts], "\(fs) -> \(ts):\n\(next.text)")
            #expect(next.boxes.map(\.rect) == d.boxes.map(\.rect))
        }
    }

    @Test func connectingArtThroughChosenSides() throws {
        let d = try gateways
        func box(_ title: String) throws -> (id: Int, rect: D.Rect) {
            let c = try find(title, in: d.text)
            return try #require(d.boxes.first { $0.rect.contains(c) })
        }
        let backends = try box("Partner's backends"), oms = try box("oms-api [1]")
        let (over, overID) = try #require(d.connecting(backends.id, side: .top, to: oms.id, side: .top), "over the top")
        #expect(try sides(over, overID, from: backends.rect, to: oms.rect) == [.top, .top], "\(over.text)")

        let websites = try box("Partner's websites"), dashboard = try box("Dashboard  ")
        let (down, downID) = try #require(d.connecting(websites.id, side: .bottom, to: dashboard.id, side: .top))
        #expect(try sides(down, downID, from: websites.rect, to: dashboard.rect) == [.bottom, .top], "\(down.text)")
        // Untouched lines stay as drawn.
        #expect(lines(down.text)[0] == lines(d.text)[0])
    }

    // MARK: - Free text

    @Test func freeCells() throws {
        let d = try gateways
        let internet = try find("INTERNET", in: d.text)
        #expect(d.isFree(internet))
        #expect(d.isFree(C(x: 40, y: 1)))
        #expect(d.isFree(C(x: 3, y: 200)))
        #expect(!d.isFree(try find("Partner's backends", in: d.text)))
        #expect(!d.isFree(try find("▲", in: d.text)))
        #expect(!d.isFree(try find("────▶", in: d.text)))
        #expect(d.textRun(at: try find("Partner's", in: d.text)) == nil)
        #expect(d.textRun(at: try find("▲", in: d.text)) == nil)
        #expect(d.typing("x", at: try find("oms-api", in: d.text)) == nil)

        let run = try #require(d.textRun(at: C(x: internet.x + 3, y: internet.y)))
        #expect(run == CanvasDrawing.TextRun(cells: D.Rect(x: internet.x, y: internet.y, width: 8, height: 1), text: "INTERNET"))
        // Single spaces join words; the footnote is one run.
        let note = try find("[1] currently", in: d.text)
        #expect(d.textRun(at: C(x: note.x + 5, y: note.y))?.text == "[1] currently api-gateway")
        #expect(d.textRun(at: C(x: note.x + 3, y: note.y))?.text == "[1] currently api-gateway")
        // A model's labels are its arrows', not free.
        let model = CanvasDrawing(D.Diagram(boxes: sideBySide.boxes.map { D.fitted(D.Box(id: $0.id, x: $0.rect.x, y: $0.rect.y, width: 0, height: 0, text: ["x"])) },
                                            arrows: [D.Arrow(id: 0, from: 0, to: 1, label: ["calls"])]))
        let label = try #require(model.rendered.labels[0])
        #expect(!model.isFree(C(x: label.x, y: label.y)))
        #expect(model.textRun(at: C(x: label.x, y: label.y)) == nil)
    }

    @Test func typingATitleIntoEmptySpace() throws {
        let d = try gateways
        let (next, caret) = try #require(d.typing("Gateways map", at: C(x: 30, y: 1)))
        #expect(caret == C(x: 42, y: 1))
        #expect(lines(next.text)[1].hasPrefix(String(repeating: " ", count: 30) + "Gateways map   "))
        #expect(next.textRun(at: C(x: 31, y: 1))?.text == "Gateways map")
        #expect(next.boxes.map(\.rect) == d.boxes.map(\.rect))
        // Character by character, as typed.
        var cur = d, at = C(x: 30, y: 1)
        for ch in "Gateways map" { (cur, at) = try #require(cur.typing(String(ch), at: at)) }
        #expect(cur.text == next.text)
        // Below the text: the grid grows.
        let rows = lines(d.text).count
        let (below, _) = try #require(d.typing("end", at: C(x: 2, y: rows + 2)))
        #expect(lines(below.text).count == rows + 3)
        #expect(lines(below.text).last == "  end")
    }

    @Test func typingInsideAWordShiftsItsTail() throws {
        let d = try gateways
        let internet = try find("INTERNET", in: d.text), gw = try find("GATEWAYS", in: d.text)
        let (next, caret) = try #require(d.typing("X", at: C(x: internet.x + 4, y: internet.y)))
        #expect(caret == C(x: internet.x + 5, y: internet.y))
        #expect(lines(next.text)[0].hasPrefix("INTEXRNET "))
        #expect(try find("GATEWAYS", in: next.text) == gw)
        // At a run's start the whole run moves right.
        let (front, _) = try #require(d.typing("THE ", at: internet))
        #expect(lines(front.text)[0].hasPrefix("THE INTERNET "))

        // Backspace takes it out again.
        let (back, at) = try #require(next.deletingBackward(at: caret))
        #expect(at == C(x: internet.x + 4, y: internet.y))
        #expect(back.text == d.text)
        // Backspace at a run's start pulls it left over the space.
        let (pulled, _) = try #require(d.deletingBackward(at: gw))
        #expect(try find("GATEWAYS", in: pulled.text) == C(x: gw.x - 1, y: gw.y))
        // Not into a box or over a line.
        let websites = try find("Partner's websites", in: d.text)
        #expect(d.deletingBackward(at: C(x: websites.x + 1, y: websites.y)) == nil)
    }

    @Test func typingCantPushTextIntoABox() throws {
        // A word right before a box: there's no room for its tail.
        let text = "ab┌───┐\n  │ x │\n  └───┘"
        let d = CanvasDrawing(try #require(AsciiArt.scan(text)))
        #expect(d.typing("z", at: C(x: 0, y: 0)) == nil)
        #expect(d.typing("z", at: C(x: 0, y: 1)) != nil)
    }

    @Test func movingARunOfText() throws {
        let d = try gateways
        let gw = try find("GATEWAYS", in: d.text)
        let run = try #require(d.textRun(at: gw))
        let moved = try #require(d.movingText(run, dx: 2, dy: 0))
        #expect(try find("GATEWAYS", in: moved.text) == C(x: gw.x + 2, y: gw.y))
        #expect(moved.textRun(at: C(x: gw.x + 2, y: gw.y))?.text == "GATEWAYS")
        let movedRun = try #require(moved.textRun(at: C(x: gw.x + 2, y: gw.y)))
        #expect(moved.movingText(movedRun, dx: -2, dy: 0)?.text == d.text)
        // Not onto other text or a box.
        let internet = try find("INTERNET", in: d.text)
        #expect(d.movingText(run, dx: internet.x - gw.x, dy: 0) == nil)
        #expect(d.movingText(run, dx: 0, dy: 4) == nil)
        // Stale run: nothing.
        #expect(d.movingText(CanvasDrawing.TextRun(cells: run.cells, text: "OTHER"), dx: 1, dy: 0) == nil)
    }

    @Test func typingIntoAModelMakesArt() throws {
        let d = sideBySide
        #expect(!d.isArt)
        let (next, caret) = try #require(d.typing("note", at: C(x: 2, y: 0)))
        #expect(next.isArt)
        #expect(caret == C(x: 6, y: 0))
        #expect(lines(next.text)[0] == "  note")
        #expect(next.boxes.map(\.rect) == d.boxes.map(\.rect))
        #expect(next.textRun(at: C(x: 3, y: 0))?.text == "note")
        // Box text isn't free in a model either.
        #expect(!d.isFree(C(x: 3, y: 3)))
        #expect(d.typing("x", at: C(x: 3, y: 3)) == nil)
    }

    // MARK: - Normalized text

    @Test func textIsNormalized() throws {
        let raw = lines(AsciiArtTests.gateways).map { $0.isEmpty ? $0 : $0 + "   " }.joined(separator: "\n") + "\n  \n\n"
        let scanned = try #require(AsciiArt.scan(raw))
        let d = CanvasDrawing(scanned)
        #expect(!d.text.hasSuffix("\n"))
        #expect(lines(d.text).allSatisfy { !$0.hasSuffix(" ") })
        #expect(d.text == CanvasDrawing.normalized(AsciiArtTests.gateways))
        // Same boxes and lines, same ids.
        #expect(d.boxes.map(\.rect) == scanned.boxes.map(\.rect))
        guard case .art(let s) = d.kind else { Issue.record("art"); return }
        #expect(s.links == scanned.links)
        #expect(AsciiArt.scan(d.text)?.boxes == scanned.boxes)
        // Edits keep it so.
        let dashboard = try find("Dashboard  ", in: d.text)
        let id = try #require(d.boxes.first { $0.rect.contains(dashboard) }?.id)
        let (moved, _) = try #require(d.moving([id], dx: -1, dy: 0))
        #expect(moved.text == CanvasDrawing.normalized(moved.text))
        let (typed, _) = try #require(d.typing("x", at: C(x: 50, y: 40)))
        #expect(typed.text == CanvasDrawing.normalized(typed.text))
        #expect(sideBySide.text == CanvasDrawing.normalized(sideBySide.text))
    }
}
