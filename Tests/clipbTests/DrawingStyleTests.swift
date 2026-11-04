import Foundation
import Testing
@testable import clipb

/// Box styles, line styles and arrowheads (docs/ascii-diagram-style-guide.md),
/// in ClipB's own drawings (`AsciiDiagram`), in hand-drawn art (`AsciiArt`)
/// and through the canvas edits (`CanvasDrawing`).
@Suite struct DrawingStyleTests {
    typealias D = AsciiDiagram
    typealias A = AsciiArt

    private func box(_ id: Int, _ x: Int, _ y: Int, _ text: String, _ style: D.BoxStyle = .light) -> D.Box {
        var b = D.fitted(D.Box(id: id, x: x, y: y, width: 0, height: 0, text: [text]))
        b.style = style
        return b
    }

    private func arrow(_ id: Int, _ from: Int, _ to: Int, _ line: D.LineStyle = .solid, _ heads: D.Heads = .forward,
                       label: [String] = []) -> D.Arrow {
        D.Arrow(id: id, from: from, to: to, label: label, line: line, heads: heads)
    }

    /// Boxes and arrows with their styles, without ids; arrows with no
    /// direction (both/none) list their ends in reading order.
    private func shape(_ d: D.Diagram) -> [String] {
        let pos = Dictionary(d.boxes.map { ($0.id, ($0.y, $0.x)) }, uniquingKeysWith: { a, _ in a })
        let boxes = d.boxes.map { "box \($0.x),\($0.y) \($0.width)x\($0.height) \($0.text) \($0.style)" }.sorted()
        let arrows = d.arrows.map { a -> String in
            var f = pos[a.from]!, t = pos[a.to]!
            if a.heads != .forward && t < f { swap(&f, &t) }
            return "arrow \(f) -> \(t) \(D.normalizedLabel(a.label)) \(a.line) \(a.heads)"
        }.sorted()
        return boxes + arrows
    }

    @discardableResult
    private func roundTrip(_ d: D.Diagram, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let r = D.render(d)
        #expect(r.unrouted.isEmpty, "unrouted: \(r.unrouted)\n\(r.text)", sourceLocation: sourceLocation)
        let parsed = try #require(D.parse(r.text), "no parse:\n\(r.text)", sourceLocation: sourceLocation)
        #expect(shape(parsed) == shape(d), "\(r.text)", sourceLocation: sourceLocation)
        #expect(D.render(parsed).text == r.text, sourceLocation: sourceLocation)
        return r.text
    }

    // MARK: - Model

