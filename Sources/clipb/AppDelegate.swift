import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let history = ClipboardHistory()
    private let watcher = ClipboardWatcher()
    private let hotKey = HotKey.history()
    private let pipeHotKey = HotKey.pipe()
    private let panel = HistoryPanel()
    private let pipeChooser = PipeChooser()
    private var pipeRun: PipeRunner?
    private let ipcServer = IPCServer()
    private var redirects = RedirectLedger()
    private var statusItem: NSStatusItem?
#if DEV_PERSIST
    private let devPersistence = DevPersistence.fromCommandLine()
    private let startedAt = Date()
    private var uptime: String { Titles.uptime(Date().timeIntervalSince(startedAt)) }
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateOtherInstances()
#if DEV_PERSIST
        DevPersistence.waitForOtherInstancesToExit()
        devPersistence.restore(into: history)
        devPersistence.installTerminationHandlers()
        panel.searchPlaceholder = { [weak self] in
            "Search clipboard history… · up \(self?.uptime ?? "")"
        }
#endif

        // After the old instance is gone, so it can't unlink our socket.
        ipcServer.onMessage = { [weak self] message in
            if let open = message.open {
                if let url = Links.webURL(in: open) {
                    if let info = message.redirect { self?.redirects.record(url, info) }
                    self?.openLink(url)
                }
                return
            }
            self?.history.push(message.text, tag: message.tag)
        }
        ipcServer.onArrived = { [weak self] raw in
            guard let url = Links.webURL(in: raw) else { return nil }
            return self?.redirects.claim(url)
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

        watcher.onChange = { [weak self] value, source in
            self?.history.push(value, source: source)
        }
        watcher.start(interval: 0.5)

        hotKey.handler = { [weak self] in
            self?.togglePanel()
        }
        hotKey.register()

        pipeHotKey.handler = { [weak self] in
            self?.startPipe()
        }
        pipeHotKey.register()

        Paste.ensureAccessibility()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ipcServer.stop()
#if DEV_PERSIST
        devPersistence.save(history)
#endif
    }

    // MARK: - Link router

    static let linkTag = "link"

    // We are the default browser: the OS delivers every clicked link here.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "http" || url.scheme == "https" {
                openLink(url)
            } else {
                BrowserLauncher.route(url)
            }
        }
    }

    private func openLink(_ url: URL) {
        history.push(url.absoluteString, tag: Self.linkTag)
        BrowserLauncher.route(url)
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

#if DEV_PERSIST
        let title = menu.addItem(withTitle: "ClipB · up \(uptime)", action: nil, keyEquivalent: "")
#else
        let title = menu.addItem(withTitle: "ClipB", action: nil, keyEquivalent: "")
#endif
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
            self?.deliver(value, into: target)
        }
        panel.onDelete = { [weak self] tag, value in
            guard let self else { return [] }
            if let index = self.history.index(of: value, tag: tag) {
                self.history.delete(at: index, tag: tag)
            }
            return PopupTabs.make(from: self.history)
        }
        panel.onToggleObfuscation = { [weak self] tag, value in
            guard let self else { return [] }
            if let index = self.history.index(of: value, tag: tag) {
                self.history.toggleObfuscation(at: index, tag: tag)
            }
            return PopupTabs.make(from: self.history)
        }
        panel.onCopy = { [weak self] value in
            self?.watcher.write(value)
        }
        panel.onOpen = { url in
            BrowserLauncher.route(url)
        }
        panel.show(tabs: tabs, at: NSEvent.mouseLocation)
    }

    // MARK: - Pipes

    private func startPipe() {
        devLog("pipe: hotkey")
        if pipeChooser.isVisible {
            pipeChooser.cancel()
            return
        }
        // Check before cutting: with nothing to pick, the text must stay where it is.
        let pipes: [PipeCommand]
        do {
            pipes = try Pipes.load()
        } catch {
            fputs("clipb: pipes: \(error)\n", stderr)
            NSSound.beep()
            return
        }
        guard !pipes.isEmpty else {
            devLog("pipe: no pipes configured")
            return NSSound.beep()
        }

        let target = PasteTarget.capture()
        Paste.afterPipeHotKeyReleased(until: Date().addingTimeInterval(2)) { [weak self] in
            self?.cutSelection(pipes: pipes, into: target)
        }
    }

    private func cutSelection(pipes: [PipeCommand], into target: PasteTarget?) {
        let before = watcher.changeCount
        guard Paste.simulateCmdX() else {
            devLog("pipe: Cmd+X not sent, Accessibility trusted=\(AXIsProcessTrusted())")
            return NSSound.beep()
        }
        watcher.waitForChange(from: before, until: Date().addingTimeInterval(0.5)) { [weak self] text in
            // No selection, or an app that ignores Cmd+X.
            guard let self, let text, !text.isEmpty else {
                devLog("pipe: pasteboard unchanged after Cmd+X")
                return NSSound.beep()
            }
            self.pipeChooser.show(
                pipes: pipes,
                characters: text.count,
                onPick: { [weak self] pipe in self?.runPipe(pipe, on: text, into: target) },
                onCancel: { [weak self] in
                    self?.pipeRun?.cancel()
                    self?.pipeRun = nil
                    self?.deliver(text, into: target)
                }
            )
        }
    }

    private func runPipe(_ pipe: PipeCommand, on text: String, into target: PasteTarget?) {
        pipeRun = PipeRunner.start(pipe.command, input: text) { [weak self] status, stdout in
            guard let self, self.pipeRun != nil else { return }
            self.pipeRun = nil
            self.pipeChooser.close()
            switch Pipes.outcome(status: status, stdout: stdout) {
            case .paste(let output):
                self.history.push(output, tag: pipe.id, source: target?.app.localizedName)
                self.deliver(output, into: target, record: false)
            case .keepCut:
                break
            case .restore:
                NSSound.beep()
                self.deliver(text, into: target)
            }
        }
    }

    private func deliver(_ value: String, into target: PasteTarget?, record: Bool = true) {
        watcher.write(value, record: record)
        guard let target else {
            devLog("deliver: no target, pasting into whatever is frontmost")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { Self.sendPaste() }
            return
        }
        target.restoreFocus { focused in
            // Never type into whatever else is frontmost; the value stays on the clipboard.
            devLog("deliver: focused=\(focused), frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
            if focused { Self.sendPaste() } else { NSSound.beep() }
        }
    }

    // Audible, so a missing grant doesn't fail silently.
    private static func sendPaste() {
        if !Paste.simulateCmdV() { NSSound.beep() }
    }
}
