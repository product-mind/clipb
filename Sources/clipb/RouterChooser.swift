import AppKit

/// Owns the keyboard so digit keys, arrows and Esc work without a text field.
private final class ChooserView: NSVisualEffectView {
    var onPick: ((Int) -> Void)?
    var onMove: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    var optionCount = 0

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            onCancel?()
            return
        case 125:
            onMove?(1)
            return
        case 126:
            onMove?(-1)
            return
        default:
            break
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
    private let problemLabel = NSTextField(labelWithString: "")
    private let buttonRow = NSStackView()
    private let rememberTitle = NSTextField(labelWithString: "Remember for:")
    private let rememberStack = NSStackView()
    private let hint = NSTextField(labelWithString: "↑↓ remember · 1-9 open · Esc cancel")
    /// Profile buttons first, then the optional "Continue anyway" button.
    private var options: [ChooserOption] = []
    /// Options before this index have a digit key; the rest are button-only.
    private var digitCount = 0
    private var remember: [RememberOption] = []
    private var rememberSelected = 0
    private var radios: [NSButton] = []
    private var onChoose: ((ChooserOption, RememberOption?) -> Void)?

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
        content.onMove = { [weak self] step in self?.moveSelection(by: step) }
        content.onCancel = { [weak self] in self?.close() }
        panel.contentView = content

        header.font = .systemFont(ofSize: 13)
        header.textColor = .labelColor
        header.lineBreakMode = .byTruncatingMiddle

        problemLabel.font = .systemFont(ofSize: 12)
        problemLabel.textColor = .secondaryLabelColor
        problemLabel.lineBreakMode = .byWordWrapping
        problemLabel.maximumNumberOfLines = 3
        problemLabel.preferredMaxLayoutWidth = 320

        buttonRow.orientation = .horizontal
        buttonRow.alignment = .top
        buttonRow.spacing = 10

        rememberTitle.font = .systemFont(ofSize: 12)
        rememberTitle.textColor = .secondaryLabelColor

        rememberStack.orientation = .vertical
        rememberStack.alignment = .leading
        rememberStack.spacing = 4

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let outer = NSStackView(views: [header, problemLabel, buttonRow, rememberTitle, rememberStack, hint])
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
    /// An empty `remember` hides the section, which is the case while a problem blocks saving.
    func show(
        host: String,
        problem: String?,
        options: [ChooserOption],
        continueOption: ChooserOption?,
        remember: [RememberOption],
        onChoose: @escaping (ChooserOption, RememberOption?) -> Void
    ) {
        self.options = options + [continueOption].compactMap { $0 }
        self.digitCount = options.count
        self.remember = remember
        self.rememberSelected = 0
        self.onChoose = onChoose
        content.optionCount = digitCount
        header.stringValue = "Open in:  \(host)"
        problemLabel.stringValue = problem ?? ""
        problemLabel.isHidden = problem == nil
        rebuildButtons()
        rebuildRadios()
        let showsRemember = !remember.isEmpty
        rememberTitle.isHidden = !showsRemember
        rememberStack.isHidden = !showsRemember
        hint.isHidden = !showsRemember

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
        remember = []
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func choose(_ index: Int) {
        guard options.indices.contains(index) else { return }
        let option = options[index]
        let handler = onChoose
        // The continue button saves nothing: it is a one-off open in Safari.
        let saved = index < digitCount && remember.indices.contains(rememberSelected) ? remember[rememberSelected] : nil
        close()
        handler?(option, saved)
    }

    private func moveSelection(by step: Int) {
        guard !remember.isEmpty else { return }
        rememberSelected = (rememberSelected + step + remember.count) % remember.count
        updateRadios()
    }

    private func rebuildButtons() {
        for view in buttonRow.arrangedSubviews {
            buttonRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, option) in options.enumerated() {
            let isDigit = index < digitCount
            let title = isDigit ? option.label : "Continue anyway"
            let button = NSButton(title: title, target: self, action: #selector(optionClicked(_:)))
            button.bezelStyle = .rounded
            button.tag = index
            // Keep keyboard focus on the content view, so digit keys still reach it.
            button.refusesFirstResponder = true
            button.cell?.lineBreakMode = .byTruncatingMiddle
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 160).isActive = true

            // The digit is a click target too: people click the number they see.
            let digit = NSButton(title: isDigit ? "\(index + 1)" : "", target: self, action: #selector(optionClicked(_:)))
            digit.isBordered = false
            digit.tag = index
            digit.refusesFirstResponder = true
            digit.isEnabled = isDigit
            digit.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            digit.contentTintColor = .secondaryLabelColor

            let column = NSStackView(views: [digit, button])
            column.orientation = .vertical
            column.alignment = .centerX
            column.spacing = 4
            buttonRow.addArrangedSubview(column)
        }
    }

    private func rebuildRadios() {
        for view in rememberStack.arrangedSubviews {
            rememberStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        radios = remember.enumerated().map { index, option in
            let radio = NSButton(radioButtonWithTitle: option.label, target: self, action: #selector(radioClicked(_:)))
            radio.tag = index
            radio.refusesFirstResponder = true
            rememberStack.addArrangedSubview(radio)
            return radio
        }
        updateRadios()
    }

    private func updateRadios() {
        for (index, radio) in radios.enumerated() {
            radio.state = index == rememberSelected ? .on : .off
        }
    }

    @objc private func optionClicked(_ sender: NSButton) {
        choose(sender.tag)
    }

    @objc private func radioClicked(_ sender: NSButton) {
        rememberSelected = sender.tag
        updateRadios()
    }
}
