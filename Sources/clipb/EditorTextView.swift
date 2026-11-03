import AppKit
import Carbon.HIToolbox

/// The text view behind the Cmd+Shift+E editor: the cut text, editable in
/// place, saved with Esc or Cmd+S. Plain by construction — code and paths go
/// through here, so smart quotes, dashes and spell-check never rewrite them —
/// and it leaves every other key to AppKit, so Cmd+A, Cmd+←/→, Cmd+↑/↓, the
/// Opt+arrows, Shift+select and the Ctrl+A/E/K emacs keys all keep working.
final class EditorTextView: NSTextView {
    /// Markdown look on or off (⌘⇧M, the MD button). Memory only; the start
    /// value is `MarkdownPainter.onByDefault`.
    static var markdownLook = MarkdownPainter.onByDefault
    static let markdownLookChanged = Notification.Name("ClipBMarkdownLookChanged")

    private let painter = MarkdownPainter()

    /// Grey text drawn right after the caret, never part of the text:
    /// "Listening…" while a take records, "Transcribing…" after (SPEC §2.13).
    var ghost: String? {
        didSet { if ghost != oldValue { needsDisplay = true } }
    }

    /// Esc, Cmd+S: hand the text back. The owner closes the panel and pastes.
    var onSave: (() -> Void)?
    /// Cmd+1-9 (digit 1-9). Return true when it ran a pipe; digits without
    /// Cmd always type.
    var onCommandDigit: ((Int) -> Bool)?

    // A subclass must NOT reach super with a nil container: the TextKit2
    // heuristic then leaves the view without a working text stack, and every
    // string assignment silently no-ops (an empty editor). Build TextKit 1
    // by hand — the one recipe that keeps a subclass's text alive.
    init() {
        let storage = NSTextStorage()
        let manager = CodeLayoutManager()
        let container = NSTextContainer(
            containerSize: NSSize(width: 620, height: CGFloat.greatestFiniteMagnitude)
        )
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        super.init(frame: NSRect(x: 0, y: 0, width: 620, height: 420), textContainer: container)
        storage.delegate = painter
        font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textColor = .textColor
        isRichText = false
        allowsUndo = true
        // Smart input is for prose; these would corrupt code, paths and quotes.
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        smartInsertDeleteEnabled = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        textContainerInset = NSSize(width: 6, height: 8)
        // A text view grows downward inside the scroll view, never sideways.
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        // Match the proven-repro recipe exactly: tracking the clip view's width
        // is what wraps lines; a zero-width containerSize unwraps them instead.
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 0
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ghost, let at = caretOrigin() else { return }
        let size = font?.pointSize ?? MarkdownPainter.fontSize
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let text = NSAttributedString(string: ghost, attributes: attributes)
        // Right at the caret (the ghost brings its own leading space); mid-line
        // it sits over the text after the caret, on the background color.
        let rect = NSRect(origin: at, size: text.size())
        backgroundColor.setFill()
        rect.insetBy(dx: -2, dy: 0).fill()
        text.draw(at: rect.origin)
    }

    /// Top-left of the caret in view coordinates, also in an empty view or
    /// past a trailing newline.
    private func caretOrigin() -> NSPoint? {
        guard let manager = layoutManager, let container = textContainer else { return nil }
        manager.ensureLayout(for: container)
        let ns = string as NSString
        let location = min(selectedRange().location, ns.length)
        var rect: NSRect
        if ns.length == 0 || (location == ns.length && ns.character(at: ns.length - 1) == 10) {
            rect = manager.extraLineFragmentRect
            if rect == .zero { rect = .zero }
            rect.size.width = 0
        } else if location == ns.length {
            let glyph = manager.glyphIndexForCharacter(at: ns.length - 1)
            rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            rect.origin.x = rect.maxX
        } else {
            let glyph = manager.glyphIndexForCharacter(at: location)
            rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        }
        return NSPoint(x: rect.minX + textContainerOrigin.x, y: rect.minY + textContainerOrigin.y)
    }

