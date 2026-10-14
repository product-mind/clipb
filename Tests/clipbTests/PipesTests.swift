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
            PipeCommand(id: "en", name: "Fix English", command: #"pi -p "x""#),
            PipeCommand(id: "upper", name: "upper", command: "tr a-z A-Z"),
        ])
    }

    @Test func noPipeTablesMeansNoPipes() throws {
        #expect(try pipes("[router]\n\"*\" = \"safari\"").isEmpty)
    }

    @Test func missingOrBlankRunIsAnError() {
        #expect(throws: Pipes.ConfigError.self) { try pipes("[pipe.x]\nname = \"X\"") }
        #expect(throws: Pipes.ConfigError.self) { try pipes("[pipe.x]\nrun = \"  \"") }
        #expect(throws: Pipes.ConfigError.self) { try pipes("[pipe.x]\nrun = 1") }
    }

    @Test func keepsOnlyTheFirstNine() throws {
        let toml = (1...11).map { "[pipe.p\($0)]\nrun = \"cat\"" }.joined(separator: "\n")
        let result = try pipes(toml)
        #expect(result.count == 9)
        #expect(result.last?.name == "p9")
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

@Suite struct PipeRunnerTests {
    private func run(_ command: String, input: String, timeout: TimeInterval = 5) async -> (Int32?, Data) {
        await withCheckedContinuation { continuation in
            _ = PipeRunner.start(command, input: input, timeout: timeout) { status, data in
                continuation.resume(returning: (status, data))
            }
        }
    }

    @Test func pipesStdinThroughTheCommand() async {
        let (status, data) = await run("cat", input: "Příliš žluťoučký kůň 🐴")
        #expect(status == 0)
        #expect(String(data: data, encoding: .utf8) == "Příliš žluťoučký kůň 🐴")
    }

    @Test func reportsNonZeroExit() async {
        let (status, _) = await run("exit 3", input: "x")
        #expect(status == 3)
    }

    @Test func survivesACommandThatIgnoresStdin() async {
        let big = String(repeating: "x", count: 1 << 20)
        let (status, data) = await run("echo done", input: big)
        #expect(status == 0)
        #expect(String(data: data, encoding: .utf8) == "done\n")
    }

    @Test func timeoutReportsNilStatus() async {
        let (status, _) = await run("sleep 5", input: "", timeout: 0.3)
        #expect(status == nil)
    }
}
