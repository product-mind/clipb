import AppKit

/// Borderless panel that can take keystrokes without activating ClipB.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Search field for the panel. An accessory app has no Edit menu, so the
/// standard editing shortcuts (Cmd+A/C/V/X) are forwarded to the field editor.
final class PopupSearchField: NSSearchField {
    /// Cmd+Delete. Plain Delete keeps editing the query.
    var onDeleteItem: (() -> Void)?
    /// Cmd+1-9: run the pipe that digit labels. Digits type normally otherwise.
    var onDigit: ((Int) -> Void)?
    /// Cmd+H: obfuscate the highlighted entry ("hide").
    var onObfuscate: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.keyCode == 51 {
            onDeleteItem?()
            return true
        }
        guard event.modifierFlags.contains(.command),
              let chars = event.charactersIgnoringModifiers, chars.count == 1
        else { return false }

        // Swallowed even with no matching pipe: Cmd+digit is never text.
        if let digit = Int(chars) {
            onDigit?(digit)
            return true
        }
        if chars.lowercased() == "h" {
            onObfuscate?()
            return true
        }

        let action: Selector
        switch chars {
        case "a": action = NSSelectorFromString("selectAll:")
        case "c": action = NSSelectorFromString("copy:")
        case "v": action = NSSelectorFromString("paste:")
        case "x": action = NSSelectorFromString("cut:")
        default: return false
        }
        guard let editor = currentEditor() ?? window?.firstResponder as? NSText else { return false }
        _ = editor.perform(action, with: nil)
        return true
    }
}

/// Table that knows which row the pointer is over. A per-cell tracking area
/// misses the exit when rows scroll under a still pointer, so hover is derived
/// from the live pointer position instead.
final class HoverTableView: NSTableView {
    var onHoverRowChange: ((Int) -> Void)?
    var onRightClickRow: ((Int) -> Void)?
    private(set) var hoveredRow = -1

    override func rightMouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onRightClickRow?(row) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseMoved(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { refreshHover() }

    /// Recomputes the hovered row from where the pointer is right now.
    func refreshHover() {
        var row = -1
        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if visibleRect.contains(point) { row = self.row(at: point) }
        }
        hoveredRow = row
        onHoverRowChange?(row)
    }
}

/// One popup row: the title, then `#tag` and `#source` pills flush against the
/// right edge. Hovering swaps the pills for the action buttons, which anchor to
/// the same right edge; the title reserves their width so it never runs under.
final class PopupRowCell: NSView {
    static let pillMaxWidth: CGFloat = 110
    static let pillHeight: CGFloat = 14
    /// Worst case: four 16 pt buttons, three 4 pt gaps, 6 pt right inset.
    static let hoverButtonsWidth: CGFloat = 4 * 16 + 3 * 4 + 6
    let label = NSTextField(labelWithString: "")

    /// Hovered rows hide their pills and reserve the buttons' slot for the title.
    var buttonsVisible = false {
        didSet {
            if buttonsVisible != oldValue { needsLayout = true }
        }
    }

    /// Tag first, then source; extra slots are hidden. Pills are names, never
    /// values, so obfuscated rows can show them.
    var pillTexts: [String] = [] {
        didSet {
            for (i, pill) in pillViews.enumerated() {
                let text = i < pillTexts.count ? pillTexts[i] : ""
                pill.stringValue = text
                pill.isHidden = text.isEmpty
            }
            needsLayout = true
        }
    }

