import AppKit

/// Search field embedded in the hotkey popup's `NSMenu`.
///
/// Two AppKit quirks make this harder than a normal text field:
/// - `NSMenu` tracking runs its own run loop mode, so a same-turn
///   `makeFirstResponder` call is silently dropped — it has to be
///   scheduled into `.eventTracking` explicitly.
/// - During tracking, `NSMenu` intercepts Cmd+key combos itself before
///   they reach a custom item's view, so standard editing shortcuts
///   (Cmd+A/C/V/X) have to be forwarded to the field editor by hand.
final class PopupSearchField: NSSearchField {
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        perform(#selector(becomeFirstResponderNow), with: nil, afterDelay: 0, inModes: [.eventTracking, .default])
    }

    @objc private func becomeFirstResponderNow() {
        window?.makeFirstResponder(self)
    }

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

/// Fuzzy-searchable popup shown at the cursor on the global hotkey.
final class SearchPopup: NSObject, NSSearchFieldDelegate {
    private let menu = NSMenu()
    private var items: [NSMenuItem] = []
    private var noMatchItem: NSMenuItem!
    private var selectedValue: String?

    private static let containerWidth: CGFloat = 320
    private static let fieldWidth: CGFloat = 300

    /// Shows the popup at `point` and blocks until it's dismissed — this
    /// just mirrors `NSMenu.popUp`, which is itself modal. Returns the
    /// selected entry's value, or nil if dismissed without a selection.
    func show(entries: [ClipEntry], at point: NSPoint) -> String? {
        build(entries: entries)

        let previousApp = NSWorkspace.shared.frontmostApplication
        // An .accessory app doesn't receive real keystrokes just because a
        // window claims key status — it has to actually activate first.
        NSApp.activate(ignoringOtherApps: true)

        menu.popUp(positioning: nil, at: point, in: nil)

        previousApp?.activate(options: [])
        return selectedValue
    }

    private func build(entries: [ClipEntry]) {
        menu.removeAllItems()
        items = []
        selectedValue = nil

        let searchField = PopupSearchField(frame: NSRect(x: 10, y: 4, width: Self.fieldWidth, height: 24))
        searchField.placeholderString = "Search clipboard history…"
        searchField.font = .systemFont(ofSize: 13)
        searchField.focusRingType = .none
        searchField.delegate = self

        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.containerWidth, height: 32))
        container.addSubview(searchField)

        let searchItem = NSMenuItem()
        searchItem.view = container
        menu.addItem(searchItem)
        menu.addItem(.separator())

        noMatchItem = NSMenuItem(title: "No matches", action: nil, keyEquivalent: "")
        noMatchItem.isEnabled = false
        noMatchItem.isHidden = true

        if entries.isEmpty {
            let empty = NSMenuItem(title: "(no items)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for entry in entries {
                let item = NSMenuItem(
                    title: Titles.popupTitle(for: entry),
                    action: #selector(itemClicked(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = entry.value
                menu.addItem(item)
                items.append(item)
            }
            menu.addItem(noMatchItem)
        }
    }

    @objc private func itemClicked(_ sender: NSMenuItem) {
        selectedValue = sender.representedObject as? String
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        let query = field.stringValue

        var visibleCount = 0
        for item in items {
            let value = item.representedObject as? String ?? ""
            let matches = query.isEmpty || FuzzyMatch.score(query: query, in: value) != nil
            item.isHidden = !matches
            if matches { visibleCount += 1 }
        }
        noMatchItem.isHidden = visibleCount > 0 || items.isEmpty
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if let first = items.first(where: { !$0.isHidden && $0.isEnabled }) {
                selectedValue = first.representedObject as? String
            }
            menu.cancelTracking()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            menu.cancelTracking()
            return true
        default:
            return false
        }
    }
}
