import Foundation

/// Hand-drawn box art, edited in place: an edit rewrites only the cells of
/// what it touches, so the rest of the drawing stays exactly as drawn.
///
/// `AsciiDiagram` owns drawings ClipB rendered itself (it re-renders them
/// whole); this reads any box-drawing art: boxes are closed ┌┐└┘ rectangles
/// (optionally split into compartments by ├──┤ rows), links are connected
/// line glyphs whose ends touch a box. Everything else is free text and is
/// never touched. Pure (Foundation only), tested.
enum AsciiArt {
    typealias Cell = AsciiDiagram.Cell
    typealias Rect = AsciiDiagram.Rect

    /// `compartments`: interior rects, top to bottom.
    struct Box: Equatable { var id: Int; var rect: Rect; var compartments: [Rect] }
    /// `cell`: the line cell touching the box (a head cell when `head`).
    struct End: Equatable { var box: Int; var cell: Cell; var head: Bool }
    /// One connected line component (may be a tree/bus).
    struct Link: Equatable { var id: Int; var cells: Set<Cell>; var ends: [End] }
    struct Scene: Equatable { var text: String; var boxes: [Box]; var links: [Link] }
    /// What the edit was about, by id in the NEW scene.
    struct Edit { var scene: Scene; var box: Int?; var link: Int? }

    // MARK: - API

    /// nil when there is no box.
    static func scan(_ text: String) -> Scene? {
        let a = Analysis(Grid(text))
        guard !a.boxes.isEmpty else { return nil }
        return a.scene(text)
    }

    static func move(_ box: Int, dx: Int, dy: Int, in s: Scene) -> Edit? {
        guard s.boxes.indices.contains(box) else { return nil }
        if dx == 0 && dy == 0 { return Edit(scene: s, box: box, link: nil) }
        let a = Analysis(Grid(s.text))
        guard a.boxes.count == s.boxes.count else { return nil }
        var r = a.boxes[box].rect
        let content = a.content(of: box)
        r.x += dx
        r.y += dy
        return relayout(box, to: r, content: content, in: s)
    }

    /// The text stays anchored top-left; nil when it would cut text.
    static func resize(_ box: Int, to rect: Rect, in s: Scene) -> Edit? {
        guard s.boxes.indices.contains(box) else { return nil }
        let b = s.boxes[box]
        if rect.width == b.rect.width && rect.height == b.rect.height {
            return move(box, dx: rect.x - b.rect.x, dy: rect.y - b.rect.y, in: s)
        }
        guard rect.width >= 3, rect.height >= 3 else { return nil }
        let g = Grid(s.text)
        var interiors = b.compartments.map { rows(of: $0, in: g) }
        var heights = b.compartments.map(\.height)
        let last = heights.count - 1
        heights[last] += rect.height - b.rect.height
        guard heights[last] >= 1 else { return nil }
        let w = rect.width - 2
        for k in interiors.indices {
            for (i, row) in interiors[k].enumerated() {
                let cut = i >= heights[k] ? row[...] : row.dropFirst(min(w, row.count))
                guard cut.allSatisfy({ $0 == " " }) else { return nil }
            }
            interiors[k] = Array(interiors[k].prefix(heights[k]))
        }
        return relayout(box, to: rect, content: frame(rect.width, heights, interiors), in: s)
    }

    static func addBox(_ rect: Rect, text: [String], in s: Scene) -> Edit? {
        let lines = text.flatMap { $0.components(separatedBy: "\n") }
        let w = max(rect.width, (lines.map(\.count).max() ?? 0) + 4, 3)
        let h = max(rect.height, lines.count + 2, 3)
        let r = Rect(x: rect.x, y: rect.y, width: w, height: h)
        guard r.x >= 0, r.y >= 0 else { return nil }
        var ed = Editor(Analysis(Grid(s.text)))
        guard ed.isFree(r) else { return nil }
        ed.draw(frame(w, [h - 2], [lines.map { Array(" " + $0) }]), at: r)
        let old = ed.a.scene(s.text)
        guard let ns = scan(ed.g.text()),
              boxKeys(ns) == (boxKeys(old) + [key(r)]).sorted(),
              signature(ns, comps: true) == signature(old, comps: true),
              let id = ns.boxes.firstIndex(where: { $0.rect == r }) else { return nil }
        return Edit(scene: ns, box: id, link: nil)
    }

    /// New arrow, head at `to`.
    static func connect(_ from: Int, to: Int, in s: Scene) -> Edit? {
        let a = Analysis(Grid(s.text))
        guard from != to, a.boxes.indices.contains(from), a.boxes.indices.contains(to) else { return nil }
        // Match the art: exit glyphs on the source border only if most ends use them.
        let tails = a.ends.joined().filter { !$0.end.head }
        let glyph = tails.filter(\.glyph).count * 2 > tails.count
        var ed = Editor(a)
        guard ed.route(from: Side(box: from, compartment: nil, head: false, glyph: glyph),
                       to: .box(Side(box: to, compartment: nil, head: true, glyph: false)),
                       link: -1, reuse: []) != nil else { return nil }
        let old = a.scene(s.text)
        let parts = [key(old.boxes[from].rect) + "-", key(old.boxes[to].rect) + ">"].sorted().joined(separator: "|")
        guard let ns = scan(ed.g.text()),
              boxKeys(ns) == boxKeys(old),
              signature(ns, comps: false) == (signature(old, comps: false) + [parts]).sorted(),
              let first = ed.lastPath.first,
              let link = ns.links.first(where: { $0.cells.contains(first) && $0.ends.count == 2 }) else { return nil }
        return Edit(scene: ns, box: nil, link: link.id)
    }

