import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let history = ClipboardHistory()
    private let watcher = ClipboardWatcher()
    private let hotKey = HotKey.history()
    private let pipeHotKey = HotKey.pipe()
    private let copyPipeHotKey = HotKey.copyPipe()
    private let panel = HistoryPanel()
    private let pipeChooser = PipeChooser()
    private var pipeRun: PipeRunner?
    private var copyPipeRun: PipeRunner?
    private var panelPipeRun: PipeRunner?
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
        // A duplicate launch must not steal the live instance's socket: the live one
        // would keep serving on the unlinked inode, and our exit would strand a
        // stale file that refuses every connect. A dying old instance (dev handoff)
        // stops answering within the grace window; a healthy daemon does not.
        if !IPC.mayBind(path: IPC.defaultPath) {
            fputs("clipb: another instance is running; exiting\n", stderr)
            exit(0)
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

        copyPipeHotKey.handler = { [weak self] in
            self?.startCopyPipe()
        }
        copyPipeHotKey.register()

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
            panel.dismiss()
            return
        }
        let tabs = PopupTabs.make(from: history)
        guard tabs.contains(where: { !$0.entries.isEmpty }) else { return }
        // A broken config only costs the pipe strip; the popup still opens.
        let pipes = (try? Pipes.load()) ?? []
        let target = PasteTarget.capture()
        panel.onSelect = { [weak self] value in
            self?.deliver(value, into: target)
        }
        panel.onDismiss = { target?.refocusKey() }
        panel.onPasteAndDelete = { [weak self] tag, value in
            guard let self else { return }
            // Delete only once the paste actually went out: a focus race
            // must not eat the secret before it reached the app.
            // record: false, or the 500 ms poll files the deleted value right back.
            self.deliver(value, into: target, record: false) { [weak self] pasted in
                guard let self, pasted else { return }
                if let index = self.history.index(of: value, tag: tag) {
                    self.history.delete(at: index, tag: tag)
                }
                self.clearPastedValue(value)
            }
        }
        panel.onPipe = { [weak self] pipe, value in
            self?.runPanelPipe(pipe, on: value, into: target)
        }
        panel.onPipeCancel = { [weak self] in
            self?.panelPipeRun?.cancel()
            self?.panelPipeRun = nil
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
        panel.show(tabs: tabs, at: NSEvent.mouseLocation, pipes: pipes)
    }

    /// Shift+Enter: the entry leaves history and the pasteboard, so a one-time
    /// secret does not linger in either. Called only after the paste went out,
    /// so the clock gives the target app the full window to read the pasteboard.
    private func clearPastedValue(_ value: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.watcher.clear(ifStill: value)
        }
    }

    /// Enter on a pipe option of the popup: the same contract as the cut flow's
    /// runPipe, but the popup stays open until the command ends.
    private func runPanelPipe(_ pipe: PipeCommand, on value: String, into target: PasteTarget?) {
        panelPipeRun?.cancel()
        panelPipeRun = nil
        var runner: PipeRunner?
        runner = PipeRunner.start(pipe.command, input: value) { [weak self] status, stdout in
            guard let self, let runner, self.panelPipeRun === runner else { return }
            self.panelPipeRun = nil
            self.panel.finishPipeRun()
            switch Pipes.outcome(status: status, stdout: stdout) {
            case .paste(let output):
                self.history.push(output, tag: pipe.id, source: target?.app.localizedName)
                self.deliver(output, into: target, record: false)
            case .keepCut:
                // Exit 0 with no output: the pipe consumed the value, nothing to paste.
                break
            case .restore:
                NSSound.beep()
                self.deliver(value, into: target, record: false)
            }
        }
        panelPipeRun = runner
    }

    // MARK: - Pipes

    private func startPipe() {
        devLog("pipe: hotkey")
        // The popup owns the keyboard while it is up; Esc is its own cancel.
        if panel.isVisible { return }
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
        let offered = Array(pipes.prefix(Pipes.maxPipes))
        Paste.afterHotKeyReleased(key: kVK_ANSI_X, until: Date().addingTimeInterval(2)) { [weak self] in
            self?.cutSelection(pipes: offered, into: target)
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
        pipeRun?.cancel()
        pipeRun = nil
        var runner: PipeRunner?
        runner = PipeRunner.start(pipe.command, input: text) { [weak self] status, stdout in
            guard let self, let runner, self.pipeRun === runner else { return }
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
        pipeRun = runner
    }

    // MARK: - Copy pipes

    /// Cmd+Shift+C: copy the selection, run the bound pipe, leave the output on the clipboard.
    /// Unlike the cut flow it never pastes back: the selection stays where it is.
    private func startCopyPipe() {
        devLog("pipe: copy hotkey")
        if panel.isVisible { return }
        // Last press wins: kill an in-flight run before its output can reach the clipboard.
        copyPipeRun?.cancel()
        copyPipeRun = nil
        let pipes: [PipeCommand]
        do {
            pipes = try Pipes.load()
        } catch {
            fputs("clipb: pipes: \(error)\n", stderr)
            return NSSound.beep()
        }
        guard let pipe = Pipes.bound(to: "c", in: pipes) else {
            devLog("pipe: no pipe bound to Cmd+Shift+C")
            return NSSound.beep()
        }
        // Captured before Cmd+C, while the copying app is still frontmost.
        let source = NSWorkspace.shared.frontmostApplication?.localizedName
        Paste.afterHotKeyReleased(key: kVK_ANSI_C, until: Date().addingTimeInterval(2)) { [weak self] in
            self?.copySelection(through: pipe, source: source)
        }
    }

    private func copySelection(through pipe: PipeCommand, source: String?) {
        let before = watcher.changeCount
        guard Paste.simulateCmdC() else {
            devLog("pipe: Cmd+C not sent, Accessibility trusted=\(AXIsProcessTrusted())")
            return NSSound.beep()
        }
        watcher.waitForChange(from: before, until: Date().addingTimeInterval(0.5)) { [weak self] text in
            // No selection, or an app that ignores Cmd+C.
            guard let self, let text, !text.isEmpty else {
                devLog("pipe: pasteboard unchanged after Cmd+C")
                return NSSound.beep()
            }
            // The 500 ms poll may lose the race to a fast command's write.
            self.history.push(text, source: source)
            self.runCopyPipe(pipe, on: text, source: source)
        }
    }

    private func runCopyPipe(_ pipe: PipeCommand, on text: String, source: String?) {
        copyPipeRun?.cancel()
        copyPipeRun = nil
        var runner: PipeRunner?
        runner = PipeRunner.start(pipe.command, input: text) { [weak self] status, stdout in
            guard let self, let runner, self.copyPipeRun === runner else { return }
            self.copyPipeRun = nil
            switch Pipes.outcome(status: status, stdout: stdout) {
            case .paste(let output):
                // Already filed under the pipe tag; keep the plain history clean of a duplicate.
                self.history.push(output, tag: pipe.id, source: source)
                self.watcher.write(output, record: false)
            case .keepCut:
                break
            case .restore:
                // The clipboard still holds the copied text; only signal the failure.
                NSSound.beep()
            }
        }
        copyPipeRun = runner
    }

    private func deliver(
        _ value: String,
        into target: PasteTarget?,
        record: Bool = true,
        completion: ((_ pasted: Bool) -> Void)? = nil
    ) {
        watcher.write(value, record: record)
        if let target {
            paste(into: target, completion: completion)
            return
        }
        // Key ≠ frontmost is normal, so a blind paste could hit the wrong
        // app: re-resolve the key-window app once the panel's orderOut settles.
        devLog("deliver: no captured target, re-resolving")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            // Frontmost is only a guess about key focus; refuse rather than
            // paste into the wrong app.
            guard let fresh = PasteTarget.capture(fallbackToFrontmost: false) else {
                devLog("deliver: no key-window target, refusing")
                NSSound.beep()
                completion?(false)
                return
            }
            self.paste(into: fresh, completion: completion)
        }
    }

    private func paste(into target: PasteTarget, completion: ((_ pasted: Bool) -> Void)? = nil) {
        target.restoreFocus { focused in
            // Never type into whatever else is frontmost; the value stays on the clipboard.
            devLog("deliver: focused=\(focused), frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
            // Audible, so a missing grant doesn't fail silently.
            if !focused || !Paste.simulateCmdV() {
                NSSound.beep()
                completion?(false)
                return
            }
            completion?(true)
        }
    }
}
