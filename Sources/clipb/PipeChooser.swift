import AppKit

/// Owns the keyboard so digit keys and Esc work without a text field.
private final class PipeChooserView: NSVisualEffectView {
    var onPick: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    var optionCount = 0

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers.isEmpty || modifiers == .command,
           let key = event.charactersIgnoringModifiers,
           let index = ChooserOptions.index(forKey: key, optionCount: optionCount) {
            onPick?(index)
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Lists the pipes for the cut entry, then shows progress while one runs.
/// The header shows the text truncated, or the image/file title; the full
/// value never appears.
final class PipeChooser: NSObject, NSWindowDelegate {
    /// About 84 monospaced columns: wider lines get hard to read.
    private static let editorWidth: CGFloat = 660
    /// Short enough that the header, the button strip and the pipe row under
    /// the text all fit on a laptop screen.
    private static let editorHeight: CGFloat = 340
    /// A short screen still gets an editor worth typing in, just a shorter one.
    private static let editorMinHeight: CGFloat = 160
    private static let editorMinWidth: CGFloat = 240
    /// The keys live behind the `?` button, not in a line under the text:
    /// the user found the always-on hint redundant (MODAL.md). A click shows
    /// them under the Paste button; another click hides them.
    static let editorHelp = """
    ⌘V, ⌘↩ or Esc — paste back where you were
    Hold ⌘C — dictate at the caret
    ⌘B bold · ⌘I italic · ⌘⇧9 quote
    ⌘. indent · ⌘, outdent · ⌘⌥T align table
    ⌘F find · ⌘⇧F or ⌘⌥F find & replace
    ⌘Z undo · ⌘⇧Z redo · ⌘⇧M Markdown look
    ◇ drawing: click for a box, drag a side for an arrow, ⇧↩ new line
    """
    static let dictationHelp = """
    ⌘V, ⌘↩ or Esc — copy and paste back where you were
    Hold ⌘C — dictate more at the caret
    ⌘1–9 — run a pipe on the text
    ⌘B bold · ⌘I italic · ⌘⇧9 quote
    ⌘. indent · ⌘, outdent · ⌘⌥T align table
    ⌘F find · ⌘⇧F or ⌘⌥F find & replace
    ⌘Z undo · ⌘⇧Z redo · ⌘⇧M Markdown look
    ◇ drawing: click for a box, drag a side for an arrow, ⇧↩ new line
    """
    static let submitTitle = "Paste ⌘V"

    private let panel: KeyablePanel
    private let content = PipeChooserView(frame: .zero)
    private let header = NSTextField(labelWithString: "")
    private let rows = PipeOptionsRow()
    /// The dictation editor's pipes, under the text.
    private let editorRows = PipeOptionsRow()
    private let hint = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let editor = EditorTextView()
    // Lazy: the strip needs the text view, which is built before the stack.
    private lazy var strip = EditorButtonStrip(editor: editor)
    private let editorScroll = NSScrollView(frame: .zero)
    /// Under the text: the pipe buttons on the left, the Paste button on the right.
    private let footer = NSStackView()
    /// Click for the keys.
    private lazy var help = NSButton(title: "", target: self, action: #selector(helpClicked))
    /// The keys, under the footer while `?` is on.
    private let helpText = NSTextField(wrappingLabelWithString: "")
    /// Stays on across panels until clicked off; memory only.
    private var helpShown = false
    private lazy var submit = NSButton(title: Self.submitTitle, target: self, action: #selector(submitClicked))
    /// Bottom-right corner: drag to resize the editor (MODAL.md).
    private let grip = ResizeGrip()
    private var editorWidthConstraint: NSLayoutConstraint!
    private var editorHeightConstraint: NSLayoutConstraint!
    private var pipes: [PipeCommand] = []
    private var onPick: ((PipeCommand) -> Void)?
    private var onCancel: (() -> Void)?
    private var onSave: ((String) -> Void)?
    private var entryIsEmpty = false
    private var isRunning = false
    private var isEditing = false
    /// Hold Cmd+C (SPEC §2.13): shown while listening, before any text.
    private var isListening = false
    /// The editor holds a dictation; a pipe runs on its edited text.
    private var onPickText: ((PipeCommand, String) -> Void)?

    override init() {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        // Drag it out of the way by its background: the top band above the
        // buttons, the gaps between them, the margins (MODAL.md).
        panel.isMovableByWindowBackground = true

        content.material = .menu
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 8
        content.onPick = { [weak self] index in self?.pick(index) }
        content.onCancel = { [weak self] in self?.cancel() }
        panel.contentView = content

        header.font = .systemFont(ofSize: 13)
        header.textColor = .labelColor

        rows.onPick = { [weak self] index in self?.pick(index) }
        editorRows.onPick = { [weak self] index in self?.pick(index) }
        editorRows.isHidden = true

        hint.font = .systemFont(ofSize: 11)
        // A long config error truncates instead of widening the panel.
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.textColor = .tertiaryLabelColor

        configureEditor()

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // The strip sits above the text, so the find bar's top edge stays one band.
        submit.bezelStyle = .rounded
        submit.keyEquivalent = "\r"
        submit.keyEquivalentModifierMask = .command
        submit.refusesFirstResponder = true
        submit.toolTip = "Paste the text back where you were (⌘V or ⌘↩)"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        help.bezelStyle = .helpButton
        help.setButtonType(.pushOnPushOff)
        help.refusesFirstResponder = true
        help.toolTip = "Keys"
        helpText.font = .systemFont(ofSize: 11)
        helpText.textColor = .secondaryLabelColor
        helpText.isSelectable = false
        helpText.isHidden = true
        for view in [editorRows, spacer, help, submit] { footer.addArrangedSubview(view) }
        footer.isHidden = true
        for view in [header, hint, rows, strip, editorScroll, footer, helpText] {
            stack.addArrangedSubview(view)
        }
        strip.isHidden = true
        content.addSubview(stack)
        grip.translatesAutoresizingMaskIntoConstraints = false
        grip.isHidden = true
        grip.onBegin = { [weak self] in
            guard let self else { return .zero }
            return NSSize(width: editorWidthConstraint.constant, height: editorHeightConstraint.constant)
        }
        grip.onDrag = { [weak self] size in self?.resizeEditor(to: size, remember: true) }
        content.addSubview(grip)
        NSLayoutConstraint.activate([
            grip.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -2),
            grip.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -2),
            grip.widthAnchor.constraint(equalToConstant: 14),
            grip.heightAnchor.constraint(equalToConstant: 14),
        ])
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            // Exactly the text's width: the buttons never widen the panel.
            strip.widthAnchor.constraint(equalTo: editorScroll.widthAnchor),
            footer.widthAnchor.constraint(equalTo: editorScroll.widthAnchor),
            helpText.widthAnchor.constraint(equalTo: editorScroll.widthAnchor),
        ])
    }

