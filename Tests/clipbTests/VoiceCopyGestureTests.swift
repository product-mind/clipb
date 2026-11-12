import Testing
@testable import clipb

@Suite struct VoiceCopyGestureTests {
    private func press(_ g: inout VoiceCopyGesture, _ key: VoiceCopyGesture.Key = .copy) -> Int {
        guard case .begin(key, let generation) = g.keyDown(key, commandOnly: true, isRepeat: false) else {
            Issue.record("press did not begin")
            return -1
        }
        return generation
    }

    @Test func tapIsThePlainCopyOrPaste() {
        for key in [VoiceCopyGesture.Key.copy, .paste] {
            var g = VoiceCopyGesture()
            let gen = press(&g, key)
            #expect(g.keyUp(key) == .tap(key))
            #expect(g.holdElapsed(generation: gen) == .none)
            #expect(g.state == .idle)
        }
    }

    @Test func holdRecordsUntilRelease() {
        for key in [VoiceCopyGesture.Key.copy, .paste] {
            var g = VoiceCopyGesture()
            let gen = press(&g, key)
            #expect(g.holdElapsed(generation: gen) == .confirm(key))
            #expect(g.state == .recording(key))
            #expect(g.keyUp(key) == .stop(key))
            #expect(g.state == .idle)
        }
    }

    @Test func releasingCmdFirstEndsThePress() {
        var g = VoiceCopyGesture()
        var gen = press(&g, .paste)
        #expect(g.commandReleased() == .tap(.paste))
        gen = press(&g, .paste)
        _ = g.holdElapsed(generation: gen)
        #expect(g.commandReleased() == .stop(.paste))
        #expect(g.keyUp(.paste) == .none)
    }

    @Test func theOtherKeysReleaseIsIgnored() {
        var g = VoiceCopyGesture()
        let gen = press(&g, .copy)
        #expect(g.keyUp(.paste) == .none)
        #expect(g.holdElapsed(generation: gen) == .confirm(.copy))
    }

    @Test func repeatsWhileHeldAreIgnored() {
        var g = VoiceCopyGesture()
        let gen = press(&g)
        #expect(g.keyDown(.copy, commandOnly: true, isRepeat: true) == .none)
        #expect(g.holdElapsed(generation: gen) == .confirm(.copy))
        #expect(g.keyDown(.copy, commandOnly: true, isRepeat: true) == .none)
        #expect(g.state == .recording(.copy))
    }

    @Test func staleTimerFromEarlierTapIsIgnored() {
        var g = VoiceCopyGesture()
        let first = press(&g)
        _ = g.keyUp(.copy)
        let second = press(&g)
        #expect(first != second)
        #expect(g.holdElapsed(generation: first) == .none)
        #expect(g.state == .pressed(.copy))
        #expect(g.holdElapsed(generation: second) == .confirm(.copy))
    }

    @Test func otherModifiersNeverBegin() {
        var g = VoiceCopyGesture()
        #expect(g.keyDown(.paste, commandOnly: false, isRepeat: false) == .none)
        #expect(g.keyUp(.paste) == .none)
        #expect(g.state == .idle)
    }

    @Test func escapeCancelsBeforeAndDuringRecording() {
        var g = VoiceCopyGesture()
        var gen = press(&g, .paste)
        #expect(g.escape() == .cancel(.paste))
        #expect(g.holdElapsed(generation: gen) == .none)

        gen = press(&g)
        _ = g.holdElapsed(generation: gen)
        #expect(g.escape() == .cancel(.copy))
        #expect(g.keyUp(.copy) == .none)
        #expect(g.state == .idle)
    }

    @Test func otherKeyBeforeThresholdIsATap() {
        var g = VoiceCopyGesture()
        let gen = press(&g, .paste)
        #expect(g.otherKey() == .tap(.paste))
        #expect(g.holdElapsed(generation: gen) == .none)
        #expect(g.state == .idle)
    }

    @Test func otherKeysWhileRecordingKeepRecording() {
        var g = VoiceCopyGesture()
        let gen = press(&g)
        _ = g.holdElapsed(generation: gen)
        #expect(g.otherKey() == .none)
        #expect(g.state == .recording(.copy))
    }

    // MARK: Right Option

    @Test func rightOptionHoldRecordsAndATapDoesNothingSpecial() {
        var g = VoiceCopyGesture()
        var gen = press(&g, .option)
        #expect(g.keyUp(.option) == .tap(.option))
        gen = press(&g, .option)
        #expect(g.holdElapsed(generation: gen) == .confirm(.option))
        #expect(g.keyUp(.option) == .stop(.option))
    }

    @Test func anOptionChordCancelsBeforeAndAfterTheThreshold() {
        var g = VoiceCopyGesture()
        var gen = press(&g, .option)
        #expect(g.otherKey() == .cancel(.option))
        #expect(g.holdElapsed(generation: gen) == .none)
        gen = press(&g, .option)
        _ = g.holdElapsed(generation: gen)
        #expect(g.otherKey() == .cancel(.option))
        #expect(g.state == .idle)
    }

    @Test func commandReleaseDoesNotEndAnOptionPress() {
        var g = VoiceCopyGesture()
        let gen = press(&g, .option)
        #expect(g.commandReleased() == .none)
        #expect(g.holdElapsed(generation: gen) == .confirm(.option))
    }

    @Test func toggleStartsAndStopsWithoutAHold() {
        var g = VoiceCopyGesture()
        #expect(g.togglePressed() == .start(.toggle))
        #expect(g.state == .recording(.toggle))
        // Cmd's release and other keys don't end it; only F5 or Esc do.
        #expect(g.commandReleased() == .none)
        #expect(g.otherKey() == .none)
        #expect(g.keyDown(.copy, commandOnly: true, isRepeat: false) == .none)
        #expect(g.togglePressed() == .stop(.toggle))
        #expect(g.state == .idle)
    }

    @Test func escapeCancelsAToggleTake() {
        var g = VoiceCopyGesture()
        _ = g.togglePressed()
        #expect(g.escape() == .cancel(.toggle))
        #expect(g.state == .idle)
    }

    @Test func toggleIsIgnoredDuringAHold() {
        var g = VoiceCopyGesture()
        let gen = press(&g, .copy)
        #expect(g.togglePressed() == .none)
        #expect(g.holdElapsed(generation: gen) == .confirm(.copy))
        #expect(g.togglePressed() == .none)
        #expect(g.keyUp(.copy) == .stop(.copy))
    }

    @Test func toggleAndCopyOpenTheEditor() {
        #expect(VoiceCopyGesture.Key.toggle.opensEditor)
        #expect(VoiceCopyGesture.Key.copy.opensEditor)
        #expect(!VoiceCopyGesture.Key.paste.opensEditor)
        #expect(!VoiceCopyGesture.Key.option.opensEditor)
    }
}