    private let pillViews: [NSTextField] = (0..<2).map { _ in NSTextField(labelWithString: "") }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13)
        addSubview(label)
        for pill in pillViews {
            pill.font = .systemFont(ofSize: 10, weight: .medium)
            pill.textColor = .secondaryLabelColor
            pill.alignment = .center
            pill.lineBreakMode = .byTruncatingTail
            pill.wantsLayer = true
            pill.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            pill.layer?.cornerRadius = 7
            pill.isHidden = true
            addSubview(pill)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        // Pills hug the right edge, source outermost; the title takes what is left.
        let inset: CGFloat = 4
        var right = bounds.width - inset
        var pillsWidth: CGFloat = 0
        for i in pillViews.indices.reversed() {
            let pill = pillViews[i]
            let text = i < pillTexts.count ? pillTexts[i] : ""
            // Hidden while hovered: the buttons take the pills' slot.
            let hidden = buttonsVisible || text.isEmpty
            if pill.isHidden != hidden { pill.isHidden = hidden }
            guard !hidden else { continue }
            let width = min(pill.intrinsicContentSize.width + 12, Self.pillMaxWidth)
            if pillsWidth > 0 { pillsWidth += 6 }
            pillsWidth += width
            pill.frame = NSRect(x: right - width, y: (bounds.height - Self.pillHeight) / 2, width: width, height: Self.pillHeight)
            right -= width + 6
        }
        let labelHeight = label.intrinsicContentSize.height
        let reserved = buttonsVisible ? Self.hoverButtonsWidth : 0
        let titleWidth = max(bounds.width - inset - pillsWidth - 8 - reserved, 80)
        label.frame = NSRect(x: 2, y: (bounds.height - labelHeight) / 2, width: titleWidth, height: labelHeight)
    }
}

