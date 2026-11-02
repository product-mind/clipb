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
    private static let editorWidth: CGFloat = 800
    /// Short enough that the header, the button strip and the pipe row under
    /// the text all fit on a laptop screen.
    private static let editorHeight: CGFloat = 340
    /// A short screen still gets an editor worth typing in, just a shorter one.
    private static let editorMinHeight: CGFloat = 160
    private static let editorMinWidth: CGFloat = 240
    static let editorHint = "Esc or ⌘S — save and paste back"
    static let dictationHint = "Esc or ⌘S — copy and paste back · hold ⌘C to dictate more"

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
        for view in [header, hint, rows, strip, editorScroll, editorRows] {
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
        near point: NSPoint,
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
        hint.stringValue = entryIsEmpty ? "Esc close" : "Esc put back"
        rows.setPipes(pipes)
        rows.isHidden = false
        strip.isHidden = true
        editorScroll.isHidden = true

        let size = content.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(PanelGeometry.origin(size: size, near: point))
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(content)
        if pipes.count == 1 { pick(0) }
    }

    /// Cmd+Shift+E: the panel turns into a text editor for the selection.
    /// Esc, Cmd+S, the hotkey again, or losing key saves and pastes back — an
    /// edit is never lost. No command runs, so there is no run state.
    func showEditor(entry: ClipEntry, near point: NSPoint, onSave: @escaping (String) -> Void) {
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

        let size = editorSize(near: point)
        panel.setContentSize(size)
        panel.setFrameOrigin(PanelGeometry.origin(size: size, near: point))
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(editor)
        // After the view is key: the undo manager only exists with a window.
        strip.syncUndoState()
    }

    // MARK: - Dictation (hold Cmd+C)

    /// The "Listening…" panel of a fresh hold is up.
    var isListeningPanel: Bool { isListening }

    /// An editor is open (dictation or Cmd+Shift+E): a hold inserts at its caret.
    var isEditorOpen: Bool { isEditing }
    /// The header to restore once a take into an open editor ends.
    private var headerBeforeListening: String?

    /// A hold became dictation. Opens the editor-sized panel at once, showing
    /// "Listening…", without taking key: the app keeps the rest of the
    /// keypress. Inside an open dictation editor only the header changes.
    func showListening(near point: NSPoint, pipes: [PipeCommand] = [], pipesError: String? = nil) {
        if isEditing {
            if headerBeforeListening == nil { headerBeforeListening = header.stringValue }
            header.stringValue = "Listening… — release to insert at the caret · Esc cancel"
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
        header.stringValue = "Listening…"
        hint.stringValue = Self.dictationHint(base: "Release to transcribe · Esc cancel", pipesError: pipesError)
        rows.isHidden = true
        strip.isHidden = true
        // The pipes show from the start, fully readable, so the panel never
        // jumps. A click picks nothing until the text arrives: `self.pipes` is
        // empty while listening.
        editorRows.setPipes(pipes)
        editorRows.isHidden = pipes.isEmpty
        editor.string = ""
        editor.isEditable = false
        editorScroll.isHidden = false
        let size = editorSize(near: point)
        panel.setContentSize(size)
        panel.setFrameOrigin(PanelGeometry.origin(size: size, near: point))
        panel.orderFrontRegardless()
    }

    func showTranscribing() {
        header.stringValue = "Transcribing…"
    }

    /// Listening ended without text (Esc, a tap, a failed take): a fresh
    /// listening panel closes; an open editor just gets its header back.
    func endListening() {
        if isEditing {
            restoreHeader()
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
        headerBeforeListening = nil
        isEditing = true
        isRunning = false
        self.pipes = pipes
        onPickText = onPick
        onCancel = onCancelRun
        self.onSave = onSave
        content.optionCount = 0
        header.stringValue = "Dictation"
        hint.stringValue = Self.dictationHint(base: Self.dictationHint, pipesError: pipesError)
        editorRows.setPipes(pipes)
        editorRows.isHidden = pipes.isEmpty
        strip.isHidden = false
        editor.isEditable = true
        editor.string = text
        let end = (text as NSString).length
        editor.setSelectedRange(NSRange(location: end, length: 0))
        editor.scrollRangeToVisible(NSRange(location: end, length: 0))
        editor.undoManager?.removeAllActions()
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
        restoreHeader()
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

    private func keepOnScreen() {
        let frame = panel.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }) ?? NSScreen.main
        else { return }
        panel.setFrameOrigin(PanelGeometry.clamped(frame, into: screen.visibleFrame).origin)
    }

    private func restoreHeader() {
        if let saved = headerBeforeListening { header.stringValue = saved }
        headerBeforeListening = nil
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
            padding: NSSize(width: 20, height: 220),
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
        headerBeforeListening = nil
        onPick = nil
        onPickText = nil
        onCancel = nil
        onSave = nil
        pipes = []
        content.optionCount = 0
        editor.string = ""
        strip.isHidden = true
        editorScroll.isHidden = true
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
            hint.stringValue = "Esc cancel"
            strip.isHidden = true
            editorScroll.isHidden = true
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
