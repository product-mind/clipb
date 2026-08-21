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

    func write(_ value: String) {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard let value = pasteboard.string(forType: .string) else { return }
        onChange?(value)
    }
}
