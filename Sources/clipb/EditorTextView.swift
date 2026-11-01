import AppKit

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
            onSave?()
            return
        }
        super.keyDown(with: event)
    }

    // Esc can arrive as cancelOperation instead of keyDown (menu/key-binding routing); saving either way
    override func cancelOperation(_ sender: Any?) {
        onSave?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd+S only: handling it here keeps it away from anything that would
        // beep, and every other chord falls through to the standard binding.
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "s" {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
