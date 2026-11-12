import Foundation

/// One take, transcribed while it is still being recorded (SPEC §2.13).
///
/// Every `tick` the audio recorded since the last tick goes through Silero
/// (`VoiceActivity`); each chunk `SpeechSegmenter` cuts at a pause goes to
/// whisper at once, so a long take is mostly transcribed by the time it
/// stops. Chunks are decoded one at a time, in order, each prompted with the
/// text before it. Without a VAD model the take is one chunk at the end, as
/// before.
///
/// Main thread only. Audio stays in memory; no text is logged.
final class DictationStream {
    static let tick: TimeInterval = 0.25

    /// Each chunk's cleaned text, in order, as soon as it is decoded.
    var onText: ((String) -> Void)?

    private let recorder: AudioRecorder
    private let vad: VoiceActivity?
    private let transcriber: WhisperTranscriber
    private let languages: [String]
    private var segmenter = SpeechSegmenter()
    private var timer: Timer?
    /// Samples handed to VAD so far.
    private var fed = 0
    private var vadBusy = false
    /// Cut but not yet decoded, in order.
    private var waiting: [Range<Int>] = []
    private var decoding = false
    private var texts: [String] = []
    private var chunkCount = 0
    /// The take's audio once the mic closed; before that it is read live.
    private var finalSamples: [Float]?
    private var finished: ((String?) -> Void)?
    private var tailQueued = false
    private var cancelled = false

    init(recorder: AudioRecorder, vad: VoiceActivity?, transcriber: WhisperTranscriber, languages: [String]) {
        self.recorder = recorder
        self.vad = vad
        self.transcriber = transcriber
        self.languages = languages
    }

    func start() {
        guard let vad else { return }
        vad.reset()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in self?.detect() }
    }

    /// The mic closed with `samples`, the whole take. `done` gets every
    /// chunk's text joined, nil when nothing was said.
    func finish(samples: [Float], done: @escaping (String?) -> Void) {
        timer?.invalidate()
        timer = nil
        finalSamples = samples
        finished = done
        detect()
    }

    /// Esc or a failed take: nothing more is decoded or delivered.
    func cancel() {
        cancelled = true
        timer?.invalidate()
        timer = nil
        waiting = []
        finished = nil
        onText = nil
    }

    /// Feeds the audio VAD hasn't seen, whole frames only while recording;
    /// after the stop, the tail too, padded to a frame.
    private func detect() {
        guard !cancelled, !vadBusy else { return }
        guard let vad else {
            if let finalSamples { closeTake(total: finalSamples.count, lastChunk: 0..<finalSamples.count) }
            return
        }
        let available = finalSamples?.count ?? recorder.sampleCount
        let frame = SpeechSegmenter.frameSamples
        var batch: [Float]
        if finalSamples != nil {
            guard !tailQueued else { return }
            tailQueued = true
            batch = samples(in: fed..<available)
            let padding = (frame - batch.count % frame) % frame
            batch += [Float](repeating: 0, count: padding)
        } else {
            let whole = (available - fed) / frame * frame
            guard whole > 0 else { return }
            batch = samples(in: fed..<(fed + whole))
        }
        fed += batch.count
        vadBusy = true
        let isTail = finalSamples != nil
        vad.probabilities(batch) { [weak self] probabilities in
            guard let self, !cancelled else { return }
            vadBusy = false
            for cut in segmenter.feed(probabilities) { enqueue(cut) }
            if isTail {
                let total = available
                closeTake(total: total, lastChunk: segmenter.finish(totalSamples: total))
            } else if finalSamples != nil {
                // The mic closed while this batch was out: now the tail.
                detect()
            }
        }
    }

    private func closeTake(total: Int, lastChunk: Range<Int>?) {
        if let lastChunk { enqueue(lastChunk) }
        tailQueued = true
        finishIfDone()
    }

    private func enqueue(_ range: Range<Int>) {
        waiting.append(range)
        decodeNext()
    }

    private func decodeNext() {
        guard !cancelled, !decoding, !waiting.isEmpty else { return }
        let range = waiting.removeFirst()
        let audio = samples(in: range)
        chunkCount += 1
        let index = chunkCount
        decoding = true
        transcriber.transcribe(audio, languages: languages, prompt: Transcript.prompt(after: texts)) { [weak self] result in
            guard let self, !cancelled else { return }
            decoding = false
            // Lengths and timings only: the transcript is a clipboard value.
            devLog("voice: chunk \(index) \(audio.count / 16) ms audio, decode \(result?.milliseconds ?? -1) ms, "
                + "lang \(result?.language ?? "-"), \(result?.text.count ?? 0) chars")
            if let text = result.flatMap({ Transcript.clean($0.text) }) {
                texts.append(text)
                onText?(text)
            }
            decodeNext()
            finishIfDone()
        }
    }

    private func finishIfDone() {
        guard tailQueued, !vadBusy, !decoding, waiting.isEmpty, let done = finished else { return }
        finished = nil
        done(Transcript.joined(texts))
    }

    private func samples(in range: Range<Int>) -> [Float] {
        guard let finalSamples else { return recorder.samples(in: range) }
        return Array(finalSamples[range.clamped(to: 0..<finalSamples.count)])
    }
}
