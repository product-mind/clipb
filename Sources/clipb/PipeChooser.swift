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
    private static let editorWidth: CGFloat = 620
    private static let editorHeight: CGFloat = 420
    /// A short screen still gets an editor worth typing in, just a shorter one.
    private static let editorMinHeight: CGFloat = 160
    private static let editorMinWidth: CGFloat = 240
    static let editorHint = "Esc or ⌘S — save and paste back"

    private let panel: KeyablePanel
    private let content = PipeChooserView(frame: .zero)
    private let header = NSTextField(labelWithString: "")
    private let rows = PipeOptionsRow()
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

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        configureEditor()

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // The strip sits above the text, so the find bar's top edge stays one band.
        for view in [header, hint, rows, strip, editorScroll] {
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
            padding: NSSize(width: 20, height: 40),
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
        onPick = nil
        onCancel = nil
        onSave = nil
        pipes = []
        content.optionCount = 0
        editor.string = ""
        strip.isHidden = true
        editorScroll.isHidden = true
        rows.isHidden = false
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
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
