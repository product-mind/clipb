import Foundation
import Testing
@testable import clipb

@Suite struct ShotTests {
    @Test func captureIsInteractiveClipboardModeWithTheSound() {
        #expect(Shot.executable == "/usr/sbin/screencapture")
        // `-ic` = interactive selection straight to the clipboard; no `-x`, so the capture sound stays.
        #expect(Shot.arguments == ["-i", "-c"])
    }

    @Test func theExitStatusComesFromTheBinary() {
        #expect(Shot.runCapture(executable: "/usr/bin/true", arguments: []) == 0)
        #expect(Shot.runCapture(executable: "/usr/bin/false", arguments: []) == 1)
    }

    @Test func aBinaryThatCannotLaunchIsNotACapture() {
        #expect(Shot.runCapture(executable: "/nonexistent/screencapture", arguments: []) == nil)
    }
}
