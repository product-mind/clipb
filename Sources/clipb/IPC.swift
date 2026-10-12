import Foundation

/// One request to the running app, sent by `clipb copy` or the Chrome native host:
/// - a snippet plus its tag (`text`, `tag`);
/// - a link to record and route (`open`), with `redirect` when the extension moved it;
/// - a question whether a link was just redirected here (`arrived`), answered with JSON.
struct IPCMessage: Codable, Equatable {
    var tag: String?
    var text: String
    var open: String? = nil
    var redirect: RedirectInfo? = nil
    var arrived: String? = nil
}

enum IPCError: Error, Equatable {
    case socket(Int32)
    case connect(Int32)
    case io
    case rejected(String)
}

/// Local Unix-domain socket plumbing shared by the app and `clipb copy`.
/// Not a network connection: it is a file only this user can open.
enum IPC {
    static let defaultPath = NSString(string: "~/.clipb/clipb.sock").expandingTildeInPath
    static let maxMessageBytes = 64 * 1024 * 1024

    /// Runs `body` with a sockaddr for `path`; nil if the path is too long.
    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, byte) in bytes.enumerated() { raw[i] = UInt8(bitPattern: byte) }
        }
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func configure(_ fd: Int32, timeoutSeconds: Int = 5) {
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Reads until EOF. Nil on error, timeout, or more than `limit` bytes.
    static func readAll(_ fd: Int32, limit: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 { return nil }
            if n == 0 { return data }
            data.append(buffer, count: n)
            if data.count > limit { return nil }
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { raw in
            while offset < data.count {
                let n = write(fd, raw.baseAddress! + offset, data.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}

enum IPCClient {
    /// Sends one message and waits for the server's "ok".
    static func send(_ message: IPCMessage, path: String = IPC.defaultPath) throws {
        let text = try request(message, path: path)
        guard text == "ok\n" else { throw IPCError.rejected(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Sends one message and returns the server's raw reply.
    static func request(_ message: IPCMessage, path: String = IPC.defaultPath) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.socket(errno) }
        defer { close(fd) }
        IPC.configure(fd)

        let result = IPC.withAddress(path) { connect(fd, $0, $1) }
        guard let result else { throw IPCError.connect(ENAMETOOLONG) }
        guard result == 0 else { throw IPCError.connect(errno) }

        guard let payload = try? JSONEncoder().encode(message), IPC.writeAll(fd, payload) else {
            throw IPCError.io
        }
        shutdown(fd, SHUT_WR)

        guard let reply = IPC.readAll(fd, limit: 64 * 1024) else { throw IPCError.io }
        return String(decoding: reply, as: UTF8.self)
    }
}
