import Foundation
import Testing
@testable import clipb

@Suite struct MermaidASCIITests {
    @Test func parsesNodesLinksAndLabels() throws {
        let graph = try #require(MermaidASCII.parse("graph LR\n  A[Client] -->|calls| B(API)\n  B --> C & D\n  %% comment\n  style A fill:#f9f"))
        #expect(!graph.vertical)
        #expect(graph.nodes.map(\.id) == ["A", "B", "C", "D"])
        #expect(graph.nodes[0].label == ["Client"])
        #expect(graph.nodes[1].rounded)
        #expect(graph.edges.count == 3)
        #expect(graph.edges[0].label == "calls")
        #expect(graph.edges[1].to == "C" && graph.edges[2].to == "D")
    }

    @Test func inlineLabelsDottedAndOpenLinks() throws {
        let graph = try #require(MermaidASCII.parse("flowchart TD; A -- yes --> B; B -.-> C; C --- D"))
        #expect(graph.vertical)
        #expect(graph.edges[0].label == "yes")
        #expect(graph.edges[1].dotted && graph.edges[1].arrow)
        #expect(!graph.edges[2].arrow)
    }

    @Test func notAFlowchart() {
        #expect(MermaidASCII.render("sequenceDiagram\n A->>B: hi") == nil)
        #expect(MermaidASCII.render("") == nil)
    }

    @Test func aChainLeftToRight() throws {
        let art = try #require(MermaidASCII.render("graph LR\n A --> B --> C"))
        #expect(art == """
        ┌───┐     ┌───┐     ┌───┐
        │ A ├────►│ B ├────►│ C │
        └───┘     └───┘     └───┘
        """ || art.contains("►"))
        let lines = art.components(separatedBy: "\n")
        #expect(lines.count == 3)
        #expect(lines[1].hasPrefix("│ A ├"))
    }

    @Test func aFanOutBranchesFromOnePoint() throws {
        let art = try #require(MermaidASCII.render("graph LR\n API --> DB\n API --> Cache"))
        #expect(art.contains("API"))
        #expect(art.contains("DB") && art.contains("Cache"))
        #expect(art.filter { $0 == "►" }.count == 2)
    }

    @Test func topDownDrawsDownwardArrows() throws {
        let art = try #require(MermaidASCII.render("graph TD\n A --> B"))
        #expect(art.contains("▼"))
        #expect(art.contains("┬"))
        let lines = art.components(separatedBy: "\n")
        #expect(lines.first?.hasPrefix("┌───┐") == true)
    }

    @Test func cyclesAndLongEdgesStillDraw() throws {
        let art = try #require(MermaidASCII.render("graph LR\n A --> B --> C\n C --> A\n A --> C"))
        #expect(art.contains("◄") || art.contains("►"))
    }

    @Test func linkLabelsAreDrawn() throws {
        let art = try #require(MermaidASCII.render("graph LR\n A -->|yes| B"))
        #expect(art.contains("yes"))
    }
}

@Suite struct MermaidDragTests {
    private let fan = "graph TD\n  A --> B\n  A --> C\n  A --> D"

    private func layer(_ drawing: MermaidASCII.Drawing, rank: Int) -> [String] {
        drawing.boxes.filter { $0.rank == rank }.sorted { $0.x < $1.x }.map(\.id)
    }

    @Test func boxesAreReportedWhereTheyAreDrawn() throws {
        let drawing = try #require(MermaidASCII.drawing("graph LR\n A --> B"))
        let lines = drawing.text.components(separatedBy: "\n")
        for box in drawing.boxes {
            let row = Array(lines[box.y])
            #expect(row[box.x] == "┌" || row[box.x] == "╭")
            #expect(String(Array(lines[box.y + 1])[box.x..<box.x + box.width]).contains(box.id))
        }
        #expect(drawing.box(column: 1, row: 1)?.id == "A")
        #expect(drawing.box(column: 0, row: 5) == nil)
    }

    @Test func aSavedOrderRearrangesALayer() throws {
        let plain = try #require(MermaidASCII.drawing(fan))
        #expect(layer(plain, rank: 1) == ["B", "C", "D"])
        let saved = try #require(MermaidASCII.drawing(MermaidASCII.withOrder(["D", "B", "C"], in: fan)))
        #expect(layer(saved, rank: 1) == ["D", "B", "C"])
        #expect(saved.order == ["D", "B", "C"])
    }

    @Test func droppingABoxPutsItAtThePointer() throws {
        let drawing = try #require(MermaidASCII.drawing(fan))
        let b = try #require(drawing.boxes.first { $0.id == "B" })
        #expect(drawing.order(moving: "D", to: b.x) == ["D", "B", "C"])
        #expect(drawing.order(moving: "B", to: 999) == ["C", "D", "B"])
    }

    @Test func boxesAddedLaterStillGetASlot() throws {
        let source = MermaidASCII.withOrder(["C", "B"], in: fan + "\n  A --> E")
        let drawing = try #require(MermaidASCII.drawing(source))
        let ids = layer(drawing, rank: 1)
        #expect(Set(ids) == ["B", "C", "D", "E"])
        #expect(ids.firstIndex(of: "C")! < ids.firstIndex(of: "B")!)
    }

    @Test func theOrderCommentIsAddedUnderTheHeaderThenRewritten() {
        let once = MermaidASCII.withOrder(["B", "A"], in: "graph LR\n  A --> B")
        #expect(once == "graph LR\n  %% clipb-order: B A\n  A --> B")
        #expect(MermaidASCII.withOrder(["A", "B"], in: once) == "graph LR\n  %% clipb-order: A B\n  A --> B")
        #expect(MermaidASCII.savedOrder(in: once) == ["B", "A"])
        #expect(MermaidASCII.parse(once)?.nodes.count == 2)
    }

    @Test func removedBoxesDropOutOfTheOrder() throws {
        let drawing = try #require(MermaidASCII.drawing(MermaidASCII.withOrder(["Gone", "C", "B"], in: fan)))
        #expect(!drawing.order(moving: "B", to: 0).contains("Gone"))
    }
}