    /// Also removes its links' branches (a link left with one end goes too).
    static func deleteBox(_ id: Int, in s: Scene) -> Edit? {
        let a = Analysis(Grid(s.text))
        guard a.boxes.indices.contains(id) else { return nil }
        var ed = Editor(a)
        var touched: Set<Int> = []
        for (li, ends) in a.ends.enumerated() {
            for e in ends where e.end.box == id {
                touched.insert(li)
                if ed.erased.contains(e.node) { continue }
                guard let w = ed.walk(e, link: li) else { return nil }
                if case .end(let o) = w.to, o.glyph { ed.restore(o) }
            }
        }
        for li in touched.sorted() {
            let left = a.ends[li].filter { $0.end.box != id && !ed.erased.contains($0.node) }
            if left.count < 2 {
                ed.erased.formUnion(a.nodes[li])
                for o in left where o.glyph { ed.restore(o) }
            }
        }
        ed.applyErase()
        for c in cells(a.boxes[id].rect) { ed.g.set(c, " ") }
        let old = a.scene(s.text)
        guard let ns = scan(ed.g.text()) ?? emptyScene(ed.g.text(), boxes: old.boxes.count - 1),
              boxKeys(ns) == boxKeys(old).filter({ $0 != key(old.boxes[id].rect) }) || old.boxes.count == 1,
              signature(ns, comps: true) == signature(old, drop: id, comps: true) else { return nil }
        return Edit(scene: ns, box: nil, link: nil)
    }

    /// The whole component.
    static func deleteLink(_ id: Int, in s: Scene) -> Edit? {
        let a = Analysis(Grid(s.text))
        guard a.links.indices.contains(id) else { return nil }
        var ed = Editor(a)
        ed.erased.formUnion(a.nodes[id])
        ed.applyErase()
        for e in a.ends[id] where e.glyph { ed.restore(e) }
        let old = a.scene(s.text)
        var expected = signature(old, comps: true)
        guard let i = expected.firstIndex(of: linkSignature(old, old.links[id], comps: true)) else { return nil }
        expected.remove(at: i)
        guard let ns = scan(ed.g.text()), boxKeys(ns) == boxKeys(old), signature(ns, comps: true) == expected else { return nil }
        return Edit(scene: ns, box: nil, link: nil)
    }

    /// The compartment's rows, spaces trimmed on both sides.
    static func text(of box: Int, compartment: Int, in s: Scene) -> [String] {
        guard s.boxes.indices.contains(box), s.boxes[box].compartments.indices.contains(compartment) else { return [] }
        return rows(of: s.boxes[box].compartments[compartment], in: Grid(s.text)).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
    }

    /// The cell where line `k` of a compartment's text starts, the line's own
    /// leading spaces counted: where the row's visible text begins, or the
    /// middle of an empty row (where centered text starts growing from).
    static func lineStart(box: Int, compartment: Int, line k: Int, of lines: [String], in s: Scene) -> Cell? {
        guard s.boxes.indices.contains(box), s.boxes[box].compartments.indices.contains(compartment) else { return nil }
        let room = s.boxes[box].compartments[compartment]
        let line = lines.indices.contains(k) ? lines[k] : ""
        let lead = line.prefix { $0 == " " || $0 == "\t" }.count
        let row = k < room.height ? rows(of: Rect(x: room.x, y: room.y + k, width: room.width, height: 1), in: Grid(s.text))[0] : []
        let visible = row.firstIndex { $0 != " " } ?? centered(line.trimmingCharacters(in: .whitespaces).count, in: room.width)
        return Cell(x: room.x + visible - lead, y: room.y + k)
    }

    /// Columns before a centered text of `count` in `width`.
    fileprivate static func centered(_ count: Int, in width: Int) -> Int { max(0, (width - count) / 2) }

    /// Writes each line centered (spaces trimmed); widens/heightens the box when needed, never shrinks it.
    static func setText(_ lines: [String], box: Int, compartment k: Int, in s: Scene) -> Edit? {
        guard s.boxes.indices.contains(box), s.boxes[box].compartments.indices.contains(k) else { return nil }
        let lines = lines.flatMap { $0.components(separatedBy: "\n") }.map { $0.trimmingCharacters(in: .whitespaces) }
        let b = s.boxes[box]
        let g = Grid(s.text)
        let w = max(b.rect.width - 2, (lines.map(\.count).max() ?? 0) + 2)
        var heights = b.compartments.map(\.height)
        heights[k] = max(heights[k], lines.count)
        var interiors = b.compartments.map { rows(of: $0, in: g) }
        interiors[k] = (0..<heights[k]).map { i in
            i < lines.count ? Array(String(repeating: " ", count: centered(lines[i].count, in: w)) + lines[i]) : []
        }
        let content = frame(w + 2, heights, interiors)
        let r = Rect(x: b.rect.x, y: b.rect.y, width: w + 2, height: content.count)
        if r != b.rect { return relayout(box, to: r, content: content, in: s) }
        // Same size: rewrite the compartment's interior only (border glyphs stay).
        var ed = Editor(Analysis(Grid(s.text)))
        let comp = b.compartments[k]
        let offset = comp.y - b.rect.y
        for dy in 0..<comp.height {
            for dx in 0..<comp.width {
                ed.g.set(Cell(x: comp.x + dx, y: comp.y + dy), content[offset + dy][1 + dx])
            }
        }
        let old = ed.a.scene(s.text)
        guard let ns = scan(ed.g.text()), boxKeys(ns) == boxKeys(old),
              signature(ns, comps: true) == signature(old, comps: true) else { return nil }
        return Edit(scene: ns, box: box, link: nil)
    }

    // MARK: - Glyphs

    fileprivate enum Dir: Int, CaseIterable {
        case right = 0, down, left, up
        var dx: Int { [1, 0, -1, 0][rawValue] }
        var dy: Int { [0, 1, 0, -1][rawValue] }
        var opposite: Dir { Dir(rawValue: (rawValue + 2) % 4)! }
        var bit: UInt8 { 1 << UInt8(rawValue) }
        var horizontal: Bool { rawValue % 2 == 0 }
        /// The head glyph pointing this way.
        var head: Character { ["▶", "▼", "◀", "▲"][rawValue] }
        /// The border glyph where a line leaves a box through the side facing this way.
        var exit: Character { ["├", "┬", "┤", "┴"][rawValue] }
    }

