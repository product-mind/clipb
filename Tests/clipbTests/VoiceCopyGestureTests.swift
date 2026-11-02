import Testing
@testable import clipb

@Suite struct VoiceCopyGestureTests {
    private func press(_ g: inout VoiceCopyGesture) -> Int {
        guard case .begin(let generation) = g.cDown(commandOnly: true, isRepeat: false) else {
            Issue.record("press did not begin")
            return -1
        }
        return generation
    }

    @Test func tapBeginsThenDiscards() {
        var g = VoiceCopyGesture()
        let gen = press(&g)
        #expect(g.released() == .discard)
        #expect(g.holdElapsed(generation: gen) == .none)
        #expect(g.state == .idle)
    }

    @Test func holdRecordsUntilRelease() {
        var g = VoiceCopyGesture()
        let gen = press(&g)
        #expect(g.holdElapsed(generation: gen) == .confirm)
        #expect(g.state == .recording)
        #expect(g.released() == .stop)
        #expect(g.state == .idle)
    }

    @Test func repeatsWhileHeldAreIgnored() {
        var g = VoiceCopyGesture()
        let gen = press(&g)
        #expect(g.cDown(commandOnly: true, isRepeat: true) == .none)
        #expect(g.holdElapsed(generation: gen) == .confirm)
        #expect(g.cDown(commandOnly: true, isRepeat: true) == .none)
        #expect(g.state == .recording)
    }

    @Test func staleTimerFromEarlierTapIsIgnored() {
        var g = VoiceCopyGesture()
        let first = press(&g)
        _ = g.released()
        let second = press(&g)
        #expect(first != second)
        #expect(g.holdElapsed(generation: first) == .none)
        #expect(g.state == .pressed)
        #expect(g.holdElapsed(generation: second) == .confirm)
    }

    @Test func otherModifiersNeverBegin() {
        var g = VoiceCopyGesture()
        #expect(g.cDown(commandOnly: false, isRepeat: false) == .none)
        #expect(g.released() == .none)
        #expect(g.state == .idle)
    }

    @Test func escapeDiscardsRecording() {
        var g = VoiceCopyGesture()
        let gen = press(&g)
        _ = g.holdElapsed(generation: gen)
        #expect(g.escape() == .discard)
        #expect(g.released() == .none)
        #expect(g.state == .idle)
    }

    @Test func escapeOrOtherKeyBeforeThresholdDiscards() {
        var g = VoiceCopyGesture()
        var gen = press(&g)
        #expect(g.escape() == .discard)
        #expect(g.holdElapsed(generation: gen) == .none)

        gen = press(&g)
        #expect(g.otherKey() == .discard)
        #expect(g.holdElapsed(generation: gen) == .none)
        #expect(g.state == .idle)
    }

    @Test func otherKeysWhileRecordingKeepRecording() {
        var g = VoiceCopyGesture()
        let gen = press(&g)
        _ = g.holdElapsed(generation: gen)
        #expect(g.otherKey() == .none)
        #expect(g.state == .recording)
    }
}
