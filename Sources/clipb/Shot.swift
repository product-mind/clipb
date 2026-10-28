import Foundation

/// Cmd+Shift+C and `clipb shot`: a full-screen screencapture straight to the
/// clipboard. The system tool owns the pasteboard write; the app's own watcher
/// poll then files the image in history like any copy. No files are written.
enum Shot {
    static let executable = "/usr/sbin/screencapture"
    /// `-c` is clipboard mode. Without `-x` the usual capture sound still plays,
    /// and without `-i` there is no selection UI: the full screen is shot at once.
    static let arguments = ["-i", "-c"]

    /// True when the capture landed on the clipboard. A denied Screen Recording
    /// permission shows up here as a non-zero exit.
    static func capture() -> Bool {
        runCapture(executable: executable, arguments: arguments) == 0
    }

    /// Exit status of the capture binary, or nil when it could not be launched.
    @discardableResult
    static func runCapture(executable: String, arguments: [String]) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // The child's chatter is not our output: `clipb` speaks a native-messaging
        // protocol on stdout when Chrome runs it as a host.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        return process.terminationReason == .exit ? process.terminationStatus : nil
    }
}