    fileprivate static func step(_ c: Cell, _ d: Dir) -> Cell { Cell(x: c.x + d.dx, y: c.y + d.dy) }

    /// Ports: right 1, down 2, left 4, up 8. A head's one port faces back along its line.
    fileprivate static func bits(_ c: Character) -> UInt8? {
        switch c {
        case "─": return 5
        case "│": return 10
        case "┌", "╭": return 3
        case "┐", "╮": return 6
        case "└", "╰": return 9
        case "┘", "╯": return 12
        case "├": return 11
        case "┤": return 14
        case "┬": return 7
        case "┴": return 13
        case "┼": return 15
        case "▶", "►": return 4
        case "◀", "◄": return 1
        case "▲": return 2
        case "▼": return 8
        default: return nil
        }
    }

    /// Which way a head points.
    fileprivate static func headDir(_ c: Character) -> Dir? {
        switch c {
        case "▶", "►": return .right
        case "◀", "◄": return .left
        case "▲": return .up
        case "▼": return .down
        default: return nil
        }
    }

    fileprivate static func glyph(_ b: UInt8, rounded: Bool) -> Character {
        switch b {
        case 5, 1, 4: return "─"
        case 10, 2, 8: return "│"
        case 3: return rounded ? "╭" : "┌"
        case 6: return rounded ? "╮" : "┐"
        case 9: return rounded ? "╰" : "└"
        case 12: return rounded ? "╯" : "┘"
        case 11: return "├"
        case 14: return "┤"
        case 7: return "┬"
        case 13: return "┴"
        case 15: return "┼"
        default: return " "
        }
    }

    // MARK: - Grid

    /// Lines of Characters; a missing cell past a line's end is a space.
    /// Lines left as they were come out byte-identical; changed ones trimmed.
    fileprivate struct Grid {
        let original: [String]
        let originalRows: [[Character]]
        var rows: [[Character]]

        init(_ text: String) {
            original = text.components(separatedBy: "\n")
            originalRows = original.map { Array($0) }
            rows = originalRows
        }

        subscript(_ c: Cell) -> Character {
            c.y >= 0 && c.y < rows.count && c.x >= 0 && c.x < rows[c.y].count ? rows[c.y][c.x] : " "
        }
        subscript(_ x: Int, _ y: Int) -> Character { self[Cell(x: x, y: y)] }

        var width: Int { rows.map(\.count).max() ?? 0 }

        mutating func set(_ c: Cell, _ ch: Character) {
            guard c.x >= 0, c.y >= 0, self[c] != ch else { return }
            while rows.count <= c.y { rows.append([]) }
            if rows[c.y].count <= c.x { rows[c.y] += Array(repeating: " ", count: c.x - rows[c.y].count + 1) }
            rows[c.y][c.x] = ch
        }

        func text() -> String {
            var out: [String] = []
            for (y, row) in rows.enumerated() {
                var r = row[...]
                while r.last == " " { r = r.dropLast() }
                if y < originalRows.count {
                    var o = originalRows[y][...]
                    while o.last == " " { o = o.dropLast() }
                    out.append(o == r ? original[y] : String(r))
                } else {
                    out.append(String(r))
                }
            }
            while out.count > original.count, out.last?.isEmpty == true { out.removeLast() }
            return out.joined(separator: "\n")
        }
    }

    fileprivate static func cells(_ r: Rect) -> [Cell] {
        guard r.width > 0, r.height > 0 else { return [] }
        return (r.y..<r.y + r.height).flatMap { y in (r.x..<r.x + r.width).map { Cell(x: $0, y: y) } }
    }

    fileprivate static func overlaps(_ a: Rect, _ b: Rect) -> Bool {
        a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
    }

    fileprivate static func rows(of r: Rect, in g: Grid) -> [[Character]] {
        (0..<r.height).map { dy in (0..<r.width).map { dx in g[r.x + dx, r.y + dy] } }
    }

    /// Interior rects between the divider rows (├──┤) of the box at `r`.
    fileprivate static func compartments(_ r: Rect, at: (Int, Int) -> Character) -> [Rect] {
        let x2 = r.x + r.width - 1, y2 = r.y + r.height - 1
        var result: [Rect] = []
        var start = r.y + 1
        for y in r.y + 1..<y2 where at(r.x, y) == "├" && at(x2, y) == "┤" && (r.x + 1..<x2).allSatisfy({ at($0, y) == "─" }) {
            result.append(Rect(x: r.x + 1, y: start, width: r.width - 2, height: y - start))
            start = y + 1
        }
        result.append(Rect(x: r.x + 1, y: start, width: r.width - 2, height: y2 - start))
        return result
    }

    /// A box drawn fresh: heights per compartment, interiors padded/cut to the width.
    fileprivate static func frame(_ w: Int, _ heights: [Int], _ interiors: [[[Character]]]) -> [[Character]] {
        let bar = Array(repeating: Character("─"), count: max(0, w - 2))
        var m: [[Character]] = [["┌"] + bar + ["┐"]]
        for (k, h) in heights.enumerated() {
            if k > 0 { m.append(["├"] + bar + ["┤"]) }
            for i in 0..<max(0, h) {
                var row = k < interiors.count && i < interiors[k].count ? interiors[k][i] : []
                if row.count > w - 2 { row = Array(row.prefix(w - 2)) }
                row += Array(repeating: " ", count: w - 2 - row.count)
                m.append(["│"] + row + ["│"])
            }
        }
        m.append(["└"] + bar + ["┘"])
        return m
    }

