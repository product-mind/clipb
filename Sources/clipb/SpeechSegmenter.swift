/// Cuts a take into chunks at the pauses (SPEC §2.13), so whisper can work on
/// the first sentences while the user is still talking. Pure: it is fed
/// Silero's per-frame speech probabilities and answers with sample ranges.
///
/// A cut lands in the middle of a pause, so no word is split. A chunk must be
/// long enough to transcribe well (short audio trips language detection),
/// unless a long pause follows it. Talking without a pause is still cut at
/// `maxChunk` (whisper reads 30 s at a time), at the quietest frame of the
/// last few seconds. Silence before the first word is dropped down to a short
/// lead-in, and a chunk with no speech at all is never emitted.
struct SpeechSegmenter {
    /// Silero's window at 16 kHz: one probability per 512 samples (32 ms).
    static let frameSamples = 512
    static let framesPerSecond = 16000.0 / Double(frameSamples)

    struct Settings {
        var threshold: Float = 0.5
        /// A pause this long ends a chunk whose speech spans `minChunk`.
        var minSilence = 0.6
        /// A pause this long ends any chunk, however short.
        var longSilence = 1.5
        var minChunk = 2.0
        var maxChunk = 25.0
        /// Where a forced cut looks for the quietest frame: the last seconds.
        var capSearch = 5.0
        /// Silence kept in front of the first word of a chunk.
        var leadIn = 0.3
    }

    private let threshold: Float
    private let minSilence: Int
    private let longSilence: Int
    private let minChunk: Int
    private let maxChunk: Int
    private let capSearch: Int
    private let leadIn: Int

    private var probabilities: [Float] = []
    /// First frame of the chunk being collected.
    private var chunkStart = 0
    /// Last speech frame in that chunk; nil: no speech in it yet.
    private var lastSpeech: Int?

    init(_ settings: Settings = Settings()) {
        func frames(_ seconds: Double) -> Int { max(1, Int((seconds * Self.framesPerSecond).rounded())) }
        threshold = settings.threshold
        minSilence = frames(settings.minSilence)
        longSilence = frames(settings.longSilence)
        minChunk = frames(settings.minChunk)
        maxChunk = frames(settings.maxChunk)
        capSearch = frames(settings.capSearch)
        leadIn = frames(settings.leadIn)
    }

    /// Frames seen so far.
    var frameCount: Int { probabilities.count }

    /// The next frames' probabilities, in order. Returns the chunks they
    /// complete, as sample ranges.
    mutating func feed(_ next: [Float]) -> [Range<Int>] {
        var cuts: [Range<Int>] = []
        for p in next {
            let i = probabilities.count
            probabilities.append(p)
            if p >= threshold { lastSpeech = i }
            guard let last = lastSpeech else {
                // Nothing said yet: keep only the lead-in in front of what comes.
                if i + 1 - chunkStart > leadIn { chunkStart = i + 1 - leadIn }
                continue
            }
            let silence = i - last
            // Up to the last word: a pause never makes a chunk long enough.
            let spoken = last + 1 - chunkStart
            if (silence >= minSilence && spoken >= minChunk) || silence >= longSilence {
                let cut = last + 1 + silence / 2
                cuts.append(samples(chunkStart..<cut))
                chunkStart = cut
                lastSpeech = nil
            } else if i + 1 - chunkStart >= maxChunk {
                let lo = max(chunkStart + 1, i + 1 - capSearch)
                // The quietest frame; the latest one on a tie, so the chunk stays long.
                var quietest = i
                for j in stride(from: i, through: lo, by: -1) where probabilities[j] < probabilities[quietest] {
                    quietest = j
                }
                cuts.append(samples(chunkStart..<quietest))
                chunkStart = quietest
                lastSpeech = (quietest...i).last { probabilities[$0] >= threshold }
            }
        }
        return cuts
    }

    /// The take ended: the chunk still being collected, if anything was said
    /// in it, running to the last sample.
    func finish(totalSamples: Int) -> Range<Int>? {
        guard lastSpeech != nil else { return nil }
        let start = min(chunkStart * Self.frameSamples, totalSamples)
        return start < totalSamples ? start..<totalSamples : nil
    }

    private func samples(_ frames: Range<Int>) -> Range<Int> {
        (frames.lowerBound * Self.frameSamples)..<(frames.upperBound * Self.frameSamples)
    }
}
