import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let history = ClipboardHistory()
    private let watcher = ClipboardWatcher()
    private let hotKey = HotKey.history()
    private let pipeHotKey = HotKey.pipe()
    private let shotHotKey = HotKey.shot()
    private let editorHotKey = HotKey.editor()
    private let voiceCopy = VoiceCopyMonitor()
    private let recorder = AudioRecorder()
    private let transcriber = WhisperTranscriber()
    private var micStart: AudioRecorder.StartResult = .failed
    /// The focused field and anchor at hold time: where a voice result goes.
    private var voiceTarget: (target: PasteTarget?, anchor: PanelAnchor)?
    /// Counts presses so a late empty-selection check can't beep for the next one.
    private var cuePress = 0
    private var cuePlayed = false
    /// This hold adds to the open dictation editor instead of starting one.
    private var voiceIntoEditor = false
    private let panel = HistoryPanel()
    private let pipeChooser = PipeChooser()
    private let notice = NoticePanel()
    private var pipeRun: PipeRunner?
    private var panelPipeRun: PipeRunner?
    private var shotInFlight = false
    private let ipcServer = IPCServer()
    private var redirects = RedirectLedger()
    /// Link routing switch, shared by the tray and every Chrome profile's extension.
    /// In memory only: a restart routes again.
    private var routingPaused = false
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
                    // A redirect was decided before any pause landed; finish it so the
                    // source tab, which already went back, does not lose the link.
                    if let info = message.redirect { self?.redirects.record(url, info) }
                    self?.openLink(url, alwaysRoute: message.redirect != nil)
                }
                return
            }
            self?.history.push(message.text, tag: message.tag)
        }
        ipcServer.onRouting = { [weak self] op in
            guard let self else { return false }
            if op == "pause" { self.routingPaused = true }
            if op == "resume" { self.routingPaused = false }
            return self.routingPaused
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

        editorHotKey.handler = { [weak self] in
            self?.startEditor()
        }
        editorHotKey.register()

        startVoiceCopy()

        Paste.ensureAccessibility()
    }

    // MARK: - Voice copy (hold Cmd+C / Cmd+V)

    private enum VoiceIndicator { case idle, recording, transcribing }

    /// SPEC §2.13. Key-down plays the cue and opens the mic at once; a tap
    /// discards the audio (and replays a held-back Cmd+V), a hold is
    /// transcribed: Cmd+C to the clipboard or the pipe chooser, Cmd+V pasted.
    private func startVoiceCopy() {
        Cue.preload()
        transcriber.load { ready in
            if !ready { devLog("voice: no model at \(WhisperTranscriber.defaultModelPath)") }
        }
        voiceCopy.onBegin = { [weak self] key in
            guard let self else { return }
            cuePress += 1
            cuePlayed = false
            if !Cue.startOnHold {
                playStartCue()
            } else if key == .copy, Cue.startAtOnceWhenNothingSelected {
                // AX off main: a slow app must not delay the mic or the copy.
                let press = cuePress
                DispatchQueue.global(qos: .userInteractive).async {
                    guard PasteTarget.focusedSelectionIsEmpty() == true else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, cuePress == press, voiceCopy.isPressed else { return }
                        playStartCue()
                    }
                }
            }
            voiceTarget = nil
            guard AudioRecorder.permission() == .granted else { micStart = .failed; return }
            let (config, error) = VoiceConfig.load()
            if let error { devLog("voice: config error, using defaults: \(error)") }
            micStart = recorder.start(preferences: config.microphones)
        }
        voiceCopy.onConfirm = { [weak self] key in
            guard let self else { return }
            playStartCue()
            showVoice(.recording)
            // A hold inside the open dictation editor adds to it: the field it
            // pastes back into was captured by the first hold.
            if pipeChooser.isEditorOpen {
                voiceTarget = nil
                voiceIntoEditor = true
                pipeChooser.showListening(near: PanelAnchor(NSEvent.mouseLocation))
                return
            }
            voiceIntoEditor = false
            // Where the result goes: captured now, while the user's field is focused.
            let target = PasteTarget.capture()
            let anchor = selectionAnchor(for: target)
            voiceTarget = (target, anchor)
            if key == .copy, !panel.isVisible, !pipeChooser.isVisible {
                let (pipes, error) = loadVoicePipes()
                pipeChooser.showListening(near: anchor, pipes: pipes, pipesError: error)
            }
        }
        voiceCopy.onStop = { [weak self] key, held in
            // Released before the start cue's AX check came back: no stop cue either.
            guard self?.cuePlayed == true else { self?.finishVoiceCopy(key, held: held); return }
            Cue.stop.play()
            self?.finishVoiceCopy(key, held: held)
        }
        voiceCopy.onTap = { [weak self] key in
            self?.discardVoice()
            if key == .paste { Paste.simulateCmdV() }
        }
        voiceCopy.onCancel = { [weak self] _ in
            self?.discardVoice()
        }
        voiceCopy.rightOptionEnabled = { VoiceConfig.load().config.rightOption }
        voiceCopy.start()
    }

    /// Once per press: the early empty-selection cue and the hold cue never double.
    private func playStartCue() {
        guard !cuePlayed else { return }
        cuePlayed = true
        Cue.start.play()
    }

    private func discardVoice() {
        _ = recorder.stop()
        micStart = .failed
        let target = voiceTarget?.target
        let anchor = voiceTarget?.anchor ?? PanelAnchor(NSEvent.mouseLocation)
        voiceTarget = nil
        voiceIntoEditor = false
        endListening(into: target, at: anchor)
        showVoice(.idle)
    }

    /// A take ended without text (Esc, nothing heard, no mic or model). A
    /// fresh listening panel the user typed into must not vanish with that
    /// text: it becomes the dictation editor holding it. Empty: it closes.
    private func endListening(into target: PasteTarget?, at anchor: PanelAnchor) {
        guard pipeChooser.isListeningPanel, pipeChooser.hasTypedText else {
            pipeChooser.endListening()
            return
        }
        devLog("voice: no take, keeping the typed text")
        deliverVoice("", key: .copy, into: target, at: anchor)
    }

    private func finishVoiceCopy(_ key: VoiceCopyGesture.Key, held: TimeInterval) {
        let samples = recorder.stop()
        let started = micStart
        micStart = .failed
        let target = voiceTarget?.target
        let anchor = voiceTarget?.anchor ?? PanelAnchor(NSEvent.mouseLocation)
        let intoEditor = voiceIntoEditor
        voiceTarget = nil
        voiceIntoEditor = false
        guard started == .recording else {
            showVoice(.idle)
            endListening(into: target, at: anchor)
            let title = if started == .noMicrophone {
                "No microphone from [voice] microphones is connected — list them: clipb mics"
            } else if AudioRecorder.permission() == .denied {
                "Can't hear you — allow ClipB in Privacy & Security › Microphone"
            } else {
                "Microphone wasn't ready — hold the keys again"
            }
            notice.show(title: title, hint: "Esc close", near: anchor)
            return
        }
        guard transcriber.isReady else {
            showVoice(.idle)
            endListening(into: target, at: anchor)
            notice.show(
                title: "No speech model — expected \(WhisperTranscriber.defaultModelPath)",
                hint: "Esc close",
                near: anchor
            )
            return
        }
        showVoice(.transcribing)
        pipeChooser.showTranscribing()
        transcriber.transcribe(samples, languages: VoiceConfig.load().config.languages) { [weak self] result in
            guard let self else { return }
            showVoice(.idle)
            // Lengths and timings only: the transcript is a clipboard value.
            devLog("voice: \(key) held \(Int(held * 1000)) ms, \(samples.count / 16) ms audio, "
                + "decode \(result?.milliseconds ?? -1) ms, lang \(result?.language ?? "-"), "
                + "\(result?.text.count ?? 0) chars")
            guard let result else {
                devLog("voice: decode failed")
                endListening(into: target, at: anchor)
                NSSound.beep()
                return
            }
            guard let text = Transcript.clean(result.text) else {
                devLog("voice: dropped by cleanup (empty, tags only, or a silence phrase)")
                endListening(into: target, at: anchor)
                NSSound.beep()
                return
            }
            if intoEditor, pipeChooser.isEditorOpen {
                devLog("voice: inserted \(text.count) chars into the editor")
                pipeChooser.insertDictation(text)
                return
            }
            deliverVoice(text, key: key, into: target, at: anchor)
        }
    }

    /// Cmd+V: paste it into the field. Cmd+C: open it in the dictation
    /// editor, pipes under the text; saving copies it and pastes it back.
    private func deliverVoice(_ text: String, key: VoiceCopyGesture.Key, into target: PasteTarget?, at anchor: PanelAnchor) {
        switch key {
        case .paste, .option:
            devLog("voice: pasting \(text.count) chars")
            // Typed, not pasted: neither the clipboard nor history keeps it.
            // A trailing space, so the next take you say doesn't glue onto this one.
            typeWithoutClipboard(text + " ", into: target, at: anchor)
        case .copy:
            // The popup or a pipe listing owns the screen: keep the take on the clipboard.
            let busy = panel.isVisible || (pipeChooser.isVisible && !pipeChooser.isEditorOpen && !pipeChooser.isListeningPanel)
            guard !busy else {
                watcher.write(text)
                return
            }
            let (pipes, pipesError) = loadVoicePipes()
            devLog("voice: editor with \(text.count) chars, \(pipes.count) pipes\(pipesError == nil ? "" : ", pipes config error")")
            pipeChooser.showDictation(
                text,
                pipes: pipes,
                pipesError: pipesError,
                onPick: { [weak self] pipe, edited in
                    self?.runPipe(pipe, on: ClipEntry(value: edited), into: target, at: anchor)
                },
                onCancelRun: { [weak self] in
                    self?.pipeRun?.cancel()
                    self?.pipeRun = nil
                },
                onSave: { [weak self] edited in
                    guard let self, !edited.isEmpty else { return }
                    history.push(edited, tag: Self.voiceTag, source: target?.app.localizedName)
                    deliver(edited, into: target, record: false) { [weak self] pasted in
                        guard !pasted else { return }
                        self?.notice.show(title: Titles.editorPasteMissedTitle(), hint: "Esc close", near: anchor)
                    }
                }
            )
        }
    }

    /// The dictation editor's pipes, or the config error that hides them.
    private func loadVoicePipes() -> (pipes: [PipeCommand], error: String?) {
        do {
            return (Array(try Pipes.load().prefix(Pipes.maxPipes)), nil)
        } catch {
            return ([], "\(error)")
        }
    }

    private func showVoice(_ state: VoiceIndicator) {
        guard let button = statusItem?.button else { return }
        let (symbol, tip): (String, String) = switch state {
        case .idle: ("list.clipboard", "Clipboard")
        case .recording: ("mic.fill", "Recording — release to stop, Esc to cancel")
        case .transcribing: ("waveform", "Transcribing…")
        }
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            image.isTemplate = true
            button.image = image
        }
        button.toolTip = tip
    }

    func applicationWillTerminate(_ notification: Notification) {
        ipcServer.stop()
#if DEV_PERSIST
        devPersistence.save(history)
#endif
    }

    // MARK: - Link router

    static let linkTag = "link"
    static let editorTag = "edit"
    static let voiceTag = "voice"

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

    private func openLink(_ url: URL, alwaysRoute: Bool = false) {
        history.push(url.absoluteString, tag: Self.linkTag)
        if routingPaused && !alwaysRoute {
            devLog("router: paused")
            BrowserLauncher.openUnrouted(url)
            return
        }
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
        let pause = menu.addItem(withTitle: "Pause Link Routing", action: #selector(pauseRoutingClicked), keyEquivalent: "")
        pause.target = self
        pause.state = routingPaused ? .on : .off
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
    @objc private func pauseRoutingClicked() {
        routingPaused.toggle()
    }

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
        panel.onDeleteAll = { [weak self] entries in
            guard let self else { return [] }
            for (tag, entry) in entries {
                if let index = self.history.index(of: entry, tag: tag) {
                    self.history.delete(at: index, tag: tag)
                }
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
        panel.show(entries: entries, near: selectionAnchor(for: target), pipes: pipes)
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
        runner = PipeRunner.start(pipe.command, input: entry, timeout: pipe.timeout) { [weak self] status, stdout, stderrData in
            guard let self, let runner, self.panelPipeRun === runner else { return }
            self.panelPipeRun = nil
            self.panel.finishPipeRun()
            switch Pipes.outcome(status: status, stdout: stdout) {
            case .paste(let output):
                self.history.push(output, tag: pipe.id, source: target?.app.localizedName)
                self.deliver(output, into: target, record: false) { [weak self] pasted in
                    guard !pasted else { return }
                    self?.notice.show(
                        title: Titles.pipePasteMissedTitle(pipe.name),
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
                        detail: Self.failedPipeDetail(pipe, entry: entry, status: status, stderr: stderrData),
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
        // The editor opens with or without pipes; a broken config is said in its hint.
        let (offered, pipesError) = loadVoicePipes()
        if let pipesError { fputs("clipb: pipes: \(pipesError)\n", stderr) }

        let target = PasteTarget.capture()
        let anchor = selectionAnchor(for: target)
        Paste.afterHotKeyReleased(key: kVK_ANSI_X, until: Date().addingTimeInterval(2)) { [weak self] in
            self?.cutSelection(pipes: offered, pipesError: pipesError, into: target, at: anchor)
        }
    }

    // MARK: - Editor

    /// Cmd+Shift+E: cut the selection, edit it in place, paste the result
    /// back. The cut is the pipe flow's cut: empty selections still open the
    /// editor, and a saved-empty edit leaves the text cut, like a sink pipe.
    private func startEditor() {
        // The popup owns the keyboard while it is up; Esc is its own cancel.
        if panel.isVisible { return }
        if pipeChooser.isVisible {
            pipeChooser.cancel()
            return
        }
        let target = PasteTarget.capture()
        let anchor = selectionAnchor(for: target)
        Paste.afterHotKeyReleased(key: kVK_ANSI_E, until: Date().addingTimeInterval(2)) { [weak self] in
            guard let self else { return }
            self.cutCurrentSelection(into: target, at: anchor, recoverUnrecordedCut: true) { entry, _ in
                // The editor edits text; an image or file cut edits nothing, not a placeholder.
                let text = entry.image == nil && entry.fileURLs == nil ? entry : ClipEntry(value: "")
                self.pipeChooser.showEditor(entry: text, near: anchor, onSave: self.editorSaveHandler(into: target, at: anchor))
            }
        }
    }

    /// The editor's save: the text was cut, so an empty save keeps it cut —
    /// the pasteboard still holds it, exactly like a sink pipe's no-output.
    private func editorSaveHandler(into target: PasteTarget?, at point: PanelAnchor) -> (String) -> Void {
        { [weak self] text in
            guard let self, !text.isEmpty else { return }
            self.history.push(text, tag: Self.editorTag, source: target?.app.localizedName)
            self.deliver(text, into: target, record: false) { [weak self] pasted in
                guard !pasted else { return }
                self?.notice.show(
                    title: Titles.editorPasteMissedTitle(),
                    hint: "Esc close",
                    near: point
                )
            }
        }
    }

    /// Where the chooser opens: see `PanelGeometry.anchor`. Computed before
    /// Cmd+X, which clears the selection.
    private func selectionAnchor(for target: PasteTarget?) -> PanelAnchor {
        let pointer = NSEvent.mouseLocation
        let window = target?.windowBounds()
        // Centering needs only the window: skip the caret and field lookups.
        let skipText = PanelPlacement.alwaysCenterOnWindow && window != nil
        let text = skipText ? nil : target?.textBounds()
        let field = text == nil && !skipText ? target?.fieldBounds() : nil
        var anchor = PanelGeometry.anchor(text: text, field: field, window: window, pointer: pointer)
        devLog("anchor: \(anchor.source)")
        // The under-selection offset can push the anchor past the caret's own
        // screen edge into the adjacent display's frame; PanelGeometry would
        // then open the panel there. Clamp into the anchor's screen first.
        guard let bounds = text ?? field, anchor.source == .text || anchor.source == .field else { return anchor }
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }) {
            let visible = screen.visibleFrame
            anchor.point.x = min(max(anchor.point.x, visible.minX), visible.maxX)
            anchor.point.y = min(max(anchor.point.y, visible.minY), visible.maxY)
        }
        return anchor
    }

    /// Cmd+Shift+X (SPEC §2.10): a text cut opens the dictation editor —
    /// the same panel as a Cmd+C hold — holding the cut, pipes under it.
    /// Saving pastes the edit back; a pipe runs on the edited text. An image
    /// or file cut has nothing to edit and gets the pipe list instead.
    private func cutSelection(pipes: [PipeCommand], pipesError: String?, into target: PasteTarget?, at point: PanelAnchor) {
        cutCurrentSelection(into: target, at: point, recoverUnrecordedCut: true) { [weak self] entry, before in
            guard let self else { return }
            if entry.image == nil, entry.fileURLs == nil {
                self.pipeChooser.showDictation(
                    entry.value,
                    pipes: pipes,
                    pipesError: pipesError,
                    near: point,
                    onPick: { [weak self] pipe, edited in
                        self?.runPipe(pipe, on: ClipEntry(value: edited), into: target, at: point)
                    },
                    onCancelRun: { [weak self] in
                        self?.pipeRun?.cancel()
                        self?.pipeRun = nil
                    },
                    onSave: self.editorSaveHandler(into: target, at: point)
                )
                return
            }
            guard !pipes.isEmpty else {
                // Nothing to edit and nothing to pick: the image or file goes back.
                self.deliver(entry, into: target)
                self.notice.show(title: "No pipes configured", hint: "Esc close · add [pipe.<id>] to ~/.config/clipb.toml", near: point)
                return
            }
            // An image or file cut pipes: its bytes, or its URL, rides stdin.
            self.pipeChooser.show(
                pipes: pipes,
                entry: entry,
                near: point,
                onPick: { [weak self] pipe in
                    guard let self else { return }
                    // Run on the late cut too: empty input would pipe nothing and overwrite it.
                    let cut = self.recoverMissedCut(entry, before: before, source: target?.app.localizedName) ?? entry
                    self.runPipe(pipe, on: cut, into: target, at: point)
                },
                onCancel: { [weak self] in
                    guard let self else { return }
                    self.pipeRun?.cancel()
                    self.pipeRun = nil
                    // A cut the 0.5 s wait missed goes back too; nothing to put back otherwise.
                    let cut = entry.isEmpty
                        ? self.recoverMissedCut(entry, before: before, source: target?.app.localizedName)
                        : entry
                    guard let cut else { return }
                    self.deliver(cut, into: target)
                }
            )
        }
    }

    /// Send Cmd+X and hand the cut entry (or an empty one for no selection) to
    /// `then`, along with the changeCount captured before the cut. The pipe
    /// picker and the editor share this one cut.
    private func cutCurrentSelection(
        into target: PasteTarget?,
        at point: PanelAnchor,
        recoverUnrecordedCut: Bool = false,
        then: @escaping (ClipEntry, Int) -> Void
    ) {
        let before = watcher.changeCount
        let xSent = Paste.simulateCmdX()
        guard xSent else {
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
            // No selection, or an app that ignores Cmd+X: still offer the pipes, on empty input.
            var entry = entry ?? ClipEntry(value: "")
            // A cut the 0.5 s wait missed still sits on the pasteboard; record it so a save cannot drop it.
            if recoverUnrecordedCut,
               let recovered = recoverMissedCut(entry, before: before, source: target?.app.localizedName) {
                entry = recovered
            }
            if entry.isEmpty { devLog("pipe: pasteboard unchanged after Cmd+X") }
            then(entry, before)
        }
    }

    /// A cut that landed after the 0.5 s wait: read the pasteboard back and file
    /// it, so a pick, an Esc, or a save cannot overwrite it. nil when the wait's
    /// entry already holds the cut, the count never moved, or nothing is there.
    private func recoverMissedCut(_ entry: ClipEntry, before: Int, source: String?) -> ClipEntry? {
        guard entry.isEmpty, watcher.changeCount != before,
              let captured = ClipboardCapture.read() else { return nil }
        let recovered = ClipboardCapture.entry(for: captured, source: source)
        history.push(recovered)
        return recovered
    }

    private func runPipe(_ pipe: PipeCommand, on entry: ClipEntry, into target: PasteTarget?, at point: PanelAnchor) {
        pipeRun?.cancel()
        pipeRun = nil
        var runner: PipeRunner?
        runner = PipeRunner.start(pipe.command, input: entry, timeout: pipe.timeout) { [weak self] status, stdout, stderrData in
            guard let self, let runner, self.pipeRun === runner else { return }
            self.pipeRun = nil
            self.pipeChooser.close()
            switch Pipes.outcome(status: status, stdout: stdout) {
            case .paste(let output):
                self.history.push(output, tag: pipe.id, source: target?.app.localizedName)
                self.deliver(output, into: target, record: false) { [weak self] pasted in
                    guard !pasted else { return }
                    self?.notice.show(
                        title: Titles.pipePasteMissedTitle(pipe.name),
                        hint: "Esc close",
                        near: point
                    )
                }
            case .keepCut:
                break
            case .restore:
                // Opening the chooser already recovered a missed cut; an empty entry holds nothing to put back.
                guard !entry.isEmpty else {
                    self.notice.show(
                        title: Titles.failedPipeTitle(pipe.name, note: "nothing was pasted"),
                        hint: "Esc close",
                        detail: Self.failedPipeDetail(pipe, entry: entry, status: status, stderr: stderrData),
                        near: point
                    )
                    return
                }
                self.deliver(entry, into: target) { [weak self] _ in
                    self?.notice.show(
                        title: Titles.failedPipeTitle(pipe.name, note: "text is back"),
                        hint: "Esc close",
                        detail: Self.failedPipeDetail(pipe, entry: entry, status: status, stderr: stderrData),
                        near: point
                    )
                }
            }
        }
        pipeRun = runner
    }

    /// The failure notice's detail: the command, its exit code, its stderr tail.
    /// Decoding is lossy on bad UTF-8, which still beats dropping the message.
    private static func failedPipeDetail(_ pipe: PipeCommand, entry: ClipEntry, status: Int32?, stderr: Data) -> String {
        Titles.failedPipeDetail(
            command: pipe.command,
            status: status,
            stderr: String(decoding: stderr, as: UTF8.self),
            obfuscated: entry.obfuscated
        )
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

    /// Types `value` into the field it was dictated for, never through the
    /// clipboard. When typing fails the text goes on the clipboard with a
    /// notice, so the take is never lost.
    private func typeWithoutClipboard(_ value: String, into target: PasteTarget?, at anchor: PanelAnchor) {
        let fail: () -> Void = { [weak self] in
            guard let self else { return }
            NSSound.beep()
            self.watcher.write(value, record: false)
            self.notice.show(title: "Dictation not typed — it is on the clipboard", hint: "Esc close", near: anchor)
        }
        let typeNow: (PasteTarget) -> Void = { target in
            target.restoreFocus { focused in
                guard focused else { return fail() }
                Paste.afterModifiersReleased(until: Date().addingTimeInterval(1.5)) {
                    if !Paste.type(value) { fail() }
                }
            }
        }
        if let target { return typeNow(target) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let fresh = PasteTarget.capture(fallbackToFrontmost: false) else { return fail() }
            typeNow(fresh)
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
