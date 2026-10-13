import AppKit

/// Owns the keyboard so digit keys and Esc work without a text field.
private final class ChooserView: NSVisualEffectView {
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

/// Asks which browser and profile should open a link; shows the host only, never the full URL.
final class RouterChooser: NSObject, NSWindowDelegate {
    private let panel: KeyablePanel
    private let content = ChooserView(frame: .zero)
    private let header = NSTextField(labelWithString: "")
    private let buttonRow = NSStackView()
    private var options: [ChooserOption] = []
    private var onChoose: ((ChooserOption) -> Void)?

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
        content.onPick = { [weak self] index in self?.choose(index) }
        content.onCancel = { [weak self] in self?.close() }
        panel.contentView = content

        header.font = .systemFont(ofSize: 13)
        header.textColor = .labelColor
        header.lineBreakMode = .byTruncatingMiddle

        buttonRow.orientation = .horizontal
        buttonRow.alignment = .top
        buttonRow.spacing = 10

        let outer = NSStackView(views: [header, buttonRow])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 12
        outer.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        outer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: content.topAnchor),
            outer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            outer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }

    /// Shows the chooser centered on the screen under the pointer. A chooser that
    /// is already open is replaced, along with its link host and options.
    func show(host: String, options: [ChooserOption], onChoose: @escaping (ChooserOption) -> Void) {
        self.options = options
        self.onChoose = onChoose
        content.optionCount = options.count
        header.stringValue = "Open in:  \(host)"
        rebuildButtons()

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

    func close() {
        onChoose = nil
        options = []
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func choose(_ index: Int) {
        guard options.indices.contains(index) else { return }
        let option = options[index]
        let handler = onChoose
        close()
        handler?(option)
    }

    private func rebuildButtons() {
        for view in buttonRow.arrangedSubviews {
            buttonRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, option) in options.enumerated() {
            let button = NSButton(title: option.label, target: self, action: #selector(optionClicked(_:)))
            button.bezelStyle = .rounded
            button.tag = index
            // Keep keyboard focus on the content view, so digit keys still reach it.
            button.refusesFirstResponder = true
            button.cell?.lineBreakMode = .byTruncatingMiddle
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 160).isActive = true

            let digit = NSTextField(labelWithString: "\(index + 1)")
            digit.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            digit.textColor = .secondaryLabelColor
            digit.alignment = .center

            let column = NSStackView(views: [digit, button])
            column.orientation = .vertical
            column.alignment = .centerX
            column.spacing = 4
            buttonRow.addArrangedSubview(column)
        }
    }

    @objc private func optionClicked(_ sender: NSButton) {
        choose(sender.tag)
    }
}