/// Fuzzy-searchable popup shown at the cursor on the global hotkey. It never
/// activates ClipB: the panel takes key focus (Spotlight model) while open,
/// and dismiss or select hands key back to the window that held it before —
/// even a non-activating panel of an app that is not frontmost. One flat list
/// across all tags, filtered by `#tag` / `#source` tokens; the pipe buttons sit
/// at the very bottom and run on a click or a Cmd+digit.
final class HistoryPanel: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    var onSelect: ((ClipEntry) -> Void)?
    /// Esc and the hotkey-toggle: key focus back to the pre-show window.
    var onDismiss: (() -> Void)?
    /// Deletes the entry and returns the refreshed merged entries.
    var onDelete: ((_ tag: String?, _ entry: ClipEntry) -> [PopupEntry])?
    /// Toggles obfuscation and returns the refreshed merged entries.
    var onToggleObfuscation: ((_ tag: String?, _ entry: ClipEntry) -> [PopupEntry])?
    /// Puts the entry on the clipboard without pasting.
    var onCopy: ((ClipEntry) -> Void)?
    var onOpen: ((URL) -> Void)?
    /// Pastes the entry and deletes it (Shift+Enter).
    var onPasteAndDelete: ((_ tag: String?, _ entry: ClipEntry) -> Void)?
    /// A pipe button or digit on a non-text row: the notice replaces the beep.
    var onNonTextPipe: ((ClipEntry) -> Void)?
    /// Runs the pipe on the highlighted row's value; the panel stays open.
    var onPipe: ((_ pipe: PipeCommand, _ value: String) -> Void)?
    /// Esc during a run: cancel it, restore the button row.
    var onPipeCancel: (() -> Void)?
    /// Evaluated on each show; the dev build appends its uptime here.
    var searchPlaceholder: () -> String = { "Search clipboard history…" }

    private static let width: CGFloat = 560
    private static let rowHeight: CGFloat = 22
    private static let visibleRows = 10
    private static let barHeight: CGFloat = 32
    private static let hintHeight: CGFloat = 14
    private static let hintText = "⏎ paste · ⇧⏎ paste & delete · ⌫ delete · ⌘H hide"

    private static let footerGap: CGFloat = 10

    private let panel: KeyablePanel
    private let background = NSVisualEffectView()
    private let searchField = PopupSearchField()
    private let pipeOptionsRow = PipeOptionsRow()
    private let pipeRunningLabel = NSTextField(labelWithString: "")
    private let pipeHint = NSTextField(labelWithString: HistoryPanel.hintText)
    private var pipeStrip = PipeStrip(pipes: [])
    private var runningPipe: PipeCommand?
    // One shared set of buttons, moved to the hovered row. Per-row buttons could
    // not be reliably hidden again after scrolling.
    private let openButton = NSButton()
    private let copyButton = NSButton()
    private let obfuscateButton = NSButton()
    private let deleteButton = NSButton()
    private let scroll = NSScrollView()
    private let table = HoverTableView()
    private var all: [PopupEntry] = []
    private var shown: [PopupEntry] = []
    private var mouseMonitor: Any?
    private var lastQueryChange = Date.distantPast
    /// The row whose hover buttons are showing; its cell hides the pills.
    private weak var hoverCell: PopupRowCell?

    override init() {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
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
        panel.acceptsMouseMovedEvents = true

        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        panel.contentView = background

        searchField.placeholderString = "Search clipboard history…"
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.onDeleteItem = { [weak self] in
            guard let self else { return }
            self.deleteRow(self.table.selectedRow)
        }
        searchField.onDigit = { [weak self] digit in self?.runPipe(digit: digit) }
        searchField.onObfuscate = { [weak self] in self?.toggleObfuscation(row: self?.table.selectedRow ?? -1) }
        background.addSubview(searchField)

        pipeOptionsRow.onPick = { [weak self] index in self?.runPipe(at: index) }
        pipeOptionsRow.isHidden = true
        background.addSubview(pipeOptionsRow)

        pipeRunningLabel.font = .systemFont(ofSize: 13)
        pipeRunningLabel.lineBreakMode = .byTruncatingTail
        pipeRunningLabel.isHidden = true
        background.addSubview(pipeRunningLabel)

        pipeHint.font = .systemFont(ofSize: 11)
        pipeHint.textColor = .tertiaryLabelColor
        pipeHint.alignment = .center
        pipeHint.isHidden = true
        background.addSubview(pipeHint)


        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        column.width = Self.width - 20
        // Fit the clip view; a wider column pushed the delete button off-screen.
        column.resizingMask = .autoresizingMask
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.intercellSpacing = .zero
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)

        table.onHoverRowChange = { [weak self] row in self?.applyHover(row) }
        table.onRightClickRow = { [weak self] row in self?.deleteRow(row) }
        // Rows slide under a still pointer while scrolling; re-derive hover.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [weak self] _ in self?.table.refreshHover() }

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        background.addSubview(scroll)

        configure(openButton, symbol: "arrow.up.right.square", tooltip: "Open in browser", action: #selector(openButtonClicked))
        configure(copyButton, symbol: "doc.on.doc", tooltip: "Copy without pasting", action: #selector(copyButtonClicked))
        configure(obfuscateButton, symbol: "eye.slash", tooltip: "Obfuscate (⌘H)", action: #selector(obfuscateButtonClicked))
        configure(deleteButton, symbol: "xmark.circle.fill", tooltip: "Delete", action: #selector(deleteButtonClicked))
    }

    private func configure(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        // Clicking it must not pull focus out of the search field.
        button.refusesFirstResponder = true
        button.target = self
        button.action = action
        button.isHidden = true
        background.addSubview(button)
    }

    var isVisible: Bool { panel.isVisible }

    func show(entries: [PopupEntry], at point: NSPoint, pipes: [PipeCommand] = []) {
        all = entries
        // A fresh load each show: edits to the config apply without a restart.
        pipeStrip = PipeStrip(pipes: pipes)
        runningPipe = nil
        pipeOptionsRow.setPipes(pipeStrip.pipes)
        layout()
        renderPipeRun()
        searchField.stringValue = ""
        searchField.placeholderString = searchPlaceholder()
        applyFilter()

        var origin = NSPoint(x: point.x, y: point.y - panel.frame.height)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            let area = screen.visibleFrame
            origin.x = min(max(origin.x, area.minX), area.maxX - panel.frame.width)
            origin.y = min(max(origin.y, area.minY), area.maxY - panel.frame.height)
        }
        panel.setFrameOrigin(origin)

        // No NSApp.activate: the frontmost app must stay frontmost.
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(searchField)

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    /// Esc / hotkey-toggle: close, then hand key focus back deterministically —
    /// orderOut already returns it to the pre-show key window, and `onDismiss`
    /// reasserts that via AX where the default heir would miss a
    /// non-activating panel target.
    func dismiss() {
        close()
        onDismiss?()
    }

    /// No refocus here: a click outside deliberately keys the clicked window.
    func close() {
        // Closing mid-run (Esc, hotkey, click outside) abandons the pipe.
        if runningPipe != nil {
            runningPipe = nil
            onPipeCancel?()
        }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        panel.orderOut(nil)
    }

    private func deleteRow(_ row: Int) {
        // A run owns the panel: deleting its input mid-flight makes the outcome land wrong.
        guard runningPipe == nil, shown.indices.contains(row), let onDelete else { return }
        reload(entries: onDelete(shown[row].tag, shown[row].entry), keepRow: row)
    }

    /// Re-renders after a delete without moving the panel's top edge.
    private func reload(entries: [PopupEntry], keepRow: Int) {
        all = entries
        applyFilter()
        if !shown.isEmpty {
            table.selectRowIndexes([min(keepRow, shown.count - 1)], byExtendingSelection: false)
        }
    }

    private func layout() {
        let area = stripVisible ? Self.barHeight : 0
        // Footer from the bottom up: the bar, then the hint line above it -
        // both modals render the hint above the buttons.
        let block = stripVisible ? area + 6 + Self.hintHeight + 10 : 0
        let height = 40 + CGFloat(Self.visibleRows) * Self.rowHeight + 8 + block
        panel.setContentSize(NSSize(width: Self.width, height: height))

        if stripVisible {
            pipeOptionsRow.frame = NSRect(x: 10, y: 4, width: Self.width - 20, height: area)
            // Same slot: the running label must not move the search field.
            pipeRunningLabel.frame = NSRect(x: 10, y: 4 + (area - 18) / 2, width: Self.width - 20, height: 18)
            pipeHint.frame = NSRect(x: 10, y: 4 + area + 6, width: Self.width - 20, height: Self.hintHeight)
        }
        pipeHint.isHidden = !stripVisible
        searchField.frame = NSRect(x: 10, y: height - 34, width: Self.width - 20, height: 24)
        scroll.frame = NSRect(x: 4, y: 4 + block, width: Self.width - 8, height: height - 44 - block)
        table.setFrameSize(NSSize(width: scroll.contentSize.width, height: table.frame.height))
        table.sizeLastColumnToFit()
    }

    private func choose(row: Int) {
        // A run owns the panel: a second Enter or click must not paste on top of it.
        guard shown.indices.contains(row), runningPipe == nil else { return }
        let entry = shown[row].entry
        close()
        onSelect?(entry)
    }

    private func pasteAndDelete(row: Int) {
        guard shown.indices.contains(row), runningPipe == nil, let onPasteAndDelete else { return }
        close()
        onPasteAndDelete(shown[row].tag, shown[row].entry)
    }

    private var stripVisible: Bool { pipeStrip.isAvailable }

    /// Cmd+N runs the option that digit labels, at once.
    private func runPipe(digit: Int) {
        guard pipeStrip.pipe(forDigit: digit) != nil else { return }
        runPipe(at: digit - 1)
    }

    /// The option's button was clicked, or its Cmd+digit pressed: run it on
    /// the highlighted row immediately, keeping the panel open.
    private func runPipe(at index: Int) {
        guard runningPipe == nil, pipeStrip.pipes.indices.contains(index),
              shown.indices.contains(table.selectedRow) else { return }
        // Pipes read text only: a non-text row gets the notice instead of piping bytes.
        let entry = shown[table.selectedRow].entry
        guard entry.image == nil, entry.fileURLs == nil else {
            onNonTextPipe?(entry)
            return
        }
        let pipe = pipeStrip.pipes[index]
        runningPipe = pipe
        renderPipeRun()
        onPipe?(pipe, entry.value)
    }

    /// While a pipe runs the buttons give way to its name; Esc brings them back.
    private func renderPipeRun() {
        if let runningPipe { pipeRunningLabel.stringValue = PipeStrip.runningLabel(for: runningPipe) }
        pipeRunningLabel.isHidden = runningPipe == nil
        pipeOptionsRow.isHidden = !stripVisible || runningPipe != nil
    }

    /// The run ended: drop the running state and close.
    func finishPipeRun() {
        runningPipe = nil
        close()
    }

    private func applyFilter() {
        shown = HistoryFilter.filtered(all, query: searchField.stringValue)
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        table.refreshHover()
    }

    @objc private func rowClicked() {
        choose(row: table.clickedRow)
    }

    private func moveSelection(by delta: Int) {
        guard !shown.isEmpty else { return }
        let next = min(max(table.selectedRow + delta, 0), shown.count - 1)
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        lastQueryChange = Date()
        applyFilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            // Tab switches nothing any more; swallow it so focus stays put.
            break
        case #selector(NSResponder.insertNewline(_:)):
            // Shift+Return reports the same selector as Return.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                pasteAndDelete(row: table.selectedRow)
            } else {
                choose(row: table.selectedRow)
            }
        case #selector(NSResponder.cancelOperation(_:)): escape()
        case #selector(NSResponder.deleteToBeginningOfLine(_:)): deleteRow(table.selectedRow)
        case #selector(NSResponder.deleteBackward(_:)):
            guard textView.string.isEmpty, canDeleteItemFromKey() else { return false }
            deleteRow(table.selectedRow)
        case #selector(NSResponder.deleteForward(_:)):
            let caret = textView.selectedRange()
            guard caret.length == 0, caret.location == textView.string.utf16.count, canDeleteItemFromKey() else { return false }
            deleteRow(table.selectedRow)
        default: return false
        }
        return true
    }

    /// Esc peels one layer at a time: a running pipe, then the popup.
    private func escape() {
        if runningPipe != nil {
            runningPipe = nil
            onPipeCancel?()
            renderPipeRun()
            return
        }
        dismiss()
    }

    /// Delete keys only remove an item once there is no text left to edit.
    /// Ignoring repeats and the key press that just emptied the query stops
    /// holding Delete from eating entries after the query is gone.
    private func canDeleteItemFromKey() -> Bool {
        if NSApp.currentEvent?.isARepeat == true { return false }
        return Date().timeIntervalSince(lastQueryChange) > 0.4
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = PopupRowCell(frame: NSRect(x: 0, y: 0, width: tableColumn?.width ?? Self.width - 20, height: Self.rowHeight))
        cell.label.stringValue = Titles.popupTitle(for: shown[row].entry)
        cell.pillTexts = HistoryFilter.pills(for: shown[row].entry)
        // Cells are reused: a new row never inherits the previous hover state.
        cell.buttonsVisible = false
        return cell
    }

    private func applyHover(_ hovered: Int) {
        let buttons = [openButton, copyButton, obfuscateButton, deleteButton]
        // The pills come back on the row the pointer just left.
        hoverCell?.buttonsVisible = false
        hoverCell = nil
        guard shown.indices.contains(hovered), let cell = table.view(atColumn: 0, row: hovered, makeIfNecessary: false) as? PopupRowCell else {
            buttons.forEach { $0.isHidden = true }
            return
        }
        cell.buttonsVisible = true
        hoverCell = cell
        let entry = shown[hovered].entry
        obfuscateButton.image = NSImage(
            systemSymbolName: entry.obfuscated ? "eye" : "eye.slash",
            accessibilityDescription: nil
        )
        obfuscateButton.toolTip = entry.obfuscated ? "Show" : "Obfuscate"

        let visible = buttons.filter { $0 !== openButton || Links.webURL(in: entry.value) != nil }
        buttons.forEach { $0.isHidden = !visible.contains($0) }
        let rowRect = table.convert(table.rect(ofRow: hovered), to: background)
        // Right-aligned: the last button sits at the edge, the rest stack leftwards.
        var x = rowRect.maxX - 6
        for button in visible.reversed() {
            x -= 16
            button.frame = NSRect(x: x, y: rowRect.midY - 8, width: 16, height: 16)
            x -= 4
        }
    }

    @objc private func openButtonClicked() {
        let row = table.hoveredRow
        guard shown.indices.contains(row), let url = Links.webURL(in: shown[row].entry.value) else { return }
        close()
        onOpen?(url)
    }

    @objc private func copyButtonClicked() {
        let row = table.hoveredRow
        guard shown.indices.contains(row) else { return }
        let entry = shown[row].entry
        close()
        onCopy?(entry)
    }

    @objc private func obfuscateButtonClicked() {
        toggleObfuscation(row: table.hoveredRow)
    }

    private func toggleObfuscation(row: Int) {
        guard runningPipe == nil, shown.indices.contains(row), let onToggleObfuscation else { return }
        reload(entries: onToggleObfuscation(shown[row].tag, shown[row].entry), keepRow: row)
    }

    @objc private func deleteButtonClicked() {
        deleteRow(table.hoveredRow)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
