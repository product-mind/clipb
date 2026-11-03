import AppKit

/// A box-and-arrow drawing inside a ``` block (MODAL.md). The block's text IS
/// the drawing, box-drawing characters that paste anywhere; this keeps the
/// model while you edit and rewrites the block on every change. A block is a
/// drawing only when `AsciiDiagram.parse` reads it back exactly, so other
/// code blocks are never touched.
///
/// Mouse: click empty space for a box (drag to size it), click a box to type
/// its title, drag it to move, drag a corner to resize, drag from a side to
/// pull an arrow (drop on a box to connect, on empty space for a new box).
/// Click an arrow to type its label. Shift+Enter: a new line. Enter, Esc or a
/// click elsewhere: done. Backspace on an empty title, or ⌘⌫: delete it.
final class DiagramCanvas {
    enum Selection: Equatable { case box(Int), arrow(Int) }

    struct Session {
        /// Ranges as of the last write.
        var block: Markdown.FencedBlock
        var diagram: AsciiDiagram.Diagram
        var rendered: AsciiDiagram.Rendered
        var selection: Selection?
        /// A box made by a click or a drag: dropped again when left empty
        /// and unconnected.
        var fresh: Int?
        /// Hand-drawn art (not ClipB's own layout): edited in place, every
        /// other character stays as drawn. `diagram` is unused then.
        var art: AsciiArt.Scene?
        /// The art box's compartment that typing goes into.
        var compartment = 0
    }

    /// Languages a drawing's fence may carry; a plain ``` is the usual one.
    static let languages: Set<String> = ["", "text", "txt", "ascii", "diagram"]
    /// A new box: wide enough to start typing into.
    static let newBoxSize = (width: 14, height: 3)

    unowned let editor: EditorTextView
    private var session: Session?
    /// An arrow being pulled out of a box: its source and the pointer.
    private var pulling: (from: Int, to: NSPoint)?
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

    /// Hand-drawn art in a drawing fence: at least one closed box.
    static func art(_ block: Markdown.FencedBlock, in ns: NSString) -> AsciiArt.Scene? {
        guard languages.contains(block.info) else { return nil }
        let text = drawingText(block, in: ns)
        guard text.contains("┌"), let scene = AsciiArt.scan(text), !scene.boxes.isEmpty else { return nil }
        return scene
    }

    static func drawing(_ block: Markdown.FencedBlock, in ns: NSString) -> AsciiDiagram.Diagram? {
        guard languages.contains(block.info) else { return nil }
        let text = drawingText(block, in: ns)
        guard text.contains("┌") else { return nil }
        return AsciiDiagram.parse(text)
    }

    /// The session still matches the text (no undo, no typing behind its back).
    private func current() -> Session? {
        guard let s = session, let storage = editor.textStorage else { return nil }
        let ns = storage.string as NSString
        guard NSMaxRange(s.block.range) <= ns.length,
              Self.drawingText(s.block, in: ns) == s.rendered.text,
              let block = Markdown.fencedBlocks(in: storage.string).first(where: { $0.range.location == s.block.range.location }),
              block.content == s.block.content else {
            session = nil
            return nil
        }
        return s
    }

    /// A selection is active: keys type into it.
    var isEditing: Bool { current()?.selection != nil }

    /// The drawing block under a text index, as a session.
    private func session(at index: Int) -> Session? {
        guard let storage = editor.textStorage else { return nil }
        if let s = current(), index >= s.block.range.location, index <= NSMaxRange(s.block.closing) { return s }
        let ns = storage.string as NSString
        guard let block = Markdown.fencedBlocks(in: storage.string).first(where: {
            index >= NSMaxRange(ns.lineRange(for: NSRange(location: $0.range.location, length: 0))) && index <= NSMaxRange($0.closing)
        }) else { return nil }
        if let diagram = Self.drawing(block, in: ns) {
            return Session(block: block, diagram: diagram, rendered: AsciiDiagram.render(diagram))
        }
        guard let scene = Self.art(block, in: ns) else { return nil }
        return Session(block: block, diagram: AsciiDiagram.Diagram(), rendered: Self.rendered(scene), art: scene)
    }

