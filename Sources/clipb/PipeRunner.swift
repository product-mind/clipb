import Foundation

/// Runs one pipe command in the user's login shell, text on stdin. Memory only:
/// neither the input nor the output is logged or written anywhere.
final class PipeRunner {
    private let process = Process()
    private let lock = NSLock()
    private var completion: ((Int32?, Data) -> Void)?

    /// `completion` runs once, on the main thread. Its status is nil when the
    /// command was cancelled, timed out, or failed to launch.
    static func start(
        _ command: String,
        input: String,
        timeout: TimeInterval = Pipes.timeout,
        completion: @escaping (_ status: Int32?, _ stdout: Data) -> Void
    ) -> PipeRunner {
        let runner = PipeRunner()
        runner.completion = completion
        runner.run(command, input: input, timeout: timeout)
        return runner
    }

    func cancel() {
        if process.isRunning { process.terminate() }
        // Don't wait for EOF: a grandchild of the shell may keep stdout open.
        finish(nil, Data())
    }

    private func finish(_ status: Int32?, _ data: Data) {
        lock.lock()
        let handler = completion
        completion = nil
        lock.unlock()
        guard let handler else { return }
        DispatchQueue.main.async { handler(status, data) }
    }

    private func run(_ command: String, input: String, timeout: TimeInterval) {
        // A GUI app's PATH lacks Homebrew; a login shell picks up the user's.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            devLog("pipe: launch failed")
            return finish(nil, Data())
        }

        // A command that exits without reading stdin must not kill ClipB with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global().async {
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.cancel()
        }
        DispatchQueue.global().async { [self] in
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let exited = process.terminationReason == .exit
            devLog("pipe: exited=\(exited) status=\(process.terminationStatus) bytes=\(data.count)")
            finish(exited ? process.terminationStatus : nil, data)
        }
    }
}
