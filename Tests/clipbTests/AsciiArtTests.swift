import Foundation
import Testing
@testable import clipb

@Suite struct AsciiArtTests {
    typealias A = AsciiArt

    /// The user's real diagram (hand-drawn, square bends, a stacked box, a bus).
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

    private func scene(_ text: String = gateways, sourceLocation: SourceLocation = #_sourceLocation) throws -> A.Scene {
        try #require(A.scan(text), sourceLocation: sourceLocation)
    }

    /// The box whose first text row starts with `title`.
    private func box(_ s: A.Scene, _ title: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> Int {
        try #require(s.boxes.firstIndex { A.text(of: $0.id, compartment: 0, in: s).first?.hasPrefix(title) == true },
                     "no box \(title)", sourceLocation: sourceLocation)
    }

    private func title(_ s: A.Scene, _ b: Int) -> String { A.text(of: b, compartment: 0, in: s).first ?? "" }

    /// Links as "from -> to" by box title (tails, then heads), sorted.
    private func links(_ s: A.Scene) -> [String] {
        s.links.map { l in
            let tails = l.ends.filter { !$0.head }.map { title(s, $0.box) }.sorted()
            let heads = l.ends.filter(\.head).map { title(s, $0.box) }.sorted()
            return tails.joined(separator: ",") + " -> " + heads.joined(separator: ",")
        }.sorted()
    }

    /// Box count, link count, ends per link.
    private func shape(_ s: A.Scene) -> [Int] {
        [s.boxes.count, s.links.count] + s.links.map(\.ends.count).sorted()
    }

    private func lines(_ t: String) -> [String] { t.components(separatedBy: "\n") }

    // MARK: - Scan

