#if DEV_PERSIST
import AppKit

/// Development-only: keeps history across restarts, in `defaultPath` unless
/// `--persist-file <path>` says otherwise. Compiled only with `-DDEV_PERSIST`
/// (`make`); release builds contain no file I/O for history. The file holds
/// clipboard values in plain text.
final class DevPersistence {
    private struct Record: Codable {
        var tag: String?
        var value: String
        var obfuscated: Bool
    }

    static let defaultPath = "~/.clipb-dev/history.json"

    let url: URL
    private var signalSources: [DispatchSourceSignal] = []

    init(url: URL) {
        self.url = url
    }

    static func fromCommandLine(_ args: [String] = CommandLine.arguments) -> DevPersistence {
        var path = defaultPath
        for (i, arg) in args.enumerated() {
            if arg == "--persist-file", i + 1 < args.count {
                path = args[i + 1]
            } else if arg.hasPrefix("--persist-file=") {
                path = String(arg.dropFirst("--persist-file=".count))
            }
        }
        if path.isEmpty { path = defaultPath }
        return DevPersistence(url: URL(fileURLWithPath: NSString(string: path).expandingTildeInPath))
    }

    func restore(into history: ClipboardHistory) {
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([Record].self, from: data)
        else { return }
        // Records are newest-first per tag; push oldest-first to rebuild order.
        for record in records.reversed() {
            history.push(record.value, tag: record.tag)
            if record.obfuscated { history.toggleObfuscation(at: 0, tag: record.tag) }
        }
    }

    func save(_ history: ClipboardHistory) {
        let records = ([nil] + history.tags.map(Optional.some)).flatMap { tag in
            history.entries(for: tag).map { Record(tag: $0.tag, value: $0.value, obfuscated: $0.obfuscated) }
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try JSONEncoder().encode(records).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            fputs("clipb: dev persistence save failed: \(error.localizedDescription)\n", stderr)
        }
    }

    /// A relaunch must read the file only after the old instance has saved.
    static func waitForOtherInstancesToExit(timeout: TimeInterval = 3) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0 != .current && !$0.isTerminated }
            if others.isEmpty { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// AppKit skips applicationWillTerminate on SIGTERM (e.g. `killall`).
    func installTerminationHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }
}
#endif
