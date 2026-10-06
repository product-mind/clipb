import AppKit

/// Borderless panel that can take keystrokes without activating ClipB.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Search field for the panel. An accessory app has no Edit menu, so the
/// standard editing shortcuts (Cmd+A/C/V/X) are forwarded to the field editor.
final class PopupSearchField: NSSearchField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
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

/// Fuzzy-searchable popup shown at the cursor on the global hotkey. It never
/// activates ClipB, so the frontmost app (e.g. an iTerm2 hotkey window) keeps
/// its focus. One tab per tag; the tab bar only appears once a tag exists.
final class HistoryPanel: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    var onSelect: ((String) -> Void)?

    private static let width: CGFloat = 420
    private static let rowHeight: CGFloat = 22
    private static let visibleRows = 10
    private static let tabBarHeight: CGFloat = 28

    private typealias Row = (title: String, matchText: String, value: String)

    private let panel: KeyablePanel
    private let background = NSVisualEffectView()
    private let tabControl = NSSegmentedControl()
    private let searchField = PopupSearchField()
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private var tabs: [PopupTab] = []
    private var currentTab = 0
    private var all: [Row] = []
    private var shown: [Row] = []
    private var mouseMonitor: Any?

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
        background.addSubview(searchField)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        column.width = Self.width - 20
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        background.addSubview(scroll)
    }

    var isVisible: Bool { panel.isVisible }

    func show(tabs: [PopupTab], at point: NSPoint) {
        self.tabs = tabs
        let showTabs = tabs.count > 1
        layout(showTabs: showTabs)

        if showTabs {
            tabControl.segmentCount = tabs.count
            for (i, tab) in tabs.enumerated() {
                tabControl.setLabel(tab.title, forSegment: i)
                tabControl.setWidth(0, forSegment: i)
            }
        }
        searchField.stringValue = ""
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
    }

    private func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        currentTab = index
        if tabs.count > 1 { tabControl.selectedSegment = index }
        all = tabs[index].entries.map { entry in
            let title = Titles.popupTitle(for: entry)
            // Obfuscated entries match on what they display, never the value.
            return (title, entry.obfuscated ? title : entry.value, entry.value)
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
        shown = all.filter { query.isEmpty || FuzzyMatch.score(query: query, in: $0.matchText) != nil }
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
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
        default: return false
        }
        return true
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: shown[row].title)
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13)
        return label
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