    // Wrapping: the text view must be exactly as wide as the visible area.
    // Autoresizing alone kept the 620 pt start width's margin, so lines ran
    // past the right edge instead of wrapping there.
    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        matchSuperviewWidth()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        matchSuperviewWidth()
    }

    private func matchSuperviewWidth() {
        guard let width = superview?.bounds.width, width > 0, frame.width != width else { return }
        setFrameSize(NSSize(width: width, height: frame.height))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            // While the find bar is up Esc dismisses it, not the whole editor.
            if findBarIsVisible {
                hideFindBar()
                return
            }
            onSave?()
            return
        }
        super.keyDown(with: event)
    }

    // Esc can arrive as cancelOperation instead of keyDown (menu/key-binding routing); saving either way
    override func cancelOperation(_ sender: Any?) {
        // The find bar gets Esc first, whichever path delivered it.
        if findBarIsVisible {
            hideFindBar()
            return
        }
        onSave?()
    }

    /// Enter continues a list or quote (SPEC §2.12) while the Markdown look is
    /// on. Shift+Enter or Option+Enter is always a plain newline.
    /// The third backtick of an opening fence adds the closing one below.
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let typed = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        let text = string
        if Self.markdownLook, let typed, let (edit, selection) = Markdown.autoCloseFence(in: text, selection: range, typed: typed) {
            apply(edit, in: text, selection: range, select: selection)
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func insertNewline(_ sender: Any?) {
        let plain = NSApp.currentEvent?.modifierFlags.intersection([.shift, .option]).isEmpty == false
        let text = string
        if Self.markdownLook, !plain, let (edit, selection) = Markdown.continueList(in: text, selection: selectedRange()) {
            apply(edit, in: text, selection: selectedRange(), select: selection)
            return
        }
        super.insertNewline(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Handled here so the chords cannot beep or reach a stale menu binding;
        // every other key falls through to the standard NSTextView binding.
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // Match brackets on keyCode: their character is keyboard-layout dependent.
        if modifiers == .command {
            switch Int(event.keyCode) {
            case kVK_ANSI_LeftBracket:
                outdentAction()
                return true
            case kVK_ANSI_RightBracket:
                indentAction()
                return true
            default:
                break
            }
        }
        // ⌘> and ⌘< (Shift+period/comma on US layouts) indent and outdent like
        // ⌘] and ⌘[; ⌘⇧9 quotes, as in Gmail. Matched on keyCode:
        // with Shift held the characters are ">" "<" "(", layout dependent.
        if modifiers == [.command, .shift] {
            switch Int(event.keyCode) {
            case kVK_ANSI_Period:
                indentAction()
                return true
            case kVK_ANSI_Comma:
                outdentAction()
                return true
            case kVK_ANSI_9:
                quoteAction()
                return true
            default:
                break
            }
        }
        if modifiers == .command, [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode)) {
            onSave?()
            return true
        }
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == .command, let key, let digit = Int(key), (1...9).contains(digit),
           onCommandDigit?(digit) == true {
            return true
        }
        switch (modifiers, key) {
        case (.command, "s"):
            onSave?()
        // Menu-less app: the Edit-menu chords must be wired by hand.
        case (.command, "a"):
            selectAll(self)
        case (.command, "c"):
            copy(self)
        // Cmd+V pastes the editor back where the user came from (SPEC §2.12),
        // like the Paste button. The clipboard still pastes into the text via
        // the right-click menu; a held Cmd+V dictates into it.
        case (.command, "v"):
            onSave?()
        case (.command, "x"):
            cut(self)
        case (.command, "z"):
            undoAction()
        case ([.command, .shift], "z"), (.command, "y"):
            redoAction()
        case (.command, "f"):
            findAction()
        // ⌘⇧F as the user reached for it; ⌘⌥F as in Xcode and VS Code.
        case ([.command, .option], "f"), ([.command, .shift], "f"):
            replaceAction()
        case ([.command, .shift], "u"):
            upperAction()
        case ([.command, .shift], "l"):
            lowerAction()
        case (.command, "b"):
            boldAction()
        case (.command, "i"):
            italicAction()
        case ([.command, .option], "t"):
            tableAction()
        case ([.command, .shift], "m"):
            markdownToggleAction()
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    // MARK: Actions

    // The button strip runs these same bodies, so a click and its chord cannot drift apart.
    func undoAction() { undoManager?.undo() }
    func redoAction() { undoManager?.redo() }
    func findAction() { textFinder(.showFindInterface) }
    func replaceAction() { textFinder(.showReplaceInterface) }

    /// `performTextFinderAction` reads the action from its sender's `tag`, as
    /// a menu item would send it. A bare enum has no tag, so nothing opened.
    private func textFinder(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        performTextFinderAction(sender)
    }
    func quoteAction() { applyLine { EditorText.toggleQuote(in: $0, selection: $1) } }
    func indentAction() { applyLine { EditorText.indent(in: $0, selection: $1) } }
    func outdentAction() { applyLine { EditorText.outdent(in: $0, selection: $1) } }
    func upperAction() { applyCase { EditorText.uppercased(in: $0, selection: $1) } }
    func lowerAction() { applyCase { EditorText.lowercased(in: $0, selection: $1) } }
    func boldAction() { applyWrap("**") }
    func italicAction() { applyWrap("*") }
    func codeAction() {
        let text = string
        let (edit, selection) = Markdown.toggleCode(in: text, selection: selectedRange())
        apply(edit, in: text, selection: selectedRange(), select: selection)
    }
    func tableAction() { applyCase { Markdown.alignedTable(in: $0, selection: $1) } }

    func markdownToggleAction() {
        Self.markdownLook.toggle()
        if let textStorage { painter.paint(textStorage) }
        NotificationCenter.default.post(name: Self.markdownLookChanged, object: nil)
    }

    private func applyWrap(_ marker: String) {
        let text = string
        let (edit, selection) = Markdown.toggleWrap(marker, in: text, selection: selectedRange())
        apply(edit, in: text, selection: selectedRange(), select: selection)
    }

    /// Trailing whitespace off every line as one undo step. A clean buffer is
    /// left alone: no undo group and nothing marked dirty.
    func trimAction() {
        let text = string
        let trimmed = EditorText.trimmed(text)
        guard trimmed != text else { return }
        let whole = NSRange(location: 0, length: (text as NSString).length)
        apply(EditorText.Edit(range: whole, replacement: trimmed), in: text, selection: selectedRange())
    }

    // The find bar belongs to the enclosing scroll view, its text finder container.
    private var findBarIsVisible: Bool { enclosingScrollView?.isFindBarVisible ?? false }

    private func hideFindBar() {
        enclosingScrollView?.isFindBarVisible = false
    }

    private func applyLine(_ make: (String, NSRange) -> EditorText.Edit) {
        let text = string
        let selection = selectedRange()
        apply(make(text, selection), in: text, selection: selection)
    }

    private func applyCase(_ make: (String, NSRange) -> EditorText.Edit?) {
        let text = string
        let selection = selectedRange()
        guard let edit = make(text, selection) else { return }
        apply(edit, in: text, selection: selection)
    }

    // One range replacement through shouldChangeText, so undo reverses the
    // whole operation in a single step.
    private func apply(_ edit: EditorText.Edit, in oldText: String, selection: NSRange, select: NSRange? = nil) {
        // Explicit grouping: the operation must undo as one step, never by luck.
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        let restored = select ?? EditorText.restoredSelection(edit: edit, oldText: oldText, selection: selection)
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(restored)
        scrollRangeToVisible(restored)
    }
}

/// Paints `Markdown.spans` onto the editor's storage after every edit:
/// attributes only, so the text, undo and what gets saved stay plain.
final class MarkdownPainter: NSObject, NSTextStorageDelegate {
    /// Knobs (SPEC §2.12). Experimental: tweak, `make`, try it.
    static let onByDefault = true
    static let fontSize: CGFloat = 13
    /// Heading point sizes for `#`, `##`, `###`; deeper levels use `fontSize`.
    static let headingSizes: [CGFloat] = [20, 17, 15]
    /// Above this many UTF-16 units the editor stays plain: repainting runs on every keystroke.
    static let maxLength = 200_000

    func textStorage(_ storage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        paint(storage)
    }

    func paint(_ storage: NSTextStorage) {
        let whole = NSRange(location: 0, length: storage.length)
        let base = NSFont.monospacedSystemFont(ofSize: Self.fontSize, weight: .regular)
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.setAttributes([.font: base, .foregroundColor: NSColor.textColor], range: whole)
        guard EditorTextView.markdownLook, storage.length <= Self.maxLength else { return }
        for span in Markdown.spans(in: storage.string) where NSMaxRange(span.range) <= storage.length {
            let r = span.range
            switch span.kind {
            case .heading(let level):
                let size = level <= Self.headingSizes.count ? Self.headingSizes[level - 1] : Self.fontSize
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size, weight: .bold), range: r)
            case .bold:
                storage.enumerateAttribute(.font, in: r) { value, sub, _ in
                    let size = (value as? NSFont)?.pointSize ?? Self.fontSize
                    storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size, weight: .bold), range: sub)
                }
            case .italic:
                storage.addAttribute(.obliqueness, value: 0.18, range: r)
            case .strike:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            case .code:
                storage.addAttribute(.clipbInlineCode, value: true, range: r)
            case .codeBlock:
                storage.addAttribute(.clipbCodeBlock, value: true, range: r)
            case .quote:
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
            case .listMarker:
                // Grey like the other markers, one step darker: bullets still read as structure.
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
            case .link:
                storage.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: r)
            case .table:
                break
            case .syntax:
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r)
            case .fence:
                storage.addAttributes([
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.monospacedSystemFont(ofSize: Self.fontSize, weight: .semibold),
                ], range: r)
            }
        }
    }
}

