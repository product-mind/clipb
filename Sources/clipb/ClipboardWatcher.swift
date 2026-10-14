import AppKit

/// Polls NSPasteboard.changeCount and reports new plain-text values.
final class ClipboardWatcher {
    var onChange: ((String) -> Void)?

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount = 0
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
        onChange?(value)
    }
}
