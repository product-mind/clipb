import Foundation
import Testing
@testable import clipb

@Suite struct PipesConfigTests {
    private func pipes(_ toml: String) throws -> [PipeCommand] {
        try Pipes.parse(TOML.parse(toml))
    }

    @Test func readsPipeTablesInFileOrder() throws {
        let result = try pipes("""
        [router]
        "*" = "safari"
        [pipe.en]
        name = "Fix English"
        run = 'pi -p "x"'
        [pipe.upper]
        run = "tr a-z A-Z"
        """)
        #expect(result == [
            PipeCommand(id: "en", name: "Fix English", command: #"pi -p "x""#, hotkey: nil),
            PipeCommand(id: "upper", name: "upper", command: "tr a-z A-Z", hotkey: nil),
        ])
    }

    @Test func readsTheHotkey() throws {
        let result = try pipes("[pipe.quote]\nrun = \"cat\"\nhotkey = \"c\"\n[pipe.up]\nrun = \"cat\"\nhotkey = \"C\"")
        #expect(result.map(\.hotkey) == ["c", "C"])
    }

    @Test func aTableWithoutHotkeyHasNone() throws {
        #expect(try pipes("[pipe.x]\nrun = \"cat\"").first?.hotkey == nil)
    }

    @Test func hotkeyMustBeASingleLetter() {
        #expect(throws: Pipes.ConfigError.self) { try pipes("[pipe.x]\nrun = \"c\"\nhotkey = \"cc\"") }
        #expect(throws: Pipes.ConfigError.self) { try pipes("[pipe.x]\nrun = \"c\"\nhotkey = \"3\"") }
        #expect(throws: Pipes.ConfigError.self) { try pipes("[pipe.x]\nrun = \"c\"\nhotkey = \"\"") }
        #expect(throws: Pipes.ConfigError.self) { try pipes("[pipe.x]\nrun = \"c\"\nhotkey = \"é\"") }
        #expect(throws: Pipes.ConfigError.self) { try pipes("[pipe.x]\nrun = \"c\"\nhotkey = 3") }
    }

    @Test func noPipeTablesMeansNoPipes() throws {
        #expect(try pipes("[router]\n\"*\" = \"safari\"").isEmpty)
    }

    @Test func timeoutDefaultsToTenMinutes() throws {
        #expect(Pipes.defaultTimeout == 600)
        #expect(try pipes("[pipe.x]\nrun = \"cat\"").first?.timeout == 600)
    }

    @Test func readsTheTimeout() throws {
        #expect(try pipes("[pipe.x]\nrun = \"cat\"\ntimeout = 5").first?.timeout == 5)
        #expect(try pipes("[pipe.x]\nrun = \"cat\"\ntimeout = 1800").first?.timeout == 1800)
    }

    @Test func zeroTimeoutMeansNoLimit() throws {
        #expect(try pipes("[pipe.x]\nrun = \"cat\"\ntimeout = 0").first?.timeout == 0)
    }

    @Test func aBadTimeoutIsAnErrorThatNamesTheNoLimitValue() {
        for entry in ["timeout = -1", "timeout = \"5\"", "timeout = true"] {
            do {
                _ = try pipes("[pipe.x]\nrun = \"cat\"\n\(entry)")
                Issue.record("expected \(entry) to throw")
            } catch let error as Pipes.ConfigError {
                #expect(error.description.contains("0 = no limit"))
            } catch {
                Issue.record("unexpected error \(error) for \(entry)")
            }
        }
    }

    @Test func missingOrBlankRunIsAnError() {
        #expect(throws: Pipes.ConfigError.self) { try pipes("[pipe.x]\nname = \"X\"") }
        #expect(throws: Pipes.ConfigError.self) { try pipes("[pipe.x]\nrun = \"  \"") }
        #expect(throws: Pipes.ConfigError.self) { try pipes("[pipe.x]\nrun = 1") }
    }

    @Test func parsesEveryPipeTheChooserCapsItself() throws {
        let toml = (1...11).map { "[pipe.p\($0)]\nrun = \"cat\"" }.joined(separator: "\n")
        let result = try pipes(toml)
        #expect(result.count == 11)
        #expect(result.last?.name == "p11")
        #expect(Array(result.prefix(Pipes.maxPipes)).last?.name == "p9")
    }

    @Test func aHotkeyOnAPipePastTheNinthStillParses() throws {
        let head = (1...9).map { "[pipe.p\($0)]\nrun = \"cat\"" }.joined(separator: "\n")
        let result = try pipes(head + "\n[pipe.quote]\nrun = \"cat\"\nhotkey = \"c\"")
        #expect(result.count == 10)
        #expect(result.last?.hotkey == "c")
    }

    @Test func theDeprecatedEditorKeyIsIgnored() throws {
        // An old [pipe.edit] block must not kill the whole pipe list.
        let result = try pipes("""
        [pipe.x]
        run = "cat"
        editor = true
        [pipe.y]
        run = "cat"
        """)
        #expect(result.map(\.id) == ["x", "y"])
        #expect(result.first?.command == "cat")
        #expect(try pipes("[pipe.x]\nrun = \"cat\"\neditor = \"yes\"").first?.command == "cat")
    }

    @Test func missingFileMeansNoPipes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipb-none-\(UUID()).toml")
        #expect(try Pipes.load(from: url).isEmpty)
    }
}

