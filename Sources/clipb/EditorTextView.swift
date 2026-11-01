import AppKit
import Carbon.HIToolbox

/// The text view behind the Cmd+Shift+E editor: the cut text, editable in
/// place, saved with Esc or Cmd+S. Plain by construction — code and paths go
/// through here, so smart quotes, dashes and spell-check never rewrite them —
/// and it leaves every other key to AppKit, so Cmd+A, Cmd+←/→, Cmd+↑/↓, the
/// Opt+arrows, Shift+select and the Ctrl+A/E/K emacs keys all keep working.
final class EditorTextView: NSTextView {
    /// Esc, Cmd+S: hand the text back. The owner closes the panel and pastes.
    var onSave: (() -> Void)?

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
                applyLine { EditorText.outdent(in: $0, selection: $1) }
                return true
            case kVK_ANSI_RightBracket:
                applyLine { EditorText.indent(in: $0, selection: $1) }
                return true
            default:
                break
            }
        }
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch (modifiers, key) {
        case (.command, "s"):
            onSave?()
        case (.command, "z"):
            undoManager?.undo()
        case ([.command, .shift], "z"), (.command, "y"):
            undoManager?.redo()
        case (.command, "f"):
            performTextFinderAction(NSTextFinder.Action.showFindInterface)
        case ([.command, .option], "f"):
            performTextFinderAction(NSTextFinder.Action.showReplaceInterface)
        case ([.command, .shift], "."):
            applyLine { EditorText.toggleQuote(in: $0, selection: $1) }
        case ([.command, .shift], "u"):
            applyCase { EditorText.uppercased(in: $0, selection: $1) }
        case ([.command, .shift], "l"):
            applyCase { EditorText.lowercased(in: $0, selection: $1) }
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
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
    private func apply(_ edit: EditorText.Edit, in oldText: String, selection: NSRange) {
        // Explicit grouping: the operation must undo as one step, never by luck.
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        let restored = EditorText.restoredSelection(edit: edit, oldText: oldText, selection: selection)
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(restored)
        scrollRangeToVisible(restored)
    }
}
