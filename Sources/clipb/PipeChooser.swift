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
        if modifiers.isEmpty,
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

/// Lists the pipes for the cut text, then shows progress while one runs.
/// Never shows the text itself: it may be a password.
final class PipeChooser: NSObject, NSWindowDelegate {
    private let panel: KeyablePanel
    private let content = PipeChooserView(frame: .zero)
    private let header = NSTextField(labelWithString: "")
    private let rows = NSStackView()
    private let hint = NSTextField(labelWithString: "")
    private var pipes: [PipeCommand] = []
    private var onPick: ((PipeCommand) -> Void)?
    private var onCancel: (() -> Void)?

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

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let outer = NSStackView(views: [header, rows, hint])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 10
        outer.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        outer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: content.topAnchor),
            outer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            outer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            outer.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
    }

    var isVisible: Bool { panel.isVisible }

    /// `onCancel` fires on Esc, a click elsewhere, or the hotkey again, while listing or running.
    func show(
        pipes: [PipeCommand],
        characters: Int,
        onPick: @escaping (PipeCommand) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.pipes = pipes
        self.onPick = onPick
        self.onCancel = onCancel
        content.optionCount = pipes.count
        header.stringValue = "Pipe \(characters) chars through:"
        hint.stringValue = "1-\(pipes.count) run · Esc put back"
        rebuildRows()
        rows.isHidden = false

        let size = content.fittingSize
        panel.setContentSize(size)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(content)
    }

    func cancel() {
        let handler = onCancel
        close()
        handler?()
    }

    /// Closes without calling either handler.
    func close() {
        onPick = nil
        onCancel = nil
        pipes = []
        content.optionCount = 0
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        cancel()
    }

    private func pick(_ index: Int) {
        guard pipes.indices.contains(index), let handler = onPick else { return }
        onPick = nil
        content.optionCount = 0
        header.stringValue = "Running \(pipes[index].name)…"
        hint.stringValue = "Esc cancel and put back"
        rows.isHidden = true
        panel.setContentSize(content.fittingSize)
        handler(pipes[index])
    }

    private func rebuildRows() {
        for view in rows.arrangedSubviews {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, pipe) in pipes.enumerated() {
            // The digit is a click target too: people click the number they see.
            let digit = NSButton(title: "\(index + 1)", target: self, action: #selector(rowClicked(_:)))
            digit.isBordered = false
            digit.tag = index
            digit.refusesFirstResponder = true
            digit.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            digit.contentTintColor = .secondaryLabelColor

            let button = NSButton(title: pipe.name, target: self, action: #selector(rowClicked(_:)))
            button.bezelStyle = .rounded
            button.tag = index
            // Keep keyboard focus on the content view, so digit keys still reach it.
            button.refusesFirstResponder = true
            button.cell?.lineBreakMode = .byTruncatingMiddle
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true

            let row = NSStackView(views: [digit, button])
            row.orientation = .horizontal
            row.spacing = 8
            rows.addArrangedSubview(row)
        }
    }

    @objc private func rowClicked(_ sender: NSButton) {
        pick(sender.tag)
    }
}
