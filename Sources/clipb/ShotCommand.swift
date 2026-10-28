import AppKit

/// `clipb shot`: the same interactive capture the hotkey runs, path printed on
/// stdout so scripts can consume it and left on the clipboard for a paste.
enum ShotCommand {
    static let usage = "usage: clipb shot\n"

    /// Returns the process exit code: 0 captured, 1 no capture, 2 usage.
    static func run(_ args: [String]) -> Int32 {
        guard args.isEmpty else {
            fputs("clipb: shot takes no arguments\n\(usage)", stderr)
            return 2
        }
        guard let path = Shot.capture() else {
            fputs("clipb: no capture\n", stderr)
            return 1
        }
        // Printed before the clipboard write: a script gets the path either way.
        print(path)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
        return 0
    }
}
