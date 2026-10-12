import Foundation

/// `clipb copy [--tag <tag>]`: reads text from stdin and hands it to the
/// running app. Text is never taken from arguments, which show up in `ps`.
enum CopyCommand {
    struct Options: Equatable {
        var tag: String?
    }

    enum ParseResult: Equatable {
        case run(Options)
        case help
        case error(String)
    }

    static let usage = """
    usage: <text> | clipb copy [--tag <tag>]

    Adds stdin to ClipB's history under <tag> (uncategorized if omitted).
    """

    static func parse(_ args: [String]) -> ParseResult {
        var options = Options()
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-h", "--help":
                return .help
            case "--tag":
                guard i + 1 < args.count else { return .error("--tag needs a value") }
                options.tag = args[i + 1]
                i += 1
            case _ where arg.hasPrefix("--tag="):
                options.tag = String(arg.dropFirst("--tag=".count))
            default:
                return .error("unknown argument: \(arg)")
            }
            i += 1
        }
        return .run(options)
    }

    /// Returns the process exit code: 0 ok, 1 delivery failed, 2 usage.
    static func run(_ args: [String]) -> Int32 {
        switch parse(args) {
        case .help:
            print(usage)
            return 0
        case .error(let message):
            fputs("clipb: \(message)\n\(usage)\n", stderr)
            return 2
        case .run(let options):
            return copy(options)
        }
    }

    private static func copy(_ options: Options) -> Int32 {
        if isatty(STDIN_FILENO) != 0 {
            fputs("clipb: copy reads stdin; pipe text into it\n\(usage)\n", stderr)
            return 2
        }
        let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }

        do {
            try sendLaunchingIfNeeded(IPCMessage(tag: options.tag, text: text))
            return 0
        } catch {
            // Losing a transcript is worse than a noisy failure, so echo it.
            fputs("clipb: could not reach ClipB (\(error)); the text follows so it is not lost:\n\(text)\n", stderr)
            return 1
        }
    }

    /// Starts the app and retries briefly when nothing is listening yet.
    static func sendLaunchingIfNeeded(_ message: IPCMessage) throws {
        do {
            try IPCClient.send(message)
        } catch IPCError.connect {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-b", "com.productmind.clipb"]
            try? open.run()

            var lastError: Error = IPCError.connect(ECONNREFUSED)
            for _ in 0..<30 {
                Thread.sleep(forTimeInterval: 0.1)
                do {
                    try IPCClient.send(message)
                    return
                } catch IPCError.connect {
                    continue
                } catch {
                    lastError = error
                    break
                }
            }
            throw lastError
        }
    }
}
