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

    private let painter = MarkdownPainter()

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
        let manager = NSLayoutManager()
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
        case (.command, "v"):
            paste(self)
        case (.command, "x"):
            cut(self)
        case (.command, "z"):
            undoAction()
        case ([.command, .shift], "z"), (.command, "y"):
            redoAction()
        case (.command, "f"):
            findAction()
        case ([.command, .option], "f"):
            replaceAction()
        case ([.command, .shift], "."):
            quoteAction()
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
    func findAction() { performTextFinderAction(NSTextFinder.Action.showFindInterface) }
    func replaceAction() { performTextFinderAction(NSTextFinder.Action.showReplaceInterface) }
    func quoteAction() { applyLine { EditorText.toggleQuote(in: $0, selection: $1) } }
    func indentAction() { applyLine { EditorText.indent(in: $0, selection: $1) } }
    func outdentAction() { applyLine { EditorText.outdent(in: $0, selection: $1) } }
    func upperAction() { applyCase { EditorText.uppercased(in: $0, selection: $1) } }
    func lowerAction() { applyCase { EditorText.lowercased(in: $0, selection: $1) } }
    func boldAction() { applyWrap("**") }
    func italicAction() { applyWrap("*") }
    func codeAction() { applyWrap("`") }
    func tableAction() { applyCase { Markdown.alignedTable(in: $0, selection: $1) } }

    func markdownToggleAction() {
        Self.markdownLook.toggle()
        if let textStorage { painter.paint(textStorage) }
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
            case .code, .codeBlock:
                storage.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor.withAlphaComponent(0.15), range: r)
            case .quote:
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
            case .listMarker:
                storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: r)
            case .link:
                storage.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: r)
            case .table:
                break
            case .syntax:
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r)
            }
        }
    }
}
