import AppKit

/// A box-and-arrow drawing inside a ``` block (MODAL.md). The block's text IS
/// the drawing, box-drawing characters that paste anywhere; this keeps the
/// drawing while you edit and rewrites the block on every change. A block is
/// a drawing when it is ClipB's own layout (`AsciiDiagram.parse` reads it
/// back exactly) or hand-drawn art with a closed box (`AsciiArt`, edited in
/// place); other code blocks are never touched.
///
/// Mouse: double-click empty space for a box. Drag on empty space: a
/// selection rectangle; dragging a selected box moves them all. Click in a
/// box's text: a caret, ←→↑↓ move it. Click a box's edge: the box is
/// selected. Drag a box (edge or text) to move it; drop an edge drag on
/// another box: an arrow to it. Drag a corner to resize. Shift-click adds a
/// box to the selection. Click an arrow to type its label.
final class DiagramCanvas {
    typealias Cell = AsciiDiagram.Cell
    typealias Rect = AsciiDiagram.Rect

    enum Selection: Equatable {
        /// Boxes picked as a whole (rings, no caret): keys move or delete them.
        case boxes([Int])
        /// Typing into a box's text (an art box's compartment `part`).
        case text(box: Int, part: Int, caret: CaretText)
        /// An arrow; with a caret when its label can be typed into.
        case arrow(Int, caret: CaretText?)
    }

    struct Session {
        /// Ranges as of the last write.
        var block: Markdown.FencedBlock
        var drawing: CanvasDrawing
        var selection: Selection?
        /// A box made by a double-click: dropped again when left empty and
        /// unconnected.
        var fresh: Int?
    }

    /// Languages a drawing's fence may carry; a plain ``` is the usual one.
    static let languages: Set<String> = ["", "text", "txt", "ascii", "diagram"]
    /// A new box: wide enough to start typing into.
    static let newBoxSize = (width: 14, height: 3)

    unowned let editor: EditorTextView
    private var session: Session?
    /// A drag from a side handle: a new arrow out of `from`, to `target` when over a box.
    private var pulling: (from: Int, to: NSPoint, target: Int?)?
    /// The box under the pointer: its side handles are drawn.
    private var hovered: Int?
    /// The caret blinks: on/off, flipped by `blink`.
    private var caretOn = true
    private var blink: Timer?
    /// A drag on empty space: the selection rectangle's corners.
    private var band: (from: Cell, to: Cell)?
    /// Mermaid source a drawing came from, keyed by the drawing's text: the
    /// way back gives the exact source while the drawing is unchanged.
    private var mermaidSources: [String: String] = [:]

    init(editor: EditorTextView) { self.editor = editor }

    // MARK: Session