    @Test func defaultsRenderAsBefore() throws {
        let art = try roundTrip(D.Diagram(boxes: [box(0, 0, 0, "A"), box(1, 12, 0, "B")], arrows: [arrow(0, 0, 1)]))
        #expect(art == """
        ┌─────┐     ┌─────┐
        │  A  ├────▶│  B  │
        └─────┘     └─────┘
        """)
    }

    @Test func everyBoxStyleRoundTrips() throws {
        let expected: [D.BoxStyle: (corner: Character, side: Character, tee: Character?)] = [
            .light: ("┌", "│", "├"), .heavy: ("┏", "┃", "┣"), .double: ("╔", "║", "╠"),
            .rounded: ("╭", "│", "├"), .dashed: ("┌", "╎", "├"), .dotted: ("╭", "┊", nil),
        ]
        for style in D.BoxStyle.allCases {
            // Right and down: a tee on the right side and on the bottom.
            let d = D.Diagram(boxes: [box(0, 0, 0, "A", style), box(1, 16, 0, "B", style), box(2, 0, 8, "C", style)],
                              arrows: [arrow(0, 0, 1), arrow(1, 0, 2)])
            let art = try roundTrip(d)
            let (corner, side, tee) = expected[style]!
            #expect(art.first == corner, "\(style)\n\(art)")
            #expect(art.contains(side), "\(style)\n\(art)")
            if let tee {
                #expect(art.contains("\(tee)─"), "\(style)\n\(art)")
                #expect(art.contains(style.glyphs.tees![1]), "\(style)\n\(art)")
            } else {
                // No tees: the line starts on the cell next to the border.
                #expect(art.contains("┊─"), "\(style)\n\(art)")
                #expect(art.contains("╰┈┈┈┬") == false && art.contains("┈┈┈┈"), "\(style)\n\(art)")
            }
        }
    }

    @Test func everyLineStyleRoundTrips() throws {
        let bends: [D.LineStyle: String] = [.solid: "╭╮╰╯", .heavy: "┏┓┗┛", .double: "╔╗╚╝", .dashed: "╭╮╰╯", .dotted: "╭╮╰╯"]
        for line in D.LineStyle.allCases {
            // Down and to the right: the line has to bend.
            let d = D.Diagram(boxes: [box(0, 0, 0, "A"), box(1, 20, 8, "B")], arrows: [arrow(0, 0, 1, line)])
            let art = try roundTrip(d)
            #expect(art.contains(line.horizontal) && art.contains(line.vertical), "\(line)\n\(art)")
            #expect(bends[line]!.contains { art.contains($0) }, "\(line)\n\(art)")
            #expect(art.contains("▼") || art.contains("▶"), "\(line)\n\(art)")
        }
    }

    @Test func everyHeadKindRoundTrips() throws {
        let boxes = [box(0, 0, 0, "A"), box(1, 16, 0, "B")]
        let forward = try roundTrip(D.Diagram(boxes: boxes, arrows: [arrow(0, 0, 1)]))
        #expect(forward.contains("├────────▶│"))
        let backward = try roundTrip(D.Diagram(boxes: boxes, arrows: [arrow(0, 1, 0)]))
        #expect(backward.contains("│◀────────┤"))
        let both = try roundTrip(D.Diagram(boxes: boxes, arrows: [arrow(0, 0, 1, .solid, .both)]))
        #expect(both.contains("│◀───────▶│"))
        let none = try roundTrip(D.Diagram(boxes: boxes, arrows: [arrow(0, 0, 1, .solid, .none)]))
        #expect(none.contains("├─────────┤"))
        // No direction: written either way round, it is the same drawing.
        #expect(D.render(D.Diagram(boxes: boxes, arrows: [arrow(0, 1, 0, .solid, .both)])).text == both)
        #expect(D.render(D.Diagram(boxes: boxes, arrows: [arrow(0, 1, 0, .solid, .none)])).text == none)
        // A dotted box has no tee: the line just starts beside it.
        let dotted = try roundTrip(D.Diagram(boxes: [box(0, 0, 0, "A", .dotted), box(1, 16, 0, "B", .dotted)],
                                             arrows: [arrow(0, 0, 1, .dashed, .none)]))
        #expect(dotted.contains("┊╌╌╌╌╌╌╌╌╌┊"))
    }

    @Test func headsOnBothEndsNeedTwoCells() {
        let d = D.Diagram(boxes: [box(0, 0, 0, "A"), box(1, 8, 0, "B")], arrows: [arrow(0, 0, 1, .solid, .both)])
        #expect(D.render(d).unrouted == [0])
        let none = D.Diagram(boxes: [box(0, 0, 0, "A"), box(1, 8, 0, "B")], arrows: [arrow(0, 0, 1, .heavy, .none)])
        #expect(D.render(none).text.contains("├━┤"))
    }

    @Test func mixedDrawingRoundTrips() throws {
        let d = D.Diagram(
            boxes: [box(0, 0, 0, "Users", .rounded), box(1, 30, 0, "Gateway", .double), box(2, 0, 12, "Core", .heavy),
                    box(3, 30, 12, "Vendor", .dotted), box(4, 60, 6, "Queue", .dashed)],
            arrows: [arrow(0, 0, 3, .heavy), arrow(1, 1, 2, .double, label: ["sql"]), arrow(2, 0, 1, .solid, .both, label: ["ws"]),
                     arrow(3, 2, 3, .dotted, .none), arrow(4, 1, 4, .dashed), arrow(5, 4, 3, .solid)])
        let art = try roundTrip(d)
        // The two diagonals cross; the crossing shows both strokes' weights.
        #expect(["╪", "╫", "┿", "╂", "┼"].contains { art.contains($0) }, "\(art)")
    }

    @Test func crossingGlyphsKeepEachStrokesWeight() throws {
        for (h, v, glyph) in [(D.LineStyle.heavy, D.LineStyle.solid, "┿"), (.solid, .heavy, "╂"), (.heavy, .heavy, "╋"),
                              (.double, .solid, "╪"), (.solid, .double, "╫"), (.double, .double, "╬"), (.dashed, .dotted, "┼")] {
            // A horizontal line (top to bottom row) crossed by a vertical one.
            let d = D.Diagram(boxes: [box(0, 0, 8, "L"), box(1, 40, 8, "R"), box(2, 20, 0, "T"), box(3, 20, 16, "B")],
                              arrows: [arrow(0, 0, 1, h), arrow(1, 2, 3, v)])
            let art = try roundTrip(d)
            #expect(art.contains(glyph), "\(h) over \(v)\n\(art)")
        }
    }

    // MARK: - Canvas edits (model)

    private var pair: D.Diagram {
        D.Diagram(boxes: [box(0, 0, 0, "A"), box(1, 16, 0, "B")], arrows: [arrow(7, 0, 1)])
    }

    @Test func cyclingBoxStyleVisitsEveryStyle() throws {
        var c = CanvasDrawing(pair)
        var seen: [D.BoxStyle] = []
        for _ in 0..<6 {
            c = try #require(c.cyclingBoxStyle(1))
            seen.append(try #require(c.boxStyle(of: 1)))
            #expect(D.parse(c.text) != nil, "\(c.text)")
        }
        #expect(seen == [.heavy, .double, .rounded, .dashed, .dotted, .light])
        #expect(c.text == CanvasDrawing(pair).text)
    }

    @Test func cyclingLineStyleVisitsEveryStyle() throws {
        var c = CanvasDrawing(pair)
        var seen: [D.LineStyle] = []
        for _ in 0..<5 {
            c = try #require(c.cyclingLineStyle(7))
            seen.append(try #require(c.lineStyle(of: 7)))
            #expect(c.text.contains(seen.last!.horizontal), "\(c.text)")
        }
        #expect(seen == [.heavy, .double, .dashed, .dotted, .solid])
        #expect(c.text == CanvasDrawing(pair).text)
    }

    @Test func cyclingHeads() throws {
        var c = CanvasDrawing(pair)
        var texts: [String] = []
        for _ in 0..<4 {
            let (next, id) = try #require(c.cyclingHeads(7))
            #expect(id == 7)
            c = next
            texts.append(c.text)
            #expect(D.parse(c.text) != nil, "\(c.text)")
        }
        #expect(texts[0].contains("│◀────────┤"))
        #expect(texts[1].contains("│◀───────▶│"))
        #expect(texts[2].contains("├─────────┤"))
        #expect(texts[3] == CanvasDrawing(pair).text)
    }

    @Test func arrowEnds() throws {
        let c = CanvasDrawing(pair)
        let path = try #require(c.rendered.paths[7])
        #expect(path.count > 2)
        #expect(c.arrowEnd(at: path.first!) == 7)
        #expect(c.arrowEnd(at: path.last!) == 7)
        #expect(c.arrowEnd(at: path[1]) == nil)
        #expect(c.arrow(at: path[1]) == 7)
    }

    // MARK: - Hand-drawn art

    /// Style guide §2, verbatim.
    static let guideBoxes = """
    Light                Heavy                Double
    ┌─────────────┐      ┏━━━━━━━━━━━━━┓      ╔═════════════╗
    │ Backend API │      ┃ Backend API ┃      ║ Backend API ║
    └─────────────┘      ┗━━━━━━━━━━━━━┛      ╚═════════════╝

    Rounded              Dotted (rounded)     Dotted (dot corners)
    ╭─────────────╮      ╭┈┈┈┈┈┈┈┈┈┈┈┈┈╮      ·┈┈┈┈┈┈┈┈┈┈┈┈┈·
    │ Backend API │      ┊ Backend API ┊      ┊ Backend API ┊
    ╰─────────────╯      ╰┈┈┈┈┈┈┈┈┈┈┈┈┈╯      ·┈┈┈┈┈┈┈┈┈┈┈┈┈·

    Block                Block (thin inset)
    ▛▀▀▀▀▀▀▀▀▀▀▀▀▀▜      ▗▄▄▄▄▄▄▄▄▄▄▄▄▄▖
    ▌ Backend API ▐      ▐ Backend API ▌
    ▙▄▄▄▄▄▄▄▄▄▄▄▄▄▟      ▝▀▀▀▀▀▀▀▀▀▀▀▀▀▘

    Database (cylinder)
     .---------.
    (           )
    |`---------'|
    |  Postgres |
     `---------'
    """

    @Test func scansTheGuidesBoxStyles() throws {
        let s = try #require(A.scan(Self.guideBoxes))
        #expect(s.boxes.count == 8)
        #expect(s.boxes.map(\.style) == [.light, .heavy, .double, .rounded, .dotted, nil, nil, nil])
        for b in s.boxes { #expect(A.text(of: b.id, compartment: 0, in: s) == ["Backend API"]) }
        #expect(s.links.isEmpty)
    }

    /// Style guide §1, §4.3 and §4.4 (vertical), verbatim.
    static let guideConnections = [
        """
        ┌─────────────┐         ┌─────────────┐
        │ Backend API │────────▶│  Frontend   │
        └─────────────┘         └─────────────┘
        """,
        """
        ┌─────────────┐
        │  Frontend   │
        └──────┬──────┘
               │
               ▼
        ┌─────────────┐
        │ Backend API │
        └─────────────┘
        """,
        """
        ┌─────────────┐
        │  Frontend   │
        └──────┬──────┘
               │ HTTPS
               ▼
        ┌─────────────┐
        │ Backend API │
        └─────────────┘
        """,
    ]

    /// Links as "tails -> heads" by box title.
    private func links(_ s: A.Scene) -> [String] {
        func title(_ b: Int) -> String { A.text(of: b, compartment: 0, in: s).first ?? "" }
        return s.links.map { l in
            l.ends.filter { !$0.head }.map { title($0.box) }.sorted().joined(separator: ",") + " -> "
                + l.ends.filter(\.head).map { title($0.box) }.sorted().joined(separator: ",")
        }.sorted()
    }

    @Test func scansTheGuidesConnections() throws {
        let basic = try #require(A.scan(Self.guideConnections[0]))
        #expect(links(basic) == ["Backend API -> Frontend"])
        for text in Self.guideConnections.dropFirst() {
            let s = try #require(A.scan(text))
            #expect(links(s) == ["Frontend -> Backend API"], "\(text)")
        }
    }

    enum End { case tee, head, plain }

    /// Boxes A and B joined by a line of `h`, its ends drawn as given.
    private func pairArt(_ h: Character, _ a: End = .tee, _ b: End = .head, box: D.BoxStyle = .light) -> String {
        let g = box.glyphs
        let bar = String(repeating: g.top, count: 3)
        let top = "\(g.topLeft)\(bar)\(g.topRight)", bottom = "\(g.bottomLeft)\(String(repeating: g.bottom, count: 3))\(g.bottomRight)"
        let aBorder = a == .tee ? g.tees![0] : g.right, bBorder = b == .tee ? g.tees![2] : g.left
        let aCell = a == .head ? "◀" : String(h), bCell = b == .head ? "▶" : String(h)
        return """
        \(top)      \(top)
        \(g.left) A \(aBorder)\(aCell)\(String(repeating: h, count: 4))\(bCell)\(bBorder) B \(g.right)
        \(bottom)      \(bottom)
        """
    }

    @Test func scansEveryLineStyleAndHead() throws {
        for line in D.LineStyle.allCases {
            let s = try #require(A.scan(pairArt(line.horizontal)))
            #expect(s.links.count == 1 && s.links[0].line == line, "\(line)")
            #expect(links(s) == ["A -> B"])
            let both = try #require(A.scan(pairArt(line.horizontal, .head, .head)))
            #expect(links(both) == [" -> A,B"])
            let none = try #require(A.scan(pairArt(line.horizontal, .tee, .tee)))
            #expect(links(none) == ["A,B -> "])
        }
        let heavy = try #require(A.scan(pairArt("━", box: .heavy)))
        #expect(heavy.boxes.map(\.style) == [.heavy, .heavy] && links(heavy) == ["A -> B"])
        let dotted = try #require(A.scan(pairArt("┈", .plain, box: .dotted)))
        #expect(dotted.boxes.map(\.style) == [.dotted, .dotted] && links(dotted) == ["A -> B"])
    }

    @Test func artBoxStyleCycles() throws {
        let start = pairArt("─")
        var c = CanvasDrawing(try #require(A.scan(start)))
        var seen: [D.BoxStyle?] = []
        for _ in 0..<6 {
            c = try #require(c.cyclingBoxStyle(0), "\(c.text)")
            seen.append(c.boxStyle(of: 0))
            let scanned = try #require(A.scan(c.text))
            #expect(links(scanned) == ["A -> B"], "\(c.text)")
        }
        #expect(seen == [.heavy, .double, .rounded, .dashed, .dotted, .light])
        #expect(c.text == start)
        // Only that box's border changed.
        let first = try #require(A.scan(start))
        let heavy = try #require(CanvasDrawing(first).cyclingBoxStyle(0))
        #expect(heavy.text == """
        ┏━━━┓      ┌───┐
        ┃ A ┣─────▶│ B │
        ┗━━━┛      └───┘
        """)
    }

    @Test func artLineStyleCycles() throws {
        let start = pairArt("─")
        var c = CanvasDrawing(try #require(A.scan(start)))
        for line in [D.LineStyle.heavy, .double, .dashed, .dotted, .solid] {
            c = try #require(c.cyclingLineStyle(0), "\(c.text)")
            #expect(c.lineStyle(of: 0) == line)
            #expect(c.text == pairArt(line.horizontal))
        }
    }

    @Test func artHeadsCycle() throws {
        let start = pairArt("─")
        var c = CanvasDrawing(try #require(A.scan(start)))
        var texts: [String] = []
        for _ in 0..<4 {
            let (next, _) = try #require(c.cyclingHeads(0), "\(c.text)")
            c = next
            texts.append(c.text)
        }
        #expect(texts[0] == pairArt("─", .head, .tee))
        #expect(texts[1] == pairArt("─", .head, .head))
        #expect(texts[2] == pairArt("─", .tee, .tee))
        #expect(texts[3] == start)
    }

    @Test func artArrowEnds() throws {
        let c = CanvasDrawing(try #require(A.scan(pairArt("─"))))
        #expect(c.arrowEnd(at: D.Cell(x: 5, y: 1)) == 0)
        #expect(c.arrowEnd(at: D.Cell(x: 10, y: 1)) == 0)
        #expect(c.arrowEnd(at: D.Cell(x: 8, y: 1)) == nil)
    }

    @Test func movingKeepsArtStyles() throws {
        let start = pairArt("━", box: .heavy)
        let c = CanvasDrawing(try #require(A.scan(start)))
        let (moved, ids) = try #require(c.moving([1], dx: 4, dy: 0))
        #expect(moved.boxStyle(of: ids[0]) == .heavy)
        #expect(moved.lineStyle(of: 0) == .heavy)
        #expect(moved.text.contains("┣━━━━━━━━━▶┃"), "\(moved.text)")
    }
}
