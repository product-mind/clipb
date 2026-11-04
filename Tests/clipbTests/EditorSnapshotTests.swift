import AppKit
import Testing
@testable import clipb

/// Renders the editor to PNGs after each step, for a human (or an agent) to
/// look at: `CLIPB_SNAPSHOTS=<dir> make test`. Without it the steps still run.
@MainActor
@Suite struct EditorSnapshotTests {
    let mermaid = "```mermaid\ngraph TD\n  %% clipb-order: B C D A\n  A --> B\n  A --> C\n  A --> D\n```"

    private func snapshot(_ editor: EditorTextView, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["CLIPB_SNAPSHOTS"] else { return }
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        editor.sizeToFit()
        let bounds = editor.bounds
        guard let rep = editor.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        editor.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        let dump = editor.string + "\n---- caret \(editor.selectedRange())"
        try? dump.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    }

    private func window(_ editor: EditorTextView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.documentView = editor
        window.contentView = scroll
        window.makeFirstResponder(editor)
        return window
    }

    private func key(_ editor: EditorTextView, _ code: UInt16, _ chars: String) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: editor.window?.windowNumber ?? 0,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        editor.keyDown(with: event)
    }

    @Test(arguments: ["down", "enter"])
    func pastedMermaidThenAKey(_ which: String) {
        let editor = EditorTextView()
        let w = window(editor)
        defer { w.close() }
        editor.insertText(mermaid, replacementRange: NSRange(location: 0, length: 0))
        snapshot(editor, "\(which)-0-pasted")
        if which == "down" { key(editor, 125, String(UnicodeScalar(NSDownArrowFunctionKey)!)) } else { key(editor, 36, "\r") }
        snapshot(editor, "\(which)-1-key")
        if which == "down" { key(editor, 126, String(UnicodeScalar(NSUpArrowFunctionKey)!)) } else { key(editor, 36, "\r") }
        snapshot(editor, "\(which)-2-key")
        #expect(editor.string.hasPrefix(mermaid))
    }

    /// ⌘V from a private pasteboard (never the user's clipboard), then keys.
    @Test(arguments: [("", ""), ("", "\n"), ("Notes:\n\n", "\n\nafter\n")])
    func pastedMermaidKeySweep(_ around: (String, String)) throws {
        let editor = EditorTextView()
        let w = window(editor)
        defer { w.close() }
        editor.insertText(around.0 + around.1, replacementRange: NSRange(location: 0, length: 0))
        editor.setSelectedRange(NSRange(location: (around.0 as NSString).length, length: 0))
        let board = NSPasteboard(name: NSPasteboard.Name("clipb-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.declareTypes([.string], owner: nil)
        board.setString(mermaid, forType: .string)
        #expect(editor.readSelection(from: board, type: .string))
        let tag = around.0.isEmpty ? (around.1.isEmpty ? "bare" : "nl") : "text"
        snapshot(editor, "\(tag)-00-pasted")
        let down = (UInt16(125), String(UnicodeScalar(NSDownArrowFunctionKey)!))
        let up = (UInt16(126), String(UnicodeScalar(NSUpArrowFunctionKey)!))
        let enter = (UInt16(36), "\r")
        let steps: [(String, (UInt16, String))] = [("down", down), ("down", down), ("up", up), ("up", up), ("up", up),
                                                   ("enter", enter), ("down", down), ("up", up), ("up", up), ("down", down), ("down", down)]
        for (k, step) in steps.enumerated() {
            key(editor, step.1.0, step.1.1)
            snapshot(editor, String(format: "%@-%02d-%@", tag, k + 1, step.0))
            // Keys move the caret; Enter only adds line breaks.
            #expect(editor.string.filter { $0 != "\n" } == (around.0 + mermaid + around.1).filter { $0 != "\n" })
        }
    }

    /// The hand-drawn gateway diagram: a box dragged, pictured before and after.
    @Test func handDrawnArtDrag() throws {
        let editor = EditorTextView()
        let w = window(editor)
        defer { w.close() }
        // The panel's part: widen to what the editor asks for.
        var asked: CGFloat = 0
        editor.onWantsWidth = { width in
            asked = width
            editor.enclosingScrollView?.frame.size.width = width + 20
            editor.frame.size.width = width
        }
        editor.insertText("```\n" + DiagramCanvasTests.gateways + "\n```\n", replacementRange: NSRange(location: 0, length: 0))
        #expect(asked > 620, "a wide drawing asks for room")
        snapshot(editor, "art-0")
        #expect(editor.canvas.begin(at: 4))
        let lines = DiagramCanvasTests.gateways.components(separatedBy: "\n")
        let y = try #require(lines.firstIndex { $0.contains("oms-api [1]") })
        let x = lines[y].distance(from: lines[y].startIndex, to: lines[y].range(of: "oms-api")!.lowerBound)
        editor.canvas.press(at: AsciiDiagram.Cell(x: x, y: y))
        for k in 1...4 { editor.canvas.pressMoved(to: AsciiDiagram.Cell(x: x + k, y: y + k)) }
        snapshot(editor, "art-1-dragging")
        editor.canvas.pressEnded(at: AsciiDiagram.Cell(x: x + 4, y: y + 4))
        snapshot(editor, "art-2-dropped")
    }

    /// A selection rectangle over the gateway column, the group dragged, then
    /// a caret in a box's text.
    @Test func handDrawnArtGroupAndCaret() throws {
        let editor = EditorTextView()
        let w = window(editor)
        defer { w.close() }
        editor.onWantsWidth = { width in
            editor.enclosingScrollView?.frame.size.width = width + 20
            editor.frame.size.width = width
        }
        editor.insertText("```\n" + DiagramCanvasTests.gateways + "\n```\n", replacementRange: NSRange(location: 0, length: 0))
        #expect(editor.canvas.begin(at: 4))
        typealias C = AsciiDiagram.Cell
        // Around oms-api and Dashboard BFF proxy.
        editor.canvas.press(at: C(x: 33, y: 3))
        editor.canvas.pressMoved(to: C(x: 45, y: 10))
        editor.canvas.pressMoved(to: C(x: 60, y: 14))
        snapshot(editor, "group-0-band")
        editor.canvas.pressEnded(at: C(x: 60, y: 14))
        guard case .boxes(let ids) = editor.canvas.selection else {
            Issue.record("picked: \(String(describing: editor.canvas.selection))")
            return
        }
        #expect(ids.count == 2)
        snapshot(editor, "group-1-picked")
        // Drag oms-api's text area one row down: both move.
        editor.canvas.press(at: C(x: 40, y: 5))
        editor.canvas.pressMoved(to: C(x: 40, y: 6))
        editor.canvas.pressEnded(at: C(x: 40, y: 6))
        snapshot(editor, "group-2-moved")
        // A click into "Dashboard" puts the caret after "Dash".
        let lines = editor.string.components(separatedBy: "\n").dropFirst()
        let y = try #require(lines.firstIndex { $0.contains("│ Dashboard ") }) - 1
        editor.canvas.press(at: C(x: 7, y: y))
        editor.canvas.pressEnded(at: C(x: 7, y: y))
        snapshot(editor, "group-3-caret")
    }
}

@MainActor
@Suite struct ClosingFenceEditorTests {
    private func editor() -> (EditorTextView, NSWindow) {
        let editor = EditorTextView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.documentView = editor
        window.contentView = scroll
        window.makeFirstResponder(editor)
        return (editor, window)
    }

    @Test func typedKeyByKey() {
        let (e, w) = editor()
        defer { w.close() }
        for ch in "```" { e.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        let afterOpen = e.string
        for ch in "this is block```" { e.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        #expect(e.string.contains("this is block\n```"), "after open: \(afterOpen.debugDescription), now: \(e.string.debugDescription)")
    }

    @Test func pasted() {
        let (e, w) = editor()
        defer { w.close() }
        let board = NSPasteboard(name: NSPasteboard.Name("clipb-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.declareTypes([.string], owner: nil)
        board.setString("```\nthis is block```\n\nmore text\n", forType: .string)
        #expect(e.readSelection(from: board, type: .string))
        #expect(e.string == "```\nthis is block\n```\n\nmore text\n", "\(e.string.debugDescription)")
    }
}