    /// The text between the fences, without its last newline.
    static func drawingText(_ block: Markdown.FencedBlock, in ns: NSString) -> String {
        var text = ns.substring(with: block.content)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    static func drawing(_ block: Markdown.FencedBlock, in ns: NSString) -> AsciiDiagram.Diagram? {
        guard languages.contains(block.info) else { return nil }
        let text = drawingText(block, in: ns)
        guard text.contains("┌") else { return nil }
        return AsciiDiagram.parse(text)
    }

    /// Either kind of drawing in a block: ClipB's own layout first.
    static func canvasDrawing(_ block: Markdown.FencedBlock, in ns: NSString) -> CanvasDrawing? {
        if let diagram = drawing(block, in: ns) { return CanvasDrawing(diagram) }
        guard languages.contains(block.info) else { return nil }
        let text = drawingText(block, in: ns)
        guard text.contains("┌"), let scene = AsciiArt.scan(text), !scene.boxes.isEmpty else { return nil }
        return CanvasDrawing(scene)
    }

    /// The session still matches the text (no undo, no typing behind its back).
    private func current() -> Session? {
        guard let s = session, let storage = editor.textStorage else { return nil }
        let ns = storage.string as NSString
        guard NSMaxRange(s.block.range) <= ns.length,
              Self.drawingText(s.block, in: ns) == s.drawing.text,
              let block = Markdown.fencedBlocks(in: storage.string).first(where: { $0.range.location == s.block.range.location }),
              block.content == s.block.content else {
            session = nil
            return nil
        }
        return s
    }

    /// Something is selected: keys go to the drawing.
    var isEditing: Bool { current()?.selection != nil }

    /// For tests: what is selected.
    var selection: Selection? { current()?.selection }

    /// The drawing block under a text index, as a session.
    private func session(at index: Int) -> Session? {
        guard let storage = editor.textStorage else { return nil }
        if let s = current(), index >= s.block.range.location, index <= NSMaxRange(s.block.closing) { return s }
        let ns = storage.string as NSString
        guard let block = Markdown.fencedBlocks(in: storage.string).first(where: {
            index >= NSMaxRange(ns.lineRange(for: NSRange(location: $0.range.location, length: 0))) && index <= NSMaxRange($0.closing)
        }), let drawing = Self.canvasDrawing(block, in: ns) else { return nil }
        return Session(block: block, drawing: drawing)
    }

    /// For tests: a session on the drawing block that holds a text index.
    func begin(at index: Int) -> Bool {
        guard let s = session(at: index) else { return false }
        session = s
        return true
    }

    /// Writes the drawing into its block. `undoable` false for drag previews.
    private func write(_ s: inout Session, undoable: Bool = true, action: String? = nil) {
        guard let storage = editor.textStorage else { return }
        let content = s.drawing.text.isEmpty ? "" : s.drawing.text + "\n"
        let range = s.block.content
        if (storage.string as NSString).substring(with: range) != content {
            if undoable {
                guard editor.shouldChangeText(in: range, replacementString: content) else { return }
                storage.replaceCharacters(in: range, with: content)
                editor.didChangeText()
                if let action { editor.undoManager?.setActionName(action) }
            } else {
                editor.undoManager?.disableUndoRegistration()
                storage.replaceCharacters(in: range, with: content)
                editor.undoManager?.enableUndoRegistration()
            }
            let delta = (content as NSString).length - range.length
            s.block.content.length += delta
            s.block.closing.location += delta
            s.block.range.length += delta
        }
        session = s
        caretOn = true
        // The text caret parks at the block's start, hidden while editing.
        editor.setSelectedRange(NSRange(location: s.block.content.location, length: 0))
        reportWidth(s)
        editor.needsDisplay = true
    }

    /// A selection change only: nothing to write.
    private func show(_ s: Session) {
        session = s
        caretOn = true
        editor.setSelectedRange(NSRange(location: s.block.content.location, length: 0))
        editor.needsDisplay = true
    }

    private func reportWidth(_ s: Session) {
        report(columns: s.drawing.text.components(separatedBy: "\n").map(\.count).max() ?? 0)
    }

    private func report(columns: Int) {
        let needed = CGFloat(columns + 2) * cellSize.width + editor.textContainerInset.width * 2
        editor.onWantsWidth?(needed)
    }

    /// Box art wider than the editor asks the panel for room on every change,
    /// not only once edited: wrapped art can't be read or clicked.
    func fitDrawings() {
        guard editor.onWantsWidth != nil, let storage = editor.textStorage, storage.length <= MarkdownPainter.maxLength,
              storage.string.contains("┌") else { return }
        let ns = storage.string as NSString
        var longest = 0
        for block in Markdown.fencedBlocks(in: storage.string) where Self.languages.contains(block.info) {
            let text = Self.drawingText(block, in: ns)
            guard text.contains("┌") else { continue }
            longest = max(longest, text.components(separatedBy: "\n").map(\.count).max() ?? 0)
        }
        if longest > 0 { report(columns: longest) }
    }

    /// Leaves the selection; a new box left empty goes away again.
    func endEditing() {
        guard var s = current(), s.selection != nil else { return }
        let fresh = s.fresh
        s.selection = nil
        s.fresh = nil
        pulling = nil
        band = nil
        if let fresh, s.drawing.isLoose(fresh), let next = s.drawing.deleting([fresh]) {
            s.drawing = next
            write(&s, action: "Delete Box")
        } else {
            session = s
        }
        // The caret goes past the block: typing continues after the drawing.
        editor.setSelectedRange(NSRange(location: min(NSMaxRange(s.block.range), (editor.string as NSString).length), length: 0))
        editor.needsDisplay = true
    }

    // MARK: Geometry

    var cellSize: NSSize {
        let font = NSFont.monospacedSystemFont(ofSize: MarkdownPainter.fontSize, weight: .regular)
        let height = editor.layoutManager?.defaultLineHeight(for: font) ?? 16
        return NSSize(width: ("M" as NSString).size(withAttributes: [.font: font]).width, height: height)
    }

    /// Top-left of the drawing's first cell, in view coordinates.
    private func origin(_ s: Session) -> NSPoint? {
        guard let manager = editor.layoutManager, let storage = editor.textStorage else { return nil }
        let at = s.block.content.length > 0 ? s.block.content.location : s.block.closing.location
        guard at < storage.length else { return nil }
        let line = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: at), effectiveRange: nil)
        return NSPoint(x: editor.textContainerOrigin.x + line.minX, y: editor.textContainerOrigin.y + line.minY)
    }

    private func cell(at point: NSPoint, in s: Session) -> Cell? {
        guard let o = origin(s) else { return nil }
        let size = cellSize
        return Cell(x: max(0, Int(floor((point.x - o.x) / size.width))), y: Int(floor((point.y - o.y) / size.height)))
    }

    private func rect(_ r: Rect, in s: Session) -> NSRect {
        let o = origin(s) ?? .zero
        let size = cellSize
        return NSRect(x: o.x + CGFloat(r.x) * size.width, y: o.y + CGFloat(r.y) * size.height,
                      width: CGFloat(r.width) * size.width, height: CGFloat(r.height) * size.height)
    }

    private func rect(_ c: Cell, in s: Session) -> NSRect { rect(Rect(x: c.x, y: c.y, width: 1, height: 1), in: s) }

    // MARK: Hit testing

    /// The zones of a box (MODAL.md, "Box zones"): corners resize, the middle
    /// of each side pulls an arrow, the text itself takes a caret, and the
    /// rest of the box (border and inside) moves it.
    private enum Target {
        case corner(Int, dx: Int, dy: Int)   // which corner: -1 left/top, 1 right/bottom
        case handle(Int)
        case edge(Int)
        case text(Int)
        case inside(Int)
        case arrow(Int)
        case empty

        var box: Int? {
            switch self {
            case .corner(let id, _, _), .handle(let id), .edge(let id), .text(let id), .inside(let id): id
            case .arrow, .empty: nil
            }
        }
    }

    private func target(at c: Cell, in s: Session) -> Target {
        for box in s.drawing.boxes {
            let r = box.rect
            guard r.contains(c) else { continue }
            let left = c.x == r.x, right = c.x == r.x + r.width - 1
            let top = c.y == r.y, bottom = c.y == r.y + r.height - 1
            if (left || right) && (top || bottom) { return .corner(box.id, dx: left ? -1 : 1, dy: top ? -1 : 1) }
            if Self.handles(of: r).contains(c) { return .handle(box.id) }
            if left || right || top || bottom { return .edge(box.id) }
            return onText(c, of: box.id, in: s) ? .text(box.id) : .inside(box.id)
        }
        return s.drawing.arrow(at: c).map { .arrow($0) } ?? .empty
    }

    /// The middle cell of each side (both middle cells of an even side).
    static func handles(of r: Rect) -> [Cell] {
        let xs = Set([r.x + (r.width - 1) / 2, r.x + r.width / 2])
        let ys = Set([r.y + (r.height - 1) / 2, r.y + r.height / 2])
        return xs.flatMap { [Cell(x: $0, y: r.y), Cell(x: $0, y: r.y + r.height - 1)] }
            + ys.flatMap { [Cell(x: r.x, y: $0), Cell(x: r.x + r.width - 1, y: $0)] }
    }

    /// The cells the box's text covers: its rows, from where the leftmost
    /// line starts to where the longest one ends; an empty text, its middle cell.
    private func onText(_ c: Cell, of id: Int, in s: Session) -> Bool {
        let part = s.drawing.part(at: c, of: id)
        let lines = s.drawing.lines(of: id, part: part)
        let starts = lines.indices.compactMap { s.drawing.lineStart(of: id, part: part, line: $0, of: lines) }
        guard starts.count == lines.count, let top = starts.first, c.y >= top.y, c.y < top.y + lines.count else { return false }
        let visible = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        guard !visible.isEmpty else { return c.y == top.y && c.x == top.x }
        let lead = { (k: Int) in lines[k].prefix { $0 == " " }.count }
        let from = visible.map { starts[$0].x + lead($0) }.min()!
        let to = visible.map { starts[$0].x + lines[$0].count }.max()!
        return c.x >= from && c.x < to
    }

    /// Hover: what a press here would do.
    func cursor(at point: NSPoint) -> NSCursor? {
        guard let index = characterIndex(at: point), let s = session(at: index), let c = cell(at: point, in: s), c.y >= 0 else {
            hover(nil)
            return nil
        }
        let hit = target(at: c, in: s)
        hover(hit.box)
        switch hit {
        case .corner:
            if #available(macOS 15.0, *) { return .frameResize(position: .bottomRight, directions: .all) }
            return .crosshair
        case .handle: return .crosshair
        case .edge, .inside: return .openHand
        case .text: return .iBeam
        case .arrow: return .pointingHand
        case .empty: return .arrow
        }
    }

    /// The pointer is over a box (or none): its handles show.
    private func hover(_ id: Int?) {
        guard id != hovered else { return }
        hovered = id
        editor.needsDisplay = true
    }

    private func characterIndex(at point: NSPoint) -> Int? {
        guard let manager = editor.layoutManager, let container = editor.textContainer, let storage = editor.textStorage, storage.length > 0 else { return nil }
        let local = NSPoint(x: point.x - editor.textContainerOrigin.x, y: point.y - editor.textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = manager.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard local.y >= line.minY - 1, local.y <= line.maxY + 1 else { return nil }
        return manager.characterIndexForGlyph(at: glyph)
    }

    // MARK: Mouse

    /// True when the press landed on a drawing and was handled here.
    func mouseDown(_ event: NSEvent) -> Bool {
        let point = editor.convert(event.locationInWindow, from: nil)
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
        guard modifiers.isEmpty || modifiers == .shift,
              let index = characterIndex(at: point), let s = session(at: index),
              let c = cell(at: point, in: s), c.y >= 0 else {
            endEditing()
            return false
        }
        guard press(at: c, clicks: event.clickCount, shift: modifiers == .shift, in: s) else { return false }
        // The event loop only turns the pointer into cells; `pressMoved` and
        // `pressEnded` do the work, so tests drive a drag the same way.
        guard let window = editor.window else { return true }
        var outsideSlop = false
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let p = editor.convert(event.locationInWindow, from: nil)
            let at = pressing.flatMap { cell(at: p, in: $0.original) } ?? c
            if event.type == .leftMouseUp {
                pressEnded(at: at, point: p)
                break
            }
            if !outsideSlop, hypot(p.x - point.x, p.y - point.y) < 3 { continue }
            outsideSlop = true
            pressMoved(to: at, point: p)
            editor.displayIfNeeded()
        }
        return true
    }

    /// A mouse press on a drawing, from down to up.
    private struct Press {
        let hit: Target
        let start: Cell
        let clicks: Int
        let shift: Bool
        /// The session at the press; previews are computed from it.
        let original: Session
        /// The boxes a drag moves: the whole selection when the press is on
        /// one of its boxes.
        let group: [Int]
        /// The last preview written (its ranges are the live ones).
        var last: Session
        var moved = false
    }

    private var pressing: Press?

    /// Starts a press at a cell of the drawing in `given` (or the current one).
    @discardableResult
    func press(at c: Cell, clicks: Int = 1, shift: Bool = false, in given: Session? = nil) -> Bool {
        guard var s = given ?? current() else { return false }
        // Leaving a new empty box for something else: it goes away first.
        if let fresh = s.fresh, target(at: c, in: s).box != fresh {
            let location = s.block.range.location
            session = s
            endEditing()
            guard let again = session(at: NSMaxRange((editor.string as NSString).lineRange(for: NSRange(location: location, length: 0)))) else { return true }
            s = again
        }
        session = s
        let hit = target(at: c, in: s)
        var group: [Int] = []
        if let id = hit.box {
            if case .boxes(let ids) = s.selection, ids.contains(id) { group = ids } else { group = [id] }
        }
        pressing = Press(hit: hit, start: c, clicks: clicks, shift: shift, original: s, group: group, last: s)
        return true
    }

    /// The pointer moved to a cell while pressed: a live preview, not undoable.
    func pressMoved(to c: Cell, point: NSPoint? = nil) {
        guard var p = pressing else { return }
        p.moved = true
        defer { pressing = p }
        var next = p.original
        // Earlier previews changed the text's length: write over what is
        // there now, not over the block as it was at the press.
        next.block = p.last.block
        pulling = nil
        switch p.hit {
        case .corner(let id, let dx, let dy):
            guard let (drawing, newID) = p.original.drawing.resizing(id, corner: (dx, dy), to: c) else { return }
            next.drawing = drawing
            next.selection = .boxes([newID])
            if next.fresh == id { next.fresh = newID }
        case .handle(let id):
            // A new arrow out of the box; over another box, dropping makes it.
            let over = overBox(c, in: p.original, besides: id)
            pulling = (id, point ?? { let r = rect(c, in: next); return NSPoint(x: r.midX, y: r.midY) }(), over)
            next.selection = .boxes([id])
            editor.needsDisplay = true
        case .edge, .text, .inside:
            NSCursor.closedHand.set()
            guard let (drawing, ids) = p.original.drawing.moving(p.group, dx: c.x - p.start.x, dy: c.y - p.start.y) else { return }
            next.drawing = drawing
            next.selection = .boxes(ids)
            if let fresh = next.fresh, let k = p.group.firstIndex(of: fresh) { next.fresh = ids[k] }
        case .empty:
            band = (p.start, c)
            let r = bandRect(p.start, c)
            let picked = p.original.drawing.boxes.filter { intersects($0.rect, r) }.map(\.id)
            next.selection = picked.isEmpty ? nil : .boxes(picked)
            editor.needsDisplay = true
        case .arrow:
            return
        }
        if next.drawing.text != p.last.drawing.text {
            write(&next, undoable: false)
        } else {
            show(next)
        }
        p.last = next
    }

    /// The press ended at a cell: a click, or the drag's result as one undo step.
    func pressEnded(at c: Cell, point: NSPoint? = nil) {
        guard let p = pressing else { return }
        pressing = nil
        let pulled = pulling
        pulling = nil
        band = nil
        // The previews were not undoable: put the start back, then make the
        // result one undo step.
        var result = p.original
        result.block = p.last.block
        if p.last.drawing.text != p.original.drawing.text { write(&result, undoable: false) }
        guard p.moved else { return click(p, at: c, result: &result) }
        switch p.hit {
        case .handle(let id):
            guard let to = pulled?.target else { return show(result) }
            guard let (drawing, arrow) = result.drawing.connecting(id, to: to) else {
                show(result)
                return NSSound.beep()
            }
            result.drawing = drawing
            result.selection = .arrow(arrow, caret: drawing.label(of: arrow).map { CaretText($0) })
            write(&result, action: "New Arrow")
        case .corner, .edge, .text, .inside:
            result.drawing = p.last.drawing
            result.selection = p.last.selection
            result.fresh = p.last.fresh
            if result.drawing.text == p.original.drawing.text { return show(result) }
            write(&result, action: { if case .corner = p.hit { return "Resize Box" } else { return p.group.count > 1 ? "Move Boxes" : "Move Box" } }())
        case .empty:
            result.selection = p.last.selection
            if result.selection == nil {
                session = result
                endEditing()
            } else {
                show(result)
            }
        case .arrow:
            show(result)
        }
    }

    private func click(_ p: Press, at c: Cell, result s: inout Session) {
        switch p.hit {
        case .empty:
            guard p.clicks >= 2 else {
                session = s
                return endEditing()
            }
            let size = Self.newBoxSize
            let r = Rect(x: max(0, c.x - size.width / 2), y: max(0, c.y - 1), width: size.width, height: size.height)
            guard let (drawing, id) = s.drawing.adding(r) else {
                show(s)
                return NSSound.beep()
            }
            s.drawing = drawing
            s.selection = .text(box: id, part: 0, caret: CaretText([""]))
            s.fresh = id
            write(&s, action: "New Box")
        case .edge(let id), .corner(let id, _, _), .handle(let id):
            if p.clicks >= 2, !p.shift {
                // Double-click the border: the next box style (light, heavy, double, rounded, dashed, dotted).
                guard let drawing = s.drawing.cyclingBoxStyle(id) else {
                    show(s)
                    return NSSound.beep()
                }
                s.drawing = drawing
                s.selection = drawing.rect(of: id) == nil ? nil : .boxes([id])
                return write(&s, action: "Box Style")
            }
            s.selection = p.shift ? toggled(id, in: s.selection) : .boxes([id])
            show(s)
        case .inside(let id):
            // Off the text: edit it, the caret at its end.
            if p.shift {
                s.selection = toggled(id, in: s.selection)
                return show(s)
            }
            let part = s.drawing.part(at: c, of: id)
            s.selection = .text(box: id, part: part, caret: CaretText(s.drawing.lines(of: id, part: part)))
            show(s)
        case .text(let id):
            if p.shift {
                s.selection = toggled(id, in: s.selection)
                return show(s)
            }
            let part = s.drawing.part(at: c, of: id)
            let lines = s.drawing.lines(of: id, part: part)
            let top = s.drawing.lineStart(of: id, part: part, line: 0, of: lines) ?? c
            let line = min(max(0, c.y - top.y), lines.count - 1)
            let start = s.drawing.lineStart(of: id, part: part, line: line, of: lines) ?? c
            s.selection = .text(box: id, part: part, caret: CaretText(lines, line: line, column: c.x - start.x))
            show(s)
        case .arrow(let id) where p.clicks >= 2:
            // Double-click a line: its next line style; its end or head: the next heads
            // (forward, backward, both, none).
            if s.drawing.arrowEnd(at: c) == id {
                guard let (drawing, arrow) = s.drawing.cyclingHeads(id) else {
                    show(s)
                    return NSSound.beep()
                }
                s.drawing = drawing
                s.selection = .arrow(arrow, caret: nil)
                return write(&s, action: "Arrowheads")
            }
            guard let drawing = s.drawing.cyclingLineStyle(id) else {
                show(s)
                return NSSound.beep()
            }
            s.drawing = drawing
            s.selection = .arrow(id, caret: nil)
            write(&s, action: "Line Style")
        case .arrow(let id):
            s.selection = .arrow(id, caret: s.drawing.label(of: id).map { CaretText($0) })
            show(s)
        }
    }

    /// Shift-click: a box joins or leaves the picked boxes.
    private func toggled(_ id: Int, in selection: Selection?) -> Selection? {
        var ids: [Int]
        switch selection {
        case .boxes(let picked): ids = picked
        case .text(let box, _, _): ids = [box]
        default: ids = []
        }
        if let k = ids.firstIndex(of: id) { ids.remove(at: k) } else { ids.append(id) }
        return ids.isEmpty ? nil : .boxes(ids)
    }

    private func overBox(_ c: Cell, in s: Session, besides id: Int) -> Int? {
        s.drawing.boxes.first { $0.id != id && $0.rect.contains(c) }?.id
    }

    private func bandRect(_ a: Cell, _ b: Cell) -> Rect {
        Rect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x) + 1, height: abs(a.y - b.y) + 1)
    }

    private func intersects(_ a: Rect, _ b: Rect) -> Bool {
        a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
    }

    // MARK: Keys

    /// Typed text: into the text or label being edited; a single picked box
    /// starts editing its text at the end.
    func insert(_ typed: String) -> Bool {
        guard var s = current(), let selection = s.selection else { return false }
        switch selection {
        case .boxes(let ids):
            guard ids.count == 1 else { return true }
            var caret = CaretText(s.drawing.lines(of: ids[0], part: 0))
            caret.insert(typed)
            apply(.text(box: ids[0], part: 0, caret: caret), in: &s)
        case .text(let box, let part, var caret):
            caret.insert(typed)
            apply(.text(box: box, part: part, caret: caret), in: &s)
        case .arrow(let id, var caret?):
            caret.insert(typed)
            apply(.arrow(id, caret: caret), in: &s)
        case .arrow(_, nil):
            break
        }
        return true
    }

    /// Writes edited text (`selection` carries it) into the drawing.
    private func apply(_ selection: Selection, in s: inout Session) {
        switch selection {
        case .text(let box, let part, let caret):
            guard let (drawing, id) = s.drawing.settingText(caret.lines, of: box, part: part) else { return NSSound.beep() }
            s.drawing = drawing
            s.selection = .text(box: id, part: part, caret: caret)
            if s.fresh == box { s.fresh = id }
        case .arrow(let id, let caret?):
            guard let drawing = s.drawing.settingLabel(caret.lines, of: id) else { return NSSound.beep() }
            s.drawing = drawing
            s.selection = .arrow(id, caret: caret)
        default:
            return
        }
        write(&s, action: "Typing")
    }

    /// Editing commands while something is selected. Every other command is
    /// swallowed too: it would type into the drawing's characters.
    func command(_ selector: Selector) -> Bool {
        guard var s = current(), let selection = s.selection else { return false }
        let shift = NSApp?.currentEvent?.modifierFlags.intersection([.shift, .option]).isEmpty == false
        let lineBreak = selector == #selector(NSResponder.insertNewline(_:)) && shift
            || selector == #selector(NSResponder.insertLineBreak(_:))
            || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endEditing()
            return true
        }
        switch selection {
        case .boxes(let ids):
            switch selector {
            case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)),
                 #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
                let delta: (Int, Int) = switch selector {
                case #selector(NSResponder.moveLeft(_:)): (-1, 0)
                case #selector(NSResponder.moveRight(_:)): (1, 0)
                case #selector(NSResponder.moveUp(_:)): (0, -1)
                default: (0, 1)
                }
                guard let (drawing, moved) = s.drawing.moving(ids, dx: delta.0, dy: delta.1) else { return beep() }
                s.drawing = drawing
                s.selection = .boxes(moved)
                write(&s, action: ids.count > 1 ? "Move Boxes" : "Move Box")
            case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)),
                 #selector(NSResponder.deleteToBeginningOfLine(_:)), #selector(NSResponder.deleteWordBackward(_:)):
                deleteBoxes(ids, in: &s)
            case #selector(NSResponder.insertNewline(_:)) where ids.count == 1 && !lineBreak:
                // Enter on a picked box: type into its text, at the end.
                s.selection = .text(box: ids[0], part: 0, caret: CaretText(s.drawing.lines(of: ids[0], part: 0)))
                show(s)
            case #selector(NSResponder.insertNewline(_:)):
                endEditing()
            default:
                break
            }
        case .arrow(let id, nil):
            switch selector {
            case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)),
                 #selector(NSResponder.deleteToBeginningOfLine(_:)), #selector(NSResponder.deleteWordBackward(_:)):
                deleteArrow(id, in: &s)
            case #selector(NSResponder.insertNewline(_:)):
                endEditing()
            default:
                break
            }
        case .text(_, _, var caret), .arrow(_, var caret?):
            let edited: (CaretText) -> Selection = { caret in
                switch selection {
                case .text(let box, let part, _): .text(box: box, part: part, caret: caret)
                case .arrow(let id, _): .arrow(id, caret: caret)
                case .boxes: selection
                }
            }
            switch selector {
            case _ where lineBreak:
                caret.newline()
                apply(edited(caret), in: &s)
            case #selector(NSResponder.insertNewline(_:)):
                endEditing()
            case #selector(NSResponder.deleteBackward(_:)):
                if caret.isEmpty { return deleteSelected(selection, in: &s) }
                guard caret.backspace() else { return true }
                apply(edited(caret), in: &s)
            case #selector(NSResponder.deleteForward(_:)):
                caret.deleteForward()
                apply(edited(caret), in: &s)
            case #selector(NSResponder.deleteWordBackward(_:)):
                caret.deleteWordBackward()
                apply(edited(caret), in: &s)
            case #selector(NSResponder.deleteToBeginningOfLine(_:)):
                return deleteSelected(selection, in: &s)
            case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveBackward(_:)):
                caret.left()
                s.selection = edited(caret)
                show(s)
            case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveForward(_:)):
                caret.right()
                s.selection = edited(caret)
                show(s)
            case #selector(NSResponder.moveUp(_:)):
                caret.up()
                s.selection = edited(caret)
                show(s)
            case #selector(NSResponder.moveDown(_:)):
                caret.down()
                s.selection = edited(caret)
                show(s)
            case #selector(NSResponder.moveToBeginningOfLine(_:)), #selector(NSResponder.moveToLeftEndOfLine(_:)):
                caret.home()
                s.selection = edited(caret)
                show(s)
            case #selector(NSResponder.moveToEndOfLine(_:)), #selector(NSResponder.moveToRightEndOfLine(_:)):
                caret.end()
                s.selection = edited(caret)
                show(s)
            default:
                break
            }
        }
        return true
    }

    private func beep() -> Bool {
        NSSound.beep()
        return true
    }

    private func deleteSelected(_ selection: Selection, in s: inout Session) -> Bool {
        switch selection {
        case .boxes(let ids): deleteBoxes(ids, in: &s)
        case .text(let box, _, _): deleteBoxes([box], in: &s)
        case .arrow(let id, _): deleteArrow(id, in: &s)
        }
        return true
    }

    private func deleteBoxes(_ ids: [Int], in s: inout Session) {
        guard let drawing = s.drawing.deleting(ids) else { return NSSound.beep() }
        s.drawing = drawing
        s.selection = nil
        s.fresh = nil
        write(&s, action: ids.count > 1 ? "Delete Boxes" : "Delete Box")
    }

    private func deleteArrow(_ id: Int, in s: inout Session) {
        guard let drawing = s.drawing.deletingArrow(id) else { return NSSound.beep() }
        s.drawing = drawing
        s.selection = nil
        write(&s, action: "Delete Arrow")
    }

    // MARK: Drawing

    /// Selection rings, the typing caret, the selection rectangle and a
    /// pulled arrow, over the text.
    func draw() {
        guard let s = current() else { return }
        let accent = NSColor.controlAccentColor
        if let band {
            let r = rect(bandRect(band.from, band.to), in: s)
            accent.withAlphaComponent(0.12).setFill()
            r.fill()
            let edge = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            edge.lineWidth = 1
            accent.withAlphaComponent(0.8).setStroke()
            edge.stroke()
        }
        if let pulled = pulling, let from = s.drawing.rect(of: pulled.from) {
            let r = rect(from, in: s)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: r.midX, y: r.midY))
            path.line(to: pulled.to)
            path.lineWidth = 1.5
            path.setLineDash([4, 3], count: 2, phase: 0)
            accent.setStroke()
            path.stroke()
            if let target = pulled.target, let to = s.drawing.rect(of: target) { ring(rect(to, in: s), dashed: true) }
        }
        if pressing == nil, let id = hovered, let r = s.drawing.rect(of: id) { drawHandles(rect(r, in: s)) }
        guard let selection = s.selection else { return }
        switch selection {
        case .boxes(let ids):
            for id in ids { if let r = s.drawing.rect(of: id) { ring(rect(r, in: s)) } }
        case .text(let box, let part, let caret):
            guard let r = s.drawing.rect(of: box),
                  let start = s.drawing.lineStart(of: box, part: part, line: caret.line, of: caret.lines) else { return }
            ring(rect(r, in: s))
            drawCaret(Cell(x: start.x + caret.column, y: start.y), in: s)
        case .arrow(let id, let caret):
            accent.withAlphaComponent(0.25).setFill()
            for c in s.drawing.cells(of: id) { rect(c, in: s).fill() }
            if let caret, let origin = s.drawing.labelOrigin(of: id) {
                drawCaret(Cell(x: origin.x + caret.column, y: origin.y + caret.line), in: s)
            }
        }
    }

    private func ring(_ r: NSRect, dashed: Bool = false) {
        let path = NSBezierPath(roundedRect: r.insetBy(dx: -2, dy: -1), xRadius: 4, yRadius: 4)
        path.lineWidth = 2
        if dashed { path.setLineDash([4, 3], count: 2, phase: 0) }
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        path.stroke()
    }

    /// A small ✛ in the middle of each side: drag it for a new arrow.
    private func drawHandles(_ r: NSRect) {
        let cell = cellSize
        let centers = [NSPoint(x: r.midX, y: r.minY + cell.height / 2), NSPoint(x: r.midX, y: r.maxY - cell.height / 2),
                       NSPoint(x: r.minX + cell.width / 2, y: r.midY), NSPoint(x: r.maxX - cell.width / 2, y: r.midY)]
        let radius = min(cell.width, cell.height) * 0.45
        for p in centers {
            let dot = NSBezierPath(ovalIn: NSRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            editor.backgroundColor.setFill()
            dot.fill()
            NSColor.controlAccentColor.setStroke()
            dot.lineWidth = 1.2
            dot.stroke()
            let plus = NSBezierPath()
            plus.move(to: NSPoint(x: p.x - radius * 0.55, y: p.y))
            plus.line(to: NSPoint(x: p.x + radius * 0.55, y: p.y))
            plus.move(to: NSPoint(x: p.x, y: p.y - radius * 0.55))
            plus.line(to: NSPoint(x: p.x, y: p.y + radius * 0.55))
            plus.lineWidth = 1.2
            plus.stroke()
        }
    }

    /// The caret blinks like the text view's own; any change shows it again.
    private func drawCaret(_ c: Cell, in s: Session) {
        startBlinking()
        guard caretOn else { return }
        let r = rect(c, in: s)
        NSColor.controlAccentColor.setFill()
        NSRect(x: r.minX, y: r.minY + 1, width: 1.5, height: cellSize.height - 2).fill()
    }

    private func startBlinking() {
        guard blink == nil else { return }
        blink = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch self.session?.selection {
                case .text?, .arrow(_, caret: _?)?:
                    self.caretOn.toggle()
                    self.editor.needsDisplay = true
                default:
                    self.blink?.invalidate()
                    self.blink = nil
                    self.caretOn = true
                }
            }
        }
    }

    // MARK: Mermaid ⇄ drawing

    /// Blocks that get a switch button: a Mermaid flowchart, or a drawing.
    struct Switchable {
        var block: Markdown.FencedBlock
        var toDrawing: Bool
    }

    private var parseCache: [String: Bool] = [:]

    func switchables() -> [Switchable] {
        guard let storage = editor.textStorage, storage.length <= MarkdownPainter.maxLength else { return [] }
        let ns = storage.string as NSString
        var out: [Switchable] = []
        for block in Markdown.fencedBlocks(in: storage.string) {
            let text = Self.drawingText(block, in: ns)
            if block.info == "mermaid" {
                let key = "m:" + text
                let ok = parseCache[key] ?? (MermaidASCII.parse(text).map { !$0.nodes.isEmpty } ?? false)
                cache(key, ok)
                if ok { out.append(Switchable(block: block, toDrawing: true)) }
            } else if Self.languages.contains(block.info), text.contains("┌") {
                let key = "a:" + text
                let ok = parseCache[key] ?? (AsciiDiagram.parse(text) != nil)
                cache(key, ok)
                if ok { out.append(Switchable(block: block, toDrawing: false)) }
            }
        }
        return out
    }

    private func cache(_ key: String, _ value: Bool) {
        if parseCache.count > 200 { parseCache.removeAll() }
        parseCache[key] = value
    }

    /// Mermaid becomes an editable drawing, a drawing becomes Mermaid. One
    /// undo step; the way back from an unchanged drawing gives the exact
    /// Mermaid it came from.
    func switchBlock(at location: Int) {
        guard let storage = editor.textStorage else { return }
        let ns = storage.string as NSString
        guard let block = Markdown.fencedBlocks(in: storage.string).first(where: { $0.range.location == location }) else { return }
        endEditing()
        let text = Self.drawingText(block, in: ns)
        let replacement: String
        if block.info == "mermaid" {
            guard let diagram = AsciiDiagram.fromMermaid(text) else { return NSSound.beep() }
            let art = AsciiDiagram.render(diagram).text
            mermaidSources[art] = text
            replacement = "```\n" + art + "\n" + ns.substring(with: block.closing)
        } else {
            guard let diagram = AsciiDiagram.parse(text) else { return NSSound.beep() }
            let source = mermaidSources[text] ?? AsciiDiagram.mermaid(diagram)
            replacement = "```mermaid\n" + source + "\n" + ns.substring(with: block.closing)
        }
        let range = NSRange(location: block.range.location, length: NSMaxRange(block.closing) - block.range.location)
        guard editor.shouldChangeText(in: range, replacementString: replacement) else { return }
        storage.replaceCharacters(in: range, with: replacement)
        editor.didChangeText()
        editor.undoManager?.setActionName(block.info == "mermaid" ? "Mermaid to Drawing" : "Drawing to Mermaid")
        // The caret right after the block: a Mermaid block shows as art.
        let after = min(block.range.location + (replacement as NSString).length, storage.length)
        editor.setSelectedRange(NSRange(location: after, length: 0))
        if block.info == "mermaid", let s = session(at: block.range.location + 4) { reportWidth(s) }
    }

    // MARK: New drawing

    /// The ◇ button: a drawing block at the caret with one box, its title
    /// ready to type.
    func insertDrawing() {
        guard let storage = editor.textStorage else { return }
        endEditing()
        let ns = storage.string as NSString
        let selection = editor.selectedRange()
        let line = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        let lineText = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
        // On its own lines: after the current line unless that line is empty.
        var at = lineText.isEmpty ? line.location : NSMaxRange(line)
        var prefix = ""
        if at == ns.length, at > 0, ns.character(at: at - 1) != 10 { prefix = "\n" }
        if !lineText.isEmpty, NSMaxRange(line) == ns.length, ns.length > 0, ns.character(at: ns.length - 1) != 10 { prefix = "\n" }
        let box = AsciiDiagram.Box(id: 0, x: 0, y: 0, width: Self.newBoxSize.width, height: Self.newBoxSize.height, text: [""])
        let diagram = AsciiDiagram.Diagram(boxes: [box], arrows: [])
        let art = AsciiDiagram.render(diagram).text
        let insertion = prefix + "```\n" + art + "\n```\n"
        at = min(at, ns.length)
        guard editor.shouldChangeText(in: NSRange(location: at, length: 0), replacementString: insertion) else { return }
        storage.replaceCharacters(in: NSRange(location: at, length: 0), with: insertion)
        editor.didChangeText()
        editor.undoManager?.setActionName("New Drawing")
        guard var s = session(at: at + (prefix as NSString).length + 4), let first = s.drawing.boxes.first else { return }
        s.selection = .text(box: first.id, part: 0, caret: CaretText([""]))
        s.fresh = nil
        session = s
        editor.setSelectedRange(NSRange(location: s.block.content.location, length: 0))
        reportWidth(s)
        editor.needsDisplay = true
    }
}
