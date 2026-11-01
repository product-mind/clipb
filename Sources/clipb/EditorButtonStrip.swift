import AppKit

/// The Cmd+Shift+E editor's action bar: one button per editor action, grouped
/// by kind and separated by hairlines. Every button runs the same method as
/// its chord, so a click and a keystroke cannot diverge. Find and Replace hand
/// focus to the find bar; every other click puts it back in the text.
final class EditorButtonStrip: NSStackView {
    /// One button's configuration: the face it shows, the tip naming the chord,
    /// and what it runs.
    private struct Item {
        var title: String
        var tooltip: String
        /// Find and Replace keep focus where the find bar put it.
        var leavesFocusInFindBar = false
        /// A word reads smaller than a glyph, so `Trim` does not shout.
        var isWord = false
        var action: (EditorTextView) -> Void
    }

    /// The arrow glyphs (↶ ↷ ⌕ ⇄) exist only in Menlo, which the monospaced
    /// face falls back to; the system font swaps in unrelated CJK faces.
    private static let glyphFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let wordFont = NSFont.systemFont(ofSize: 12)
    private static let separatorHeight: CGFloat = 14

    private weak var editor: EditorTextView?
    private var handlers: [(run: (EditorTextView) -> Void, refocus: Bool)] = []
    private var undoObservers: [NSObjectProtocol] = []
    private weak var observedManager: UndoManager?
    private weak var undoButton: NSButton?
    private weak var redoButton: NSButton?

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
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
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
                // The first group is Undo/Redo; its two buttons carry the enabled state.
                if groupIndex == 0 {
                    if tag == 0 { undoButton = button } else { redoButton = button }
                }
                tag += 1
            }
        }
    }

    private func makeButton(_ item: Item, tag: Int) -> NSButton {
        let button = NSButton(title: item.title, target: self, action: #selector(clicked(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.tag = tag
        button.toolTip = item.tooltip
        button.font = item.isWord ? Self.wordFont : Self.glyphFont
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
            Item(title: "↶", tooltip: "Undo (⌘Z)") {
                $0.undoAction()
            },
            Item(title: "↷", tooltip: "Redo (⌘⇧Z)") {
                $0.redoAction()
            },
        ],
        [
            Item(
                title: "⌕",
                tooltip: "Find (⌘F)",
                leavesFocusInFindBar: true,
                action: { $0.findAction() }
            ),
            Item(
                title: "⇄",
                tooltip: "Replace (⌘⌥F)",
                leavesFocusInFindBar: true,
                action: { $0.replaceAction() }
            ),
        ],
        [
            Item(title: ">", tooltip: "Quote (⌘⇧.)") {
                $0.quoteAction()
            },
            Item(title: "<<", tooltip: "Outdent (⌘[)") {
                $0.outdentAction()
            },
            Item(title: ">>", tooltip: "Indent (⌘])") {
                $0.indentAction()
            },
        ],
        [
            Item(title: "AA", tooltip: "Uppercase (⌘⇧U)") {
                $0.upperAction()
            },
            Item(title: "aa", tooltip: "Lowercase (⌘⇧L)") {
                $0.lowerAction()
            },
        ],
        [
            Item(title: "Trim", tooltip: "Trim trailing whitespace", isWord: true) {
                $0.trimAction()
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