    /// The editor rides in the same stack as the header, hidden while listing.
    private func configureEditor() {
        editor.onSave = { [weak self] in self?.save() }
        editor.onWantsWidth = { [weak self] width in self?.growEditor(toFit: width) }
        editor.onCommandDigit = { [weak self] digit in
            guard let self, onPickText != nil, pipes.indices.contains(digit - 1) else { return false }
            pick(digit - 1)
            return true
        }
        editorScroll.documentView = editor
        editorScroll.borderType = .noBorder
        editorScroll.hasHorizontalRuler = false
        editorScroll.hasVerticalRuler = false
        editorScroll.hasVerticalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.drawsBackground = true
        editorScroll.backgroundColor = .textBackgroundColor
        editorScroll.wantsLayer = true
        editorScroll.layer?.cornerRadius = 6
        editorScroll.layer?.masksToBounds = true
        editorScroll.translatesAutoresizingMaskIntoConstraints = false
        editorScroll.isHidden = true
        footer.isHidden = true
        grip.isHidden = true
        editorWidthConstraint = editorScroll.widthAnchor.constraint(equalToConstant: Self.editorWidth)
        editorHeightConstraint = editorScroll.heightAnchor.constraint(equalToConstant: Self.editorHeight)
        NSLayoutConstraint.activate([editorWidthConstraint, editorHeightConstraint])
    }

    var isVisible: Bool { panel.isVisible }

