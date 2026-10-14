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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.keyCode == 51 {
            onDeleteItem?()
            return true
        }
        guard event.modifierFlags.contains(.command),
              let chars = event.charactersIgnoringModifiers, chars.count == 1
        else { return false }

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

/// One popup row: the title, then a pill with the source app. Space on the
/// right is left for the panel's hover action buttons.
final class PopupRowCell: NSView {
    static let reservedRight: CGFloat = 96
    static let pillMaxWidth: CGFloat = 110
    let label = NSTextField(labelWithString: "")
    let pill = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13)
        addSubview(label)
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

    required init?(coder: NSCoder) { fatalError("not used") }

    var source: String? {
        didSet {
            pill.stringValue = source ?? ""
            pill.isHidden = source == nil
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let available = bounds.width - Self.reservedRight
        var pillWidth: CGFloat = 0
        if !pill.isHidden {
            pillWidth = min(pill.intrinsicContentSize.width + 12, Self.pillMaxWidth)
            pill.frame = NSRect(x: available - pillWidth, y: (bounds.height - 14) / 2, width: pillWidth, height: 14)
            pillWidth += 6
        }
        let labelHeight = label.intrinsicContentSize.height
        label.frame = NSRect(x: 2, y: (bounds.height - labelHeight) / 2, width: available - pillWidth - 2, height: labelHeight)
    }
}

