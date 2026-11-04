import Foundation
import Testing
@testable import clipb

@Suite struct AsciiDiagramTests {
    typealias D = AsciiDiagram

    private func box(_ id: Int, _ x: Int, _ y: Int, _ text: [String], width: Int = 0, height: Int = 0) -> D.Box {
        D.fitted(D.Box(id: id, x: x, y: y, width: width, height: height, text: text))
    }

    private func arrow(_ id: Int, _ from: Int, _ to: Int, _ label: [String] = []) -> D.Arrow {
        D.Arrow(id: id, from: from, to: to, label: label)
    }

    /// Boxes and arrows compared without ids (arrows by box position).
    private func shape(_ d: D.Diagram) -> [String] {
        let pos = Dictionary(d.boxes.map { ($0.id, "\($0.x),\($0.y)") }, uniquingKeysWith: { a, _ in a })
        let boxes = d.boxes.map { "box \($0.x),\($0.y) \($0.width)x\($0.height) \($0.text)" }.sorted()
        let arrows = d.arrows.map { "arrow \(pos[$0.from]!) -> \(pos[$0.to]!) \(D.normalizedLabel($0.label))" }.sorted()
        return boxes + arrows
    }

    /// Renders, checks the art parses back to the same diagram, returns the art.
    @discardableResult
    private func roundTrip(_ d: D.Diagram, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let r = D.render(d)
        #expect(r.unrouted.isEmpty, "unrouted: \(r.unrouted)\n\(r.text)", sourceLocation: sourceLocation)
        let parsed = try #require(D.parse(r.text), "no parse:\n\(r.text)", sourceLocation: sourceLocation)
        #expect(shape(parsed) == shape(d), "\(r.text)", sourceLocation: sourceLocation)
        #expect(D.render(parsed).text == r.text, sourceLocation: sourceLocation)
        return r.text
    }

    private var twoBoxes: D.Diagram {
        D.Diagram(boxes: [box(1, 0, 0, ["Client"]), box(2, 24, 0, ["API"])],
                  arrows: [arrow(1, 1, 2, ["calls"])])
    }

    private var crossing: D.Diagram {
        D.Diagram(boxes: [box(0, 0, 0, ["A"]), box(1, 30, 0, ["B"]), box(2, 0, 12, ["C"]), box(3, 30, 12, ["D"])],
                  arrows: [arrow(0, 0, 3), arrow(1, 1, 2), arrow(2, 0, 1, ["ab"]), arrow(3, 2, 3)])
    }

    @Test func oneBox() throws {
        let art = try roundTrip(D.Diagram(boxes: [box(0, 0, 0, ["Hello"])]))
        #expect(art == "┌─────────┐\n│ Hello   │\n└─────────┘" || art == "┌───────┐\n│ Hello │\n└───────┘")
    }

    @Test func fittedGrows() {
        let b = D.fitted(D.Box(id: 0, x: 0, y: 0, width: 1, height: 1, text: ["a", "longer line", ""]))
        #expect(b.width == 15 && b.height == 5)
        let empty = D.fitted(D.Box(id: 0, x: 0, y: 0, width: 0, height: 0, text: [""]))
        #expect(empty.width == D.minWidth && empty.height == D.minHeight)
        let big = D.fitted(D.Box(id: 0, x: 0, y: 0, width: 20, height: 9, text: ["a"]))
        #expect(big.width == 20 && big.height == 9)
    }

