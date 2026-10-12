import Foundation

/// Chrome native messaging framing: a 4-byte length in native byte order, then JSON.
enum NativeMessaging {
    static let maxMessageBytes = 1024 * 1024

    static func frame(_ json: Data) -> Data {
        var length = UInt32(json.count)
        return Data(bytes: &length, count: 4) + json
    }

    /// Nil at EOF, on a read error, or for an oversized message.
    static func readMessage(from fd: Int32 = STDIN_FILENO) -> Data? {
        guard let header = readExactly(4, from: fd) else { return nil }
        let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard length <= maxMessageBytes else { return nil }
        return length == 0 ? Data() : readExactly(length, from: fd)
    }

    static func write(_ json: Data, to fd: Int32 = STDOUT_FILENO) -> Bool {
        IPC.writeAll(fd, frame(json))
    }

    private static func readExactly(_ count: Int, from fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: count)
        while data.count < count {
            let n = read(fd, &buffer, count - data.count)
            if n <= 0 { return nil }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// `clipb` started by Chrome for the ClipB Router extension. Answers
/// `decide` (does this link belong in another profile?) and `open` (hand the
/// link to the running app). stdout carries only protocol frames.
enum NativeHost {
    struct Request: Decodable {
        var op: String
        var url: String?
        /// Email of the profile the request comes from.
        var email: String?
        /// For `open`: what the extension decided, so the target profile can explain it.
        var target: String?
        var rule: String?
    }

    struct Response: Encodable, Equatable {
        var v = 1
        var ok: Bool
        var move: Bool? = nil
        var reason: String? = nil
        var target: String? = nil
        var rule: String? = nil
        /// Where the rules live, so the extension can tell the user.
        var config: String? = nil
        var error: String? = nil
        /// For `arrived`: the profile (email) the link was redirected from.
        var from: String? = nil
    }

    static func run() -> Int32 {
        let cache = RouterConfigCache()
        while let data = NativeMessaging.readMessage() {
            let response = respond(
                to: data,
                config: { try cache.current() },
                localState: { chromeLocalState() },
                open: { url, info in
                    try CopyCommand.sendLaunchingIfNeeded(
                        IPCMessage(tag: nil, text: "", open: url.absoluteString, redirect: info)
                    )
                },
                arrived: { url in
                    // A question, not a delivery: never launch the app for it.
                    guard let reply = try? IPCClient.request(IPCMessage(tag: nil, text: "", arrived: url.absoluteString)) else {
                        return nil
                    }
                    return try? JSONDecoder().decode(RedirectInfo.self, from: Data(reply.utf8))
                }
            )
            guard let out = try? JSONEncoder().encode(response), NativeMessaging.write(out) else { return 1 }
        }
        return 0
    }

    static func respond(
        to data: Data,
        config: () throws -> RouterConfig,
        localState: () -> Data?,
        open: (URL, RedirectInfo?) throws -> Void,
        arrived: (URL) -> RedirectInfo? = { _ in nil }
    ) -> Response {
        guard let request = try? JSONDecoder().decode(Request.self, from: data),
              let raw = request.url, let url = Links.webURL(in: raw) else {
            return Response(ok: false, error: "bad request")
        }
        switch request.op {
        case "decide":
            do {
                let decision = ExtensionRouting.decide(
                    url: url, currentEmail: request.email, config: try config(), localState: localState()
                )
                return Response(
                    ok: true, move: decision.move, reason: decision.reason, target: decision.target,
                    rule: decision.rule, config: RouterConfig.displayPath
                )
            } catch {
                return Response(ok: false, error: "config unusable: \(error)")
            }
        case "open":
            do {
                let info = request.email.flatMap { $0.isEmpty ? nil : RedirectInfo(from: $0, target: request.target, rule: request.rule) }
                try open(url, info)
                return Response(ok: true)
            } catch {
                return Response(ok: false, error: "ClipB unreachable: \(error)")
            }
        case "arrived":
            guard let info = arrived(url) else { return Response(ok: true) }
            return Response(ok: true, target: info.target, rule: info.rule, config: RouterConfig.displayPath, from: info.from)
        default:
            return Response(ok: false, error: "unknown op")
        }
    }

    private static func chromeLocalState() -> Data? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
        return try? Data(contentsOf: path)
    }
}

/// `clipb install-native-host [--extension-id <id>]...`: lets Chrome start
/// this binary for the extension. Run it again after moving the app.
enum NativeHostInstaller {
    static let hostName = "com.productmind.clipb"
    /// The id that the `key` in extension/chrome/manifest.json pins for unpacked installs.
    static let devExtensionID = "hiimoliolcnghhceefngpikhdkglecnp"

    static func manifest(executable: String, extensionIDs: [String]) -> Data {
        let object: [String: Any] = [
            "name": hostName,
            "description": "ClipB link router",
            "path": executable,
            "type": "stdio",
            "allowed_origins": extensionIDs.map { "chrome-extension://\($0)/" },
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static func run(_ args: [String]) -> Int32 {
        var ids = [devExtensionID]
        var i = 0
        while i < args.count {
            guard args[i] == "--extension-id", i + 1 < args.count else {
                fputs("usage: clipb install-native-host [--extension-id <id>]...\n", stderr)
                return 2
            }
            ids.append(args[i + 1])
            i += 2
        }
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
            fputs("clipb: cannot locate its own executable\n", stderr)
            return 1
        }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/\(hostName).json")
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manifest(executable: executable, extensionIDs: ids).write(to: file, options: .atomic)
        } catch {
            fputs("clipb: could not write \(file.path): \(error)\n", stderr)
            return 1
        }
        print("wrote \(file.path)\nhost: \(executable)")
        return 0
    }
}
