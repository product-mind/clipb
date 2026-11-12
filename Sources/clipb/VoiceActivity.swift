import Foundation
import whisper

/// Silero voice activity detection, from the whisper.cpp ClipB already links
/// (SPEC §2.13): where the speech is, so a take can be cut at its pauses.
///
/// CPU only, one thread, on its own serial queue: the model is ~1 MB and an
/// LSTM over 32 ms frames, far below what a GPU dispatch costs, and the GPU
/// stays free for whisper. Streaming: the LSTM state carries from one call to
/// the next, so audio is fed as it arrives; `reset` starts a new take.
final class VoiceActivity {
    /// whisper.cpp's name for the file, then voxtype's copy of it.
    static let modelFiles = ["ggml-silero-v5.1.2.bin", "ggml-silero-vad.bin"]

    /// Same places as the speech model (`WhisperTranscriber.modelCandidates`).
    static var modelCandidates: [String] {
        var paths: [String] = []
        for file in modelFiles {
            if let bundled = Bundle.main.resourceURL?.appendingPathComponent(file).path { paths.append(bundled) }
            paths.append(NSString(string: "~/Library/Application Support/ClipB/models/\(file)").expandingTildeInPath)
            paths.append(NSString(string: "~/Library/Application Support/voxtype/models/\(file)").expandingTildeInPath)
        }
        return paths
    }

    private let queue = DispatchQueue(label: "clipb.vad", qos: .userInitiated)
    private var context: OpaquePointer?

    /// Main thread: true once `load` succeeded.
    private(set) var isReady = false

    func load(done: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            var params = whisper_vad_default_context_params()
            params.n_threads = 1
            params.use_gpu = false
            let path = Self.modelCandidates.first { FileManager.default.fileExists(atPath: $0) }
            let context = path.flatMap { whisper_vad_init_from_file_with_params($0, params) }
            devLog("vad: \(context == nil ? "no model (\(Self.modelFiles.joined(separator: " or ")))" : "loaded")")
            self?.context = context
            DispatchQueue.main.async {
                self?.isReady = context != nil
                done(context != nil)
            }
        }
    }

    /// A new take: forget the previous one's LSTM state.
    func reset() {
        queue.async { [weak self] in
            guard let context = self?.context else { return }
            whisper_vad_reset_state(context)
        }
    }

    /// One speech probability per `SpeechSegmenter.frameSamples` of
    /// `samples`, whose count must be a multiple of it. `done` runs on main,
    /// with an empty array on failure.
    func probabilities(_ samples: [Float], done: @escaping ([Float]) -> Void) {
        queue.async { [weak self] in
            var result: [Float] = []
            if let context = self?.context, !samples.isEmpty {
                let ok = samples.withUnsafeBufferPointer {
                    whisper_vad_detect_speech_no_reset(context, $0.baseAddress, Int32($0.count))
                }
                if ok, let probs = whisper_vad_probs(context) {
                    let count = min(Int(whisper_vad_n_probs(context)), samples.count / SpeechSegmenter.frameSamples)
                    result = Array(UnsafeBufferPointer(start: probs, count: count))
                }
            }
            DispatchQueue.main.async { done(result) }
        }
    }
}