    @Test func horizontalLabelledArrow() throws {
        let art = try roundTrip(twoBoxes)
        #expect(art == """
                      calls
        ┌────────┐            ┌───────┐
        │ Client ├───────────▶│ API   │
        └────────┘            └───────┘
        """ || art.contains("├") && art.contains("▶") && art.contains("calls"))
    }

    @Test func verticalArrow() throws {
        let d = D.Diagram(boxes: [box(0, 0, 0, ["Top"]), box(1, 0, 8, ["Bottom"])], arrows: [arrow(0, 0, 1, ["down"])])
        let art = try roundTrip(d)
        #expect(art.contains("┬") && art.contains("▼"))
    }

    @Test func headRightAfterTheExit() throws {
        let d = D.Diagram(boxes: [box(0, 0, 0, ["A"]), box(1, 8, 0, ["B"])], arrows: [arrow(0, 0, 1)])
        let art = try roundTrip(d)
        #expect(art.contains("├▶│"))
        let touching = D.Diagram(boxes: [box(0, 0, 0, ["A"]), box(1, 7, 0, ["B"])], arrows: [arrow(0, 0, 1)])
        #expect(D.render(touching).unrouted == [0])
    }

    @Test func multiLineLabels() throws {
        let d = D.Diagram(boxes: [box(0, 0, 0, ["A"]), box(1, 20, 6, ["B"])],
                          arrows: [arrow(0, 0, 1, ["  first line ", "", "second"])])
        let art = try roundTrip(d)
        #expect(art.contains("first line") && art.contains("second"))
    }

    @Test func multiLineBoxText() throws {
        let tall = box(0, 2, 1, ["Title", "", "centered"], width: 18, height: 8)
        let d = D.Diagram(boxes: [tall, box(1, 30, 3, ["Other"])], arrows: [arrow(0, 0, 1)])
        let art = try roundTrip(d)
        let parsed = try #require(D.parse(art))
        #expect(parsed.boxes[0].text == ["Title", "", "centered"])
        #expect(parsed.boxes[0].height == 8)
    }

    @Test func boxTextIsCentered() throws {
        let d = D.Diagram(boxes: [box(0, 0, 0, ["Hi", "there", "  you  "], width: 13, height: 5)], arrows: [])
        #expect(D.render(d).text == """
            ┌───────────┐
            │    Hi     │
            │   there   │
            │    you    │
            └───────────┘
            """)
        // Spaces around a line only shift where its caret goes, never the drawing.
        let parsed = try #require(D.parse(D.render(d).text))
        #expect(parsed.boxes[0].text == ["Hi", "there", "you"])
        #expect(D.lineStart(d.boxes[0], line: 2, of: d.boxes[0].text) == D.Cell(x: 3, y: 3))
        #expect(D.lineStart(d.boxes[0], line: 1, of: d.boxes[0].text) == D.Cell(x: 4, y: 2))
    }

    @Test func crossingArrows() throws {
        let art = try roundTrip(crossing)
        #expect(art.contains("┼"))
    }

    @Test func arrowsBothWays() throws {
        let d = D.Diagram(boxes: [box(0, 0, 0, ["A"], height: 4), box(1, 16, 0, ["B"], height: 4)],
                          arrows: [arrow(0, 0, 1, ["req"]), arrow(1, 1, 0, ["resp"])])
        let art = try roundTrip(d)
        #expect(art.contains("▶") && art.contains("◀"))
    }

    @Test func boxesBelowBlankLines() throws {
        let d = D.Diagram(boxes: [box(0, 3, 2, ["A"]), box(1, 3, 9, ["B"])], arrows: [arrow(0, 0, 1)])
        let art = try roundTrip(d)
        #expect(art.hasPrefix("\n\n   ┌"))
    }

    @Test func fixedDiagramsParseBack() throws {
        let fan = D.Diagram(boxes: [box(0, 14, 0, ["Load balancer"]), box(1, 0, 8, ["web-1"]), box(2, 16, 8, ["web-2"]), box(3, 32, 8, ["web-3"])],
                            arrows: [arrow(0, 0, 1), arrow(1, 0, 2), arrow(2, 0, 3)])
        let chain = D.Diagram(boxes: [box(0, 0, 0, ["Edit"]), box(1, 20, 0, ["Render"]), box(2, 40, 0, ["Paste"])],
                              arrows: [arrow(0, 0, 1, ["model"]), arrow(1, 1, 2, ["text"])])
        let diagonal = D.Diagram(boxes: [box(0, 0, 0, ["Start"]), box(1, 30, 10, ["End"])],
                                 arrows: [arrow(0, 0, 1, ["go"]), arrow(1, 1, 0)])
        let empty = D.Diagram(boxes: [box(0, 0, 0, [""]), box(1, 12, 0, [""])], arrows: [arrow(0, 0, 1)])
        for d in [fan, chain, diagonal, empty, crossing, twoBoxes] { try roundTrip(d) }
        let parsed = try #require(D.parse(D.render(chain).text))
        #expect(parsed.boxes.map(\.id) == [0, 1, 2])
        #expect(parsed.arrows.map(\.id) == [0, 1])
        #expect(parsed.arrows.map(\.label) == [["model"], ["text"]])
    }

    @Test func notADrawing() {
        #expect(D.parse("func x() {}") == nil)
        #expect(D.parse("") == nil)
        #expect(D.parse("""
        ┌────┬──────┐
        │ id │ name │
        ├────┼──────┤
        │  1 │ ann  │
        └────┴──────┘
        """) == nil)
        #expect(D.parse("+--+\n|  |\n+--+") == nil)
        // A drawing with stray text that is not ClipB's layout.
        #expect(D.parse("┌───────┐\n│ A     │\n└───────┘ x") == nil)
        #expect(D.parse("┌───────┐\n│ A     ├──\n└───────┘") == nil)
    }

    @Test func renderIgnoresArrayOrderAndIds() {
        let a = crossing
        var b = a
        b.boxes.reverse()
        b.arrows.reverse()
        var c = a
        c.boxes = c.boxes.map { var x = $0; x.id += 100; return x }
        c.arrows = c.arrows.map { D.Arrow(id: $0.id + 7, from: $0.from + 100, to: $0.to + 100, label: $0.label) }
        #expect(D.render(a).text == D.render(b).text)
        #expect(D.render(a).text == D.render(c).text)
    }

    @Test func labelsNeverOverlapLinesOrBoxes() {
        for d in [crossing, twoBoxes] {
            let r = D.render(d)
            let lineCells = Set(r.paths.values.flatMap { $0 })
            for (_, rect) in r.labels {
                for b in d.boxes {
                    let o = b.rect
                    let apart = rect.x + rect.width <= o.x || o.x + o.width <= rect.x || rect.y + rect.height <= o.y || o.y + o.height <= rect.y
                    #expect(apart)
                }
                #expect(!lineCells.contains { rect.contains($0) })
            }
            #expect(r.labels.count == d.arrows.filter { !$0.label.isEmpty }.count)
        }
    }

    @Test func pathsEndInHeads() {
        let r = D.render(crossing)
        let lines = r.text.components(separatedBy: "\n").map { Array($0) }
        for (_, path) in r.paths {
            let last = path.last!
            #expect("▶◀▲▼".contains(lines[last.y][last.x]))
        }
    }

    @Test func selfAndDanglingArrowsAreUnrouted() {
        let d = D.Diagram(boxes: [box(0, 0, 0, ["A"])], arrows: [arrow(5, 0, 0), arrow(6, 0, 9)])
        let r = D.render(d)
        #expect(r.unrouted == [5, 6])
        #expect(r.paths.isEmpty)
    }

    @Test func fromMermaid() throws {
        let d = try #require(D.fromMermaid("graph LR\n A[Client] -->|calls| B(API)"))
        #expect(d.boxes.count == 2)
        #expect(d.arrows.count == 1)
        #expect(d.arrows[0].label == ["calls"])
        #expect(Set(d.boxes.map(\.text)) == [["Client"], ["API"]])
        let r = D.render(d)
        #expect(r.unrouted.isEmpty)
        #expect(D.parse(r.text) != nil)
        let mermaid = D.mermaid(d)
        #expect(mermaid.hasPrefix("graph LR"))
        #expect(mermaid.contains("A[\"Client\"]"))
        #expect(mermaid.contains("B[\"API\"]"))
        #expect(mermaid.contains("A -->|\"calls\"| B"))
        #expect(!mermaid.hasSuffix("\n"))
    }

    @Test func fromMermaidTopDown() throws {
        let d = try #require(D.fromMermaid("graph TD\n A --> B\n A --> C\n B --> D\n C --> D"))
        #expect(d.boxes.count == 4 && d.arrows.count == 4)
        try roundTrip(d)
        #expect(D.mermaid(d).hasPrefix("graph TD"))
        #expect(D.fromMermaid("sequenceDiagram\n A->>B: hi") == nil)
    }

    @Test func mermaidOutput() {
        let d = D.Diagram(boxes: [box(4, 20, 0, ["Second"]), box(3, 0, 0, ["First", "line two"]), box(9, 40, 0, [""])],
                          arrows: [arrow(0, 3, 4, ["a", "b"]), arrow(1, 4, 9)])
        #expect(D.mermaid(d) == """
        graph LR
          A["First<br>line two"]
          B["Second"]
          C[" "]
          A -->|"a<br>b"| B
          B --> C
        """)
        #expect(D.mermaidID(25) == "Z" && D.mermaidID(26) == "AA" && D.mermaidID(27) == "AB")
    }

    @Test func largeDiagramIsFast() {
        var boxes: [D.Box] = []
        for i in 0..<20 { boxes.append(box(i, (i % 5) * 22, (i / 5) * 9, ["node \(i)"])) }
        var arrows: [D.Arrow] = []
        for i in 0..<30 { arrows.append(arrow(i, i % 20, (i * 7 + 3) % 20, i % 3 == 0 ? ["e\(i)"] : [])) }
        let d = D.Diagram(boxes: boxes, arrows: arrows)
        let start = Date()
        let r = D.render(d)
        let elapsed = Date().timeIntervalSince(start)
        // Debug build with tests in parallel; about 17 ms in a release build.
        #expect(elapsed < 15, "took \(elapsed)")
        #expect(!r.text.isEmpty)
    }

    @Test func mermaidRoundTripKeepsTheGraph() throws {
        let d = try #require(D.fromMermaid("graph TD\n A[Editor] -->|model| B[Renderer]\n A --> C[Parser]\n B -->|text| D[Slack]\n C --> B"))
        try roundTrip(d)
        let again = try #require(D.fromMermaid(D.mermaid(d)))
        let texts = { (x: D.Diagram) -> [String] in x.boxes.map { $0.text.joined(separator: "\n") }.sorted() }
        #expect(texts(again) == texts(d))
        #expect(again.arrows.count == d.arrows.count)
    }
}

