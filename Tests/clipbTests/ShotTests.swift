import Foundation
import Testing
@testable import clipb

@Suite struct ShotTests {
    @Test func captureIsClipboardModeWithTheSound() {
        #expect(Shot.executable == "/usr/sbin/screencapture")
        // `-c` = clipboard, and no `-x`: the capture sound stays.
        #expect(Shot.arguments == ["-c"])
    }

    @Test func theExitStatusComesFromTheBinary() {
        #expect(Shot.runCapture(executable: "/usr/bin/true", arguments: []) == 0)
        #expect(Shot.runCapture(executable: "/usr/bin/false", arguments: []) == 1)
    }

    @Test func aBinaryThatCannotLaunchIsNotACapture() {
        #expect(Shot.runCapture(executable: "/nonexistent/screencapture", arguments: []) == nil)
    }
}
