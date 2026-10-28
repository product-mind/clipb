import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let history = ClipboardHistory()
    private let watcher = ClipboardWatcher()
    private let hotKey = HotKey.history()
    private let pipeHotKey = HotKey.pipe()
    private let shotHotKey = HotKey.shot()
    private let panel = HistoryPanel()
    private let pipeChooser = PipeChooser()
    private let notice = NoticePanel()
    private var pipeRun: PipeRunner?
    private var panelPipeRun: PipeRunner?
    private var shotInFlight = false
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

        watcher.onChange = { [weak self] entry in
            self?.history.push(entry)
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

        shotHotKey.handler = { [weak self] in
            self?.startShot()
        }
        shotHotKey.register()

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
        // With tags, the uncategorized Clear needs a count too, like the others.
        let clearTitle = history.tags.isEmpty
            ? "Clear"
            : "Clear (\(history.entries.count))"
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
        copy.representedObject = entry
        submenu.addItem(copy)

        let obfuscate = NSMenuItem(
            title: "Obfuscate Password",
            action: #selector(obfuscateClicked(_:)),
            keyEquivalent: ""
        )
        obfuscate.target = self
        obfuscate.representedObject = entry
        obfuscate.state = entry.obfuscated ? .on : .off
        submenu.addItem(obfuscate)

        let delete = NSMenuItem(title: "Delete", action: #selector(deleteClicked(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = entry
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

    // The full entry rides in `representedObject`: several image rows share the
    // `[image]` value, so the value alone could not name the clicked row.
    @objc private func copyClicked(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ClipEntry else { return }
        watcher.write(entry)
    }

    @objc private func obfuscateClicked(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ClipEntry,
              let index = history.index(of: entry) else { return }
        history.toggleObfuscation(at: index)
    }

    @objc private func deleteClicked(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ClipEntry,
              let index = history.index(of: entry) else { return }
        history.delete(at: index)
    }

    // MARK: - Hotkey popup

    private func togglePanel() {
        if panel.isVisible {
            panel.dismiss()
            return
        }
        let entries = HistoryFilter.merged(from: history)
        guard !entries.isEmpty else { return }
        // A broken config only costs the pipe strip; the popup still opens.
        let pipes = (try? Pipes.load()) ?? []
        let target = PasteTarget.capture()
        panel.onSelect = { [weak self] entry in
            self?.deliver(entry, into: target)
        }
        panel.onDismiss = { target?.refocusKey() }
        panel.onPasteAndDelete = { [weak self] tag, entry in
            guard let self else { return }
            // Delete only once the paste actually went out: a focus race
            // must not eat the secret before it reached the app.
            // record: false, or the 500 ms poll files the deleted value right back.
            self.deliver(entry, into: target, record: false) { [weak self] pasted in
                guard let self, pasted else { return }
                if let index = self.history.index(of: entry, tag: tag) {
                    self.history.delete(at: index, tag: tag)
                }
                self.clearPastedValue(entry)
            }
        }
        panel.onPipe = { [weak self] pipe, entry in
            self?.runPanelPipe(pipe, on: entry, into: target)
        }
        panel.onPipeCancel = { [weak self] in
            self?.panelPipeRun?.cancel()
            self?.panelPipeRun = nil
        }
        panel.onDelete = { [weak self] tag, entry in
            guard let self else { return [] }
            if let index = self.history.index(of: entry, tag: tag) {
                self.history.delete(at: index, tag: tag)
            }
            return HistoryFilter.merged(from: self.history)
        }
        panel.onToggleObfuscation = { [weak self] tag, entry in
            guard let self else { return [] }
            if let index = self.history.index(of: entry, tag: tag) {
                self.history.toggleObfuscation(at: index, tag: tag)
            }
            return HistoryFilter.merged(from: self.history)
        }
        panel.onCopy = { [weak self] entry in
            self?.watcher.write(entry)
        }
        panel.onOpen = { url in
            BrowserLauncher.route(url)
        }
        panel.show(entries: entries, at: NSEvent.mouseLocation, pipes: pipes)
    }

    /// Shift+Enter: the entry leaves history and the pasteboard, so a one-time
    /// secret does not linger in either. Called only after the paste went out,
    /// so the clock gives the target app the full window to read the pasteboard.
    private func clearPastedValue(_ entry: ClipEntry) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.watcher.clear(ifStill: entry)
        }
    }

    /// A pipe button or its digit in the popup: the same contract as the cut
    /// flow's runPipe, but the popup stays open until the command ends.
    private func runPanelPipe(_ pipe: PipeCommand, on entry: ClipEntry, into target: PasteTarget?) {
        panelPipeRun?.cancel()
        panelPipeRun = nil
        var runner: PipeRunner?
        runner = PipeRunner.start(pipe.command, input: entry) { [weak self] status, stdout in
            guard let self, let runner, self.panelPipeRun === runner else { return }
            self.panelPipeRun = nil
            self.panel.finishPipeRun()
            switch Pipes.outcome(status: status, stdout: stdout) {
            case .paste(let output):
                self.history.push(output, tag: pipe.id, source: target?.app.localizedName)
                self.deliver(output, into: target, record: false) { [weak self] pasted in
                    guard pasted else { return }
                    self?.notice.show(
                        title: Titles.failedPipeTitle(pipe.name, note: "output on the clipboard"),
                        hint: "Esc close",
                        near: NSEvent.mouseLocation
                    )
                }
            case .keepCut:
                // Exit 0 with no output: the pipe consumed the value, nothing to paste.
                break
            case .restore:
                // The notice is the signal; a beep on top of it would double up.
                self.deliver(entry, into: target, record: false) { [weak self] _ in
                    self?.notice.show(
                        title: Titles.failedPipeTitle(pipe.name, note: "original pasted back"),
                        hint: "Esc close",
                        near: NSEvent.mouseLocation
                    )
                }
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
            notice.show(
                title: "Pipes config error",
                hint: "Esc close",
                near: NSEvent.mouseLocation
            )
            return
        }
        guard !pipes.isEmpty else {
            devLog("pipe: no pipes configured")
            notice.show(
                title: "No pipes configured",
                hint: "Esc close · add [pipe.<id>] to ~/.config/clipb.toml",
                near: NSEvent.mouseLocation
            )
            return
        }

        let target = PasteTarget.capture()
        let anchor = selectionAnchor(for: target)
        let offered = Array(pipes.prefix(Pipes.maxPipes))
        Paste.afterHotKeyReleased(key: kVK_ANSI_X, until: Date().addingTimeInterval(2)) { [weak self] in
            self?.cutSelection(pipes: offered, into: target, at: anchor)
        }
    }

    /// Where the chooser opens: under the selected text, else at the pointer.
    /// Computed before Cmd+X, which clears the selection.
    private func selectionAnchor(for target: PasteTarget?) -> NSPoint {
        guard let bounds = target?.selectionBounds() else { return NSEvent.mouseLocation }
        return NSPoint(x: bounds.midX, y: bounds.minY - 8)
    }

    private func cutSelection(pipes: [PipeCommand], into target: PasteTarget?, at point: NSPoint) {
        let before = watcher.changeCount
        guard Paste.simulateCmdX() else {
            devLog("pipe: Cmd+X not sent, Accessibility trusted=\(AXIsProcessTrusted())")
            notice.show(
                title: "Can't send ⌘X — check ClipB in Accessibility settings",
                hint: "Esc close",
                near: point
            )
            return
        }
        watcher.waitForChange(from: before, until: Date().addingTimeInterval(0.5)) { [weak self] entry in
            guard let self else { return }
            // No selection, or an app that ignores Cmd+X.
            guard let entry else {
                devLog("pipe: pasteboard unchanged after Cmd+X")
                self.notice.show(
                    title: "Nothing was cut — nothing selected",
                    hint: "Esc close",
                    near: point
                )
                return
            }
            // An image or file cut pipes too: its bytes, or its URL, ride stdin.
            self.pipeChooser.show(
                pipes: pipes,
                entry: entry,
                near: point,
                onPick: { [weak self] pipe in self?.runPipe(pipe, on: entry, into: target, at: point) },
                onCancel: { [weak self] in
                    self?.pipeRun?.cancel()
                    self?.pipeRun = nil
                    self?.deliver(entry, into: target)
                }
            )
        }
    }

    private func runPipe(_ pipe: PipeCommand, on entry: ClipEntry, into target: PasteTarget?, at point: NSPoint) {
        pipeRun?.cancel()
        pipeRun = nil
        var runner: PipeRunner?
        runner = PipeRunner.start(pipe.command, input: entry) { [weak self] status, stdout in
            guard let self, let runner, self.pipeRun === runner else { return }
            self.pipeRun = nil
            self.pipeChooser.close()
            switch Pipes.outcome(status: status, stdout: stdout) {
            case .paste(let output):
                self.history.push(output, tag: pipe.id, source: target?.app.localizedName)
                self.deliver(output, into: target, record: false) { [weak self] pasted in
                    guard pasted else { return }
                    self?.notice.show(
                        title: Titles.failedPipeTitle(pipe.name, note: "output on the clipboard"),
                        hint: "Esc close",
                        near: point
                    )
                }
            case .keepCut:
                break
            case .restore:
                self.deliver(entry, into: target) { [weak self] _ in
                    self?.notice.show(
                        title: Titles.failedPipeTitle(pipe.name, note: "text is back"),
                        hint: "Esc close",
                        near: point
                    )
                }
            }
        }
        pipeRun = runner
    }

    // MARK: - Screencapture

    /// Cmd+Shift+C: full-screen screencapture straight to the clipboard. The
    /// capture blocks, so it runs off-main; the watcher's poll then files the
    /// image in history like any copy — ClipB itself never writes the pasteboard.
    private func startShot() {
        devLog("shot: hotkey")
        if panel.isVisible { return }
        if pipeChooser.isVisible { return }
        // A second chord while the capture is running would stack a second shot.
        if shotInFlight { return }
        shotInFlight = true
        Paste.afterHotKeyReleased(key: kVK_ANSI_C, until: Date().addingTimeInterval(2)) { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let captured = Shot.capture()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.shotInFlight = false
                    guard !captured else { return }
                    devLog("shot: no capture")
                    self.notice.show(
                        title: "Can't capture the screen — check Screen Recording in Privacy & Security",
                        hint: "Esc close",
                        near: NSEvent.mouseLocation
                    )
                }
            }
        }
    }

    private func deliver(
        _ value: String,
        into target: PasteTarget?,
        record: Bool = true,
        completion: ((_ pasted: Bool) -> Void)? = nil
    ) {
        deliver(ClipEntry(value: value), into: target, record: record, completion: completion)
    }

    private func deliver(
        _ entry: ClipEntry,
        into target: PasteTarget?,
        record: Bool = true,
        completion: ((_ pasted: Bool) -> Void)? = nil
    ) {
        watcher.write(entry, record: record)
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
