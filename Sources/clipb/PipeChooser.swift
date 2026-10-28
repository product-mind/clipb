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

/// Lists the pipes for the cut text, then shows progress while one runs.
/// The header shows the text truncated; the full value never appears.
final class PipeChooser: NSObject, NSWindowDelegate {
    private let panel: KeyablePanel
    private let content = PipeChooserView(frame: .zero)
    private let header = NSTextField(labelWithString: "")
    private let rows = PipeOptionsRow()
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

        rows.onPick = { [weak self] index in self?.pick(index) }

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
    /// A single pipe skips the list and runs at once.
    func show(
        pipes: [PipeCommand],
        text: String,
        near point: NSPoint,
        onPick: @escaping (PipeCommand) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.pipes = pipes
        self.onPick = onPick
        self.onCancel = onCancel
        content.optionCount = pipes.count
        header.stringValue = Titles.pipeHeader(for: text, maxBytes: ClipboardHistory.popupTruncateLength)
        hint.stringValue = "⌘1-\(pipes.count) run · Esc put back"
        rows.setPipes(pipes, digitLabel: "⌘")
        rows.isHidden = false

        let size = content.fittingSize
        panel.setContentSize(size)
        var origin = NSPoint(x: point.x, y: point.y - size.height)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            let area = screen.visibleFrame
            origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
            origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(content)
        if pipes.count == 1 { pick(0) }
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
        header.stringValue = PipeStrip.runningLabel(for: pipes[index])
        hint.stringValue = "Esc cancel and put back"
        rows.isHidden = true
        panel.setContentSize(content.fittingSize)
        handler(pipes[index])
    }

}