    // MARK: - Analysis

    fileprivate struct BoxInfo { var rect: Rect; var compartments: [Rect] }

    /// A line cell; a ┼ crossing is two nodes: 1 its horizontal, 2 its vertical stroke.
    fileprivate struct Node: Hashable { var cell: Cell; var sub: UInt8 }

    fileprivate struct EndInfo {
        var end: End
        var node: Node
        /// From the end cell toward the box.
        var toBox: Dir
        /// The border cell it touches.
        var border: Cell
        /// The border cell carries an outward attachment glyph (├ ┤ ┬ ┴ ┼).
        var glyph: Bool
        var compartment: Int?
    }

    fileprivate struct Analysis {
        let grid: Grid
        var boxes: [BoxInfo] = []
        var boxAt: [Int]
        let width: Int
        var links: [Link] = []
        var ends: [[EndInfo]] = []
        var nodes: [[Node]] = []
        var linkOf: [Node: Int] = [:]
        var rounded = false

        init(_ g: Grid) {
            grid = g
            width = g.width + 1
            boxAt = Array(repeating: -1, count: width * max(1, g.rows.count))
            findBoxes()
            findLinks()
        }

        func box(at c: Cell) -> Int? {
            guard c.x >= 0, c.y >= 0, c.x < width, c.y < grid.rows.count else { return nil }
            let b = boxAt[c.y * width + c.x]
            return b >= 0 ? b : nil
        }

        private mutating func findBoxes() {
            let g = grid
            let edge: Set<Character> = ["─", "┬", "┴", "┼"], side: Set<Character> = ["│", "├", "┤", "┼"]
            for y in g.rows.indices {
                for x in g.rows[y].indices where g.rows[y][x] == "┌" && box(at: Cell(x: x, y: y)) == nil {
                    var x2 = x + 1
                    while edge.contains(g[x2, y]) { x2 += 1 }
                    guard g[x2, y] == "┐", x2 - x >= 2 else { continue }
                    var y2 = y + 1
                    while side.contains(g[x, y2]) && side.contains(g[x2, y2]) { y2 += 1 }
                    guard y2 - y >= 2, g[x, y2] == "└", g[x2, y2] == "┘",
                          (x + 1..<x2).allSatisfy({ edge.contains(g[$0, y2]) }) else { continue }
                    let r = Rect(x: x, y: y, width: x2 - x + 1, height: y2 - y + 1)
                    guard !boxes.contains(where: { AsciiArt.overlaps($0.rect, r) }) else { continue }
                    let id = boxes.count
                    boxes.append(BoxInfo(rect: r, compartments: AsciiArt.compartments(r) { g[$0, $1] }))
                    for c in AsciiArt.cells(r) { boxAt[c.y * width + c.x] = id }
                }
            }
        }

        func isLine(_ c: Cell) -> Bool { AsciiArt.bits(grid[c]) != nil && box(at: c) == nil }

        func ports(_ n: Node) -> UInt8 { n.sub == 1 ? 5 : n.sub == 2 ? 10 : AsciiArt.bits(grid[n.cell]) ?? 0 }

        /// The node at `c` that has a port facing `d`.
        func node(at c: Cell, port d: Dir) -> Node? {
            guard isLine(c) else { return nil }
            let ch = grid[c]
            if ch == "┼" { return Node(cell: c, sub: d.horizontal ? 1 : 2) }
            return AsciiArt.bits(ch)! & d.bit != 0 ? Node(cell: c, sub: 0) : nil
        }

        func neighbour(_ n: Node, _ d: Dir) -> Node? {
            guard ports(n) & d.bit != 0 else { return nil }
            return node(at: AsciiArt.step(n.cell, d), port: d.opposite)
        }

        func onBorder(_ b: Int, _ c: Cell) -> Bool {
            let r = boxes[b].rect
            return c.x == r.x || c.y == r.y || c.x == r.x + r.width - 1 || c.y == r.y + r.height - 1
        }

        func compartment(_ b: Int, _ border: Cell) -> Int? {
            let info = boxes[b]
            if border.y == info.rect.y { return 0 }
            if border.y == info.rect.y + info.rect.height - 1 { return info.compartments.count - 1 }
            return info.compartments.firstIndex { border.y >= $0.y && border.y < $0.y + $0.height }
        }

        /// An end touching box border cell `m`, reached from the end cell moving `d`.
        func endInfo(_ n: Node, toward d: Dir, head: Bool) -> EndInfo? {
            let m = AsciiArt.step(n.cell, d)
            guard let b = box(at: m), onBorder(b, m) else { return nil }
            let r = boxes[b].rect
            let corner = (m.x == r.x || m.x == r.x + r.width - 1) && (m.y == r.y || m.y == r.y + r.height - 1)
            let outward: Set<Character> = [["┤", "┼"], ["┴", "┼"], ["├", "┼"], ["┬", "┼"]][d.rawValue]
            let glyph = !corner && outward.contains(grid[m])
            return EndInfo(end: End(box: b, cell: n.cell, head: head), node: n, toBox: d, border: m,
                           glyph: glyph, compartment: compartment(b, m))
        }

        private mutating func findLinks() {
            var all: [Node] = []
            for y in grid.rows.indices {
                for x in grid.rows[y].indices {
                    let c = Cell(x: x, y: y)
                    guard isLine(c) else { continue }
                    if grid[c] == "╭" || grid[c] == "╮" || grid[c] == "╰" || grid[c] == "╯" { rounded = true }
                    if grid[c] == "┼" {
                        all.append(Node(cell: c, sub: 1))
                        all.append(Node(cell: c, sub: 2))
                    } else {
                        all.append(Node(cell: c, sub: 0))
                    }
                }
            }
            var seen: Set<Node> = []
            var comps: [(cells: Set<Cell>, nodes: [Node], ends: [EndInfo], first: Cell)] = []
            for start in all where !seen.contains(start) {
                seen.insert(start)
                var queue = [start], i = 0
                var ends: [EndInfo] = []
                while i < queue.count {
                    let n = queue[i]
                    i += 1
                    for d in Dir.allCases where ports(n) & d.bit != 0 {
                        if let m = neighbour(n, d) {
                            if seen.insert(m).inserted { queue.append(m) }
                        } else if let e = endInfo(n, toward: d, head: false) {
                            ends.append(e)
                        }
                    }
                    if n.sub == 0, let hd = AsciiArt.headDir(grid[n.cell]), let e = endInfo(n, toward: hd, head: true) {
                        ends.append(e)
                    }
                }
                guard ends.count >= 2 else { continue }
                let cells = Set(queue.map(\.cell))
                let first = cells.min { ($0.y, $0.x) < ($1.y, $1.x) }!
                ends.sort { ($0.end.cell.y, $0.end.cell.x, $0.end.box, $0.end.head ? 1 : 0) < ($1.end.cell.y, $1.end.cell.x, $1.end.box, $1.end.head ? 1 : 0) }
                comps.append((cells, queue, ends, first))
            }
            comps.sort { ($0.first.y, $0.first.x) < ($1.first.y, $1.first.x) }
            for (i, c) in comps.enumerated() {
                links.append(Link(id: i, cells: c.cells, ends: c.ends.map(\.end)))
                ends.append(c.ends)
                nodes.append(c.nodes)
                for n in c.nodes { linkOf[n] = i }
            }
        }

        func scene(_ text: String) -> Scene {
            Scene(text: text, boxes: boxes.enumerated().map { Box(id: $0.offset, rect: $0.element.rect, compartments: $0.element.compartments) },
                  links: links)
        }

        /// The box's cells, outward attachment glyphs put back to plain border.
        func content(of b: Int) -> [[Character]] {
            let r = boxes[b].rect
            var m = AsciiArt.rows(of: r, in: grid)
            let w = r.width, h = r.height
            for x in 1..<w - 1 {
                if m[0][x] == "┴" || m[0][x] == "┼" { m[0][x] = "─" }
                if m[h - 1][x] == "┬" || m[h - 1][x] == "┼" { m[h - 1][x] = "─" }
            }
            for y in 1..<h - 1 {
                if m[y][0] == "┤" || m[y][0] == "┼" { m[y][0] = "│" }
                if m[y][w - 1] == "├" || m[y][w - 1] == "┼" { m[y][w - 1] = "│" }
            }
            return m
        }
    }

