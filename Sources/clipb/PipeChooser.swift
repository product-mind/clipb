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
    static let editorHint = "⌘V, ⌘↩ or Esc — paste back"
    static let dictationHint = "⌘V, ⌘↩ or Esc — copy and paste back · hold ⌘C to dictate more"
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
    private lazy var submit = NSButton(title: Self.submitTitle, target: self, action: #selector(submitClicked))
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
        for view in [editorRows, spacer, submit] { footer.addArrangedSubview(view) }
        footer.isHidden = true
        for view in [header, hint, rows, strip, editorScroll, footer] {
            stack.addArrangedSubview(view)
        }
        strip.isHidden = true
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            // Exactly the text's width: the buttons never widen the panel.
            strip.widthAnchor.constraint(equalTo: editorScroll.widthAnchor),
            footer.widthAnchor.constraint(equalTo: editorScroll.widthAnchor),
        ])
    }

    /// The editor rides in the same stack as the header, hidden while listing.
    private func configureEditor() {
        editor.onSave = { [weak self] in self?.save() }
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
        hint.stringValue = Self.editorHint
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
        hint.stringValue = Self.dictationHint(base: Self.dictationHint, pipesError: pipesError)
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
        hint.stringValue = Self.dictationHint(base: Self.dictationHint, pipesError: pipesError)
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
        // Keep the top edge where the listening panel stood: the pipe row grows
        // it downward. Then pull it back onto the screen so that row is never cut off.
        let top = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setContentSize(content.fittingSize)
        panel.setFrameTopLeftPoint(top)
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
    static func dictationHint(base: String, pipesError: String?) -> String {
        guard let pipesError else { return base }
        return "\(base)\nNo pipes — \(RouterConfig.displayPath): \(pipesError)"
    }

    /// Under the header for the pipe list and a run; at the very bottom, under
    /// the Paste button, in the editors.
    private func placeHint(atBottom: Bool) {
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

    /// ~620×420, shrunk to fit the screen the chooser opens on.
    private func editorSize(near point: NSPoint) -> NSSize {
        let size = PanelGeometry.constrainedSize(
            NSSize(width: Self.editorWidth, height: Self.editorHeight),
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
