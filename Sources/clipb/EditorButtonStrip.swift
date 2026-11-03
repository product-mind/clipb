import AppKit

/// The Cmd+Shift+E editor's action bar: one button per editor action, grouped
/// by kind and separated by hairlines. Every button runs the same method as
/// its chord, so a click and a keystroke cannot diverge. Find and Replace hand
/// focus to the find bar; every other click puts it back in the text.
final class EditorButtonStrip: NSStackView {
    /// One button's configuration: the face it shows, the tip naming the chord,
    /// and what it runs.
    private struct Item {
        /// Also the button's identity (undo, redo) and its face when the
        /// symbol is missing.
        var title: String
        var tooltip: String
        /// An SF Symbol, drawn semibold: reads better than a thin glyph.
        var symbol: String? = nil
        /// Find and Replace keep focus where the find bar put it.
        var leavesFocusInFindBar = false
        /// A word reads smaller than a glyph, so `MD` does not shout.
        var isWord = false
        /// A toggle: the button shows pressed while this is true.
        var isOn: (() -> Bool)? = nil
        /// Enabled only while text is selected.
        var needsSelection = false
        var action: (EditorTextView) -> Void
    }

    /// Faces are large and bold, buttons narrow: the user found the thin
    /// glyphs unreadable (MODAL.md). Text faces fall back to Menlo for the
    /// arrows; the system font swaps in unrelated CJK faces.
    private static let glyphFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .bold)
    private static let wordFont = NSFont.systemFont(ofSize: 12, weight: .bold)
    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
    private static let buttonWidth: CGFloat = 30
    private static let separatorHeight: CGFloat = 14

    private weak var editor: EditorTextView?
    private var handlers: [(run: (EditorTextView) -> Void, refocus: Bool)] = []
    private var undoObservers: [NSObjectProtocol] = []
    private weak var observedManager: UndoManager?
    private weak var undoButton: NSButton?
    private weak var redoButton: NSButton?
    private var toggles: [(button: NSButton, isOn: () -> Bool)] = []
    private var selectionButtons: [NSButton] = []
    private var selectionObserver: NSObjectProtocol?
    private var lookObserver: NSObjectProtocol?

    init(editor: EditorTextView) {
        self.editor = editor
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        // The strip lives inside a fixed-width panel: shrink it, never widen the panel.
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        buildGroups()
        syncUndoState()
        lookObserver = NotificationCenter.default.addObserver(
            forName: EditorTextView.markdownLookChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.syncToggles() }
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: editor, queue: .main
        ) { [weak self] _ in self?.syncSelectionButtons() }
        syncSelectionButtons()
    }

    /// Indent and outdent act on selected lines only.
    func syncSelectionButtons() {
        let selected = (editor?.selectedRange().length ?? 0) > 0
        for button in selectionButtons { button.isEnabled = selected }
    }

    /// Pressed or not, after a click or ⌘⇧M.
    func syncToggles() {
        for toggle in toggles { toggle.button.state = toggle.isOn() ? .on : .off }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let lookObserver { NotificationCenter.default.removeObserver(lookObserver) }
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        for token in undoObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Reads the manager once it exists and on every change it posts. The panel
    /// is reused and the manager only appears with the window, so a read at
    /// init or at click time would go stale while typing.
    func syncUndoState() {
        let manager = editor?.undoManager
        if manager !== observedManager { observe(manager) }
        undoButton?.isEnabled = manager?.canUndo ?? false
        redoButton?.isEnabled = manager?.canRedo ?? false
    }

    private func observe(_ manager: UndoManager?) {
        for token in undoObservers {
            NotificationCenter.default.removeObserver(token)
        }
        undoObservers.removeAll()
        observedManager = manager
        guard let manager else { return }
        let names: [Notification.Name] = [
            .NSUndoManagerDidCloseUndoGroup,
            .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange,
        ]
        for name in names {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: manager,
                queue: .main
            ) { [weak self] _ in self?.syncUndoState() }
            undoObservers.append(token)
        }
    }

    private func buildGroups() {
        var tag = 0
        for (groupIndex, group) in Self.groups.enumerated() {
            if groupIndex > 0 { addArrangedSubview(Self.separator()) }
            for item in group {
                let button = makeButton(item, tag: tag)
                addArrangedSubview(button)
                handlers.append((item.action, !item.leavesFocusInFindBar))
                // Undo and Redo carry the enabled state.
                if item.title == "↶" { undoButton = button }
                if item.title == "↷" { redoButton = button }
                if item.needsSelection { selectionButtons.append(button) }
                if let isOn = item.isOn {
                    button.setButtonType(.pushOnPushOff)
                    toggles.append((button, isOn))
                }
                tag += 1
            }
        }
        syncToggles()
    }

    private func makeButton(_ item: Item, tag: Int) -> NSButton {
        let button = NSButton(title: item.title, target: self, action: #selector(clicked(_:)))
        // The toolbar bezel hugs its face; the push bezel pads it wide.
        button.bezelStyle = .texturedRounded
        button.controlSize = .regular
        button.tag = tag
        button.toolTip = item.tooltip
        button.font = item.isWord ? Self.wordFont : Self.glyphFont
        if let name = item.symbol,
           let image = NSImage(systemSymbolName: name, accessibilityDescription: item.tooltip)?
               .withSymbolConfiguration(Self.symbolConfig) {
            button.title = ""
            button.image = image
            button.imagePosition = .imageOnly
        }
        if !item.isWord {
            button.widthAnchor.constraint(equalToConstant: Self.buttonWidth).isActive = true
        }
        // A click must not pull focus out of the text.
        button.refusesFirstResponder = true
        // The panel is narrow when a screen is: labels give way before the row does.
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    private static func separator() -> NSView {
        let view = EditorStripSeparator()
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 1),
            view.heightAnchor.constraint(equalToConstant: separatorHeight),
        ])
        return view
    }

    @objc private func clicked(_ sender: NSButton) {
        guard handlers.indices.contains(sender.tag), let editor else { return }
        let handler = handlers[sender.tag]
        handler.run(editor)
        guard handler.refocus else { return }
        // The selection stays where it was; only the first responder moves.
        editor.window?.makeFirstResponder(editor)
    }

    private static let groups: [[Item]] = [
        [
            Item(title: "B", tooltip: "Bold (⌘B)", symbol: "bold") { $0.boldAction() },
            Item(title: "I", tooltip: "Italic (⌘I)", symbol: "italic") { $0.italicAction() },
            Item(
                title: "<>",
                tooltip: "Code: `backticks` within a line, a ``` block across lines",
                symbol: "chevron.left.forwardslash.chevron.right"
            ) { $0.codeAction() },
            Item(title: "⊞", tooltip: "Align table (⌘⌥T)", symbol: "tablecells") { $0.tableAction() },
            Item(
                title: "MD",
                tooltip: "Markdown look (⌘⇧M): # headings larger, **bold**, *italic*, `code` styled. The text stays plain.",
                isWord: true,
                isOn: { EditorTextView.markdownLook },
                action: { $0.markdownToggleAction() }
            ),
        ],
        [
            Item(title: "↶", tooltip: "Undo (⌘Z)", symbol: "arrow.uturn.backward") {
                $0.undoAction()
            },
            Item(title: "↷", tooltip: "Redo (⌘⇧Z)", symbol: "arrow.uturn.forward") {
                $0.redoAction()
            },
        ],
        [
            Item(
                title: "⌕",
                tooltip: "Find (⌘F)",
                symbol: "magnifyingglass",
                leavesFocusInFindBar: true,
                action: { $0.findAction() }
            ),
            Item(
                title: "⇄",
                tooltip: "Find & replace (⌘⇧F or ⌘⌥F)",
                symbol: "arrow.left.arrow.right",
                leavesFocusInFindBar: true,
                action: { $0.replaceAction() }
            ),
        ],
        [
            Item(title: ">", tooltip: "Quote the selected lines (⌘⇧9)", symbol: "text.quote", needsSelection: true) {
                $0.quoteAction()
            },
            Item(title: "<<", tooltip: "Outdent the selected lines (⌘< or ⌘[)", symbol: "decrease.indent", needsSelection: true) {
                $0.outdentAction()
            },
            Item(title: ">>", tooltip: "Indent the selected lines (⌘> or ⌘])", symbol: "increase.indent", needsSelection: true) {
                $0.indentAction()
            },
        ],
    ]
}

/// One hairline between two groups. Drawn rather than layered, so a light/dark
/// switch repaints the separator colour.
private final class EditorStripSeparator: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSBezierPath(rect: bounds).fill()
    }
}