    // MARK: - Editing

    fileprivate struct Side { var box: Int; var compartment: Int?; var head: Bool; var glyph: Bool }
    fileprivate enum Goal { case box(Side), join(Int) }
    fileprivate enum WalkTarget { case end(EndInfo), junction(Cell) }

    fileprivate struct Editor {
        let a: Analysis
        var g: Grid
        var rects: [Rect?]
        var comps: [[Rect]]
        var erased: Set<Node> = []
        var applied: Set<Node> = []
        /// Link id -> its line cells now on the canvas.
        var live: [Int: Set<Cell>] = [:]
        var lastPath: [Cell] = []
        /// Cells drawn by this edit's routes: joining them is allowed but
        /// costs more, so branches go back to the line as it was drawn.
        var routed: Set<Cell> = []

        init(_ a: Analysis) {
            self.a = a
            g = a.grid
            rects = a.boxes.map(\.rect)
            comps = a.boxes.map(\.compartments)
            for (i, ns) in a.nodes.enumerated() { live[i] = Set(ns.map(\.cell)) }
        }

        /// Walks from an end along its line to a junction (kept) or another
        /// end (erased with the rest); marks the walked nodes erased.
        mutating func walk(_ e: EndInfo, link: Int) -> (path: [Cell], to: WalkTarget)? {
            var cur = e.node
            var prev: Node? = nil
            var path: [Node] = []
            while path.count <= a.nodes[link].count {
                let nbrs = Dir.allCases.compactMap { a.neighbour(cur, $0) }.filter { !erased.contains($0) }
                if prev != nil && nbrs.count >= 3 {
                    erased.formUnion(path)
                    return (path.map(\.cell), .junction(cur.cell))
                }
                path.append(cur)
                if let o = a.ends[link].first(where: { $0.node == cur && !($0.end == e.end) }) {
                    guard o.end.box != e.end.box else { return nil }
                    erased.formUnion(path)
                    return (path.map(\.cell), .end(o))
                }
                let fwd = nbrs.filter { $0 != prev }
                guard fwd.count == 1 else { return nil }
                prev = cur
                cur = fwd[0]
            }
            return nil
        }

        /// Clears erased nodes from the canvas; a junction that lost a branch gets its glyph back.
        mutating func applyErase() {
            let new = erased.subtracting(applied)
            for n in new {
                if n.sub == 0 {
                    g.set(n.cell, " ")
                } else {
                    let other = Node(cell: n.cell, sub: 3 - n.sub)
                    g.set(n.cell, erased.contains(other) ? " " : other.sub == 1 ? "─" : "│")
                }
                if let l = a.linkOf[n] { live[l]?.remove(n.cell) }
            }
            var fix: Set<Node> = []
            for n in new {
                for d in Dir.allCases {
                    if let m = a.neighbour(n, d), !erased.contains(m), m.sub == 0 { fix.insert(m) }
                }
            }
            for m in fix where AsciiArt.headDir(a.grid[m.cell]) == nil {
                var b = a.ports(m)
                for d in Dir.allCases where b & d.bit != 0 {
                    if let k = a.neighbour(m, d), erased.contains(k) { b &= ~d.bit }
                }
                g.set(m.cell, AsciiArt.glyph(b, rounded: a.rounded))
            }
            applied.formUnion(new)
        }

        /// An end's border cell back to plain border.
        mutating func restore(_ e: EndInfo) {
            g.set(e.border, e.toBox.horizontal ? "│" : "─")
        }

        func isFree(_ r: Rect) -> Bool {
            guard r.x >= 0, r.y >= 0 else { return false }
            if rects.contains(where: { $0.map { AsciiArt.overlaps($0, r) } ?? false }) { return false }
            return AsciiArt.cells(r).allSatisfy { g[$0] == " " }
        }

        mutating func draw(_ m: [[Character]], at r: Rect) {
            for (dy, row) in m.enumerated() {
                for (dx, ch) in row.enumerated() { g.set(Cell(x: r.x + dx, y: r.y + dy), ch) }
            }
        }

        /// Border cells a line may leave/enter `s` through on `side`.
        func border(_ s: Side, _ side: Dir) -> [Cell] {
            guard let r = rects[s.box] else { return [] }
            let cs = comps[s.box]
            let k = s.compartment.flatMap { cs.indices.contains($0) ? $0 : nil }
            switch side {
            case .up, .down:
                if let k, k != (side == .up ? 0 : cs.count - 1) { return [] }
                let y = side == .up ? r.y : r.y + r.height - 1
                return (r.x + 1..<r.x + r.width - 1).map { Cell(x: $0, y: y) }
            case .left, .right:
                let x = side == .left ? r.x : r.x + r.width - 1
                let use = k.map { [cs[$0]] } ?? cs
                return use.flatMap { c in (c.y..<c.y + c.height).map { Cell(x: x, y: $0) } }
            }
        }

        /// Routes a new line from `s` to `goal` and draws it; its cost, nil when there is no route.
        /// `reuse`: cells of the line it replaces (cheaper, so lines stay put);
        /// `prefer`: where it started and ended before (other places cost more).
        mutating func route(from s: Side, to goal: Goal, link: Int, reuse: Set<Cell>,
                            prefer: (start: Cell?, end: Cell?) = (nil, nil)) -> Int? {
            guard let sr = rects[s.box] else { return nil }
            let present = rects.compactMap { $0 }
            let W = max(g.width, present.map { $0.x + $0.width }.max() ?? 0) + 8
            let H = max(g.rows.count, present.map { $0.y + $0.height }.max() ?? 0) + 8
            let N = W * H
            var owner = [Int](repeating: -1, count: N)
            for (i, r) in rects.enumerated() {
                guard let r else { continue }
                for c in AsciiArt.cells(r) where c.x < W && c.y < H { owner[c.y * W + c.x] = i }
            }
            var goalBox = -1
            if case .box(let t) = goal { goalBox = t.box }
            var nearAny = [Bool](repeating: false, count: N), nearOther = [Bool](repeating: false, count: N)
            for y in 0..<H {
                for x in 0..<W where owner[y * W + x] < 0 {
                    for d in Dir.allCases {
                        let nx = x + d.dx, ny = y + d.dy
                        guard nx >= 0, ny >= 0, nx < W, ny < H else { continue }
                        let o = owner[ny * W + nx]
                        if o >= 0 {
                            nearAny[y * W + x] = true
                            if o != s.box && o != goalBox { nearOther[y * W + x] = true }
                        }
                    }
                }
            }
            var linksAt: [Cell: Set<Int>] = [:]
            for (l, cs) in live { for c in cs { linksAt[c, default: []].insert(l) } }
            // 0 free, 1 blocked, 2 a ─ that may be crossed vertically, 3 a │ crossed horizontally.
            var kind = [UInt8](repeating: 0, count: N)
            for y in 0..<H {
                for x in 0..<W {
                    let i = y * W + x
                    if owner[i] >= 0 { kind[i] = 1; continue }
                    let ch = g[x, y]
                    guard ch != " " else { continue }
                    kind[i] = 1
                    if let ls = linksAt[Cell(x: x, y: y)], !ls.isEmpty, !ls.contains(link), !nearAny[i] {
                        if ch == "─" { kind[i] = 2 } else if ch == "│" { kind[i] = 3 }
                    }
                }
            }

            var goalMap: [Int: Dir] = [:]
            var joinable: [Int: UInt8] = [:]
            var target: Rect
            switch goal {
            case .box(let t):
                guard let tr = rects[t.box] else { return nil }
                target = tr
                for side in Dir.allCases {
                    for c in border(t, side) where c.x < W && c.y < H { goalMap[c.y * W + c.x] = side.opposite }
                }
            case .join(let l):
                var best: (Int, Cell)? = nil
                for c in live[l] ?? [] where c.x < W && c.y < H {
                    let ch = g[c]
                    guard AsciiArt.headDir(ch) == nil, ch != "┼", let b = AsciiArt.bits(ch), b.nonzeroBitCount == 2,
                          linksAt[c]?.count == 1, !nearAny[c.y * W + c.x] else { continue }
                    joinable[c.y * W + c.x] = b
                    let dist = max(0, sr.x - c.x, c.x - (sr.x + sr.width - 1)) + max(0, sr.y - c.y, c.y - (sr.y + sr.height - 1))
                    if best == nil || (dist, c.y, c.x) < (best!.0, best!.1.y, best!.1.x) { best = (dist, c) }
                }
                guard let best else { return nil }
                target = Rect(x: best.1.x, y: best.1.y, width: 1, height: 1)
            }
            var facing: Set<Dir> = []
            if target.x > sr.x + sr.width - 1 { facing.insert(.right) }
            if target.x + target.width - 1 < sr.x { facing.insert(.left) }
            if target.y > sr.y + sr.height - 1 { facing.insert(.down) }
            if target.y + target.height - 1 < sr.y { facing.insert(.up) }
            if facing.isEmpty { facing = Set(Dir.allCases) }

            let bendCost = 40, crossCost = 60, faceCost = 120, moveCost = 12
            func stepCost(_ i: Int) -> Int {
                (reuse.contains(Cell(x: i % W, y: i / W)) ? 1 : 4) + (nearOther[i] ? 8 : nearAny[i] ? 5 : 0)
            }
            let goalHead: Bool
            if case .box(let t) = goal { goalHead = t.head } else { goalHead = false }

            var dist = [Int](repeating: .max, count: N * 4)
            var prev = [Int32](repeating: -1, count: N * 4)
            var fresh = [Bool](repeating: false, count: N * 4)
            var heap = Heap()
            for side in Dir.allCases {
                for b in border(s, side) {
                    let o = AsciiArt.step(b, side)
                    guard o.x >= 0, o.y >= 0, o.x < W, o.y < H, kind[o.y * W + o.x] == 0 else { continue }
                    let st = (o.y * W + o.x) * 4 + side.rawValue
                    let c = (facing.contains(side) ? 0 : faceCost) + stepCost(o.y * W + o.x)
                        + (prefer.start.map { $0 == o ? 0 : moveCost } ?? 0)
                    if c < dist[st] {
                        dist[st] = c
                        fresh[st] = true
                        heap.push(c << 32 | st)
                    }
                }
            }
            var best: (cost: Int, st: Int, d: Dir)? = nil
            while let top = heap.pop() {
                let c = top >> 32, st = top & 0xffff_ffff
                guard c == dist[st] else { continue }
                if let b = best, c >= b.cost { break }
                let p = st / 4, d = Dir(rawValue: st % 4)!
                let px = p % W, py = p / W
                let straight = kind[p] >= 2 || (fresh[st] && s.head)
                for d2 in Dir.allCases where d2 != d.opposite && (!straight || d2 == d) {
                    let qx = px + d2.dx, qy = py + d2.dy
                    guard qx >= 0, qy >= 0, qx < W, qy < H else { continue }
                    let q = qy * W + qx
                    let bend = d2 != d ? bendCost : 0
                    if kind[p] == 0 {
                        var finish = false
                        var extra = 0
                        if let need = goalMap[q], need == d2, !(goalHead && d2 != d) {
                            finish = true
                            if let e = prefer.end, e != Cell(x: px, y: py) { extra = moveCost }
                        }
                        if let jb = joinable[q], jb & d2.opposite.bit == 0 {
                            finish = true
                            if routed.contains(Cell(x: qx, y: qy)) { extra += 30 }
                            if let e = prefer.end, e != Cell(x: qx, y: qy) { extra += moveCost }
                        }
                        if finish {
                            let fc = c + bend + 1 + extra
                            if best == nil || fc < best!.cost { best = (fc, st, d2) }
                            continue
                        }
                    }
                    let nk = kind[q]
                    guard nk == 0 || (nk == 2 && !d2.horizontal) || (nk == 3 && d2.horizontal) else { continue }
                    let nc = c + bend + stepCost(q) + (nk >= 2 ? crossCost : 0)
                    let ns = q * 4 + d2.rawValue
                    if nc < dist[ns] {
                        dist[ns] = nc
                        prev[ns] = Int32(st)
                        fresh[ns] = false
                        heap.push(nc << 32 | ns)
                    }
                }
            }
            guard let best else { return nil }

            var states: [Int] = []
            var st = best.st
            while st >= 0 {
                states.append(st)
                st = Int(prev[st])
            }
            states.reverse()
            let path = states.map { Cell(x: ($0 / 4) % W, y: ($0 / 4) / W) }
            let dirs = states.map { Dir(rawValue: $0 % 4)! }
            for (i, c) in path.enumerated() {
                let into = dirs[i], out = i + 1 < dirs.count ? dirs[i + 1] : best.d
                let ch: Character
                if kind[c.y * W + c.x] >= 2 {
                    ch = "┼"
                } else if i == 0 && s.head {
                    ch = into.opposite.head
                } else if i == path.count - 1 && goalHead {
                    ch = out.head
                } else {
                    ch = AsciiArt.glyph(into.opposite.bit | out.bit, rounded: a.rounded)
                }
                g.set(c, ch)
                live[link, default: []].insert(c)
                routed.insert(c)
            }
            if s.glyph && !s.head { g.set(AsciiArt.step(path[0], dirs[0].opposite), dirs[0].exit) }
            let end = AsciiArt.step(path[path.count - 1], best.d)
            switch goal {
            case .box(let t):
                if t.glyph && !t.head { g.set(end, best.d.opposite.exit) }
            case .join:
                g.set(end, AsciiArt.glyph(AsciiArt.bits(g[end])! | best.d.opposite.bit, rounded: a.rounded))
            }
            lastPath = path
            return best.cost
        }
    }

