import Foundation

/// A drawing on the canvas, whichever kind: ClipB's own layout
/// (`AsciiDiagram`, re-rendered whole on every change) or hand-drawn art
/// (`AsciiArt`, edited in place). The canvas talks to this only. Every edit
/// returns the new drawing, or nil when it can't be done cleanly (overlap,
/// no route); ids may change on art edits, so edits report the new ones.
struct CanvasDrawing {
    typealias Cell = AsciiDiagram.Cell
    typealias Rect = AsciiDiagram.Rect

    enum Kind: Equatable {
        case model(AsciiDiagram.Diagram)
        case art(AsciiArt.Scene)
    }

    let kind: Kind
    /// The model's layout (paths, labels); for art only its text.
    let rendered: AsciiDiagram.Rendered

    init(_ diagram: AsciiDiagram.Diagram) {
        kind = .model(diagram)
        rendered = AsciiDiagram.render(diagram)
    }

    /// The text is normalized (see `normalized`); boxes and lines don't
    /// depend on trailing spaces, so the scene's ids stay.
    init(_ scene: AsciiArt.Scene) {
        var scene = scene
        scene.text = Self.normalized(scene.text)
        kind = .art(scene)
        rendered = AsciiDiagram.Rendered(text: scene.text, paths: [:], labels: [:], unrouted: [])
    }

