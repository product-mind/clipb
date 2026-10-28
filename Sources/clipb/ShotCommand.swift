import Foundation

/// `clipb shot`: the same full-screen capture the hotkey runs, for scripts.
/// The image lands on the clipboard; nothing is printed and no file is written.
enum ShotCommand {
    static let usage = "usage: clipb shot\n"

    /// Returns the process exit code: 0 captured, 1 no capture, 2 usage.
    static func run(_ args: [String]) -> Int32 {
        guard args.isEmpty else {
            fputs("clipb: shot takes no arguments\n\(usage)", stderr)
            return 2
        }
        guard Shot.capture() else {
            fputs("clipb: no capture — check Screen Recording in Privacy & Security\n", stderr)
            return 1
        }
        return 0
    }
}