    /// Erases box `id` and its line branches, draws `content` at `rect` and
    /// routes every branch again (simple links to their other box, bus
    /// branches back onto the rest of the bus).
    fileprivate static func relayout(_ id: Int, to r: Rect, content: [[Character]], in s: Scene) -> Edit? {
        let a = Analysis(Grid(s.text))
        guard a.boxes.indices.contains(id), a.boxes.count == s.boxes.count, r.x >= 0, r.y >= 0 else { return nil }
        var ed = Editor(a)
        var jobs: [(link: Int, me: EndInfo, to: EndInfo?, old: [Cell], end: Cell)] = []
        for (li, ends) in a.ends.enumerated() {
            for e in ends where e.end.box == id {
                guard !ed.erased.contains(e.node), let w = ed.walk(e, link: li) else { return nil }
                switch w.to {
                case .end(let o): jobs.append((li, e, o, w.path, o.end.cell))
                case .junction(let j): jobs.append((li, e, nil, w.path, j))
                }
            }
        }
        ed.applyErase()
        for j in jobs { if let o = j.to, o.glyph { ed.restore(o) } }
        for c in cells(a.boxes[id].rect) { ed.g.set(c, " ") }
        ed.rects[id] = nil
        guard ed.isFree(r) else { return nil }
        ed.draw(content, at: r)
        ed.rects[id] = r
        ed.comps[id] = compartments(r) { x, y in
            let dy = y - r.y, dx = x - r.x
            return dy >= 0 && dy < content.count && dx >= 0 && dx < content[dy].count ? content[dy][dx] : " "
        }
        guard ed.comps[id].count == a.boxes[id].compartments.count else { return nil }
        let order = { (j: (link: Int, me: EndInfo, to: EndInfo?, old: [Cell], end: Cell)) in
            (j.to == nil ? 1 : 0, j.me.end.cell.y, j.me.end.cell.x)
        }
        jobs.sort { order($0) < order($1) }
        let simple = jobs.filter { $0.to != nil }, joins = jobs.filter { $0.to == nil }
        let old = a.scene(s.text)
        let rename = [id: key(r)]
        // Lines are routed one after another, so the order matters (an early
        // line may force a later one around it): try a few, keep the cheapest.
        var best: (cost: Int, edit: Edit)? = nil
        for (flipSimple, flipJoins) in [(false, false), (true, false), (false, true), (true, true)] {
            if (flipSimple && simple.count < 2) || (flipJoins && joins.count < 2) { continue }
            var e = ed
            var total = 0
            for j in (flipSimple ? simple.reversed() : simple) + (flipJoins ? joins.reversed() : joins) {
                let me = Side(box: id, compartment: j.me.compartment, head: j.me.end.head, glyph: j.me.glyph)
                let goal: Goal = j.to.map { .box(Side(box: $0.end.box, compartment: $0.compartment, head: $0.end.head, glyph: $0.glyph)) }
                    ?? .join(j.link)
                guard let c = e.route(from: me, to: goal, link: j.link, reuse: Set(j.old),
                                      prefer: (follow(j.me.end.cell, from: a.boxes[id].rect, to: r), j.end)) else {
                    total = -1
                    break
                }
                total += c
            }
            guard total >= 0, best == nil || total < best!.cost,
                  let ns = scan(e.g.text()),
                  boxKeys(ns) == boxKeys(old, rename: rename),
                  signature(ns, comps: true) == signature(old, rename: rename, comps: true),
                  let nid = ns.boxes.firstIndex(where: { $0.rect == r }),
                  ns.boxes[nid].compartments.count == old.boxes[id].compartments.count else { continue }
            best = (total, Edit(scene: ns, box: nid, link: nil))
        }
        return best?.edit
    }

