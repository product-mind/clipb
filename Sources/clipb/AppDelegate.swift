import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let history = ClipboardHistory()
    private let watcher = ClipboardWatcher()
    private let hotKey = HotKey()
    private let panel = HistoryPanel()
    private let ipcServer = IPCServer()
    private var statusItem: NSStatusItem?
#if DEV_PERSIST
    private let devPersistence = DevPersistence.fromCommandLine()
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateOtherInstances()
#if DEV_PERSIST
        DevPersistence.waitForOtherInstancesToExit()
        devPersistence.restore(into: history)
        devPersistence.installTerminationHandlers()
#endif

        // After the old instance is gone, so it can't unlink our socket.
        ipcServer.onMessage = { [weak self] message in
            self?.history.push(message.text, tag: message.tag)
        }
        do {
            try ipcServer.start()
        } catch {
            fputs("clipb: clipb copy is unavailable, IPC server failed: \(error)\n", stderr)
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Clipboard") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "📋"
            }
            button.toolTip = "Clipboard"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        watcher.onChange = { [weak self] value in
            self?.history.push(value)
        }
        watcher.start(interval: 0.5)

        hotKey.handler = { [weak self] in
            self?.togglePanel()
        }
        hotKey.register()

        Paste.ensureAccessibility()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ipcServer.stop()
#if DEV_PERSIST
        devPersistence.save(history)
#endif
    }

    private func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where app != .current {
            app.terminate()
        }
    }

    // MARK: - Tray menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let title = menu.addItem(withTitle: "ClipB", action: nil, keyEquivalent: "")
        title.isEnabled = false
        let quit = menu.addItem(withTitle: "Quit", action: #selector(quitClicked), keyEquivalent: "")
        quit.target = self
        // With tags, name the list like its tab so every Clear item reads alike.
        let clearTitle = history.tags.isEmpty
            ? "Clear"
            : "Clear \u{201C}\(PopupTabs.uncategorizedTitle)\u{201D} (\(history.entries.count))"
        let clear = menu.addItem(withTitle: clearTitle, action: #selector(clearClicked), keyEquivalent: "")
        clear.target = self
        for tag in history.tags {
            let count = history.entries(for: tag).count
            let item = menu.addItem(
                withTitle: "Clear \u{201C}\(tag)\u{201D} (\(count))",
                action: #selector(clearTagClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = tag
        }
        menu.addItem(.separator())

        for entry in history.entries {
            let title = Titles.menuTitle(for: entry)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            // Never leak the full value of an obfuscated entry, even in a tooltip.
            item.toolTip = entry.obfuscated ? title : entry.value
            item.submenu = entrySubmenu(for: entry)
            menu.addItem(item)
        }
    }

    private func entrySubmenu(for entry: ClipEntry) -> NSMenu {
        let submenu = NSMenu()

        let copy = NSMenuItem(title: "Copy", action: #selector(copyClicked(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = entry.value
        submenu.addItem(copy)

        let obfuscate = NSMenuItem(
            title: "Obfuscate Password",
            action: #selector(obfuscateClicked(_:)),
            keyEquivalent: ""
        )
        obfuscate.target = self
        obfuscate.representedObject = entry.value
        obfuscate.state = entry.obfuscated ? .on : .off
        submenu.addItem(obfuscate)

        let delete = NSMenuItem(title: "Delete", action: #selector(deleteClicked(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = entry.value
        submenu.addItem(delete)

        return submenu
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    // Uncategorized only: tagged items (dictations) must survive a casual Clear.
    @objc private func clearClicked() {
        history.clear(tag: nil)
    }

    @objc private func clearTagClicked(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String else { return }
        history.clear(tag: tag)
    }

    @objc private func copyClicked(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        watcher.write(value)
    }

    @objc private func obfuscateClicked(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let index = history.index(of: value) else { return }
        history.toggleObfuscation(at: index)
    }

    @objc private func deleteClicked(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let index = history.index(of: value) else { return }
        history.delete(at: index)
    }

    // MARK: - Hotkey popup

    private func togglePanel() {
        if panel.isVisible {
            panel.close()
            return
        }
        let tabs = PopupTabs.make(from: history)
        guard tabs.contains(where: { !$0.entries.isEmpty }) else { return }
        let target = PasteTarget.capture()
        panel.onSelect = { [weak self] value in
            self?.watcher.write(value)
            target?.restoreFocus()
            // Let the target window take key status before the keystroke.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                // Audible, so a missing grant doesn't fail silently.
                if !Paste.simulateCmdV() { NSSound.beep() }
            }
        }
        panel.onDelete = { [weak self] tag, value in
            guard let self else { return [] }
            if let index = self.history.index(of: value, tag: tag) {
                self.history.delete(at: index, tag: tag)
            }
            return PopupTabs.make(from: self.history)
        }
        panel.show(tabs: tabs, at: NSEvent.mouseLocation)
    }
}
