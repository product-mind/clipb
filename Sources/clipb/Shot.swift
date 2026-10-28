import Foundation

/// Cmd+Shift+C and `clipb shot`: an interactive screencapture written to a file.
/// The file is the point of the command the user ran, not clipboard history —
/// history itself still lives in memory only.
enum Shot {
    static let executable = "/usr/sbin/screencapture"
    static let suffix = ".png"

    /// `<tmp>/clipb`, where captures land.
    static func directory(tmp: String = NSTemporaryDirectory()) -> URL {
        URL(fileURLWithPath: tmp, isDirectory: true).appendingPathComponent("clipb", isDirectory: true)
    }

    /// `img-yyyyMMdd-HHmmss.png` in the local time zone: sorts by name, reads at a glance.
    static func name(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        // POSIX locale: a user locale with its own numbering would change the digits.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "img-\(formatter.string(from: date))\(suffix)"
    }

    /// `name(at:)`, with `-2`, `-3`, … appended while that second is already taken.
    static func nextPath(
        in directory: URL,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let name = name(at: now, timeZone: timeZone)
        let stem = String(name.dropLast(suffix.count))
        var url = directory.appendingPathComponent(name)
        var counter = 2
        while exists(url) {
            url = directory.appendingPathComponent("\(stem)-\(counter)\(suffix)")
            counter += 1
        }
        return url
    }

    /// Creates `directory` owner-only when missing. An existing directory is left as is.
    @discardableResult
    static func ensureDirectory(_ directory: URL) -> Bool {
        if FileManager.default.fileExists(atPath: directory.path) { return true }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return true
        } catch {
            return false
        }
    }

    /// Interactive selection with the usual capture sound (`-i`, nothing else).
    /// Blocks while the crosshair is up; returns nil when the user pressed Esc
    /// or no file came out.
    static func capture() -> String? {
        let directory = self.directory()
        guard ensureDirectory(directory) else { return nil }
        let url = nextPath(in: directory)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-i", url.path]
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

        // An Esc can leave exit status 0, so the file is the only truth.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size > 0
        else { return nil }
        return url.path
    }
}