@Suite struct PipesOutcomeTests {
    @Test func outputReplacesTheTextWithoutTrailingNewlines() {
        #expect(Pipes.outcome(status: 0, stdout: Data("HELLO\n\n".utf8)) == .paste("HELLO"))
        #expect(Pipes.outcome(status: 0, stdout: Data("  a\nb  \n".utf8)) == .paste("  a\nb  "))
    }

    @Test func silentSuccessKeepsTheTextCut() {
        #expect(Pipes.outcome(status: 0, stdout: Data()) == .keepCut)
        #expect(Pipes.outcome(status: 0, stdout: Data(" \n".utf8)) == .keepCut)
    }

    @Test func failureRestores() {
        #expect(Pipes.outcome(status: 1, stdout: Data("partial".utf8)) == .restore)
        #expect(Pipes.outcome(status: nil, stdout: Data("x".utf8)) == .restore)
        #expect(Pipes.outcome(status: 0, stdout: Data([0xFF, 0xFE])) == .restore)
    }

    @Test func roundTripsNonASCII() {
        let text = "Příliš žluťoučký kůň 🐴"
        #expect(Pipes.outcome(status: 0, stdout: Data((text + "\n").utf8)) == .paste(text))
    }
}

@Suite struct PipesStdinTests {
    @Test func textSendsItsBytes() {
        #expect(Pipes.stdin(for: ClipEntry(value: "Příliš 🐴")) == Data("Příliš 🐴".utf8))
    }

    @Test func anEmptyEntrySendsEmptyStdin() {
        #expect(Pipes.stdin(for: ClipEntry(value: "")) == Data())
    }

    @Test func anImageSendsItsPNGBytes() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        #expect(Pipes.stdin(for: ClipEntry(value: ClipboardCapture.imageValue, image: png)) == png)
    }

    @Test func filesSendOneURLPerLine() {
        let entry = ClipEntry(
            value: "[file] a",
            fileURLs: [URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b")]
        )
        #expect(Pipes.stdin(for: entry) == Data("file:///tmp/a\nfile:///tmp/b".utf8))
    }
}

@Suite struct ClipEntryEmptyTests {
    @Test func anEmptyValueIsEmpty() {
        #expect(ClipEntry(value: "").isEmpty)
    }

    @Test func anyContentIsNotEmpty() {
        #expect(!ClipEntry(value: "x").isEmpty)
        #expect(!ClipEntry(value: "[image]", image: Data([1])).isEmpty)
        #expect(!ClipEntry(value: "[file] a", fileURLs: [URL(fileURLWithPath: "/tmp/a")]).isEmpty)
    }
}

@Suite struct PipeRunnerTests {
    private func run(
        _ command: String,
        input: ClipEntry,
        timeout: TimeInterval = 5
    ) async -> (Int32?, Data, Data) {
        await withCheckedContinuation { continuation in
            _ = PipeRunner.start(command, input: input, timeout: timeout) { status, stdout, stderr in
                continuation.resume(returning: (status, stdout, stderr))
            }
        }
    }

    private func run(_ command: String, input: String, timeout: TimeInterval = 5) async -> (Int32?, Data, Data) {
        await run(command, input: ClipEntry(value: input), timeout: timeout)
    }

    private func freshDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipb-pipe-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func pipesStdinThroughTheCommand() async {
        let (status, data, _) = await run("cat", input: "Příliš žluťoučký kůň 🐴")
        #expect(status == 0)
        #expect(String(data: data, encoding: .utf8) == "Příliš žluťoučký kůň 🐴")
    }

    @Test func reportsNonZeroExit() async {
        let (status, _, _) = await run("exit 3", input: "x")
        #expect(status == 3)
    }

    @Test func capturesStderrForTheFailureNotice() async {
        let (status, _, stderr) = await run("echo oops >&2; exit 3", input: "x")
        #expect(status == 3)
        #expect(String(decoding: stderr, as: UTF8.self) == "oops\n")
    }

    @Test func aSuccessfulCommandHasNoStderr() async {
        let (status, _, stderr) = await run("echo done", input: "x")
        #expect(status == 0)
        #expect(stderr.isEmpty)
    }

    @Test func survivesACommandThatIgnoresStdin() async {
        let big = String(repeating: "x", count: 1 << 20)
        let (status, data, _) = await run("echo done", input: big)
        #expect(status == 0)
        #expect(String(data: data, encoding: .utf8) == "done\n")
    }

    @Test func timeoutReportsNilStatus() async {
        let (status, _, _) = await run("sleep 5", input: "", timeout: 0.3)
        #expect(status == nil)
    }

    @Test func aZeroTimeoutNeverSchedulesACancel() async {
        let (status, data, _) = await run("sleep 1; echo done", input: "", timeout: 0)
        #expect(status == 0)
        #expect(String(data: data, encoding: .utf8) == "done\n")
    }

    @Test func anImageReachesTheCommandAsPNGBytes() async throws {
        let directory = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("out.png")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

        let (status, data, _) = await run(
            "cat > '\(file.path)'",
            input: ClipEntry(value: ClipboardCapture.imageValue, image: png)
        )

        // A sink pipe: success with no output means nothing to paste.
        #expect(status == 0)
        #expect(data.isEmpty)
        #expect(try Data(contentsOf: file) == png)
    }

    @Test func fileURLsReachTheCommandOnePerLine() async {
        let entry = ClipEntry(
            value: "[file] a",
            fileURLs: [URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b")]
        )
        let (status, data, _) = await run("cat", input: entry)
        #expect(status == 0)
        #expect(String(data: data, encoding: .utf8) == "file:///tmp/a\nfile:///tmp/b")
    }
}
