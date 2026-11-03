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

    init(_ scene: AsciiArt.Scene) {
        kind = .art(scene)
        rendered = AsciiDiagram.Rendered(text: scene.text, paths: [:], labels: [:], unrouted: [])
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

    /// The cell of a box text's first character.
    func textOrigin(of id: Int, part: Int) -> Cell? {
        switch kind {
        case .model(let d):
            return d.boxes.first { $0.id == id }.map { Cell(x: $0.x + 2, y: $0.y + 1) }
        case .art(let s):
            guard let box = s.boxes.first(where: { $0.id == id }), part < box.compartments.count else { return nil }
            let room = box.compartments[part]
            return Cell(x: room.x + 1, y: room.y)
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

    /// Boxes keep one free cell between them, so arrows can still leave.
    static func overlaps(_ box: AsciiDiagram.Box, _ others: [AsciiDiagram.Box]) -> Bool {
        others.contains { other in
            other.id != box.id
                && box.x <= other.x + other.width && other.x <= box.x + box.width
                && box.y <= other.y + other.height && other.y <= box.y + box.height
        }
    }
}