    /// Where an end cell next to `old` sits next to `new`: same side, same
    /// offset from the side's start.
    fileprivate static func follow(_ c: Cell, from old: Rect, to new: Rect) -> Cell {
        let ox2 = old.x + old.width - 1, oy2 = old.y + old.height - 1
        let nx2 = new.x + new.width - 1, ny2 = new.y + new.height - 1
        if c.x < old.x { return Cell(x: new.x - 1, y: c.y - old.y + new.y) }
        if c.x > ox2 { return Cell(x: nx2 + 1, y: c.y - old.y + new.y) }
        if c.y < old.y { return Cell(x: c.x - old.x + new.x, y: new.y - 1) }
        if c.y > oy2 { return Cell(x: c.x - old.x + new.x, y: ny2 + 1) }
        return c
    }

    // MARK: - Checks

    /// Every edit is checked against the scene it should produce: same boxes
    /// (but the edited one) and the same links box to box, compartment to
    /// compartment, so an edit never silently changes what the art means.
    fileprivate static func key(_ r: Rect) -> String { "\(r.x),\(r.y),\(r.width)x\(r.height)" }

    fileprivate static func boxKeys(_ s: Scene, rename: [Int: String] = [:]) -> [String] {
        s.boxes.map { rename[$0.id] ?? key($0.rect) }.sorted()
    }