    /// `onCancel` fires on Esc, a click elsewhere, or the hotkey again, while listing or running.
    /// A single pipe skips the list and runs at once.
    func show(
        pipes: [PipeCommand],
        entry: ClipEntry,
        near anchor: PanelAnchor,
        onPick: @escaping (PipeCommand) -> Void,
        onCancel: @escaping () -> Void
    ) {
        // A listing shown over a finished edit must not inherit its save-instead-of-cancel.
        isEditing = false
        isListening = false
        onPickText = nil
        editorRows.isHidden = true
        onSave = nil
        self.pipes = pipes
        self.onPick = onPick
        self.onCancel = onCancel
        content.optionCount = pipes.count
        entryIsEmpty = entry.isEmpty
        header.stringValue = Titles.pipeHeader(for: entry, maxBytes: ClipboardHistory.popupTruncateLength)
        header.isHidden = false
        placeHint(atBottom: false)
        hint.stringValue = entryIsEmpty ? "Esc close" : "Esc put back"
        rows.setPipes(pipes)
        rows.isHidden = false
        strip.isHidden = true
        editorScroll.isHidden = true
        footer.isHidden = true
        grip.isHidden = true

        let size = content.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(PanelGeometry.origin(size: size, near: anchor))
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(content)
        if pipes.count == 1 { pick(0) }
    }

    /// Cmd+Shift+E: the panel turns into a text editor for the selection.
    /// Esc, Cmd+S, the hotkey again, or losing key saves and pastes back — an
    /// edit is never lost. No command runs, so there is no run state.
    func showEditor(entry: ClipEntry, near anchor: PanelAnchor, onSave: @escaping (String) -> Void) {
        isListening = false
        onPickText = nil
        editorRows.isHidden = true
        editor.isEditable = true
        self.onSave = onSave
        onPick = nil
        onCancel = nil
        pipes = []
        content.optionCount = 0
        isRunning = false
        isEditing = true
        entryIsEmpty = false
        header.stringValue = Self.editorHeader(for: entry)
        header.isHidden = false
        placeHint(atBottom: true)
        hint.stringValue = ""
        hint.isHidden = true
        helpText.stringValue = Self.editorHelp
        rows.isHidden = true
        editor.string = entry.value
        // A fresh session: the caret starts past the last character, where the
        // next keystroke usually belongs, and undo cannot reach back past the
        // text this session began with.
        let end = (entry.value as NSString).length
        editor.setSelectedRange(NSRange(location: end, length: 0))
        editor.scrollRangeToVisible(NSRange(location: end, length: 0))
        editor.undoManager?.removeAllActions()
        strip.isHidden = false
        editorScroll.isHidden = false
        footer.isHidden = false
        grip.isHidden = false

        let size = editorSize(near: anchor.point)
        panel.setContentSize(size)
        panel.setFrameOrigin(PanelGeometry.origin(size: size, near: anchor))
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(editor)
        // After the view is key: the undo manager only exists with a window.
        strip.syncUndoState()
    }

    // MARK: - Dictation (hold Cmd+C)

