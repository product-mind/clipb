import Foundation

/// The two reader queues publish here; each write precedes its `leave()`, and
/// the reader runs after `wait()`, so the group orders the pair — no lock needed.
private final class PipeOutput: @unchecked Sendable {
    private var out = Data()
    private var err = Data()

    func setOut(_ data: Data) { out = data }
    func setErr(_ data: Data) { err = data }

    var both: (out: Data, err: Data) { (out, err) }
}

/// Runs one pipe command in the user's login shell, the clipboard entry on
/// stdin. Memory only: neither the input nor the output is logged or written
/// anywhere by ClipB (the command's own writes are the user's).
final class PipeRunner {
    private let process = Process()
    private let lock = NSLock()
    private var completion: ((Int32?, Data, Data) -> Void)?

    /// `completion` runs once, on the main thread. Its status is nil when the
    /// command was cancelled, timed out, or failed to launch; its stderr is
    /// diagnosis for the failure notice, never log material. A `timeout` of 0
    /// or less never schedules a cancel.
    static func start(
        _ command: String,
        input: ClipEntry,
        timeout: TimeInterval = Pipes.defaultTimeout,
        completion: @escaping (_ status: Int32?, _ stdout: Data, _ stderr: Data) -> Void
    ) -> PipeRunner {
        let runner = PipeRunner()
        runner.completion = completion
        runner.run(command, input: Pipes.stdin(for: input), timeout: timeout)
        return runner
    }

    func cancel() {
        if process.isRunning { process.terminate() }
        // Don't wait for EOF: a grandchild of the shell may keep stdout open.
        finish(nil, Data(), Data())
    }

    private func finish(_ status: Int32?, _ out: Data, _ err: Data) {
        lock.lock()
        let handler = completion
        completion = nil
        lock.unlock()
        guard let handler else { return }
        DispatchQueue.main.async { handler(status, out, err) }
    }

    private func run(_ command: String, input: Data, timeout: TimeInterval) {
        // A GUI app's PATH lacks Homebrew; a login shell picks up the user's.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        // Diagnosis for the failure notice: read, never logged.
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            devLog("pipe: launch failed")
            let reason = Data("could not start the command: \(error.localizedDescription)".utf8)
            return finish(nil, Data(), reason)
        }

        // A command that exits without reading stdin must not kill ClipB with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global().async {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        // 0 = no limit: an interactive pipe ends when the user quits it, not on a clock.
        if timeout > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.cancel()
            }
        }
        // Both pipes drain while the command runs: a full one would block it.
        let drained = DispatchGroup()
        let output = PipeOutput()
        drained.enter()
        DispatchQueue.global().async {
            output.setOut(stdout.fileHandleForReading.readDataToEndOfFile())
            drained.leave()
        }
        drained.enter()
        DispatchQueue.global().async {
            output.setErr(stderr.fileHandleForReading.readDataToEndOfFile())
            drained.leave()
        }
        DispatchQueue.global().async { [self] in
            process.waitUntilExit()
            drained.wait()
            let (out, err) = output.both
            let exited = process.terminationReason == .exit
            devLog("pipe: exited=\(exited) status=\(process.terminationStatus) stdout=\(out.count) stderr=\(err.count)")
            finish(exited ? process.terminationStatus : nil, out, err)
        }
    }
}