    fileprivate static func compartmentIndex(_ b: Box, _ c: Cell) -> Int {
        if c.y < b.rect.y { return 0 }
        if c.y >= b.rect.y + b.rect.height { return b.compartments.count - 1 }
        return b.compartments.firstIndex { c.y >= $0.y && c.y < $0.y + $0.height } ?? -1
    }

    fileprivate static func linkSignature(_ s: Scene, _ l: Link, rename: [Int: String] = [:], drop: Int? = nil, comps: Bool) -> String {
        l.ends.filter { $0.box != drop }.map { e in
            (rename[e.box] ?? key(s.boxes[e.box].rect)) + (e.head ? ">" : "-")
                + (comps ? "#\(compartmentIndex(s.boxes[e.box], e.cell))" : "")
        }.sorted().joined(separator: "|")
    }

    fileprivate static func signature(_ s: Scene, rename: [Int: String] = [:], drop: Int? = nil, comps: Bool) -> [String] {
        s.links.filter { l in l.ends.filter { $0.box != drop }.count >= 2 }
            .map { linkSignature(s, $0, rename: rename, drop: drop, comps: comps) }.sorted()
    }

    fileprivate static func emptyScene(_ text: String, boxes: Int) -> Scene? {
        boxes == 0 ? Scene(text: text, boxes: [], links: []) : nil
    }

    /// Binary min-heap of packed (priority << 32 | state) keys.
    fileprivate struct Heap {
        var items: [Int] = []
        mutating func push(_ v: Int) {
            items.append(v)
            var i = items.count - 1
            while i > 0 {
                let p = (i - 1) / 2
                if items[p] <= items[i] { break }
                items.swapAt(p, i)
                i = p
            }
        }
        mutating func pop() -> Int? {
            guard let first = items.first else { return nil }
            let last = items.removeLast()
            if items.isEmpty { return first }
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count && items[l] < items[m] { m = l }
                if r < items.count && items[r] < items[m] { m = r }
                if m == i { break }
                items.swapAt(m, i)
                i = m
            }
            return first
        }
    }
}
