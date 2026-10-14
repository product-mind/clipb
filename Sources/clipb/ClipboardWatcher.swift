import AppKit

/// Polls NSPasteboard.changeCount and reports new plain-text values.
final class ClipboardWatcher {
    /// `source` is the copying app's name; nil for ClipB's own writes.
    var onChange: ((_ value: String, _ source: String?) -> Void)?

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount = 0
    private var ownChangeCount = -1
    private var timer: Timer?

    func start(interval: TimeInterval) {
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // .common so the timer keeps firing while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// `record: false` keeps the write out of `onChange`, for values already filed under a tag.
    func write(_ value: String, record: Bool = true) {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        ownChangeCount = pasteboard.changeCount
        if !record { lastChangeCount = pasteboard.changeCount }
    }

    /// Calls `done` with the pasteboard text once `changeCount` moves past `count`, or nil at `deadline`.
    func waitForChange(from count: Int, until deadline: Date, done: @escaping (String?) -> Void) {
        if pasteboard.changeCount != count { return done(pasteboard.string(forType: .string)) }
        if Date() >= deadline { return done(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.waitForChange(from: count, until: deadline, done: done)
        }
    }

    var changeCount: Int { pasteboard.changeCount }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard let value = pasteboard.string(forType: .string) else { return }
        onChange?(value, count == ownChangeCount ? nil : copyingApp())
    }

    /// The nspasteboard.org source marker when the app sets one, else the frontmost app.
    /// The 500 ms poll can lag an app switch, so the fallback is a best guess.
    private func copyingApp() -> String? {
        if let bundleID = pasteboard.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.source")),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app != .current else { return nil }
        return app.localizedName
    }
}
