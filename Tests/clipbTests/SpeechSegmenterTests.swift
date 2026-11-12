import Testing
@testable import clipb

@Suite struct SpeechSegmenterTests {
    private let frame = SpeechSegmenter.frameSamples
    private func speech(_ n: Int, _ p: Float = 0.9) -> [Float] { Array(repeating: p, count: n) }
    private func silence(_ n: Int, _ p: Float = 0.05) -> [Float] { Array(repeating: p, count: n) }

    @Test func silenceAloneIsNeverAChunk() {
        var s = SpeechSegmenter()
        #expect(s.feed(silence(500)).isEmpty)
        #expect(s.finish(totalSamples: 500 * frame) == nil)
    }

    @Test func cutsInTheMiddleOfAPauseAndKeepsAShortLeadIn() {
        var s = SpeechSegmenter()
        // 10 frames of silence, ~3.2 s of speech, then a pause.
        let cuts = s.feed(silence(10) + speech(100) + silence(30))
        // Lead-in: 9 frames (0.3 s) before the first word; the cut sits 9
        // frames into the 19-frame (0.6 s) pause that ended the chunk.
        #expect(cuts == [(1 * frame)..<(119 * frame)])
    }

    @Test func aShortUtteranceWaitsForMoreUnlessThePauseIsLong() {
        var s = SpeechSegmenter()
        // 1 s, a 0.8 s pause, 1 s: too short to cut at the first pause.
        var cuts = s.feed(speech(31) + silence(25) + speech(31))
        #expect(cuts.isEmpty)
        cuts = s.feed(silence(25))
        #expect(cuts.count == 1)
        #expect(cuts.first?.lowerBound == 0)

        var t = SpeechSegmenter()
        // A lone "yes" and a 1.5 s pause: flushed even though it is short.
        let flushed = t.feed(speech(20) + silence(60))
        #expect(flushed == [0..<((20 + 23) * frame)])
    }

    @Test func talkingWithoutAPauseIsCutAtTheQuietestRecentFrame() {
        var s = SpeechSegmenter()
        var audio = speech(900)
        audio[700] = 0.6
        let cuts = s.feed(audio)
        #expect(cuts == [0..<(700 * frame)])
        // The rest is still speech, handed over when the take ends.
        #expect(s.finish(totalSamples: 900 * frame) == (700 * frame)..<(900 * frame))
    }

    @Test func finishReturnsTheTailRunningToTheLastSample() {
        var s = SpeechSegmenter()
        _ = s.feed(silence(5) + speech(40))
        // The recorder may hold a partial frame more than VAD saw.
        #expect(s.finish(totalSamples: 45 * frame + 100) == 0..<(45 * frame + 100))
    }

    @Test func aFinishedChunkLeavesNothingBehind() {
        var s = SpeechSegmenter()
        #expect(s.feed(speech(100) + silence(60)).count == 1)
        #expect(s.finish(totalSamples: 160 * frame) == nil)
    }

    @Test func piecemealFeedingCutsTheSame() {
        var audio = silence(12) + speech(80) + silence(22) + speech(200) + silence(50) + speech(30)
        audio[150] = 0.2
        var whole = SpeechSegmenter()
        let expected = whole.feed(audio)
        var pieces = SpeechSegmenter()
        var got: [Range<Int>] = []
        var index = 0
        while index < audio.count {
            let end = min(audio.count, index + 7)
            got += pieces.feed(Array(audio[index..<end]))
            index = end
        }
        #expect(got == expected)
        #expect(expected.count == 2)
        #expect(pieces.finish(totalSamples: audio.count * frame) == whole.finish(totalSamples: audio.count * frame))
    }
}