    /// Writes the drawing into its block. `undoable` false for drag previews.
    private func write(_ s: inout Session, undoable: Bool = true, action: String? = nil) {
        guard let storage = editor.textStorage else { return }
        s.rendered = s.art.map(Self.rendered) ?? AsciiDiagram.render(s.diagram)
        let content = s.rendered.text.isEmpty ? "" : s.rendered.text + "\n"
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
        // The text caret parks at the block's start, hidden while editing.
        editor.setSelectedRange(NSRange(location: s.block.content.location, length: 0))
        reportWidth(s)
        editor.needsDisplay = true
    }

    private func reportWidth(_ s: Session) {
        report(columns: s.rendered.text.components(separatedBy: "\n").map(\.count).max() ?? 0)
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

    /// Leaves the selection; an empty new box goes away again.
    func endEditing() {
        guard var s = current(), s.selection != nil else { return }
        let fresh = s.fresh
        s.selection = nil
        s.fresh = nil
        pulling = nil
        if let fresh, let scene = s.art {
            let empty = AsciiArt.text(of: fresh, compartment: 0, in: scene).allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            let linked = scene.links.contains { $0.ends.contains { $0.box == fresh } }
            if empty, !linked, scene.boxes.count > 1, let edit = AsciiArt.deleteBox(fresh, in: scene) {
                s.art = edit.scene
                write(&s, action: "Delete Box")
            } else {
                session = s
            }
        } else if let fresh, let box = s.diagram.boxes.first(where: { $0.id == fresh }),
           box.text.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }),
           !s.diagram.arrows.contains(where: { $0.from == fresh || $0.to == fresh }), s.diagram.boxes.count > 1 {
            s.diagram.boxes.removeAll { $0.id == fresh }
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

    private func cell(at point: NSPoint, in s: Session) -> AsciiDiagram.Cell? {
        guard let o = origin(s) else { return nil }
        let size = cellSize
        return AsciiDiagram.Cell(x: max(0, Int(floor((point.x - o.x) / size.width))), y: Int(floor((point.y - o.y) / size.height)))
    }

    private func rect(_ r: AsciiDiagram.Rect, in s: Session) -> NSRect {
        let o = origin(s) ?? .zero
        let size = cellSize
        return NSRect(x: o.x + CGFloat(r.x) * size.width, y: o.y + CGFloat(r.y) * size.height,
                      width: CGFloat(r.width) * size.width, height: CGFloat(r.height) * size.height)
    }

    // MARK: Hit testing

    private enum Target {
        case corner(Int, dx: Int, dy: Int)   // which corner: -1 left/top, 1 right/bottom
        case side(Int)
        case inside(Int)
        case arrow(Int)
        case empty
    }

    /// Every box's id and rectangle, whichever kind of drawing.
    private func boxRects(_ s: Session) -> [(id: Int, rect: AsciiDiagram.Rect)] {
        s.art.map { $0.boxes.map { ($0.id, $0.rect) } } ?? s.diagram.boxes.map { ($0.id, $0.rect) }
    }

    private func target(at c: AsciiDiagram.Cell, in s: Session) -> Target {
        for box in boxRects(s) {
            let r = box.rect
            guard r.contains(c) else { continue }
            let left = c.x == r.x, right = c.x == r.x + r.width - 1
            let top = c.y == r.y, bottom = c.y == r.y + r.height - 1
            if (left || right) && (top || bottom) { return .corner(box.id, dx: left ? -1 : 1, dy: top ? -1 : 1) }
            if left || right || top || bottom { return .side(box.id) }
            return .inside(box.id)
        }
        if let scene = s.art {
            for link in scene.links where link.cells.contains(c) { return .arrow(link.id) }
            for link in scene.links where link.cells.contains(where: { abs($0.x - c.x) + abs($0.y - c.y) <= 1 }) { return .arrow(link.id) }
            return .empty
        }
        for (id, r) in s.rendered.labels where r.contains(c) { return .arrow(id) }
        for (id, path) in s.rendered.paths where path.contains(c) { return .arrow(id) }
        // A near miss on a thin line still picks it.
        for (id, path) in s.rendered.paths where path.contains(where: { abs($0.x - c.x) <= 1 && abs($0.y - c.y) <= 0 || abs($0.x - c.x) <= 0 && abs($0.y - c.y) <= 1 }) {
            return .arrow(id)
        }
        return .empty
    }

    /// Hover: what a press here would do.
    func cursor(at point: NSPoint) -> NSCursor? {
        guard let index = characterIndex(at: point), let s = session(at: index), let c = cell(at: point, in: s), c.y >= 0 else { return nil }
        switch target(at: c, in: s) {
        case .corner:
            if #available(macOS 15.0, *) { return .frameResize(position: .bottomRight, directions: .all) }
            return .crosshair
        case .side: return .crosshair
        case .inside: return .openHand
        case .arrow: return .pointingHand
        case .empty: return .arrow
        }
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
        guard event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
              let index = characterIndex(at: point), let s = session(at: index),
              let c = cell(at: point, in: s), c.y >= 0 else {
            endEditing()
            return false
        }
        guard press(at: c, in: s) else { return false }
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
        let start: AsciiDiagram.Cell
        /// The session at the press; previews are computed from it.
        let original: Session
        /// The last preview written (its ranges are the live ones).
        var last: Session
        var moved = false
    }

    private var pressing: Press?

    /// Starts a press at a cell of the drawing in `s`.
    @discardableResult
    func press(at c: AsciiDiagram.Cell, in given: Session? = nil) -> Bool {
        guard var s = given ?? current() else { return false }
        // Leaving one element for another: an empty new box goes away first.
        if s.selection != nil, s.fresh != nil {
            let location = s.block.range.location
            session = s
            endEditing()
            guard let again = session(at: NSMaxRange((editor.string as NSString).lineRange(for: NSRange(location: location, length: 0)))) else { return true }
            s = again
        }
        session = s
        pressing = Press(hit: target(at: c, in: s), start: c, original: s, last: s)
        return true
    }

    /// The pointer moved to a cell while pressed: a live preview, not undoable.
    func pressMoved(to c: AsciiDiagram.Cell, point: NSPoint? = nil) {
        guard var p = pressing else { return }
        p.moved = true
        defer { pressing = p }
        var next = p.original
        // Earlier previews changed the text's length: write over what is
        // there now, not over the block as it was at the press.
        next.block = p.last.block
        if next.art != nil {
            guard artPreview(&next, press: p, to: c, point: point) else { return }
            guard next.art?.text != p.last.art?.text || next.selection != p.last.selection else { return }
            write(&next, undoable: false)
            p.last = next
            return
        }
        switch p.hit {
        case .inside(let id):
            NSCursor.closedHand.set()
            guard move(id, by: (c.x - p.start.x, c.y - p.start.y), in: &next.diagram) else { return }
            next.selection = .box(id)
        case .corner(let id, let dx, let dy):
            resize(id, corner: (dx, dy), to: c, in: &next.diagram)
            next.selection = .box(id)
        case .side(let id):
            pulling = (id, point ?? rect(AsciiDiagram.Rect(x: c.x, y: c.y, width: 1, height: 1), in: next).origin)
            editor.needsDisplay = true
            return
        case .empty:
            let box = boxSpanning(p.start, c, id: nextBoxID(next.diagram))
            guard !overlaps(box, in: next.diagram) else { return }
            next.diagram.boxes.append(box)
            next.selection = .box(box.id)
            next.fresh = box.id
        case .arrow:
            return
        }
        guard next.diagram != p.last.diagram || next.selection != p.last.selection else { return }
        write(&next, undoable: false)
        p.last = next
    }

    /// The press ended at a cell: a click, or the drag's result as one undo step.
    func pressEnded(at c: AsciiDiagram.Cell, point: NSPoint? = nil) {
        guard let p = pressing else { return }
        pressing = nil
        pulling = nil
        // The previews were not undoable: put the start back, then make the
        // result one undo step.
        var result = p.original
        result.block = p.last.block
        if p.last.diagram != p.original.diagram || p.last.art != p.original.art { write(&result, undoable: false) }
        if result.art != nil {
            artEnded(p, at: c, result: &result)
            return
        }
        if !p.moved {
            click(p.hit, at: p.start, in: &result)
            return
        }
        switch p.hit {
        case .inside(let id), .corner(let id, _, _):
            result.diagram = p.last.diagram
            result.selection = .box(id)
            write(&result, action: "Move Box")
        case .empty:
            result.diagram = p.last.diagram
            result.selection = p.last.selection
            result.fresh = p.last.fresh
            write(&result, action: "New Box")
        case .side(let id):
            connect(from: id, at: c, in: &result)
        case .arrow:
            session = result
        }
    }

    /// For tests: a session on the drawing block that holds a text index.
    func begin(at index: Int) -> Bool {
        guard let s = session(at: index) else { return false }
        session = s
        return true
    }

    /// For tests: the selected box or arrow.
    var selection: Selection? { current()?.selection }

    private func click(_ hit: Target, at c: AsciiDiagram.Cell, in s: inout Session) {
        switch hit {
        case .inside(let id), .side(let id), .corner(let id, _, _):
            s.selection = .box(id)
            session = s
        case .arrow(let id):
            s.selection = .arrow(id)
            session = s
        case .empty:
            if s.selection != nil {
                // The first click away just finishes the edit.
                session = s
                endEditing()
                return
            }
            let size = Self.newBoxSize
            let box = AsciiDiagram.Box(id: nextBoxID(s.diagram), x: max(0, c.x - size.width / 2), y: max(0, c.y - 1),
                                       width: size.width, height: size.height, text: [""])
            guard !overlaps(box, in: s.diagram) else { return }
            s.diagram.boxes.append(box)
            s.selection = .box(box.id)
            s.fresh = box.id
            write(&s, action: "New Box")
            return
        }
        editor.setSelectedRange(NSRange(location: s.block.content.location, length: 0))
        editor.needsDisplay = true
    }

    /// A pulled arrow dropped: onto a box connects it; onto empty space it
    /// makes a box there, ready for its title.
    private func connect(from id: Int, at c: AsciiDiagram.Cell, in s: inout Session) {
        let arrowID = (s.diagram.arrows.map(\.id).max() ?? -1) + 1
        if let target = s.diagram.boxes.first(where: { $0.rect.contains(c) }) {
            guard target.id != id else {
                session = s
                editor.needsDisplay = true
                return
            }
            s.diagram.arrows.append(AsciiDiagram.Arrow(id: arrowID, from: id, to: target.id, label: []))
            s.selection = .arrow(arrowID)
            write(&s, action: "New Arrow")
            return
        }
        let size = Self.newBoxSize
        var box = AsciiDiagram.Box(id: nextBoxID(s.diagram), x: max(0, c.x - size.width / 2), y: max(0, c.y - 1),
                                   width: size.width, height: size.height, text: [""])
        // Nudged off anything it would land on.
        var tries = 0
        while overlaps(box, in: s.diagram), tries < 40 {
            box.y += 1
            tries += 1
        }
        s.diagram.boxes.append(box)
        s.diagram.arrows.append(AsciiDiagram.Arrow(id: arrowID, from: id, to: box.id, label: []))
        s.selection = .box(box.id)
        s.fresh = box.id
        write(&s, action: "New Box")
    }

    private func nextBoxID(_ d: AsciiDiagram.Diagram) -> Int { (d.boxes.map(\.id).max() ?? -1) + 1 }

    /// Boxes keep one free cell between them, so arrows can still leave.
    private func overlaps(_ box: AsciiDiagram.Box, in d: AsciiDiagram.Diagram) -> Bool {
        d.boxes.contains { other in
            other.id != box.id
                && box.x <= other.x + other.width && other.x <= box.x + box.width
                && box.y <= other.y + other.height && other.y <= box.y + box.height
        }
    }

    private func move(_ id: Int, by delta: (Int, Int), in d: inout AsciiDiagram.Diagram) -> Bool {
        guard let k = d.boxes.firstIndex(where: { $0.id == id }) else { return false }
        var box = d.boxes[k]
        box.x = max(0, box.x + delta.0)
        box.y = max(0, box.y + delta.1)
        guard !overlaps(box, in: d) else { return false }
        d.boxes[k] = box
        return true
    }

    private func resize(_ id: Int, corner: (Int, Int), to c: AsciiDiagram.Cell, in d: inout AsciiDiagram.Diagram) {
        guard let k = d.boxes.firstIndex(where: { $0.id == id }) else { return }
        let old = d.boxes[k]
        let smallest = AsciiDiagram.fitted(AsciiDiagram.Box(id: id, x: 0, y: 0, width: 0, height: 0, text: old.text))
        var left = old.x, top = old.y, right = old.x + old.width - 1, bottom = old.y + old.height - 1
        if corner.0 < 0 { left = max(0, min(c.x, right - smallest.width + 1)) } else { right = max(c.x, left + smallest.width - 1) }
        if corner.1 < 0 { top = max(0, min(c.y, bottom - smallest.height + 1)) } else { bottom = max(c.y, top + smallest.height - 1) }
        var box = old
        box.x = left
        box.y = top
        box.width = right - left + 1
        box.height = bottom - top + 1
        guard !overlaps(box, in: d) else { return }
        d.boxes[k] = box
    }

    private func boxSpanning(_ a: AsciiDiagram.Cell, _ b: AsciiDiagram.Cell, id: Int) -> AsciiDiagram.Box {
        let x = min(a.x, b.x), y = max(0, min(a.y, b.y))
        return AsciiDiagram.Box(id: id, x: x, y: y,
                                width: max(AsciiDiagram.minWidth, abs(a.x - b.x) + 1),
                                height: max(AsciiDiagram.minHeight, abs(a.y - b.y) + 1), text: [""])
    }

    // MARK: Keys

    /// Text typed while a box or arrow is selected goes into its title.
    func insert(_ typed: String) -> Bool {
        guard var s = current(), let selection = s.selection else { return false }
        // Art arrows carry no text of their own: typing on one does nothing.
        if s.art != nil, case .arrow = selection { return true }
        let pieces = typed.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        edit(selection, in: &s) { lines in
            lines[lines.count - 1] += pieces[0]
            lines.append(contentsOf: pieces.dropFirst())
        }
        write(&s, action: "Typing")
        return true
    }

    /// Editing commands while a box or arrow is selected. Every other command
    /// is swallowed too: it would type into the drawing's characters.
    func command(_ selector: Selector) -> Bool {
        guard var s = current(), let selection = s.selection else { return false }
        let shift = NSApp.currentEvent?.modifierFlags.intersection([.shift, .option]).isEmpty == false
        switch selector {
        case #selector(NSResponder.insertNewline(_:)) where shift,
             #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            edit(selection, in: &s) { $0.append("") }
            write(&s, action: "Typing")
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)):
            endEditing()
        case #selector(NSResponder.deleteBackward(_:)):
            if text(of: selection, in: s) == [""] { return delete(selection, in: &s) }
            edit(selection, in: &s) { lines in
                if lines[lines.count - 1].isEmpty, lines.count > 1 { lines.removeLast() } else { lines[lines.count - 1].removeLast() }
            }
            write(&s, action: "Typing")
        case #selector(NSResponder.deleteForward(_:)), #selector(NSResponder.deleteToBeginningOfLine(_:)),
             #selector(NSResponder.deleteWordBackward(_:)):
            if selector == #selector(NSResponder.deleteWordBackward(_:)), text(of: selection, in: s) != [""] {
                edit(selection, in: &s) { lines in
                    var last = lines[lines.count - 1]
                    while last.last == " " { last.removeLast() }
                    while let ch = last.last, ch != " " { last.removeLast() }
                    lines[lines.count - 1] = last
                }
                write(&s, action: "Typing")
                return true
            }
            return delete(selection, in: &s)
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)),
             #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            guard case .box(let id) = selection else { return true }
            let delta: (Int, Int) = switch selector {
            case #selector(NSResponder.moveLeft(_:)): (-1, 0)
            case #selector(NSResponder.moveRight(_:)): (1, 0)
            case #selector(NSResponder.moveUp(_:)): (0, -1)
            default: (0, 1)
            }
            if let scene = s.art {
                if let edit = AsciiArt.move(id, dx: delta.0, dy: delta.1, in: scene) {
                    s.art = edit.scene
                    s.selection = .box(edit.box ?? id)
                    if s.fresh == id { s.fresh = edit.box ?? id }
                    write(&s, action: "Move Box")
                } else {
                    NSSound.beep()
                }
            } else if move(id, by: delta, in: &s.diagram) {
                write(&s, action: "Move Box")
            }
        default:
            break
        }
        return true
    }

    private func text(of selection: Selection, in s: Session) -> [String] {
        if let scene = s.art {
            guard case .box(let id) = selection else { return [""] }
            var lines = AsciiArt.text(of: id, compartment: s.compartment, in: scene)
            // Blank padding rows under the text are not part of it.
            while lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
            return lines.isEmpty ? [""] : lines
        }
        switch selection {
        case .box(let id): return s.diagram.boxes.first { $0.id == id }?.text ?? [""]
        case .arrow(let id):
            let label = s.diagram.arrows.first { $0.id == id }?.label ?? []
            return label.isEmpty ? [""] : label
        }
    }

    private func edit(_ selection: Selection, in s: inout Session, _ change: (inout [String]) -> Void) {
        if let scene = s.art {
            guard case .box(let id) = selection else { return }
            var lines = text(of: selection, in: s)
            change(&lines)
            guard let edit = AsciiArt.setText(lines, box: id, compartment: s.compartment, in: scene) else { return NSSound.beep() }
            s.art = edit.scene
            s.selection = .box(edit.box ?? id)
            if s.fresh == id { s.fresh = edit.box ?? id }
            return
        }
        switch selection {
        case .box(let id):
            guard let k = s.diagram.boxes.firstIndex(where: { $0.id == id }) else { return }
            var lines = s.diagram.boxes[k].text.isEmpty ? [""] : s.diagram.boxes[k].text
            change(&lines)
            s.diagram.boxes[k].text = lines
            var grown = AsciiDiagram.fitted(s.diagram.boxes[k])
            // Growing into a neighbour: grow anyway, the drawing stays legible
            // only with the text inside its box.
            grown.width = max(grown.width, s.diagram.boxes[k].width)
            s.diagram.boxes[k] = grown
        case .arrow(let id):
            guard let k = s.diagram.arrows.firstIndex(where: { $0.id == id }) else { return }
            var lines = s.diagram.arrows[k].label.isEmpty ? [""] : s.diagram.arrows[k].label
            change(&lines)
            s.diagram.arrows[k].label = lines == [""] ? [] : lines
        }
    }

    private func delete(_ selection: Selection, in s: inout Session) -> Bool {
        if let scene = s.art {
            let edit: AsciiArt.Edit? = switch selection {
            case .box(let id): AsciiArt.deleteBox(id, in: scene)
            case .arrow(let id): AsciiArt.deleteLink(id, in: scene)
            }
            guard let edit else {
                NSSound.beep()
                return true
            }
            s.art = edit.scene
            s.selection = nil
            s.fresh = nil
            write(&s, action: "Delete")
            return true
        }
        switch selection {
        case .box(let id):
            s.diagram.boxes.removeAll { $0.id == id }
            s.diagram.arrows.removeAll { $0.from == id || $0.to == id }
        case .arrow(let id):
            s.diagram.arrows.removeAll { $0.id == id }
        }
        s.selection = nil
        s.fresh = nil
        write(&s, action: "Delete")
        return true
    }

    // MARK: Drawing

    /// Selection ring, typing caret and a pulled arrow, over the text.
    func draw() {
        guard let s = current() else { return }
        let size = cellSize
        let accent = NSColor.controlAccentColor
        if let from = pulling, let box = boxRects(s).first(where: { $0.id == from.from }) {
            let r = rect(box.rect, in: s)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: r.midX, y: r.midY))
            path.line(to: from.to)
            path.lineWidth = 1.5
            path.setLineDash([4, 3], count: 2, phase: 0)
            accent.setStroke()
            path.stroke()
        }
        guard let selection = s.selection else { return }
        if let scene = s.art {
            drawArtSelection(selection, scene: scene, in: s)
            return
        }
        var caret: AsciiDiagram.Cell?
        switch selection {
        case .box(let id):
            guard let box = s.diagram.boxes.first(where: { $0.id == id }) else { return }
            let ring = NSBezierPath(roundedRect: rect(box.rect, in: s).insetBy(dx: -2, dy: -1), xRadius: 4, yRadius: 4)
            ring.lineWidth = 2
            accent.withAlphaComponent(0.8).setStroke()
            ring.stroke()
            let lines = box.text.isEmpty ? [""] : box.text
            caret = AsciiDiagram.Cell(x: box.x + 2 + lines[lines.count - 1].count, y: box.y + lines.count)
        case .arrow(let id):
            for c in s.rendered.paths[id] ?? [] {
                accent.withAlphaComponent(0.25).setFill()
                rect(AsciiDiagram.Rect(x: c.x, y: c.y, width: 1, height: 1), in: s).fill()
            }
            let label = (s.diagram.arrows.first { $0.id == id }?.label ?? [])
            if let r = s.rendered.labels[id] {
                let ring = NSBezierPath(roundedRect: rect(r, in: s).insetBy(dx: -3, dy: -1), xRadius: 3, yRadius: 3)
                ring.lineWidth = 1.5
                accent.withAlphaComponent(0.8).setStroke()
                ring.stroke()
                let shown = label.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if label.last?.trimmingCharacters(in: .whitespaces).isEmpty == true, label.count > 1 {
                    caret = AsciiDiagram.Cell(x: r.x, y: r.y + r.height)
                } else {
                    caret = AsciiDiagram.Cell(x: r.x + (shown.last?.count ?? 0), y: r.y + r.height - 1)
                }
            } else if let path = s.rendered.paths[id], !path.isEmpty {
                let middle = path[path.count / 2]
                caret = AsciiDiagram.Cell(x: middle.x + 1, y: max(0, middle.y - 1))
            }
        }
        if let caret {
            let r = rect(AsciiDiagram.Rect(x: caret.x, y: caret.y, width: 1, height: 1), in: s)
            accent.setFill()
            NSRect(x: r.minX, y: r.minY + 1, width: 1.5, height: size.height - 2).fill()
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
        guard var s = session(at: at + (prefix as NSString).length + 4) else { return }
        s.selection = .box(s.diagram.boxes.first?.id ?? 0)
        s.fresh = nil
        session = s
        editor.setSelectedRange(NSRange(location: s.block.content.location, length: 0))
        reportWidth(s)
        editor.needsDisplay = true
    }

    // MARK: Hand-drawn art

    static func rendered(_ scene: AsciiArt.Scene) -> AsciiDiagram.Rendered {
        AsciiDiagram.Rendered(text: scene.text, paths: [:], labels: [:], unrouted: [])
    }

    /// The compartment of an art box holding a cell (the first one for its border).
    private func compartment(at c: AsciiDiagram.Cell, of id: Int, in scene: AsciiArt.Scene) -> Int {
        guard let box = scene.boxes.first(where: { $0.id == id }) else { return 0 }
        return box.compartments.firstIndex { $0.y <= c.y && c.y < $0.y + $0.height } ?? 0
    }

    /// The box with this rectangle after an edit renumbered the boxes.
    private func boxID(at rect: AsciiDiagram.Rect, in scene: AsciiArt.Scene) -> Int? {
        scene.boxes.first { $0.rect == rect }?.id
    }

    /// One drag preview of an art edit, always from the art at the press.
    /// False when the drag shows nothing new (blocked, or pulling an arrow).
    private func artPreview(_ next: inout Session, press p: Press, to c: AsciiDiagram.Cell, point: NSPoint?) -> Bool {
        guard let scene = p.original.art else { return false }
        switch p.hit {
        case .inside(let id):
            NSCursor.closedHand.set()
            guard let edit = AsciiArt.move(id, dx: c.x - p.start.x, dy: c.y - p.start.y, in: scene) else { return false }
            next.art = edit.scene
            next.selection = .box(edit.box ?? id)
            if next.fresh == id { next.fresh = edit.box ?? id }
        case .corner(let id, let dx, let dy):
            guard let old = scene.boxes.first(where: { $0.id == id }) else { return false }
            var left = old.rect.x, top = old.rect.y
            var right = old.rect.x + old.rect.width - 1, bottom = old.rect.y + old.rect.height - 1
            if dx < 0 { left = max(0, min(c.x, right - AsciiDiagram.minWidth + 1)) } else { right = max(c.x, left + AsciiDiagram.minWidth - 1) }
            if dy < 0 { top = max(0, min(c.y, bottom - AsciiDiagram.minHeight + 1)) } else { bottom = max(c.y, top + AsciiDiagram.minHeight - 1) }
            let rect = AsciiDiagram.Rect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
            guard let edit = AsciiArt.resize(id, to: rect, in: scene) else { return false }
            next.art = edit.scene
            next.selection = .box(edit.box ?? id)
            if next.fresh == id { next.fresh = edit.box ?? id }
        case .side(let id):
            pulling = (id, point ?? rect(AsciiDiagram.Rect(x: c.x, y: c.y, width: 1, height: 1), in: next).origin)
            editor.needsDisplay = true
            return false
        case .empty:
            let r = boxSpanning(p.start, c, id: 0).rect
            guard let edit = AsciiArt.addBox(r, text: [""], in: scene) else { return false }
            next.art = edit.scene
            next.selection = edit.box.map { .box($0) }
            next.fresh = edit.box
        case .arrow:
            return false
        }
        return true
    }

    /// The press on art ended: a click selects or makes a box; a drag's
    /// result becomes one undo step.
    private func artEnded(_ p: Press, at c: AsciiDiagram.Cell, result: inout Session) {
        guard let scene = result.art else { return }
        if !p.moved {
            switch p.hit {
            case .inside(let id), .side(let id), .corner(let id, _, _):
                result.selection = .box(id)
                result.compartment = compartment(at: p.start, of: id, in: scene)
                session = result
            case .arrow(let id):
                result.selection = .arrow(id)
                session = result
            case .empty:
                if result.selection != nil {
                    session = result
                    endEditing()
                    return
                }
                let size = Self.newBoxSize
                let r = AsciiDiagram.Rect(x: max(0, c.x - size.width / 2), y: max(0, c.y - 1), width: size.width, height: size.height)
                guard let edit = AsciiArt.addBox(r, text: [""], in: scene) else {
                    session = result
                    return NSSound.beep()
                }
                result.art = edit.scene
                result.selection = edit.box.map { .box($0) }
                result.fresh = edit.box
                result.compartment = 0
                write(&result, action: "New Box")
                return
            }
            editor.setSelectedRange(NSRange(location: result.block.content.location, length: 0))
            editor.needsDisplay = true
            return
        }
        switch p.hit {
        case .inside, .corner, .empty:
            guard let shown = p.last.art, shown != scene else {
                session = result
                editor.needsDisplay = true
                return
            }
            result.art = shown
            result.selection = p.last.selection
            result.fresh = p.last.fresh
            result.compartment = 0
            write(&result, action: { if case .empty = p.hit { return "New Box" } else { return "Move Box" } }())
        case .side(let id):
            artConnect(from: id, at: c, in: &result)
        case .arrow:
            session = result
        }
    }

    /// A pulled arrow dropped on art: onto a box connects it; onto empty
    /// space it makes a box there first.
    private func artConnect(from id: Int, at c: AsciiDiagram.Cell, in s: inout Session) {
        guard let scene = s.art, let source = scene.boxes.first(where: { $0.id == id }) else { return }
        if let target = scene.boxes.first(where: { $0.rect.contains(c) }) {
            guard target.id != id, let edit = AsciiArt.connect(id, to: target.id, in: scene) else {
                session = s
                editor.needsDisplay = true
                if target.id != id { NSSound.beep() }
                return
            }
            s.art = edit.scene
            s.selection = edit.link.map { .arrow($0) }
            write(&s, action: "New Arrow")
            return
        }
        let size = Self.newBoxSize
        var r = AsciiDiagram.Rect(x: max(0, c.x - size.width / 2), y: max(0, c.y - 1), width: size.width, height: size.height)
        var made: AsciiArt.Edit?
        for _ in 0..<40 {
            made = AsciiArt.addBox(r, text: [""], in: scene)
            if made != nil { break }
            r.y += 1
        }
        guard let added = made, let newBox = added.box, let from = boxID(at: source.rect, in: added.scene),
              let linked = AsciiArt.connect(from, to: newBox, in: added.scene) else {
            session = s
            editor.needsDisplay = true
            return NSSound.beep()
        }
        s.art = linked.scene
        let box = boxID(at: r, in: linked.scene)
        s.selection = box.map { .box($0) }
        s.fresh = box
        s.compartment = 0
        write(&s, action: "New Box")
    }

    /// Ring around the selected box with a caret after its text, or the
    /// selected line's cells tinted.
    private func drawArtSelection(_ selection: Selection, scene: AsciiArt.Scene, in s: Session) {
        let accent = NSColor.controlAccentColor
        switch selection {
        case .box(let id):
            guard let box = scene.boxes.first(where: { $0.id == id }) else { return }
            let ring = NSBezierPath(roundedRect: rect(box.rect, in: s).insetBy(dx: -2, dy: -1), xRadius: 4, yRadius: 4)
            ring.lineWidth = 2
            accent.withAlphaComponent(0.8).setStroke()
            ring.stroke()
            guard s.compartment < box.compartments.count else { return }
            let room = box.compartments[s.compartment]
            let lines = text(of: selection, in: s)
            let caret = AsciiDiagram.Cell(x: room.x + 1 + lines[lines.count - 1].count, y: room.y + lines.count - 1)
            let r = rect(AsciiDiagram.Rect(x: caret.x, y: caret.y, width: 1, height: 1), in: s)
            accent.setFill()
            NSRect(x: r.minX, y: r.minY + 1, width: 1.5, height: cellSize.height - 2).fill()
        case .arrow(let id):
            accent.withAlphaComponent(0.25).setFill()
            for c in scene.links.first(where: { $0.id == id })?.cells ?? [] {
                rect(AsciiDiagram.Rect(x: c.x, y: c.y, width: 1, height: 1), in: s).fill()
            }
        }
    }
}
