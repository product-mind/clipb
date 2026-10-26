import Foundation
import Testing
@testable import clipb

@Suite struct IPCTests {
    private func tempSocketPath() -> String {
        NSTemporaryDirectory() + "clipb-\(UUID().uuidString.prefix(8))/s.sock"
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    private func startServer(at path: String, received: @escaping (IPCMessage) -> Void) throws -> IPCServer {
        let server = IPCServer(path: path, queue: DispatchQueue(label: "ipc-test"))
        server.onMessage = received
        try server.start()
        return server
    }

    // MARK: - Parsing

    @Test func parsesTagForms() {
        #expect(CopyCommand.parse([]) == .run(.init(tag: nil)))
        #expect(CopyCommand.parse(["--tag", "dictation"]) == .run(.init(tag: "dictation")))
        #expect(CopyCommand.parse(["--tag=dictation"]) == .run(.init(tag: "dictation")))
    }

    @Test func parseRejectsBadInput() {
        #expect(CopyCommand.parse(["--tag"]) == .error("--tag needs a value"))
        #expect(CopyCommand.parse(["some text"]) == .error("unknown argument: some text"))
        #expect(CopyCommand.parse(["--help"]) == .help)
    }

    // MARK: - Wire format

    @Test func messageRoundTripsNonASCII() throws {
        let message = IPCMessage(tag: "dictation", text: "Příliš žluťoučký kůň 🐴\nsecond line")
        let decoded = try JSONDecoder().decode(IPCMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded == message)
    }

    // MARK: - Server and client

    @Test func clientDeliversMessageToServer() throws {
        let path = tempSocketPath()
        defer { cleanup(path) }
        let delivered = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var received: IPCMessage?
        let server = try startServer(at: path) {
            received = $0
            delivered.signal()
        }
        defer { server.stop() }

        let message = IPCMessage(tag: "dictation", text: "hello 🐴")
        try IPCClient.send(message, path: path)

        #expect(delivered.wait(timeout: .now() + 2) == .success)
        #expect(received == message)
    }

    @Test func isListeningTracksLivenessAndProbesDoNotDisturbTheServer() throws {
        let path = tempSocketPath()
        defer { cleanup(path) }
        #expect(!IPC.isListening(path))

        let delivered = DispatchSemaphore(value: 0)
        let server = try startServer(at: path) { _ in delivered.signal() }
        defer { server.stop() }

        #expect(IPC.isListening(path))
        try IPCClient.send(IPCMessage(tag: nil, text: "probe survived"), path: path)
        #expect(delivered.wait(timeout: .now() + 2) == .success)

        server.stop()
        #expect(!IPC.isListening(path))
    }

    @Test func mayBindRefusesAHealthyDaemon() throws {
        let path = tempSocketPath()
        defer { cleanup(path) }
        let server = try startServer(at: path) { _ in }
        defer { server.stop() }

        #expect(!IPC.mayBind(path: path, graceSeconds: 0.3))
    }

    @Test func mayBindTakesOverWhenTheOldInstanceQuits() throws {
        let path = tempSocketPath()
        defer { cleanup(path) }
        let old = try startServer(at: path) { _ in }
        // The old instance was told to quit but lingers briefly, like a dev handoff.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { old.stop() }

        #expect(IPC.mayBind(path: path, graceSeconds: 2))
        #expect(!IPC.isListening(path))
    }

    @Test func mayBindAcceptsStaleSocketFile() throws {
        let path = tempSocketPath()
        defer { cleanup(path) }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))

        #expect(IPC.mayBind(path: path, graceSeconds: 0.3))
    }

    @Test func serverRebindsOverStaleSocketFile() throws {
        let path = tempSocketPath()
        defer { cleanup(path) }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))

        let delivered = DispatchSemaphore(value: 0)
        let server = try startServer(at: path) { _ in delivered.signal() }
        defer { server.stop() }

        try IPCClient.send(IPCMessage(tag: nil, text: "after stale"), path: path)
        #expect(delivered.wait(timeout: .now() + 2) == .success)
    }

    @Test func sendFailsWhenNothingListens() {
        let path = tempSocketPath()
        #expect(throws: IPCError.self) {
            try IPCClient.send(IPCMessage(tag: nil, text: "x"), path: path)
        }
    }

    @Test func garbageIsRejectedAndNotDelivered() throws {
        let path = tempSocketPath()
        defer { cleanup(path) }
        nonisolated(unsafe) var called = false
        let server = try startServer(at: path) { _ in called = true }
        defer { server.stop() }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        IPC.configure(fd)
        #expect(IPC.withAddress(path) { connect(fd, $0, $1) } == 0)
        #expect(IPC.writeAll(fd, Data("not json".utf8)))
        shutdown(fd, SHUT_WR)
        let reply = IPC.readAll(fd, limit: 1024).map { String(decoding: $0, as: UTF8.self) }

        #expect(reply == "error: bad request\n")
        #expect(!called)
    }

    @Test func socketIsOwnerOnly() throws {
        let path = tempSocketPath()
        defer { cleanup(path) }
        let server = try startServer(at: path) { _ in }
        defer { server.stop() }

        let socketPerms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        let dirPerms = try FileManager.default
            .attributesOfItem(atPath: (path as NSString).deletingLastPathComponent)[.posixPermissions] as? Int
        #expect(socketPerms == 0o600)
        #expect(dirPerms == 0o700)
    }

    @Test func stopRemovesItsSocket() throws {
        let path = tempSocketPath()
        defer { cleanup(path) }
        let server = try startServer(at: path) { _ in }
        #expect(FileManager.default.fileExists(atPath: path))
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func oldInstanceStopDoesNotRemoveNewInstancesSocket() throws {
        let path = tempSocketPath()
        defer { cleanup(path) }
        let delivered = DispatchSemaphore(value: 0)
        let old = try startServer(at: path) { _ in }
        let new = try startServer(at: path) { _ in delivered.signal() }
        defer { new.stop() }

        old.stop()
        try IPCClient.send(IPCMessage(tag: nil, text: "still works"), path: path)
        #expect(delivered.wait(timeout: .now() + 2) == .success)
    }
}