/// Fuzzy-searchable popup shown at the cursor on the global hotkey. It never
/// activates ClipB, so the frontmost app (e.g. an iTerm2 hotkey window) keeps
/// its focus. One tab per tag; the tab bar only appears once a tag exists.
final class HistoryPanel: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    var onSelect: ((String) -> Void)?
    /// Deletes the entry and returns the refreshed tabs.
    var onDelete: ((_ tag: String?, _ value: String) -> [PopupTab])?
    /// Toggles obfuscation and returns the refreshed tabs.
    var onToggleObfuscation: ((_ tag: String?, _ value: String) -> [PopupTab])?
    /// Puts the value on the clipboard without pasting.
    var onCopy: ((String) -> Void)?
    var onOpen: ((URL) -> Void)?
    /// Evaluated on each show; the dev build appends its uptime here.
    var searchPlaceholder: () -> String = { "Search clipboard history…" }

    private static let width: CGFloat = 480
    private static let rowHeight: CGFloat = 22
    private static let visibleRows = 10
    private static let tabBarHeight: CGFloat = 28

    private typealias Row = (title: String, matchText: String, value: String, obfuscated: Bool, link: URL?, source: String?)

    private let panel: KeyablePanel
    private let background = NSVisualEffectView()
    private let tabControl = NSSegmentedControl()
    private let searchField = PopupSearchField()
    // One shared set of buttons, moved to the hovered row. Per-row buttons could
    // not be reliably hidden again after scrolling.
    private let openButton = NSButton()
    private let copyButton = NSButton()
    private let obfuscateButton = NSButton()
    private let deleteButton = NSButton()
    private let scroll = NSScrollView()
    private let table = HoverTableView()
    private var tabs: [PopupTab] = []
    private var currentTab = 0
    private var all: [Row] = []
    private var shown: [Row] = []
    private var mouseMonitor: Any?
    private var lastQueryChange = Date.distantPast

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

        // Clicking a tab must not pull focus out of the search field.
        tabControl.refusesFirstResponder = true
        tabControl.segmentStyle = .rounded
        tabControl.trackingMode = .selectOne
        tabControl.target = self
        tabControl.action = #selector(tabClicked)
        background.addSubview(tabControl)

        searchField.placeholderString = "Search clipboard history…"
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.onDeleteItem = { [weak self] in
            guard let self else { return }
            self.deleteRow(self.table.selectedRow)
        }
        background.addSubview(searchField)

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
        configure(obfuscateButton, symbol: "eye.slash", tooltip: "Obfuscate", action: #selector(obfuscateButtonClicked))
        configure(deleteButton, symbol: "xmark.circle.fill", tooltip: "Delete (⌘⌫)", action: #selector(deleteButtonClicked))
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

    func show(tabs: [PopupTab], at point: NSPoint) {
        self.tabs = tabs
        layout(showTabs: tabs.count > 1)
        configureTabControl()
        searchField.stringValue = ""
        searchField.placeholderString = searchPlaceholder()
        selectTab(PopupTabs.initialIndex(of: tabs))

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

    func close() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        panel.orderOut(nil)
    }

    private func configureTabControl() {
        guard tabs.count > 1 else { return }
        tabControl.segmentCount = tabs.count
        for (i, tab) in tabs.enumerated() {
            tabControl.setLabel(tab.title, forSegment: i)
            tabControl.setWidth(0, forSegment: i)
        }
    }

    /// While searching, each tab shows how many of its entries match.
    private func updateTabLabels() {
        guard tabs.count > 1 else { return }
        let query = searchField.stringValue
        let counts = PopupTabs.matchCounts(in: tabs, query: query)
        for (i, tab) in tabs.enumerated() {
            tabControl.setLabel(query.isEmpty ? tab.title : "\(tab.title) (\(counts[i]))", forSegment: i)
            tabControl.setWidth(0, forSegment: i)
        }
    }

    private func deleteRow(_ row: Int) {
        guard shown.indices.contains(row), let onDelete else { return }
        reload(tabs: onDelete(tabs[currentTab].tag, shown[row].value), keepRow: row)
    }

    /// Re-renders after a delete without moving the panel's top edge.
    private func reload(tabs newTabs: [PopupTab], keepRow: Int) {
        let keptTag = tabs.indices.contains(currentTab) ? tabs[currentTab].tag : nil
        let top = panel.frame.maxY
        tabs = newTabs
        layout(showTabs: newTabs.count > 1)
        panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
        configureTabControl()

        selectTab(newTabs.firstIndex { $0.tag == keptTag } ?? PopupTabs.initialIndex(of: newTabs))
        if !shown.isEmpty {
            table.selectRowIndexes([min(keepRow, shown.count - 1)], byExtendingSelection: false)
        }
    }

    private func layout(showTabs: Bool) {
        let base = 40 + CGFloat(Self.visibleRows) * Self.rowHeight + 8
        let height = base + (showTabs ? Self.tabBarHeight : 0)
        panel.setContentSize(NSSize(width: Self.width, height: height))

        var top = height
        tabControl.isHidden = !showTabs
        if showTabs {
            tabControl.frame = NSRect(x: 10, y: top - Self.tabBarHeight, width: Self.width - 20, height: 24)
            top -= Self.tabBarHeight
        }
        searchField.frame = NSRect(x: 10, y: top - 34, width: Self.width - 20, height: 24)
        scroll.frame = NSRect(x: 4, y: 4, width: Self.width - 8, height: top - 44)
        table.setFrameSize(NSSize(width: scroll.contentSize.width, height: table.frame.height))
        table.sizeLastColumnToFit()
    }

    private func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        currentTab = index
        if tabs.count > 1 { tabControl.selectedSegment = index }
        all = tabs[index].entries.map { entry in
            let title = Titles.popupTitle(for: entry)
            return (title, PopupTabs.matchText(for: entry), entry.value, entry.obfuscated, Links.webURL(in: entry.value), entry.source)
        }
        applyFilter()
    }

    private func choose(row: Int) {
        guard shown.indices.contains(row) else { return }
        let value = shown[row].value
        close()
        onSelect?(value)
    }

    private func applyFilter() {
        let query = searchField.stringValue
        shown = FuzzyMatch.rank(all, query: query) { $0.matchText }
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        table.refreshHover()
        updateTabLabels()
    }

    @objc private func rowClicked() {
        choose(row: table.clickedRow)
    }

    @objc private func tabClicked() {
        selectTab(tabControl.selectedSegment)
        panel.makeFirstResponder(searchField)
    }

    private func moveSelection(by delta: Int) {
        guard !shown.isEmpty else { return }
        let next = min(max(table.selectedRow + delta, 0), shown.count - 1)
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    private func moveTab(by delta: Int) {
        guard tabs.count > 1 else { return }
        selectTab(PopupTabs.index(from: currentTab, by: delta, count: tabs.count))
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
        case #selector(NSResponder.insertTab(_:)): moveTab(by: 1)
        case #selector(NSResponder.insertBacktab(_:)): moveTab(by: -1)
        case #selector(NSResponder.insertNewline(_:)): choose(row: table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)): close()
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
        cell.label.stringValue = shown[row].title
        cell.source = shown[row].source
        return cell
    }

    private func applyHover(_ hovered: Int) {
        let buttons = [openButton, copyButton, obfuscateButton, deleteButton]
        guard shown.indices.contains(hovered) else {
            buttons.forEach { $0.isHidden = true }
            return
        }
        let row = shown[hovered]
        obfuscateButton.image = NSImage(
            systemSymbolName: row.obfuscated ? "eye" : "eye.slash",
            accessibilityDescription: nil
        )
        obfuscateButton.toolTip = row.obfuscated ? "Show" : "Obfuscate"

        let visible = buttons.filter { $0 !== openButton || row.link != nil }
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
        guard shown.indices.contains(row), let url = shown[row].link else { return }
        close()
        onOpen?(url)
    }

    @objc private func copyButtonClicked() {
        let row = table.hoveredRow
        guard shown.indices.contains(row) else { return }
        let value = shown[row].value
        close()
        onCopy?(value)
    }

    @objc private func obfuscateButtonClicked() {
        let row = table.hoveredRow
        guard shown.indices.contains(row), let onToggleObfuscation else { return }
        reload(tabs: onToggleObfuscation(tabs[currentTab].tag, shown[row].value), keepRow: row)
    }

    @objc private func deleteButtonClicked() {
        deleteRow(table.hoveredRow)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
