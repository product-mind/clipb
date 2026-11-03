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
        }), let diagram = Self.drawing(block, in: ns) else { return nil }
        return Session(block: block, diagram: diagram, rendered: AsciiDiagram.render(diagram))
    }

    /// Writes the drawing into its block. `undoable` false for drag previews.
    private func write(_ s: inout Session, undoable: Bool = true, action: String? = nil) {
        guard let storage = editor.textStorage else { return }
        s.rendered = AsciiDiagram.render(s.diagram)
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
        let longest = s.rendered.text.components(separatedBy: "\n").map(\.count).max() ?? 0
        let needed = CGFloat(longest + 2) * cellSize.width + editor.textContainerInset.width * 2
        editor.onWantsWidth?(needed)
    }

    /// Leaves the selection; an empty new box goes away again.
    func endEditing() {
        guard var s = current(), s.selection != nil else { return }
        let fresh = s.fresh
        s.selection = nil
        s.fresh = nil
        pulling = nil
        if let fresh, let box = s.diagram.boxes.first(where: { $0.id == fresh }),
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

    private func target(at c: AsciiDiagram.Cell, in s: Session) -> Target {
        for box in s.diagram.boxes {
            let r = box.rect
            guard r.contains(c) else { continue }
            let left = c.x == r.x, right = c.x == r.x + r.width - 1
            let top = c.y == r.y, bottom = c.y == r.y + r.height - 1
            if (left || right) && (top || bottom) { return .corner(box.id, dx: left ? -1 : 1, dy: top ? -1 : 1) }
            if left || right || top || bottom { return .side(box.id) }
            return .inside(box.id)
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
              let index = characterIndex(at: point), var s = session(at: index),
              let c = cell(at: point, in: s), c.y >= 0 else {
            endEditing()
            return false
        }
        // Leaving one element for another: an empty new box goes away first.
        if s.selection != nil, s.fresh != nil {
            endEditing()
            guard let again = session(at: index) else { return true }
            s = again
        }
        session = s
        let hit = target(at: c, in: s)
        drag(from: point, cell: c, hit: hit, start: s)
        return true
    }

    private func drag(from point: NSPoint, cell start: AsciiDiagram.Cell, hit: Target, start original: Session) {
        guard let window = editor.window else { return }
        var moved = false
        var last = original
        var dropCell = start
        var dropPoint = point
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let p = editor.convert(event.locationInWindow, from: nil)
            if event.type == .leftMouseUp { dropPoint = p; break }
            if !moved, hypot(p.x - point.x, p.y - point.y) < 3 { continue }
            moved = true
            dropPoint = p
            guard let c = cell(at: p, in: original) else { continue }
            dropCell = c
            var next = original
            switch hit {
            case .inside(let id):
                NSCursor.closedHand.set()
                guard move(id, by: (c.x - start.x, c.y - start.y), in: &next.diagram) else { continue }
                next.selection = .box(id)
            case .corner(let id, let dx, let dy):
                resize(id, corner: (dx, dy), to: c, in: &next.diagram)
                next.selection = .box(id)
            case .side(let id):
                pulling = (id, p)
                editor.needsDisplay = true
                editor.displayIfNeeded()
                continue
            case .empty:
                let box = boxSpanning(start, c, id: nextBoxID(next.diagram))
                guard !overlaps(box, in: next.diagram) else { continue }
                next.diagram.boxes.append(box)
                next.selection = .box(box.id)
                next.fresh = box.id
            case .arrow:
                continue
            }
            guard next.diagram != last.diagram || next.selection != last.selection else { continue }
            last = next
            write(&next, undoable: false)
            editor.displayIfNeeded()
        }
        pulling = nil
        // The previews were not undoable: put the start back, then make the
        // result one undo step.
        if last.diagram != original.diagram {
            var restore = original
            restore.block = currentBlock(of: last) ?? original.block
            write(&restore, undoable: false)
        }
        var result = session ?? original
        result.diagram = original.diagram
        result.selection = original.selection
        result.fresh = original.fresh
        if !moved {
            click(hit, at: start, in: &result)
            return
        }
        switch hit {
        case .inside(let id), .corner(let id, _, _):
            result.diagram = last.diagram
            result.selection = .box(id)
            write(&result, action: "Move Box")
        case .empty:
            result.diagram = last.diagram
            result.selection = last.selection
            result.fresh = last.fresh
            write(&result, action: "New Box")
        case .side(let id):
            connect(from: id, at: cell(at: dropPoint, in: result) ?? dropCell, in: &result)
        case .arrow:
            break
        }
    }

    /// The block's ranges as written last (they shift with each preview).
    private func currentBlock(of s: Session) -> Markdown.FencedBlock? { session?.block ?? s.block }

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
            if move(id, by: delta, in: &s.diagram) { write(&s, action: "Move Box") }
        default:
            break
        }
        return true
    }

    private func text(of selection: Selection, in s: Session) -> [String] {
        switch selection {
        case .box(let id): return s.diagram.boxes.first { $0.id == id }?.text ?? [""]
        case .arrow(let id):
            let label = s.diagram.arrows.first { $0.id == id }?.label ?? []
            return label.isEmpty ? [""] : label
        }
    }

    private func edit(_ selection: Selection, in s: inout Session, _ change: (inout [String]) -> Void) {
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
        if let from = pulling, let box = s.diagram.boxes.first(where: { $0.id == from.from }) {
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
}