    @Test func scanGateways() throws {
        let s = try scene()
        #expect(s.boxes.count == 9)
        let titles = Set(s.boxes.map { title(s, $0.id) })
        #expect(titles == ["Partner's backends", "Partner's websites", "Dashboard", "Backoffice", "oms-api [1]",
                           "Dashboard BFF proxy", "dashboard-api", "backoffice-api", "auth"])
        let stacked = try box(s, "auth")
        #expect(s.boxes[stacked].compartments.count == 11)
        #expect((0..<11).map { A.text(of: stacked, compartment: $0, in: s) }
            == [["auth"], ["core [2]"], ["bpn-api"], ["waas"], ["indexer"], ["analytics"], ["audit"], ["events"], ["webhooks"],
                ["capture"], ["files"]])
        #expect(A.text(of: try box(s, "oms-api"), compartment: 0, in: s) == ["oms-api [1]"])
        #expect(A.text(of: try box(s, "Partner's backends"), compartment: 0, in: s) == ["Partner's backends", "[secret key → API token]"])
        let dashboard = try box(s, "Dashboard")
        #expect(A.text(of: dashboard, compartment: 0, in: s) == ["Dashboard", "[user session token]"])

        let ls = links(s)
        #expect(ls.contains("Partner's backends -> oms-api [1]"))
        #expect(ls.contains("Partner's websites -> oms-api [1]"))
        #expect(ls.contains("Dashboard -> Dashboard BFF proxy"))
        #expect(ls.contains("Dashboard BFF proxy -> dashboard-api"))
        #expect(ls.contains("Backoffice -> backoffice-api"))
        #expect(s.links.count == 6, "\(ls)")
        let bus = try #require(s.links.first { $0.ends.count > 2 })
        #expect(bus.ends.filter { !$0.head }.map { title(s, $0.box) }.sorted() == ["backoffice-api", "dashboard-api", "oms-api [1]"])
        #expect(bus.ends.filter(\.head).count == 11)
        #expect(Set(bus.ends.filter(\.head).map(\.box)) == [stacked])
        // L-shaped: head ▲ right under oms-api.
        let websites = try box(s, "Partner's websites"), oms = try box(s, "oms-api")
        let l = try #require(s.links.first { Set($0.ends.map(\.box)) == [websites, oms] })
        let head = try #require(l.ends.first { $0.head })
        #expect(head.box == oms && head.cell.y == s.boxes[oms].rect.y + s.boxes[oms].rect.height)
        // The ┬ ▼ exit: one cell, both ends.
        let bff = try box(s, "Dashboard BFF"), dapi = try box(s, "dashboard-api")
        let exit = try #require(s.links.first { Set($0.ends.map(\.box)) == [bff, dapi] })
        #expect(exit.cells.count == 1)
    }

    @Test func clipbRenderScans() throws {
        typealias D = AsciiDiagram
        let d = D.Diagram(boxes: [D.fitted(D.Box(id: 0, x: 0, y: 0, width: 0, height: 0, text: ["Client"])),
                                  D.fitted(D.Box(id: 1, x: 24, y: 0, width: 0, height: 0, text: ["API"])),
                                  D.fitted(D.Box(id: 2, x: 24, y: 8, width: 0, height: 0, text: ["DB"]))],
                          arrows: [D.Arrow(id: 0, from: 0, to: 1, label: ["calls"]), D.Arrow(id: 1, from: 1, to: 2, label: []),
                                   D.Arrow(id: 2, from: 0, to: 2, label: [])])
        let art = D.render(d).text
        let s = try scene(art)
        #expect(s.boxes.map(\.rect) == d.boxes.map(\.rect), "\(art)")
        #expect(links(s) == ["API -> DB", "Client -> API", "Client -> DB"], "\(art)")
        // And it edits like hand-drawn art.
        let moved = try #require(A.move(2, dx: 4, dy: 1, in: s), "\(art)")
        #expect(links(moved.scene) == links(s), "\(moved.scene.text)")
        print("ClipB art:\n\(art)\nDB moved:\n\(moved.scene.text)")
        // New bends follow the art: rounded here.
        #expect(moved.scene.text.contains { "╭╮╰╯".contains($0) } && !moved.scene.text.contains("┌─╯"))
        #expect(A.scan(moved.scene.text) == moved.scene)
    }

    @Test func ordinaryTextHasNoBoxes() {
        let go = """
        func main() {
            if x := f(); x > 0 {
                fmt.Println("│ not a box │")
            }
        }
        """
        let table = """
        | Name | Value |
        |------|-------|
        | a    | 1     |
        """
        let tree = """
        .
        ├── Sources
        │   └── clipb
        │       ├── AsciiArt.swift
        │       └── main.swift
        └── Tests
        """
        let corners = "┌── not closed\n│\n└──"
        for t in [go, table, tree, corners, ""] {
            #expect(A.scan(t) == nil, "\(t)")
        }
    }

    // MARK: - Move

    /// Cells an edit of box `b` may change: its old and new rect and the
    /// lines attached to it before and after (with their neighbours, for
    /// junction and border glyphs).
    private func touched(_ s: A.Scene, _ b: Int, _ e: A.Edit) -> Set<A.Cell> {
        var t = Set<A.Cell>()
        func add(_ r: A.Rect) { for y in r.y..<r.y + r.height { for x in r.x..<r.x + r.width { t.insert(A.Cell(x: x, y: y)) } } }
        func addLinks(_ s: A.Scene, _ b: Int) {
            for l in s.links where l.ends.contains(where: { $0.box == b }) {
                for c in l.cells {
                    for (dx, dy) in [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)] { t.insert(A.Cell(x: c.x + dx, y: c.y + dy)) }
                }
            }
        }
        add(s.boxes[b].rect)
        addLinks(s, b)
        if let nb = e.box {
            add(e.scene.boxes[nb].rect)
            addLinks(e.scene, nb)
        }
        return t
    }

    /// Differences outside `allowed`, as "x,y".
    private func strayChanges(_ before: String, _ after: String, allowed: Set<A.Cell>) -> [String] {
        let a = lines(before).map { Array($0) }, b = lines(after).map { Array($0) }
        var out: [String] = []
        for y in 0..<max(a.count, b.count) {
            let ra = y < a.count ? a[y] : [], rb = y < b.count ? b[y] : []
            for x in 0..<max(ra.count, rb.count) {
                let ca = x < ra.count ? ra[x] : " ", cb = x < rb.count ? rb[x] : " "
                if ca != cb && !allowed.contains(A.Cell(x: x, y: y)) { out.append("\(x),\(y)") }
            }
        }
        return out
    }

    /// Checks one edit kept the drawing's meaning and left the rest alone.
    private func checkMove(_ s: A.Scene, _ b: Int, _ e: A.Edit, sameTitles: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) {
        let art = "moved \(title(s, b)):\n\(e.scene.text)"
        #expect(A.scan(e.scene.text) == e.scene, "\(art)", sourceLocation: sourceLocation)
        #expect(shape(e.scene) == shape(s), "\(art)", sourceLocation: sourceLocation)
        if sameTitles { #expect(links(e.scene) == links(s), "\(art)", sourceLocation: sourceLocation) }
        let before = lines(s.text), after = lines(e.scene.text)
        #expect(after.count >= before.count, "\(art)", sourceLocation: sourceLocation)
        for y in [0, 1, 27, 28] { #expect(after[y] == before[y], "line \(y)\n\(art)", sourceLocation: sourceLocation) }
        let stray = strayChanges(s.text, e.scene.text, allowed: touched(s, b, e))
        #expect(stray.isEmpty, "changed outside the edit: \(stray)\n\(art)", sourceLocation: sourceLocation)
        // A line that changed is trimmed; a line that did not is byte-identical.
        for (y, line) in after.enumerated() where y < before.count && line != before[y] {
            #expect(line.last != " ", "\(art)", sourceLocation: sourceLocation)
        }
    }

    @Test func moveEveryBox() throws {
        let s = try scene()
        var report: [String] = []
        for b in s.boxes {
            var moved = 0
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                for k in 1...3 {
                    guard let e = A.move(b.id, dx: dx * k, dy: dy * k, in: s) else { continue }
                    checkMove(s, b.id, e)
                    moved += 1
                    break
                }
            }
            report.append("\(title(s, b.id)): \(moved)")
            #expect(moved >= 2, "\(title(s, b.id)) moved in only \(moved) directions")
        }
        print(report)
    }

    @Test func moveStackedBoxRight() throws {
        let s = try scene()
        let stacked = try box(s, "auth")
        let start = Date()
        let e = try #require(A.move(stacked, dx: 6, dy: 0, in: s))
        let ms = Date().timeIntervalSince(start) * 1000
        print("stacked box moved right by 6 in \(Int(ms)) ms:\n\(e.scene.text)")
        checkMove(s, stacked, e)
        let nb = try #require(e.box)
        let r = e.scene.boxes[nb].rect
        #expect(r.x == s.boxes[stacked].rect.x + 6 && e.scene.boxes[nb].compartments.count == 11)
        let buses = e.scene.links.filter { $0.ends.count > 2 }
        #expect(buses.count == 1)
        let heads = buses.first?.ends.filter(\.head) ?? []
        #expect(heads.count == 11)
        #expect(heads.allSatisfy { $0.box == nb && $0.cell.x == r.x - 1 }, "\(e.scene.text)")
        #expect(Set(heads.map(\.cell.y)) == Set(e.scene.boxes[nb].compartments.map(\.y)))
        #expect(ms < 1000)
    }

    @Test func moveOmsApi() throws {
        let s = try scene()
        let oms = try box(s, "oms-api")
        let e = try #require(A.move(oms, dx: 1, dy: 2, in: s))
        print("oms-api moved down 2, right 1:\n\(e.scene.text)")
        checkMove(s, oms, e)
        let nb = try #require(e.box)
        let bus = try #require(e.scene.links.first { $0.ends.count > 2 })
        #expect(bus.ends.count == 14)
        let tail = try #require(bus.ends.first { $0.box == nb })
        let r = e.scene.boxes[nb].rect
        #expect(tail.cell.x == r.x + r.width && tail.cell.y > r.y && tail.cell.y < r.y + r.height, "\(e.scene.text)")
        let partner = try box(e.scene, "Partner's backends"), websites = try box(e.scene, "Partner's websites")
        for from in [partner, websites] {
            let l = try #require(e.scene.links.first { Set($0.ends.map(\.box)) == [from, nb] }, "\(e.scene.text)")
            #expect(l.ends.first { $0.head }?.box == nb)
        }
    }

    @Test func moveIntoAnotherBoxFails() throws {
        let s = try scene()
        let partner = try box(s, "Partner's backends")
        #expect(A.move(partner, dx: 0, dy: 5, in: s) == nil)
        #expect(A.move(partner, dx: 0, dy: -5, in: s) == nil, "off the top")
        #expect(A.move(partner, dx: 0, dy: 0, in: s)?.scene == s)
    }

    // MARK: - Text

    @Test func setTextWidensBox() throws {
        let s = try scene()
        let oms = try box(s, "oms-api")
        let e = try #require(A.setText(["oms-api [1] (api-gw v2)"], box: oms, compartment: 0, in: s))
        print("oms-api retitled:\n\(e.scene.text)")
        checkMove(s, oms, e, sameTitles: false)
        let nb = try #require(e.box)
        #expect(e.scene.boxes[nb].rect.width > s.boxes[oms].rect.width)
        #expect(A.text(of: nb, compartment: 0, in: e.scene) == ["oms-api [1] (api-gw v2)"])
        #expect(e.scene.links.filter { $0.ends.contains { $0.box == nb } }.count == 3)

        // Same size: only the text changes.
        let same = try #require(A.setText(["oms-api"], box: oms, compartment: 0, in: s))
        #expect(A.text(of: oms, compartment: 0, in: same.scene) == ["oms-api"])
        #expect(strayChanges(s.text, same.scene.text, allowed: Set(s.boxes[oms].compartments.flatMap { c in
            (c.x..<c.x + c.width).map { A.Cell(x: $0, y: c.y) } })).isEmpty)

        // A compartment of the stacked box grows a row; the bus follows.
        let stacked = try box(s, "auth")
        let tall = try #require(A.setText(["core [2]", "second line"], box: stacked, compartment: 1, in: s))
        print("stacked box, two-line compartment:\n\(tall.scene.text)")
        let nb2 = try #require(tall.box)
        #expect(A.text(of: nb2, compartment: 1, in: tall.scene) == ["core [2]", "second line"])
        #expect(tall.scene.links.first { $0.ends.count > 2 }?.ends.filter(\.head).count == 11)
        #expect(links(tall.scene) == links(s))
    }

    // MARK: - Connect, delete, add

    @Test func connectAndDelete() throws {
        let s = try scene()
        let websites = try box(s, "Partner's websites"), dashboard = try box(s, "Dashboard")
        let c = try #require(A.connect(websites, to: dashboard, in: s))
        print("websites -> Dashboard:\n\(c.scene.text)")
        #expect(A.scan(c.scene.text) == c.scene)
        #expect(c.scene.links.count == s.links.count + 1)
        let l = try #require(c.link)
        #expect(c.scene.links[l].ends.map(\.head).sorted { !$0 && $1 } == [false, true])
        #expect(Set(c.scene.links[l].ends.map { title(c.scene, $0.box) }) == ["Partner's websites", "Dashboard"])

        let back = try #require(A.deleteLink(l, in: c.scene))
        #expect(back.scene.text == s.text)

        // Deleting a box takes its simple arrow along...
        let backoffice = try box(s, "Backoffice")
        let d1 = try #require(A.deleteBox(backoffice, in: s))
        print("without Backoffice:\n\(d1.scene.text)")
        #expect(d1.scene.boxes.count == 8 && d1.scene.links.count == 5)
        #expect(!lines(d1.scene.text)[23].contains("▶│ backoffice"))
        // ...and its branch of the bus.
        let bapi = try box(s, "backoffice-api")
        let d2 = try #require(A.deleteBox(bapi, in: s))
        print("without backoffice-api:\n\(d2.scene.text)")
        #expect(d2.scene.boxes.count == 8 && d2.scene.links.count == 5)
        #expect(d2.scene.links.first { $0.ends.count > 2 }?.ends.count == 13)
        #expect(A.scan(d2.scene.text) == d2.scene)

        let bus = try #require(s.links.first { $0.ends.count > 2 })
        let d3 = try #require(A.deleteLink(bus.id, in: s))
        #expect(d3.scene.links.count == 5 && !d3.scene.text.contains("├──▶"))
    }

    @Test func addBox() throws {
        let s = try scene()
        let e = try #require(A.addBox(A.Rect(x: 98, y: 4, width: 8, height: 3), text: ["cache"], in: s))
        let nb = try #require(e.box)
        #expect(e.scene.boxes.count == 10 && A.text(of: nb, compartment: 0, in: e.scene) == ["cache"])
        #expect(e.scene.links == s.links.map { l in
            var l = l
            l.ends = l.ends.map { var e = $0; e.box += $0.box >= nb ? 1 : 0; return e }
            return l
        })
        #expect(A.scan(e.scene.text) == e.scene)
        // Then connect it.
        let stacked = try box(e.scene, "auth")
        let c = try #require(A.connect(stacked, to: nb, in: e.scene), "\(e.scene.text)")
        print("new box, connected:\n\(c.scene.text)")
        #expect(A.addBox(A.Rect(x: 5, y: 5, width: 8, height: 3), text: ["x"], in: s) == nil)
        #expect(A.addBox(A.Rect(x: 40, y: 0, width: 8, height: 3), text: ["x"], in: s) == nil, "over the header text")
    }
}
