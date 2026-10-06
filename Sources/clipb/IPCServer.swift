import Foundation

/// Accepts `clipb copy` requests on a Unix socket. Reads happen on a
/// background thread; `onMessage` is delivered on `queue` (main in the app)
/// so history stays main-thread only. Set `onMessage` before `start()`.
final class IPCServer {
    var onMessage: ((IPCMessage) -> Void)?

    private let path: String
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var identity: (dev: dev_t, ino: ino_t)?

    init(path: String = IPC.defaultPath, queue: DispatchQueue = .main) {
        self.path = path
        self.queue = queue
    }

    func start() throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // A leftover socket from a crashed run would make bind() fail.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.socket(errno) }

        let bound = IPC.withAddress(path) { bind(fd, $0, $1) }
        guard bound == 0 else {
            let code = bound == nil ? ENAMETOOLONG : errno
            close(fd)
            throw IPCError.socket(code)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw IPCError.socket(code)
        }

        var info = stat()
        lock.lock()
        listenFD = fd
        if stat(path, &info) == 0 { identity = (info.st_dev, info.st_ino) }
        lock.unlock()

        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    func stop() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        let mine = identity
        lock.unlock()
        guard fd >= 0 else { return }
        close(fd)

        // A newer instance may already have replaced the socket file.
        var info = stat()
        if let mine, stat(path, &info) == 0, info.st_dev == mine.dev, info.st_ino == mine.ino {
            unlink(path)
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listenFD < 0
    }

    private func acceptLoop(_ fd: Int32) {
        while !isStopped {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if isStopped { return }
                continue
            }
            handle(client)
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        IPC.configure(client)

        guard let data = IPC.readAll(client, limit: IPC.maxMessageBytes),
              let message = try? JSONDecoder().decode(IPCMessage.self, from: data)
        else {
            _ = IPC.writeAll(client, Data("error: bad request\n".utf8))
            return
        }
        queue.async { [weak self] in self?.onMessage?(message) }
        _ = IPC.writeAll(client, Data("ok\n".utf8))
    }
}
