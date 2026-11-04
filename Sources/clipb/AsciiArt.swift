import Foundation

/// Hand-drawn box art, edited in place: an edit rewrites only the cells of
/// what it touches, so the rest of the drawing stays exactly as drawn.
///
/// `AsciiDiagram` owns drawings ClipB rendered itself (it re-renders them
/// whole); this reads any box-drawing art: boxes are closed rectangles in any
/// style of the style guide (light ┌┐└┘, heavy, double, rounded, dashed,
/// dotted, block; optionally split into compartments by ├──┤ rows), links
/// are connected line glyphs (any line style) whose ends touch a box. Everything else is free text and is
/// never touched. Pure (Foundation only), tested.
enum AsciiArt {
    typealias Cell = AsciiDiagram.Cell
    typealias Rect = AsciiDiagram.Rect

    /// `compartments`: interior rects, top to bottom. `style`: nil for a
    /// shape the model has no style for (block, dot corners).
    struct Box: Equatable {
        var id: Int; var rect: Rect; var compartments: [Rect]
        var style: AsciiDiagram.BoxStyle? = .light
    }
    /// `cell`: the line cell touching the box (a head cell when `head`).
    struct End: Equatable { var box: Int; var cell: Cell; var head: Bool }
    /// One connected line component (may be a tree/bus); `line`: the style
    /// most of its strokes show.
    struct Link: Equatable {
        var id: Int; var cells: Set<Cell>; var ends: [End]
        var line: AsciiDiagram.LineStyle = .solid
    }
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
        return relayout(box, to: rect, content: frame(rect.width, heights, interiors, glyphs(of: box, in: g)), in: s)
    }

    static func addBox(_ rect: Rect, text: [String], in s: Scene) -> Edit? {
        let lines = text.flatMap { $0.components(separatedBy: "\n") }
        let w = max(rect.width, (lines.map(\.count).max() ?? 0) + 4, 3)
        let h = max(rect.height, lines.count + 2, 3)
        let r = Rect(x: rect.x, y: rect.y, width: w, height: h)
        guard r.x >= 0, r.y >= 0 else { return nil }
        var ed = Editor(Analysis(Grid(s.text)))
        guard ed.isFree(r) else { return nil }
        ed.draw(frame(w, [h - 2], [lines.map { Array(" " + $0) }], AsciiDiagram.BoxStyle.light.glyphs), at: r)
        let old = ed.a.scene(s.text)
        guard let ns = scan(ed.g.text()),
              boxKeys(ns) == (boxKeys(old) + [key(r)]).sorted(),
              signature(ns, comps: true) == signature(old, comps: true),
              let id = ns.boxes.firstIndex(where: { $0.rect == r }) else { return nil }
        return Edit(scene: ns, box: id, link: nil)
    }

    /// New arrow, head at `to`; `fromSide`/`toSide` pin the side of each
    /// box it leaves and enters through (nil: the router picks).
    static func connect(_ from: Int, to: Int, fromSide: CanvasDrawing.Side? = nil, toSide: CanvasDrawing.Side? = nil,
                        in s: Scene) -> Edit? {
        let a = Analysis(Grid(s.text))
        guard from != to, a.boxes.indices.contains(from), a.boxes.indices.contains(to) else { return nil }
        // Match the art: exit glyphs on the source border only if most ends use them.
        let tails = a.ends.joined().filter { !$0.end.head }
        let glyph = tails.filter(\.glyph).count * 2 > tails.count
        var ed = Editor(a)
        guard ed.route(from: Side(box: from, compartment: nil, head: false, glyph: glyph, only: fromSide.map(Dir.init)),
                       to: .box(Side(box: to, compartment: nil, head: true, glyph: false, only: toSide.map(Dir.init))),
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
        let content = frame(w + 2, heights, interiors, glyphs(of: box, in: g))
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

    /// Redraws the box's border (dividers included) in `style`; its text and
    /// lines stay. Tees stay where lines leave; coming from a style without
    /// tees, tails get them when most tails in the art have them.
    static func restyleBox(_ id: Int, to style: AsciiDiagram.BoxStyle, in s: Scene) -> Edit? {
        let a = Analysis(Grid(s.text))
        guard a.boxes.indices.contains(id), a.boxes.count == s.boxes.count else { return nil }
        let info = a.boxes[id], gl = style.glyphs, r = info.rect
        let x2 = r.x + r.width - 1, y2 = r.y + r.height - 1
        let addTees = info.glyphs.tees == nil && usesTees(a)
        var teeAt: [Cell: Int] = [:]
        for e in a.ends.joined() where e.end.box == id && (e.glyph || (addTees && !e.end.head)) {
            teeAt[e.border] = e.toBox.opposite.rawValue
        }
        var ed = Editor(a)
        func put(_ c: Cell, _ side: Int) { ed.g.set(c, teeAt[c].flatMap { gl.tees?[$0] } ?? gl.side(side)) }
        ed.g.set(Cell(x: r.x, y: r.y), gl.topLeft)
        ed.g.set(Cell(x: x2, y: r.y), gl.topRight)
        ed.g.set(Cell(x: r.x, y: y2), gl.bottomLeft)
        ed.g.set(Cell(x: x2, y: y2), gl.bottomRight)
        for x in r.x + 1..<x2 {
            put(Cell(x: x, y: r.y), 3)
            put(Cell(x: x, y: y2), 1)
        }
        let dividers = Set(info.compartments.dropFirst().map { $0.y - 1 })
        for y in r.y + 1..<y2 {
            if dividers.contains(y) {
                ed.g.set(Cell(x: r.x, y: y), gl.tees?[0] ?? gl.left)
                ed.g.set(Cell(x: x2, y: y), gl.tees?[2] ?? gl.right)
                for x in r.x + 1..<x2 { ed.g.set(Cell(x: x, y: y), gl.top) }
            } else {
                put(Cell(x: r.x, y: y), 2)
                put(Cell(x: x2, y: y), 0)
            }
        }
        let old = a.scene(s.text)
        guard let ns = scan(ed.g.text()), boxKeys(ns) == boxKeys(old),
              signature(ns, comps: true) == signature(old, comps: true),
              let nid = ns.boxes.firstIndex(where: { $0.rect == r }), ns.boxes[nid].style == style,
              ns.boxes[nid].compartments.count == info.compartments.count else { return nil }
        return Edit(scene: ns, box: nid, link: nil)
    }

    /// Redraws the link's line glyphs in `line`; heads and box borders stay,
    /// crossings keep the other stroke's weight.
    static func restyleLink(_ id: Int, to line: AsciiDiagram.LineStyle, in s: Scene) -> Edit? {
        let a = Analysis(Grid(s.text))
        guard a.links.indices.contains(id) else { return nil }
        var ed = Editor(a)
        for n in a.nodes[id] {
            let ch = ed.g[n.cell]
            if headDir(ch) != nil { continue }
            if n.sub != 0 {
                guard let g = AsciiDiagram.lineGlyphs[ch] else { return nil }
                ed.g.set(n.cell, AsciiDiagram.crossing(n.sub == 1 ? line.weight : g.hWeight, n.sub == 2 ? line.weight : g.vWeight))
            } else {
                ed.g.set(n.cell, glyph(a.ports(n), line: line, rounded: a.linkRounded[id]))
            }
        }
        let old = a.scene(s.text)
        guard let ns = scan(ed.g.text()), boxKeys(ns) == boxKeys(old),
              signature(ns, comps: true) == signature(old, comps: true),
              let link = ns.links.first(where: { $0.cells == old.links[id].cells }) else { return nil }
        return Edit(scene: ns, box: nil, link: link.id)
    }

    /// A two-ended link's heads, cycled: forward → backward → both → none →
    /// forward, "forward" pointing at the later box in reading order. nil
    /// for a bus, or when an end that gets a head isn't straight.
    static func cycleHeads(_ id: Int, in s: Scene) -> Edit? {
        let a = Analysis(Grid(s.text))
        guard a.links.indices.contains(id), a.ends[id].count == 2 else { return nil }
        let ends = a.ends[id].sorted { $0.end.box < $1.end.box }
        guard ends[0].end.box != ends[1].end.box else { return nil }
        let want: [Bool]
        switch (ends[0].end.head, ends[1].end.head) {
        case (false, true): want = [true, false]
        case (true, false): want = [true, true]
        case (true, true): want = [false, false]
        case (false, false): want = [false, true]
        }
        let tails = ends.filter { !$0.end.head && a.boxes[$0.end.box].glyphs.tees != nil }
        let tees = tails.isEmpty ? usesTees(a) : tails.contains(where: \.glyph)
        var ed = Editor(a)
        for (e, head) in zip(ends, want) where e.end.head != head {
            guard e.node.sub == 0 else { return nil }
            let axis = e.toBox.bit | e.toBox.opposite.bit
            if head {
                guard a.ports(e.node) == axis else { return nil }
                ed.g.set(e.end.cell, e.toBox.head)
                if e.glyph { ed.restore(e) }
            } else {
                ed.g.set(e.end.cell, glyph(axis, line: a.links[id].line, rounded: true))
                if tees, let t = a.boxes[e.end.box].glyphs.tees { ed.g.set(e.border, t[e.toBox.opposite.rawValue]) }
            }
        }
        let old = a.scene(s.text)
        var link = old.links[id]
        for k in link.ends.indices {
            if let i = ends.firstIndex(where: { $0.end == link.ends[k] }) { link.ends[k].head = want[i] }
        }
        var expected = signature(old, comps: true)
        guard let i = expected.firstIndex(of: linkSignature(old, old.links[id], comps: true)) else { return nil }
        expected[i] = linkSignature(old, link, comps: true)
        guard let ns = scan(ed.g.text()), boxKeys(ns) == boxKeys(old), signature(ns, comps: true) == expected.sorted(),
              let nl = ns.links.first(where: { $0.cells == old.links[id].cells }) else { return nil }
        return Edit(scene: ns, box: nil, link: nl.id)
    }

    /// Lines leave boxes through tees (the style guide's way) unless most
    /// tails on boxes that have tees in their style are drawn without.
    fileprivate static func usesTees(_ a: Analysis) -> Bool {
        let tails = a.ends.joined().filter { !$0.end.head && a.boxes[$0.end.box].glyphs.tees != nil }
        return tails.isEmpty || tails.filter(\.glyph).count * 2 > tails.count
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
        init(_ side: CanvasDrawing.Side) {
            switch side {
            case .right: self = .right
            case .bottom: self = .down
            case .left: self = .left
            case .top: self = .up
            }
        }
    }

    fileprivate static func step(_ c: Cell, _ d: Dir) -> Cell { Cell(x: c.x + d.dx, y: c.y + d.dy) }

    /// Ports: right 1, down 2, left 4, up 8. A head's one port faces back along its line.
    fileprivate static func bits(_ c: Character) -> UInt8? {
        if let g = AsciiDiagram.lineGlyphs[c] { return g.bits }
        switch c {
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

    fileprivate static func glyph(_ b: UInt8, line: AsciiDiagram.LineStyle, rounded: Bool) -> Character {
        AsciiDiagram.lineGlyph(b, h: line, v: line, rounded: rounded)
    }

    /// The style a line glyph shows (its weight when that is all it tells).
    fileprivate static func lineStyle(of c: Character) -> AsciiDiagram.LineStyle {
        guard let g = AsciiDiagram.lineGlyphs[c] else { return .solid }
        return g.h ?? g.v ?? AsciiDiagram.inferredStyle([(nil, max(g.hWeight, g.vWeight))])
    }

    static let crossings: Set<Character> = ["┼", "┿", "╂", "╋", "╪", "╫", "╬"]

    /// Every box shape scan knows; the first whose rectangle closes wins.
    fileprivate static let boxShapes: [(style: AsciiDiagram.BoxStyle?, glyphs: AsciiDiagram.BoxGlyphs)] =
        AsciiDiagram.BoxStyle.allCases.map { ($0, $0.glyphs) } + AsciiDiagram.BoxGlyphs.artOnly.map { (nil, $0) }

    /// Tee glyphs of any style for a line leaving through the side facing `d`, crossings too.
    fileprivate static func tees(_ d: Dir) -> Set<Character> {
        Set([AsciiDiagram.BoxGlyphs.lightTees, AsciiDiagram.BoxGlyphs.heavyTees, AsciiDiagram.BoxGlyphs.doubleTees].map { $0[d.rawValue] })
            .union(crossings)
    }

    /// The glyphs of the box at `id` as scanned from `g`.
    fileprivate static func glyphs(of id: Int, in g: Grid) -> AsciiDiagram.BoxGlyphs {
        let a = Analysis(g)
        return a.boxes.indices.contains(id) ? a.boxes[id].glyphs : AsciiDiagram.BoxStyle.light.glyphs
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

    /// Interior rects between the divider rows (├──┤, in the box's style)
    /// of the box at `r`.
    fileprivate static func compartments(_ r: Rect, _ gl: AsciiDiagram.BoxGlyphs, at: (Int, Int) -> Character) -> [Rect] {
        let x2 = r.x + r.width - 1, y2 = r.y + r.height - 1
        let left = gl.tees?[0] ?? gl.left, right = gl.tees?[2] ?? gl.right
        var result: [Rect] = []
        var start = r.y + 1
        for y in r.y + 1..<y2 where at(r.x, y) == left && at(x2, y) == right && (r.x + 1..<x2).allSatisfy({ at($0, y) == gl.top }) {
            result.append(Rect(x: r.x + 1, y: start, width: r.width - 2, height: y - start))
            start = y + 1
        }
        result.append(Rect(x: r.x + 1, y: start, width: r.width - 2, height: y2 - start))
        return result
    }

    /// A box drawn fresh: heights per compartment, interiors padded/cut to the width.
    fileprivate static func frame(_ w: Int, _ heights: [Int], _ interiors: [[[Character]]], _ gl: AsciiDiagram.BoxGlyphs) -> [[Character]] {
        let n = max(0, w - 2)
        var m: [[Character]] = [[gl.topLeft] + Array(repeating: gl.top, count: n) + [gl.topRight]]
        for (k, h) in heights.enumerated() {
            if k > 0 { m.append([gl.tees?[0] ?? gl.left] + Array(repeating: gl.top, count: n) + [gl.tees?[2] ?? gl.right]) }
            for i in 0..<max(0, h) {
                var row = k < interiors.count && i < interiors[k].count ? interiors[k][i] : []
                if row.count > w - 2 { row = Array(row.prefix(w - 2)) }
                row += Array(repeating: " ", count: w - 2 - row.count)
                m.append([gl.left] + row + [gl.right])
            }
        }
        m.append([gl.bottomLeft] + Array(repeating: gl.bottom, count: n) + [gl.bottomRight])
        return m
    }

    // MARK: - Analysis

    fileprivate struct BoxInfo {
        var rect: Rect; var compartments: [Rect]
        var style: AsciiDiagram.BoxStyle?; var glyphs: AsciiDiagram.BoxGlyphs
    }

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
        /// Per link: light bends drawn rounded (╭) rather than square (┌).
        var linkRounded: [Bool] = []

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
            for y in g.rows.indices {
                for x in g.rows[y].indices where box(at: Cell(x: x, y: y)) == nil {
                    for shape in AsciiArt.boxShapes where shape.glyphs.topLeft == g.rows[y][x] {
                        let gl = shape.glyphs, tees = gl.tees ?? []
                        let top = Set([gl.top] + tees).union(AsciiArt.crossings), bottom = Set([gl.bottom] + tees).union(AsciiArt.crossings)
                        let left = Set([gl.left] + tees).union(AsciiArt.crossings), right = Set([gl.right] + tees).union(AsciiArt.crossings)
                        var x2 = x + 1
                        while top.contains(g[x2, y]) { x2 += 1 }
                        guard g[x2, y] == gl.topRight, x2 - x >= 2 else { continue }
                        var y2 = y + 1
                        while left.contains(g[x, y2]) && right.contains(g[x2, y2]) { y2 += 1 }
                        guard y2 - y >= 2, g[x, y2] == gl.bottomLeft, g[x2, y2] == gl.bottomRight,
                              (x + 1..<x2).allSatisfy({ bottom.contains(g[$0, y2]) }) else { continue }
                        let r = Rect(x: x, y: y, width: x2 - x + 1, height: y2 - y + 1)
                        guard !boxes.contains(where: { AsciiArt.overlaps($0.rect, r) }) else { continue }
                        let id = boxes.count
                        boxes.append(BoxInfo(rect: r, compartments: AsciiArt.compartments(r, gl) { g[$0, $1] }, style: shape.style, glyphs: gl))
                        for c in AsciiArt.cells(r) { boxAt[c.y * width + c.x] = id }
                        break
                    }
                }
            }
        }

        func isLine(_ c: Cell) -> Bool { AsciiArt.bits(grid[c]) != nil && box(at: c) == nil }

        func ports(_ n: Node) -> UInt8 { n.sub == 1 ? 5 : n.sub == 2 ? 10 : AsciiArt.bits(grid[n.cell]) ?? 0 }

        /// The node at `c` that has a port facing `d`.
        func node(at c: Cell, port d: Dir) -> Node? {
            guard isLine(c) else { return nil }
            let ch = grid[c]
            if AsciiArt.crossings.contains(ch) { return Node(cell: c, sub: d.horizontal ? 1 : 2) }
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
            let glyph = !corner && AsciiArt.tees(d.opposite).contains(grid[m])
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
                    if AsciiArt.crossings.contains(grid[c]) {
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
                // The style most of its strokes show; their weight when none tells.
                var counts: [AsciiDiagram.LineStyle: Int] = [:]
                var weights: [(exact: AsciiDiagram.LineStyle?, weight: Int)] = []
                var round = 0, square = 0
                for n in c.nodes {
                    let ch = grid[n.cell]
                    guard let g = AsciiDiagram.lineGlyphs[ch] else { continue }
                    if "╭╮╰╯".contains(ch) { round += 1 } else if "┌┐└┘".contains(ch) { square += 1 }
                    let stroke: AsciiDiagram.LineStyle? = n.sub == 1 ? g.h : n.sub == 2 ? g.v : g.bits == 5 ? g.h : g.bits == 10 ? g.v : nil
                    if let stroke { counts[stroke, default: 0] += 1 }
                    weights.append((nil, n.sub == 1 ? g.hWeight : n.sub == 2 ? g.vWeight : max(g.hWeight, g.vWeight)))
                }
                let line = counts.max { ($0.value, -$0.key.rawValue) < ($1.value, -$1.key.rawValue) }?.key
                    ?? AsciiDiagram.inferredStyle(weights)
                links.append(Link(id: i, cells: c.cells, ends: c.ends.map(\.end), line: line))
                linkRounded.append(round > 0 ? true : square > 0 ? false : rounded)
                ends.append(c.ends)
                nodes.append(c.nodes)
                for n in c.nodes { linkOf[n] = i }
            }
        }

        func scene(_ text: String) -> Scene {
            Scene(text: text, boxes: boxes.enumerated().map {
                Box(id: $0.offset, rect: $0.element.rect, compartments: $0.element.compartments, style: $0.element.style)
            },
                  links: links)
        }

        /// The box's cells, outward attachment glyphs put back to plain border.
        func content(of b: Int) -> [[Character]] {
            let r = boxes[b].rect
            var m = AsciiArt.rows(of: r, in: grid)
            let w = r.width, h = r.height, gl = boxes[b].glyphs
            for x in 1..<w - 1 {
                if AsciiArt.tees(.up).contains(m[0][x]) { m[0][x] = gl.top }
                if AsciiArt.tees(.down).contains(m[h - 1][x]) { m[h - 1][x] = gl.bottom }
            }
            for y in 1..<h - 1 {
                if AsciiArt.tees(.left).contains(m[y][0]) { m[y][0] = gl.left }
                if AsciiArt.tees(.right).contains(m[y][w - 1]) { m[y][w - 1] = gl.right }
            }
            return m
        }
    }

    // MARK: - Editing

    /// `only`: the one side of the box a line may use (nil: any).
    fileprivate struct Side { var box: Int; var compartment: Int?; var head: Bool; var glyph: Bool; var only: Dir? = nil }
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
                    let line = a.linkOf[other].map { a.links[$0].line } ?? .solid
                    g.set(n.cell, erased.contains(other) ? " " : other.sub == 1 ? line.horizontal : line.vertical)
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
                let l = a.linkOf[m]
                g.set(m.cell, AsciiArt.glyph(b, line: AsciiArt.lineStyle(of: a.grid[m.cell]), rounded: l.map { a.linkRounded[$0] } ?? a.rounded))
            }
            applied.formUnion(new)
        }

        /// An end's border cell back to plain border.
        mutating func restore(_ e: EndInfo) {
            g.set(e.border, a.boxes[e.end.box].glyphs.side(e.toBox.opposite.rawValue))
        }

        func boxGlyphs(_ b: Int) -> AsciiDiagram.BoxGlyphs {
            a.boxes.indices.contains(b) ? a.boxes[b].glyphs : AsciiDiagram.BoxStyle.light.glyphs
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
                            prefer: (start: Cell?, end: Cell?) = (nil, nil),
                            line: AsciiDiagram.LineStyle = .solid, rounded: Bool? = nil) -> Int? {
            let rounded = rounded ?? a.rounded
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
                        let b = AsciiDiagram.lineGlyphs[ch]?.bits
                        if b == 5 { kind[i] = 2 } else if b == 10 { kind[i] = 3 }
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
                for side in Dir.allCases where t.only == nil || t.only == side {
                    for c in border(t, side) where c.x < W && c.y < H { goalMap[c.y * W + c.x] = side.opposite }
                }
            case .join(let l):
                var best: (Int, Cell)? = nil
                for c in live[l] ?? [] where c.x < W && c.y < H {
                    let ch = g[c]
                    guard AsciiArt.headDir(ch) == nil, !AsciiArt.crossings.contains(ch), let b = AsciiArt.bits(ch), b.nonzeroBitCount == 2,
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
            for side in Dir.allCases where s.only == nil || s.only == side {
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
                if kind[c.y * W + c.x] >= 2, let crossed = AsciiDiagram.lineGlyphs[g[c]] {
                    ch = into.horizontal ? AsciiDiagram.crossing(line.weight, crossed.vWeight) : AsciiDiagram.crossing(crossed.hWeight, line.weight)
                } else if i == 0 && s.head {
                    ch = into.opposite.head
                } else if i == path.count - 1 && goalHead {
                    ch = out.head
                } else {
                    ch = AsciiArt.glyph(into.opposite.bit | out.bit, line: line, rounded: rounded)
                }
                g.set(c, ch)
                live[link, default: []].insert(c)
                routed.insert(c)
            }
            if s.glyph && !s.head, let tees = boxGlyphs(s.box).tees { g.set(AsciiArt.step(path[0], dirs[0].opposite), tees[dirs[0].rawValue]) }
            let end = AsciiArt.step(path[path.count - 1], best.d)
            switch goal {
            case .box(let t):
                if t.glyph && !t.head, let tees = boxGlyphs(t.box).tees { g.set(end, tees[best.d.opposite.rawValue]) }
            case .join:
                g.set(end, AsciiArt.glyph(AsciiArt.bits(g[end])! | best.d.opposite.bit, line: AsciiArt.lineStyle(of: g[end]), rounded: rounded))
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
        ed.comps[id] = compartments(r, a.boxes[id].glyphs) { x, y in
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
                                      prefer: (follow(j.me.end.cell, from: a.boxes[id].rect, to: r), j.end),
                                      line: a.links[j.link].line, rounded: a.linkRounded[j.link]) else {
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

// MARK: - Segments

extension AsciiArt {
    /// A straight run of a link between two bends (or a bend and an end),
    /// those cells included, in reading order.
    struct Run: Equatable { var link: Int; var cells: [Cell]; var horizontal: Bool }

    /// The run through `c`; on a bend or a tee, the longer of its two runs.
    static func run(at c: Cell, in s: Scene) -> Run? {
        let a = Analysis(Grid(s.text))
        guard a.isLine(c) else { return nil }
        let crossing = crossings.contains(a.grid[c])
        var best: (run: Run, both: Bool)? = nil
        for horizontal in [true, false] {
            let node = crossing ? Node(cell: c, sub: horizontal ? 1 : 2) : Node(cell: c, sub: 0)
            let fwd: Dir = horizontal ? .right : .down
            let axis = fwd.bit | fwd.opposite.bit
            let ports = a.ports(node)
            guard let link = a.linkOf[node], ports & axis != 0 else { continue }
            var cells = [c]
            for d in [fwd, fwd.opposite] {
                var cur = node
                while cells.count <= a.nodes[link].count, let next = a.neighbour(cur, d) {
                    cells.append(next.cell)
                    cur = next
                }
            }
            cells.sort { horizontal ? $0.x < $1.x : $0.y < $1.y }
            let both = ports & axis == axis
            if best == nil || cells.count > best!.run.cells.count || (cells.count == best!.run.cells.count && both && !best!.both) {
                best = (Run(link: link, cells: cells, horizontal: horizontal), both)
            }
        }
        return best?.run
    }

    /// The run moved `offset` cells across itself (+ right/down). The runs
    /// branching off it (bends, tees) stretch or shrink along their own
    /// axis; an end on a box side slides along that side (never onto a
    /// corner or another line's tee), its tee going with it. nil when it
    /// would overlap anything, collapse a branch, or change what connects.
    static func moveRun(_ cells: [Cell], horizontal: Bool, by offset: Int, in s: Scene) -> Scene? {
        guard !cells.isEmpty else { return nil }
        if offset == 0 { return s }
        let a = Analysis(Grid(s.text))
        guard a.boxes.count == s.boxes.count else { return nil }
        let along: Dir = horizontal ? .right : .down
        let m: Dir = horizontal ? (offset > 0 ? .down : .up) : (offset > 0 ? .right : .left)
        let n = abs(offset)
        let axis = along.bit | along.opposite.bit, perp = m.bit | m.opposite.bit
        let perpSub: UInt8 = horizontal ? 2 : 1
        func shift(_ c: Cell, _ d: Dir, _ k: Int) -> Cell { Cell(x: c.x + d.dx * k, y: c.y + d.dy * k) }

        let cells = cells.sorted { horizontal ? $0.x < $1.x : $0.y < $1.y }
        var nodes: [Node] = []
        for c in cells {
            guard a.isLine(c) else { return nil }
            nodes.append(crossings.contains(a.grid[c]) ? Node(cell: c, sub: horizontal ? 1 : 2) : Node(cell: c, sub: 0))
        }
        guard let link = a.linkOf[nodes[0]], nodes.allSatisfy({ a.linkOf[$0] == link }) else { return nil }
        for i in nodes.indices.dropFirst() { guard a.neighbour(nodes[i - 1], along) == nodes[i] else { return nil } }
        // The whole run, from bend to bend: a piece of it can't move alone.
        guard a.neighbour(nodes[0], along.opposite) == nil, a.neighbour(nodes[nodes.count - 1], along) == nil else { return nil }
        let style = a.links[link].line

        func free(_ c: Cell) -> Bool { c.x >= 0 && c.y >= 0 && a.box(at: c) == nil && a.grid[c] == " " }
        /// Another line's straight stroke this one may cross: the crossing glyph.
        func crossing(_ c: Cell, strokeHorizontal: Bool) -> Character? {
            guard a.isLine(c), let gl = AsciiDiagram.lineGlyphs[a.grid[c]],
                  let other = a.linkOf[Node(cell: c, sub: 0)], other != link else { return nil }
            if strokeHorizontal && gl.bits == 10 { return AsciiDiagram.crossing(style.weight, gl.vWeight) }
            if !strokeHorizontal && gl.bits == 5 { return AsciiDiagram.crossing(gl.hWeight, style.weight) }
            return nil
        }
        /// A crossing cell without one of its strokes: the other one, straight.
        func remaining(_ c: Cell, leaving sub: UInt8) -> Character {
            let other = Node(cell: c, sub: 3 - sub)
            let os = a.linkOf[other].map { a.links[$0].line } ?? .solid
            return other.sub == 1 ? os.horizontal : os.vertical
        }

        var writes: [Cell: Character] = [:]
        // The run leaves its cells.
        for node in nodes { writes[node.cell] = node.sub != 0 ? remaining(node.cell, leaving: node.sub) : " " }
        // Branches stretch or shrink.
        var consumed: Set<Cell> = []
        for node in nodes where node.sub == 0 {
            let c = node.cell, ports = a.ports(node)
            for p in [m, m.opposite] where ports & p.bit != 0 {
                let toBox = a.ends[link].contains { $0.node == node && $0.toBox == p }
                let next = a.neighbour(node, p)
                guard toBox || next != nil else { return nil }
                var straight: Character = horizontal ? style.vertical : style.horizontal
                if let next, next.sub == 0, AsciiDiagram.lineGlyphs[a.grid[next.cell]]?.bits == perp { straight = a.grid[next.cell] }
                if p == m {
                    // Toward the branch: its first cells go, the run takes the next.
                    guard !toBox else { return nil }
                    for j in 1...n {
                        let cj = shift(c, m, j)
                        guard a.isLine(cj) else { return nil }
                        let nd = crossings.contains(a.grid[cj]) ? Node(cell: cj, sub: perpSub) : Node(cell: cj, sub: 0)
                        guard a.linkOf[nd] == link, a.ports(nd) == perp else { return nil }
                        if j == n {
                            guard nd.sub == 0 else { return nil }
                            consumed.insert(cj)
                        } else {
                            writes[cj] = nd.sub != 0 ? remaining(cj, leaving: nd.sub) : " "
                        }
                    }
                } else {
                    // Away from it: the branch grows to the run's new place.
                    writes[c] = straight
                    for j in 1..<n {
                        let cj = shift(c, m, j)
                        if free(cj) {
                            writes[cj] = straight
                        } else if let x = crossing(cj, strokeHorizontal: !horizontal) {
                            writes[cj] = x
                        } else {
                            return nil
                        }
                    }
                }
            }
        }
        // The run in its new place, each cell the glyph it had.
        var moved: [Cell] = []
        for node in nodes {
            let c = node.cell, t = shift(c, m, n)
            let ch: Character = node.sub != 0 ? (horizontal ? style.horizontal : style.vertical) : a.grid[c]
            moved.append(t)
            if consumed.contains(t) || free(t) {
                writes[t] = ch
            } else if node.sub != 0 || (a.ports(node) == axis && headDir(ch) == nil),
                      let x = crossing(t, strokeHorizontal: horizontal) {
                writes[t] = x
            } else {
                return nil
            }
        }
        // Ends on a box side slide along it; a tee goes with its line.
        for e in a.ends[link] where nodes.contains(e.node) && (e.toBox == along || e.toBox == along.opposite) {
            let b = e.end.box, r = a.boxes[b].rect, nb = shift(e.border, m, n)
            let corner = (nb.x == r.x || nb.x == r.x + r.width - 1) && (nb.y == r.y || nb.y == r.y + r.height - 1)
            let plain = a.boxes[b].glyphs.side(e.toBox.opposite.rawValue)
            guard a.box(at: nb) == b, a.onBorder(b, nb), !corner, a.grid[nb] == plain else { return nil }
            if a.grid[e.border] != plain {
                writes[e.border] = plain
                writes[nb] = a.grid[e.border]
            }
        }
        var g = a.grid
        for (c, ch) in writes { g.set(c, ch) }
        let old = a.scene(s.text)
        guard let ns = scan(g.text()), boxKeys(ns) == boxKeys(old),
              signature(ns, comps: false) == signature(old, comps: false),
              ns.links.contains(where: { l in moved.allSatisfy(l.cells.contains) }) else { return nil }
        return ns
    }
}

// MARK: - Free text

extension AsciiArt {
    /// Not a box cell (border, text or padding) nor a line cell.
    static func isFree(_ c: Cell, in s: Scene) -> Bool {
        c.x >= 0 && c.y >= 0 && !s.boxes.contains { $0.rect.contains(c) } && !s.links.contains { $0.cells.contains(c) }
    }

    /// The run of free text on `c`'s row holding `c`: words one space apart.
    static func textRun(at c: Cell, in s: Scene) -> (rect: Rect, text: String)? {
        let f = FreeText(s)
        guard let r = f.run(at: c) else { return nil }
        return (Rect(x: r.lowerBound, y: c.y, width: r.count, height: 1), String(r.map { f.g[$0, c.y] }))
    }

    /// `text` typed at a free cell; the rest of the run there (or the run it
    /// would run into) moves right, into free space only. The caret after it.
    static func type(_ text: String, at c: Cell, in s: Scene) -> (scene: Scene, caret: Cell)? {
        let chars = Array(text)
        guard !chars.isEmpty, !chars.contains(where: \.isNewline) else { return nil }
        var f = FreeText(s)
        guard f.free(c) else { return nil }
        let n = chars.count, y = c.y
        var tailEnd = c.x
        if let r = f.run(at: c) {
            tailEnd = r.upperBound + 1
        } else if let x = (c.x..<c.x + n).first(where: { !f.space(Cell(x: $0, y: y)) }) {
            guard let r = f.run(at: Cell(x: x, y: y)) else { return nil }
            tailEnd = r.upperBound + 1
        }
        let tail = (c.x..<tailEnd).map { f.g[$0, y] }
        for x in tailEnd..<tailEnd + n { guard f.space(Cell(x: x, y: y)) else { return nil } }
        for (k, ch) in (chars + tail).enumerated() { f.g.set(Cell(x: c.x + k, y: y), ch) }
        guard let ns = f.finish() else { return nil }
        return (ns, Cell(x: c.x + n, y: y))
    }

    /// The free character before `c` removed; the run's rest from `c` on moves left.
    static func deleteBackward(at c: Cell, in s: Scene) -> (scene: Scene, caret: Cell)? {
        var f = FreeText(s)
        let before = Cell(x: c.x - 1, y: c.y)
        guard f.free(before) else { return nil }
        let tailEnd = f.free(c) ? f.run(at: c).map { $0.upperBound + 1 } ?? c.x : c.x
        let tail = (c.x..<tailEnd).map { f.g[$0, c.y] }
        for (k, ch) in (tail + [" "]).enumerated() { f.g.set(Cell(x: before.x + k, y: c.y), ch) }
        guard let ns = f.finish() else { return nil }
        return (ns, before)
    }

    /// A run of free text moved; nil when it would land on anything but free space.
    static func moveText(_ r: Rect, text: String, dx: Int, dy: Int, in s: Scene) -> Scene? {
        var f = FreeText(s)
        let chars = Array(text)
        guard r.height == 1, r.width == chars.count else { return nil }
        let cells = (0..<r.width).map { Cell(x: r.x + $0, y: r.y) }
        guard cells.allSatisfy(f.free), cells.map({ f.g[$0] }) == chars else { return nil }
        if dx == 0 && dy == 0 { return f.s }
        for c in cells { f.g.set(c, " ") }
        for (k, c) in cells.enumerated() {
            let t = Cell(x: c.x + dx, y: c.y + dy)
            guard f.free(t), f.g[t] == " " else { return nil }
            f.g.set(t, chars[k])
        }
        return f.finish()
    }

    /// The grid with the cells of boxes and lines fenced off.
    fileprivate struct FreeText {
        var g: Grid
        let s: Scene
        let blocked: Set<Cell>

        init(_ scene: Scene) {
            s = AsciiArt.scan(scene.text) ?? scene
            g = Grid(s.text)
            var b = Set<Cell>()
            for box in s.boxes { b.formUnion(AsciiArt.cells(box.rect)) }
            for l in s.links { b.formUnion(l.cells) }
            blocked = b
        }

        func free(_ c: Cell) -> Bool { c.x >= 0 && c.y >= 0 && !blocked.contains(c) }
        func text(_ x: Int, _ y: Int) -> Bool { free(Cell(x: x, y: y)) && g[x, y] != " " }
        func space(_ c: Cell) -> Bool { free(c) && g[c] == " " }

        /// Columns of the run holding `c` (a word, or a single space between two).
        func run(at c: Cell) -> ClosedRange<Int>? {
            let y = c.y
            var x0: Int, x1: Int
            if text(c.x, y) {
                (x0, x1) = (c.x, c.x)
            } else if space(c), text(c.x - 1, y), text(c.x + 1, y) {
                (x0, x1) = (c.x - 1, c.x + 1)
            } else {
                return nil
            }
            while true {
                if text(x0 - 1, y) { x0 -= 1 } else if space(Cell(x: x0 - 1, y: y)), text(x0 - 2, y) { x0 -= 2 } else { break }
            }
            while true {
                if text(x1 + 1, y) { x1 += 1 } else if space(Cell(x: x1 + 1, y: y)), text(x1 + 2, y) { x1 += 2 } else { break }
            }
            return x0...x1
        }

        /// The new scene, when boxes and lines read back exactly as before.
        func finish() -> Scene? {
            guard let ns = AsciiArt.scan(g.text()), ns.boxes == s.boxes, ns.links == s.links else { return nil }
            return ns
        }
    }
}
