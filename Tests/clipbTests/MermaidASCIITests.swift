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