    /// The "Listening…" panel of a fresh hold is up.
    var isListeningPanel: Bool { isListening }
    /// The user typed into the listening panel: it must not close on an empty take.
    var hasTypedText: Bool { !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// An editor is open (dictation or Cmd+Shift+E): a hold inserts at its caret.
    var isEditorOpen: Bool { isEditing }
    /// No leading space: every take already ends with one (`dictationInsertion`).
    static let listeningGhost = "Listening…"
    static let transcribingGhost = "Transcribing…"

    /// A hold became dictation. Opens the dictation editor at once, empty,
    /// with the caret blinking in the text and a grey "Listening…" after it:
    /// that is where the words will land. The copy already happened at
    /// key-down, so taking key now costs the app nothing. Inside an open
    /// editor only the grey text appears, at its caret.
    func showListening(near anchor: PanelAnchor, pipes: [PipeCommand] = [], pipesError: String? = nil) {
        if isEditing {
            editor.ghost = Self.listeningGhost
            return
        }
        isEditing = false
        isRunning = false
        isListening = true
        onPick = nil
        onCancel = nil
        onSave = nil
        onPickText = nil
        // Nothing to run on yet: digits and clicks pick nothing until the text arrives.
        self.pipes = []
        content.optionCount = 0
        // The same panel as a hold inside the open editor: header line, hint,
        // button strip, text, pipes and Paste, so nothing jumps when the text lands.
        // No title: the text area says what this is. The keys sit at the bottom.
        header.stringValue = ""
        header.isHidden = true
        placeHint(atBottom: true)
        hint.stringValue = Self.pipesErrorHint(pipesError) ?? ""
        hint.isHidden = hint.stringValue.isEmpty
        helpText.stringValue = Self.dictationHelp
        rows.isHidden = true
        strip.isHidden = false
        // The pipes show from the start, fully readable, so the panel never
        // jumps. A click picks nothing until the text arrives: `self.pipes` is
        // empty while listening.
        editorRows.setPipes(pipes)
        editorRows.isHidden = pipes.isEmpty
        editor.string = ""
        // Editable so the caret blinks; anything typed meanwhile stays, and
        // the transcript lands at the caret.
        editor.isEditable = true
        editor.ghost = Self.listeningGhost
        editorScroll.isHidden = false
        footer.isHidden = false
        let size = editorSize(near: anchor.point)
        panel.setContentSize(size)
        panel.setFrameOrigin(PanelGeometry.origin(size: size, near: anchor))
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(editor)
    }

    func showTranscribing() {
        editor.ghost = Self.transcribingGhost
    }

    /// Listening ended without text (Esc, a tap, a failed take): a fresh
    /// listening panel closes; an open editor just gets its header back.
    func endListening() {
        editor.ghost = nil
        if isEditing {
            return
        } else if isListening {
            close()
        }
    }

    /// The transcript arrives: the panel turns into the editor, with `pipes`
    /// as buttons and Cmd+1-9 under the text. Esc, Cmd+S or losing key saves.
    func showDictation(
        _ text: String,
        pipes: [PipeCommand],
        pipesError: String? = nil,
        near anchor: PanelAnchor? = nil,
        onPick: @escaping (PipeCommand, String) -> Void,
        onCancelRun: @escaping () -> Void,
        onSave: @escaping (String) -> Void
    ) {
        isListening = false
        editor.ghost = nil
        isEditing = true
        isRunning = false
        self.pipes = pipes
        onPickText = onPick
        onCancel = onCancelRun
        self.onSave = onSave
        content.optionCount = 0
        // No title: the text area says what this is. The keys sit at the bottom.
        header.stringValue = ""
        header.isHidden = true
        placeHint(atBottom: true)
        hint.stringValue = Self.pipesErrorHint(pipesError) ?? ""
        hint.isHidden = hint.stringValue.isEmpty
        helpText.stringValue = Self.dictationHelp
        editorRows.setPipes(pipes)
        editorRows.isHidden = pipes.isEmpty
        strip.isHidden = false
        editor.isEditable = true
        if editor.string.isEmpty {
            let first = EditorText.dictationInsertion(text, into: "", at: NSRange(location: 0, length: 0))
            editor.string = first
            let end = (first as NSString).length
            editor.setSelectedRange(NSRange(location: end, length: 0))
            editor.scrollRangeToVisible(NSRange(location: end, length: 0))
            editor.undoManager?.removeAllActions()
        } else if !text.isEmpty {
            // Typed while listening: the take lands at the caret, like a second hold.
            let range = editor.selectedRange()
            editor.insertText(EditorText.dictationInsertion(text, into: editor.string, at: range), replacementRange: range)
        }
        editorScroll.isHidden = false
        footer.isHidden = false
        grip.isHidden = false
        if let anchor, !panel.isVisible {
            // Opened straight away (Cmd+Shift+X), not grown out of a listening panel.
            let size = editorSize(near: anchor.point)
            panel.setContentSize(size)
            panel.setFrameOrigin(PanelGeometry.origin(size: size, near: anchor))
            panel.orderFrontRegardless()
        } else {
            // Keep the top edge where the listening panel stood: the pipe row grows
            // it downward.
            let top = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
            panel.setContentSize(content.fittingSize)
            panel.setFrameTopLeftPoint(top)
        }
        // Pulled back onto the screen so the pipe row is never cut off.
        keepOnScreen()
        panel.makeKey()
        panel.makeFirstResponder(editor)
        strip.syncUndoState()
    }

    /// A take into an open editor lands at the caret as one undo step, spaced
    /// from its neighbours.
    func insertDictation(_ text: String) {
        editor.ghost = nil
        let range = editor.selectedRange()
        let insertion = EditorText.dictationInsertion(text, into: editor.string, at: range)
        editor.insertText(insertion, replacementRange: range)
        panel.makeFirstResponder(editor)
    }

    /// A broken pipes config is said out loud instead of silently showing none.
    static func pipesErrorHint(_ pipesError: String?) -> String? {
        guard let pipesError else { return nil }
        return "No pipes — \(RouterConfig.displayPath): \(pipesError)"
    }

    /// Under the header for the pipe list and a run; at the very bottom, under
    /// the Paste button, in the editors.
    private func placeHint(atBottom: Bool) {
        hint.isHidden = false
        // atBottom means an editor panel: only those have the `?`.
        helpText.isHidden = !(atBottom && helpShown)
        help.state = helpShown ? .on : .off
        stack.removeArrangedSubview(hint)
        if atBottom {
            stack.addArrangedSubview(hint)
        } else {
            stack.insertArrangedSubview(hint, at: 1)
        }
    }

    private func keepOnScreen() {
        let frame = panel.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }) ?? NSScreen.main
        else { return }
        panel.setFrameOrigin(PanelGeometry.clamped(frame, into: screen.visibleFrame).origin)
    }

    /// The editor's header: the entry on one line, or `Edit` when it is empty.
    static func editorHeader(for entry: ClipEntry) -> String {
        let line = Titles.pipeHeader(for: entry, maxBytes: ClipboardHistory.popupTruncateLength)
        return line.isEmpty ? "Edit" : line
    }

    /// A size dragged with the corner grip; every editor opens at it.
    private static let sizeKey = "editorSize"
    private static var rememberedSize: NSSize? {
        get {
            guard let size = UserDefaults.standard.string(forKey: sizeKey).map(NSSizeFromString), size.width > 0 else { return nil }
            return size
        }
        set { UserDefaults.standard.set(newValue.map(NSStringFromSize), forKey: sizeKey) }
    }

    /// The grip or a wide drawing: the text area takes `size`, the panel's
    /// top-left corner stays put, and the panel stays on its screen.
    private func resizeEditor(to size: NSSize, remember: Bool) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = min(max(size.width, Self.editorMinWidth), visible.width - 40)
        let height = min(max(size.height, Self.editorMinHeight), visible.height - 250)
        editorWidthConstraint.constant = width
        editorHeightConstraint.constant = height
        if remember { Self.rememberedSize = NSSize(width: width, height: height) }
        let top = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setContentSize(content.fittingSize)
        panel.setFrameTopLeftPoint(top)
        keepOnScreen()
    }

    /// A drawing wider than the text area widens the panel (up to the screen);
    /// it never narrows on its own.
    private func growEditor(toFit width: CGFloat) {
        let needed = width + (editorScroll.verticalScroller?.frame.width ?? 15) + 4
        guard isEditing || onPickText != nil, needed > editorWidthConstraint.constant else { return }
        resizeEditor(to: NSSize(width: needed, height: editorHeightConstraint.constant), remember: false)
    }

    /// ~620×420 (or the size last dragged), shrunk to fit the screen the chooser opens on.
    private func editorSize(near point: NSPoint) -> NSSize {
        let size = PanelGeometry.constrainedSize(
            Self.rememberedSize ?? NSSize(width: Self.editorWidth, height: Self.editorHeight),
            minimum: NSSize(width: Self.editorMinWidth, height: Self.editorMinHeight),
            // Height padding leaves room for the header, hint, strip and pipe row.
            padding: NSSize(width: 20, height: 250),
            near: point
        )
        editorWidthConstraint.constant = size.width
        editorHeightConstraint.constant = size.height
        return content.fittingSize
    }

    func cancel() {
        // The hotkey again while editing saves: an edit is never lost to a toggle.
        guard !isEditing else {
            save()
            return
        }
        let handler = onCancel
        close()
        handler?()
    }

    /// Esc, Cmd+S, or losing key: hand the text back, then close.
    /// A click while listening does nothing: there is no text yet (`onSave` is nil).
    @objc private func submitClicked() { save() }

    /// Shows or hides the keys under the footer; the panel grows downward,
    /// its top edge and the text where they were.
    @objc private func helpClicked() {
        helpShown.toggle()
        help.state = helpShown ? .on : .off
        helpText.isHidden = !helpShown
        let top = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setContentSize(content.fittingSize)
        panel.setFrameTopLeftPoint(top)
        keepOnScreen()
        panel.makeFirstResponder(editor)
    }

    private func save() {
        guard let handler = onSave else { return }
        // Every save emits trimmed text: trailing whitespace is never meant to paste.
        let text = EditorText.trimmed(editor.string)
        close()
        handler(text)
    }

    /// Closes without calling either handler.
    func close() {
        isRunning = false
        isEditing = false
        isListening = false
        editor.ghost = nil
        onPick = nil
        onPickText = nil
        onCancel = nil
        onSave = nil
        pipes = []
        content.optionCount = 0
        editor.string = ""
        strip.isHidden = true
        editorScroll.isHidden = true
        footer.isHidden = true
        grip.isHidden = true
        editorRows.isHidden = true
        editor.isEditable = true
        rows.isHidden = false
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        // A click on the listening panel can make it key; losing key again
        // must not close it while the take is still being recorded.
        guard !isListening else { return }
        // Leaving an edit saves it: there is no way to lose the text by accident.
        guard !isEditing else {
            save()
            return
        }
        // An interactive pipe opens its own window and takes key focus; that must not abort the run.
        guard !isRunning else { return }
        cancel()
    }

    private func pick(_ index: Int) {
        if let handler = onPickText, pipes.indices.contains(index) {
            // The edited dictation feeds the pipe; the panel shows the run.
            let text = EditorText.trimmed(editor.string)
            isEditing = false
            onPickText = nil
            onSave = nil
            isRunning = true
            header.stringValue = PipeStrip.runningLabel(for: pipes[index])
            header.isHidden = false
            placeHint(atBottom: false)
            hint.stringValue = "Esc cancel"
            strip.isHidden = true
            editorScroll.isHidden = true
            footer.isHidden = true
            editorRows.isHidden = true
            panel.makeFirstResponder(content)
            panel.setContentSize(content.fittingSize)
            handler(pipes[index], text)
            return
        }
        guard pipes.indices.contains(index), let handler = onPick else { return }
        isRunning = true
        onPick = nil
        content.optionCount = 0
        header.stringValue = PipeStrip.runningLabel(for: pipes[index])
        hint.stringValue = entryIsEmpty ? "Esc cancel" : "Esc cancel and put back"
        rows.isHidden = true
        panel.setContentSize(content.fittingSize)
        handler(pipes[index])
    }

}

/// Three diagonal hairlines in the corner; dragging them resizes the editor.
/// Never moves the window (the panel is movable by its background).
final class ResizeGrip: NSView {
    /// The editor size when the drag starts.
    var onBegin: () -> NSSize = { .zero }
    var onDrag: (NSSize) -> Void = { _ in }
    private var start: (point: NSPoint, size: NSSize)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        // The diagonal resize cursor exists only as a private one; the frame
        // resize cursor is the closest public one.
        if #available(macOS 15.0, *) {
            addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
        } else {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func mouseDown(with event: NSEvent) {
        start = (NSEvent.mouseLocation, onBegin())
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let now = NSEvent.mouseLocation
        // Screen y grows upward: dragging down makes it taller.
        onDrag(NSSize(width: start.size.width + now.x - start.point.x, height: start.size.height - (now.y - start.point.y)))
    }

    override func mouseUp(with event: NSEvent) { start = nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        for k in [4.0, 8.0, 12.0] {
            path.move(to: NSPoint(x: bounds.maxX - k, y: bounds.minY + 1))
            path.line(to: NSPoint(x: bounds.maxX - 1, y: bounds.minY + k))
        }
        path.stroke()
    }
}