extension NSAttributedString.Key {
    /// Drawn by `CodeLayoutManager` as a rounded pill behind the glyphs.
    static let clipbInlineCode = NSAttributedString.Key("clipbInlineCode")
    /// Drawn by `CodeLayoutManager` as one full-width box per block.
    static let clipbCodeBlock = NSAttributedString.Key("clipbCodeBlock")
}

/// Paints code the way GitHub and Slack do: inline `code` on a rounded grey
/// pill, a fenced block as one rounded box across the editor's width with a
/// hairline border. Behind the text, never over it.
final class CodeLayoutManager: NSLayoutManager {
    /// Knobs (SPEC §2.12). Experimental: tweak, `make`, try it.
    static let inlineFill = dynamic(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.11))
    static let blockFill = dynamic(light: NSColor(white: 0, alpha: 0.045), dark: NSColor(white: 1, alpha: 0.07))
    static let blockBorder = dynamic(light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 1, alpha: 0.12))
    static let inlineRadius: CGFloat = 4
    static let blockRadius: CGFloat = 6
    /// How far the block box reaches past the text on the left and right.
    static let blockOutset: CGFloat = 4

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return }
        let shown = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let whole = NSRange(location: 0, length: storage.length)

        // Blocks: the whole run, even when only part of it is redrawn, so the
        // rounded corners stay at the block's real ends.
        var location = shown.location
        while location < NSMaxRange(shown) {
            var run = NSRange()
            let isBlock = storage.attribute(.clipbCodeBlock, at: location, longestEffectiveRange: &run, in: whole) != nil
            if isBlock { drawBlock(run, container: container, origin: origin) }
            location = max(NSMaxRange(run), location + 1)
        }
        storage.enumerateAttribute(.clipbInlineCode, in: shown) { value, range, _ in
            guard value != nil else { return }
            drawInline(range, container: container, origin: origin)
        }
    }

    private func drawBlock(_ characters: NSRange, container: NSTextContainer, origin: NSPoint) {
        let glyphs = glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        var box = NSRect.null
        enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in box = box.union(rect) }
        guard !box.isNull else { return }
        box.origin.x = -Self.blockOutset
        box.size.width = container.size.width + 2 * Self.blockOutset
        box = box.offsetBy(dx: origin.x, dy: origin.y)
        let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.blockRadius, yRadius: Self.blockRadius)
        Self.blockFill.setFill()
        path.fill()
        Self.blockBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawInline(_ characters: NSRange, container: NSTextContainer, origin: NSPoint) {
        let glyphs = glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        Self.inlineFill.setFill()
        // One pill per line the span wraps across.
        enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
            let pill = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: 0)
            NSBezierPath(roundedRect: pill, xRadius: Self.inlineRadius, yRadius: Self.inlineRadius).fill()
        }
    }
}
