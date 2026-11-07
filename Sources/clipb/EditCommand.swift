import AppKit

/// `clipb edit <file>`: ClipB's editor on one file, as its own process. It
/// never talks to the running app and never touches clipboard history, the
/// pasteboard, hotkeys, dictation or the tray; the only thing it writes is
/// the file named on the command line. Exit 0 on close, 1 unreadable file, 2 usage.
enum EditCommand {
    static func run(_ args: [String]) -> Int32 {
        guard let path = EditDocument.parse(args) else {
            fputs("\(EditDocument.usage)\n", stderr)
            return 2
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var content: String?
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                content = try String(contentsOf: url, encoding: .utf8)
            } catch {
                fputs("clipb: \(path): can't read as UTF-8 text\n", stderr)
                return 1
            }
        }
        let app = NSApplication.shared
        let controller = EditWindowController(url: url, document: EditDocument(fileContent: content))
        app.delegate = controller
        app.setActivationPolicy(.regular)
        app.run()
        return 0
    }
}

/// One window, one `EditorTextView`; also the app delegate and the target of Cmd+S.
final class EditWindowController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let url: URL
    private let document: EditDocument
    private let window: NSWindow
    private let scroll = NSScrollView(frame: .zero)
    private let editor = EditorTextView()
    /// What the buffer held when last written (or read).
    private var lastSaved: String

    /// First open: most of the screen, so a file reads without scrolling
    /// sideways; later opens reuse the last frame (`frameName`).
    private static let startSize = NSSize(width: 700, height: 520)
    private static let frameName = "ClipBEditWindow"

    private static func firstSize(on screen: NSRect) -> NSSize {
        NSSize(width: min(max(screen.width * 0.6, 900), screen.width * 0.9, 1400),
               height: min(max(screen.height * 0.8, 600), screen.height * 0.9))
    }

    init(url: URL, document: EditDocument) {
        self.url = url
        self.document = document
        lastSaved = document.shown
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.startSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = url.lastPathComponent
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 240)

        scroll.documentView = editor
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        window.contentView = scroll

        editor.onSave = { [weak self] in _ = self?.save() }
        editor.onWantsWidth = { [weak self] width in self?.grow(toFit: width) }
        editor.applyConfig()
        editor.string = document.shown
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.undoManager?.removeAllActions()
        NotificationCenter.default.addObserver(
            self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: editor
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMenu()
        if !window.setFrameUsingName(Self.frameName) {
            if let screen = (NSScreen.main ?? window.screen)?.visibleFrame {
                window.setContentSize(Self.firstSize(on: screen))
            }
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
        window.makeFirstResponder(editor)
        bringToFront()
        // After the window exists: wide box art opens wide enough not to wrap.
        editor.canvas.fitDrawings()
    }

    /// Started from a terminal, the app is not the one the user is in, and
    /// macOS 14+ may refuse to activate it: the window opened behind. So the
    /// window is ordered above every app's windows regardless, and activation
    /// is asked again once the run loop is up, when the switch from the
    /// bundle's LSUIElement to a regular app has taken effect.
    private func bringToFront() {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        for delay in [0.0, 0.15, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !NSApp.isActive else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.window.makeKeyAndOrderFront(nil)
                self.window.orderFrontRegardless()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        saveIfChanged() ? .terminateNow : .terminateCancel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { saveIfChanged() }

    // MARK: - Saving

    @objc func save(_ sender: Any?) { _ = save() }

    /// Atomic write of the (unwrapped) buffer. A failure is said on stderr and
    /// beeps; the window stays so nothing is lost.
    @discardableResult
    private func save() -> Bool {
        let shown = editor.string
        do {
            try document.fileText(forShown: shown).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            fputs("clipb: \(url.path): \(error.localizedDescription)\n", stderr)
            NSSound.beep()
            return false
        }
        lastSaved = shown
        updateEdited()
        return true
    }

    private func saveIfChanged() -> Bool {
        EditDocument.shouldSaveOnClose(shown: editor.string, lastSaved: lastSaved) ? save() : true
    }

    @objc private func textChanged(_ note: Notification) { updateEdited() }

    private func updateEdited() { window.isDocumentEdited = editor.string != lastSaved }

    /// A drawing wider than the window asks for room, up to the screen.
    private func grow(toFit width: CGFloat) {
        let current = window.contentView?.bounds.width ?? 0
        let needed = width + (scroll.verticalScroller?.frame.width ?? 15) + 4
        guard needed > current, let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = window.frame
        frame.size.width += min(needed, visible.width) - current
        if frame.maxX > visible.maxX { frame.origin.x = max(visible.minX, visible.maxX - frame.width) }
        window.setFrame(frame, display: true)
    }

    // MARK: - Menu

    private static func makeMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
        }
        func submenu(_ title: String) -> NSMenu {
            let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            main.setSubmenu(menu, for: item)
            return menu
        }
        let app = submenu("clipb")
        add(app, "Quit", #selector(NSApplication.terminate(_:)), "q")
        let file = submenu("File")
        add(file, "Save", #selector(EditWindowController.save(_:)), "s")
        let edit = submenu("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        let view = submenu("View")
        add(view, "Bigger", #selector(EditorTextView.zoomIn(_:)), "+")
        add(view, "Smaller", #selector(EditorTextView.zoomOut(_:)), "-")
        add(view, "Actual Size", #selector(EditorTextView.zoomReset(_:)), "0")
        return main
    }
}
