import AppKit

/// Polls NSPasteboard.changeCount and reports new clipboard entries: text,
/// an image, or copied file references. The content is read once per change.
final class ClipboardWatcher {
    /// `entry.source` is the copying app's name; nil for ClipB's own writes.
    var onChange: ((_ entry: ClipEntry) -> Void)?

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
        write(ClipEntry(value: value), record: record)
    }

    /// Writes the entry's full payload: PNG bytes, file URLs, or plain text.
    func write(_ entry: ClipEntry, record: Bool = true) {
        pasteboard.clearContents()
        if let image = entry.image {
            pasteboard.declareTypes([.png], owner: nil)
            pasteboard.setData(image, forType: .png)
        } else if let urls = entry.fileURLs {
            pasteboard.writeObjects(urls as [NSURL])
        } else {
            pasteboard.setString(entry.value, forType: .string)
        }
        ownChangeCount = pasteboard.changeCount
        if !record { lastChangeCount = pasteboard.changeCount }
    }

    /// Clears the pasteboard only while it still holds what ClipB last wrote,
    /// so anything the user copied in between survives. `ownChangeCount` alone
    /// is not enough: another ClipB write bumps that too.
    func clear(ifStill entry: ClipEntry) {
        guard pasteboard.changeCount == ownChangeCount,
              pasteboardHolds(entry) else { return }
        pasteboard.clearContents()
        ownChangeCount = pasteboard.changeCount
        lastChangeCount = pasteboard.changeCount
    }

    private func pasteboardHolds(_ entry: ClipEntry) -> Bool {
        if let image = entry.image { return pasteboard.data(forType: .png) == image }
        if let urls = entry.fileURLs {
            let read = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
            return read == urls
        }
        return pasteboard.string(forType: .string) == entry.value
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
        guard let captured = readPasteboard() else { return }
        let source = count == ownChangeCount ? nil : copyingApp()
        onChange?(ClipboardCapture.entry(for: captured, source: source))
    }

    /// The one read per change: text first, then an image, then file URLs.
    private func readPasteboard() -> CapturedContent? {
        let text = pasteboard.string(forType: .string)
        // Only touch the (potentially large) image data when there is no text.
        let hasText = text.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        let png = hasText ? nil : pasteboard.data(forType: .png)
        let tiff = (hasText || png != nil) ? nil : pasteboard.data(forType: .tiff)
        let fileStrings = hasText || png != nil || tiff != nil
            ? []
            : (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .fileURL) }
        return ClipboardCapture.classify(text: text, png: png, tiff: tiff, fileURLStrings: fileStrings)
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