    /// No trailing spaces on any line, no trailing blank lines.
    static func normalized(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n").map { line -> String in
            var s = line
            while s.last == " " { s.removeLast() }
            return s
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// The drawing as hand-drawn art: itself, or the model's text scanned.
    /// Edits the model can't express are made on this, in place.
    private var art: AsciiArt.Scene? {
        switch kind {
        case .art(let s): s
        case .model: AsciiArt.scan(text)
        }
    }

    var text: String { rendered.text }
    var isArt: Bool { if case .art = kind { true } else { false } }

    // MARK: Reading

    var boxes: [(id: Int, rect: Rect)] {
        switch kind {
        case .model(let d): d.boxes.map { ($0.id, $0.rect) }
        case .art(let s): s.boxes.map { ($0.id, $0.rect) }
        }
    }

    func rect(of id: Int) -> Rect? { boxes.first { $0.id == id }?.rect }

    /// The box's text part holding a cell: an art compartment, else 0.
    func part(at c: Cell, of id: Int) -> Int {
        guard case .art(let s) = kind, let box = s.boxes.first(where: { $0.id == id }) else { return 0 }
        return box.compartments.firstIndex { $0.y <= c.y && c.y < $0.y + $0.height }
            ?? (c.y >= (box.compartments.last.map { $0.y + $0.height } ?? 0) ? box.compartments.count - 1 : 0)
    }

    /// A box's text, without blank rows under it; never empty.
    func lines(of id: Int, part: Int) -> [String] {
        var lines: [String]
        switch kind {
        case .model(let d): lines = d.boxes.first { $0.id == id }?.text ?? []
        case .art(let s): lines = AsciiArt.text(of: id, compartment: part, in: s)
        }
        while lines.count > 1, lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return lines.isEmpty ? [""] : lines
    }

    /// The cell where line `k` of a box's text starts (its leading spaces
    /// counted), with `lines` as being typed: box text is centered, so each
    /// line starts elsewhere. Caret cells and clicked columns go through it.
    func lineStart(of id: Int, part: Int, line k: Int, of lines: [String]) -> Cell? {
        switch kind {
        case .model(let d):
            return d.boxes.first { $0.id == id }.map { AsciiDiagram.lineStart($0, line: k, of: lines) }
        case .art(let s):
            return AsciiArt.lineStart(box: id, compartment: part, line: k, of: lines, in: s)
        }
    }

    /// The arrow (or art line) under a cell, near misses included.
    func arrow(at c: Cell) -> Int? {
        switch kind {
        case .model:
            for (id, r) in rendered.labels where r.contains(c) { return id }
            for (id, path) in rendered.paths where path.contains(c) { return id }
            for (id, path) in rendered.paths where path.contains(where: { abs($0.x - c.x) + abs($0.y - c.y) <= 1 }) { return id }
        case .art(let s):
            for link in s.links where link.cells.contains(c) { return link.id }
            for link in s.links where link.cells.contains(where: { abs($0.x - c.x) + abs($0.y - c.y) <= 1 }) { return link.id }
        }
        return nil
    }

    func cells(of arrow: Int) -> [Cell] {
        switch kind {
        case .model: rendered.paths[arrow] ?? []
        case .art(let s): Array(s.links.first { $0.id == arrow }?.cells ?? [])
        }
    }

    /// An arrow's label; nil when the drawing's lines carry no text (art).
    func label(of arrow: Int) -> [String]? {
        guard case .model(let d) = kind, let a = d.arrows.first(where: { $0.id == arrow }) else { return nil }
        return a.label.isEmpty ? [""] : a.label
    }

    /// Where a label's first character sits (beside the middle of an
    /// unlabelled arrow, where typing will put it).
    func labelOrigin(of arrow: Int) -> Cell? {
        if let r = rendered.labels[arrow] { return Cell(x: r.x, y: r.y) }
        guard let path = rendered.paths[arrow], !path.isEmpty else { return nil }
        let middle = path[path.count / 2]
        return Cell(x: middle.x + 1, y: max(0, middle.y - 1))
    }

    /// No text and no arrows: a box made by mistake.
    func isLoose(_ id: Int) -> Bool {
        let empty = lines(of: id, part: 0).allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        switch kind {
        case .model(let d): return empty && !d.arrows.contains { $0.from == id || $0.to == id } && d.boxes.count > 1
        case .art(let s): return empty && !s.links.contains { $0.ends.contains { $0.box == id } } && s.boxes.count > 1
        }
    }

    // MARK: Edits

    /// Several boxes moved together. The new ids, in the same order.
    func moving(_ ids: [Int], dx: Int, dy: Int) -> (CanvasDrawing, [Int])? {
        guard dx != 0 || dy != 0 else { return (self, ids) }
        switch kind {
        case .model(var d):
            let moving = Set(ids)
            for k in d.boxes.indices where moving.contains(d.boxes[k].id) {
                d.boxes[k].x += dx
                d.boxes[k].y += dy
                guard d.boxes[k].x >= 0, d.boxes[k].y >= 0 else { return nil }
            }
            for box in d.boxes where moving.contains(box.id) {
                guard !Self.overlaps(box, d.boxes.filter { !moving.contains($0.id) }) else { return nil }
            }
            return (CanvasDrawing(d), ids)
        case .art(var s):
            // The box furthest along the move goes first: it never lands on
            // a box of the group that hasn't moved yet.
            var rects = ids.compactMap { id in s.boxes.first { $0.id == id }?.rect }
            guard rects.count == ids.count else { return nil }
            let order = rects.indices.sorted { rects[$0].x * dx + rects[$0].y * dy > rects[$1].x * dx + rects[$1].y * dy }
            for k in order {
                guard let id = s.boxes.first(where: { $0.rect == rects[k] })?.id,
                      let edit = AsciiArt.move(id, dx: dx, dy: dy, in: s) else { return nil }
                s = edit.scene
                rects[k].x += dx
                rects[k].y += dy
            }
            let newIDs = rects.compactMap { r in s.boxes.first { $0.rect == r }?.id }
            return newIDs.count == ids.count ? (CanvasDrawing(s), newIDs) : nil
        }
    }

    /// A corner dragged to a cell; the box never gets smaller than its text.
    func resizing(_ id: Int, corner: (x: Int, y: Int), to c: Cell) -> (CanvasDrawing, Int)? {
        guard let old = rect(of: id) else { return nil }
        let smallest: (width: Int, height: Int)
        switch kind {
        case .model(let d):
            let box = d.boxes.first { $0.id == id }!
            let fit = AsciiDiagram.fitted(AsciiDiagram.Box(id: id, x: 0, y: 0, width: 0, height: 0, text: box.text))
            smallest = (fit.width, fit.height)
        case .art:
            smallest = (AsciiDiagram.minWidth, AsciiDiagram.minHeight)
        }
        var left = old.x, top = old.y, right = old.x + old.width - 1, bottom = old.y + old.height - 1
        if corner.x < 0 { left = max(0, min(c.x, right - smallest.width + 1)) } else { right = max(c.x, left + smallest.width - 1) }
        if corner.y < 0 { top = max(0, min(c.y, bottom - smallest.height + 1)) } else { bottom = max(c.y, top + smallest.height - 1) }
        let r = Rect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        guard r != old else { return (self, id) }
        switch kind {
        case .model(var d):
            guard let k = d.boxes.firstIndex(where: { $0.id == id }) else { return nil }
            d.boxes[k].x = r.x
            d.boxes[k].y = r.y
            d.boxes[k].width = r.width
            d.boxes[k].height = r.height
            guard !Self.overlaps(d.boxes[k], d.boxes) else { return nil }
            return (CanvasDrawing(d), id)
        case .art(let s):
            guard let edit = AsciiArt.resize(id, to: r, in: s) else { return nil }
            return (CanvasDrawing(edit.scene), edit.box ?? id)
        }
    }

    /// A new empty box.
    func adding(_ r: Rect) -> (CanvasDrawing, Int)? {
        switch kind {
        case .model(var d):
            let box = AsciiDiagram.Box(id: (d.boxes.map(\.id).max() ?? -1) + 1, x: r.x, y: r.y,
                                       width: r.width, height: r.height, text: [""])
            guard !Self.overlaps(box, d.boxes) else { return nil }
            d.boxes.append(box)
            return (CanvasDrawing(d), box.id)
        case .art(let s):
            guard let edit = AsciiArt.addBox(r, text: [""], in: s), let id = edit.box else { return nil }
            return (CanvasDrawing(edit.scene), id)
        }
    }

    /// A new arrow; its id.
    func connecting(_ from: Int, to: Int) -> (CanvasDrawing, Int)? {
        guard from != to else { return nil }
        switch kind {
        case .model(var d):
            let id = (d.arrows.map(\.id).max() ?? -1) + 1
            d.arrows.append(AsciiDiagram.Arrow(id: id, from: from, to: to, label: []))
            let next = CanvasDrawing(d)
            return next.rendered.unrouted.contains(id) ? nil : (next, id)
        case .art(let s):
            guard let edit = AsciiArt.connect(from, to: to, in: s), let id = edit.link else { return nil }
            return (CanvasDrawing(edit.scene), id)
        }
    }

    enum Side: Equatable { case top, bottom, left, right }

    /// Which side of `r` a cell just outside it is on.
    static func side(of c: Cell, outside r: Rect) -> Side {
        if c.x < r.x { return .left }
        if c.x >= r.x + r.width { return .right }
        return c.y < r.y ? .top : .bottom
    }

    /// An arrow (or art line) leaving `from` through `fromSide` and entering
    /// `to` through `toSide` (nil: pick as today). Returns the new drawing
    /// and the arrow's id. ClipB's layout picks its own sides: when it
    /// would pick others than asked, the arrow is drawn as art instead (the
    /// drawing becomes art).
    func connecting(_ from: Int, side fromSide: Side?, to: Int, side toSide: Side?) -> (CanvasDrawing, Int)? {
        guard from != to else { return nil }
        if fromSide == nil && toSide == nil { return connecting(from, to: to) }
        switch kind {
        case .model:
            if let made = connecting(from, to: to), let path = made.0.rendered.paths[made.1],
               let first = path.first, let last = path.last, let f = made.0.rect(of: from), let t = made.0.rect(of: to),
               fromSide == nil || Self.side(of: first, outside: f) == fromSide,
               toSide == nil || Self.side(of: last, outside: t) == toSide {
                return made
            }
            guard let s = art, let f = rect(of: from), let t = rect(of: to),
                  let af = s.boxes.first(where: { $0.rect == f })?.id,
                  let at = s.boxes.first(where: { $0.rect == t })?.id else { return nil }
            return CanvasDrawing(s).connecting(af, side: fromSide, to: at, side: toSide)
        case .art(let s):
            guard let edit = AsciiArt.connect(from, to: to, fromSide: fromSide, toSide: toSide, in: s),
                  let id = edit.link else { return nil }
            return (CanvasDrawing(edit.scene), id)
        }
    }

    /// A box's text replaced; the box grows to hold it.
    func settingText(_ lines: [String], of id: Int, part: Int) -> (CanvasDrawing, Int)? {
        switch kind {
        case .model(var d):
            guard let k = d.boxes.firstIndex(where: { $0.id == id }) else { return nil }
            d.boxes[k].text = lines
            var grown = AsciiDiagram.fitted(d.boxes[k])
            // Growing into a neighbour: grow anyway, the drawing stays legible
            // only with the text inside its box.
            grown.width = max(grown.width, d.boxes[k].width)
            d.boxes[k] = grown
            return (CanvasDrawing(d), id)
        case .art(let s):
            guard let edit = AsciiArt.setText(lines, box: id, compartment: part, in: s) else { return nil }
            return (CanvasDrawing(edit.scene), edit.box ?? id)
        }
    }

    func settingLabel(_ lines: [String], of arrow: Int) -> CanvasDrawing? {
        guard case .model(var d) = kind, let k = d.arrows.firstIndex(where: { $0.id == arrow }) else { return nil }
        d.arrows[k].label = lines.allSatisfy(\.isEmpty) ? [] : lines
        return CanvasDrawing(d)
    }

    /// Boxes and every arrow touching them.
    func deleting(_ ids: [Int]) -> CanvasDrawing? {
        switch kind {
        case .model(var d):
            let gone = Set(ids)
            d.boxes.removeAll { gone.contains($0.id) }
            d.arrows.removeAll { gone.contains($0.from) || gone.contains($0.to) }
            return CanvasDrawing(d)
        case .art(var s):
            let rects = ids.compactMap { id in s.boxes.first { $0.id == id }?.rect }
            for r in rects {
                guard let id = s.boxes.first(where: { $0.rect == r })?.id, let edit = AsciiArt.deleteBox(id, in: s) else { return nil }
                s = edit.scene
            }
            return CanvasDrawing(s)
        }
    }

    func deletingArrow(_ id: Int) -> CanvasDrawing? {
        switch kind {
        case .model(var d):
            d.arrows.removeAll { $0.id == id }
            return CanvasDrawing(d)
        case .art(let s):
            return AsciiArt.deleteLink(id, in: s).map { CanvasDrawing($0.scene) }
        }
    }

    // MARK: Segments

    /// A straight run of a line between two bends (or a bend and an end)
    /// that can be dragged across. `cells` include the bends and the head.
    struct Segment: Equatable { var arrow: Int; var cells: [Cell]; var horizontal: Bool }

    /// The segment under a cell (on a bend: the longer of its two runs).
    func segment(at c: Cell) -> Segment? {
        guard let s = art, let run = AsciiArt.run(at: c, in: s) else { return nil }
        switch kind {
        case .art:
            return Segment(arrow: run.link, cells: run.cells, horizontal: run.horizontal)
        case .model:
            guard let id = rendered.paths.sorted(by: { $0.key < $1.key })
                .first(where: { p in run.cells.allSatisfy(p.value.contains) })?.key else { return nil }
            return Segment(arrow: id, cells: run.cells, horizontal: run.horizontal)
        }
    }

    /// The segment moved perpendicular to itself by `offset` cells (+ =
    /// right/down); the neighbouring runs stretch or shrink, ends stay
    /// attached to their boxes (an end on a box side slides along that side,
    /// staying off corners). Nil when it would overlap something or detach.
    /// ClipB's layout routes its own lines, so a moved one makes it art.
    func movingSegment(_ seg: Segment, by offset: Int) -> CanvasDrawing? {
        if offset == 0 { return self }
        guard let s = art, let ns = AsciiArt.moveRun(seg.cells, horizontal: seg.horizontal, by: offset, in: s) else { return nil }
        return CanvasDrawing(ns)
    }

    // MARK: Free text

    /// Characters on the grid that are not part of a box, its text, a line,
    /// or a model label; one row, words one space apart (2+ split runs).
    struct TextRun: Equatable { var cells: Rect; var text: String }

    /// Whether a cell is free space or free text (where a click puts a free caret).
    func isFree(_ c: Cell) -> Bool {
        guard c.x >= 0, c.y >= 0 else { return false }
        switch kind {
        case .model:
            return !boxes.contains { $0.rect.contains(c) }
                && !rendered.paths.values.contains { $0.contains(c) }
                && !rendered.labels.values.contains { $0.contains(c) }
        case .art(let s):
            return AsciiArt.isFree(c, in: s)
        }
    }

    /// ClipB's own drawings hold no free text (labels belong to arrows).
    func textRun(at c: Cell) -> TextRun? {
        guard case .art(let s) = kind, let run = AsciiArt.textRun(at: c, in: s) else { return nil }
        return TextRun(cells: run.rect, text: run.text)
    }

    /// Nil if it would land on anything non-space.
    func movingText(_ run: TextRun, dx: Int, dy: Int) -> CanvasDrawing? {
        guard let s = art, let ns = AsciiArt.moveText(run.cells, text: run.text, dx: dx, dy: dy, in: s) else { return nil }
        return CanvasDrawing(ns)
    }

    /// Typing at a free cell (not on a box or line): writes there; if the
    /// caret is inside or at the start of a run, the run's tail shifts
    /// right, only into free space (nil if it would hit something). Returns
    /// the caret's new cell. Rows/columns beyond the text grow it. In
    /// ClipB's own drawing the text makes it art.
    func typing(_ text: String, at c: Cell) -> (CanvasDrawing, Cell)? {
        guard isFree(c), let s = art, let r = AsciiArt.type(text, at: c, in: s) else { return nil }
        return (CanvasDrawing(r.scene), r.caret)
    }

    /// Backspace at a free caret: removes the free character before `c` on
    /// the row (the run's tail shifts left).
    func deletingBackward(at c: Cell) -> (CanvasDrawing, Cell)? {
        guard c.x > 0, isFree(Cell(x: c.x - 1, y: c.y)), let s = art,
              let r = AsciiArt.deleteBackward(at: c, in: s) else { return nil }
        return (CanvasDrawing(r.scene), r.caret)
    }

    // MARK: Styles (docs/ascii-diagram-style-guide.md)

    /// nil for an art shape the model has no style for (block, dot corners).
    func boxStyle(of id: Int) -> AsciiDiagram.BoxStyle? {
        switch kind {
        case .model(let d): d.boxes.first { $0.id == id }?.style
        case .art(let s): s.boxes.first { $0.id == id }?.style
        }
    }

    func lineStyle(of arrow: Int) -> AsciiDiagram.LineStyle? {
        switch kind {
        case .model(let d): d.arrows.first { $0.id == arrow }?.line
        case .art(let s): s.links.first { $0.id == arrow }?.line
        }
    }

    /// The arrow whose end is at `c`: its head, or the first/last cell of its
    /// line (an art line: any cell touching a box). Elsewhere on a line, nil.
    func arrowEnd(at c: Cell) -> Int? {
        switch kind {
        case .model:
            return rendered.paths.sorted { $0.key < $1.key }.first { $0.value.first == c || $0.value.last == c }?.key
        case .art(let s):
            return s.links.first { $0.ends.contains { $0.cell == c } }?.id
        }
    }

    /// light → heavy → double → rounded → dashed → dotted → light.
    func cyclingBoxStyle(_ id: Int) -> CanvasDrawing? {
        switch kind {
        case .model(var d):
            guard let k = d.boxes.firstIndex(where: { $0.id == id }) else { return nil }
            d.boxes[k].style = d.boxes[k].style.next
            return CanvasDrawing(d)
        case .art(let s):
            guard let box = s.boxes.first(where: { $0.id == id }) else { return nil }
            return AsciiArt.restyleBox(id, to: box.style?.next ?? .light, in: s).map { CanvasDrawing($0.scene) }
        }
    }

    /// solid → heavy → double → dashed → dotted → solid.
    func cyclingLineStyle(_ arrow: Int) -> CanvasDrawing? {
        switch kind {
        case .model(var d):
            guard let k = d.arrows.firstIndex(where: { $0.id == arrow }) else { return nil }
            d.arrows[k].line = d.arrows[k].line.next
            let next = CanvasDrawing(d)
            return next.rendered.unrouted.contains(arrow) ? nil : next
        case .art(let s):
            guard let link = s.links.first(where: { $0.id == arrow }) else { return nil }
            return AsciiArt.restyleLink(arrow, to: link.line.next, in: s).map { CanvasDrawing($0.scene) }
        }
    }

    /// forward → backward → both → none → forward. "Forward" points from
    /// the earlier box in reading order to the later one; backward the other
    /// way. The arrow's id afterwards.
    func cyclingHeads(_ arrow: Int) -> (CanvasDrawing, Int)? {
        switch kind {
        case .model(var d):
            guard let k = d.arrows.firstIndex(where: { $0.id == arrow }),
                  let f = d.boxes.first(where: { $0.id == d.arrows[k].from }),
                  let t = d.boxes.first(where: { $0.id == d.arrows[k].to }) else { return nil }
            let reading = (f.y, f.x) < (t.y, t.x)
            var a = d.arrows[k]
            switch a.heads {
            case .forward where reading: swap(&a.from, &a.to)
            case .forward: a.heads = .both
            case .both: a.heads = .none
            case .none:
                a.heads = .forward
                if !reading { swap(&a.from, &a.to) }
            }
            d.arrows[k] = a
            let next = CanvasDrawing(d)
            return next.rendered.unrouted.contains(arrow) ? nil : (next, arrow)
        case .art(let s):
            guard let edit = AsciiArt.cycleHeads(arrow, in: s), let id = edit.link else { return nil }
            return (CanvasDrawing(edit.scene), id)
        }
    }

    /// Boxes keep one free cell between them, so arrows can still leave.
    static func overlaps(_ box: AsciiDiagram.Box, _ others: [AsciiDiagram.Box]) -> Bool {
        others.contains { other in
            other.id != box.id
                && box.x <= other.x + other.width && other.x <= box.x + box.width
                && box.y <= other.y + other.height && other.y <= box.y + box.height
        }
    }
}
