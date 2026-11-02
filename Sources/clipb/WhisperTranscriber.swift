import Foundation
import whisper

/// On-device speech to text with whisper.cpp (SPEC §2.13). The model is
/// loaded once at launch and kept warm. Every whisper call runs on `queue`
/// (a whisper context is not thread-safe); results hop to main.
final class WhisperTranscriber {
    /// voxtype's copy, reused in place: no second 574 MB download.
    static let defaultModelPath = NSString(
        string: "~/Library/Application Support/voxtype/models/ggml-large-v3-turbo.bin"
    ).expandingTildeInPath

    struct Result {
        let text: String
        let language: String
        let milliseconds: Int
    }

    private let queue = DispatchQueue(label: "clipb.whisper", qos: .userInitiated)
    private var context: OpaquePointer?

    /// Main thread: true once `load` succeeded.
    private(set) var isReady = false

    func load(path: String = defaultModelPath, done: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            // Only the backend choice is logged, never text: "Metal linked"
            // proved nothing for voxtype, so show what actually ran.
            whisper_log_set({ _, text, _ in
                guard let text else { return }
                let line = String(cString: text)
                if line.contains("backend") || line.contains("GPU") || line.contains("model size") {
                    devLog("whisper: \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }, nil)
            var params = whisper_context_default_params()
            params.use_gpu = true
            params.flash_attn = true
            let started = Date()
            let context = FileManager.default.fileExists(atPath: path)
                ? whisper_init_from_file_with_params(path, params) : nil
            devLog("whisper: load \(context == nil ? "failed" : "ok") in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            self?.context = context
            DispatchQueue.main.async {
                self?.isReady = context != nil
                done(context != nil)
            }
        }
    }

    /// `samples`: 16 kHz mono. `done` runs on main with nil on failure.
    func transcribe(_ samples: [Float], done: @escaping (Result?) -> Void) {
        queue.async { [weak self] in
            let result = self?.decode(Transcript.padded(samples))
            DispatchQueue.main.async { done(result) }
        }
    }

    private func decode(_ samples: [Float]) -> Result? {
        guard let context else { return nil }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.no_timestamps = true
        params.n_threads = Int32(min(8, ProcessInfo.processInfo.activeProcessorCount))
        let started = Date()
        let status: Int32 = "auto".withCString { language in
            params.language = language
            return samples.withUnsafeBufferPointer {
                whisper_full(context, params, $0.baseAddress, Int32($0.count))
            }
        }
        guard status == 0 else { return nil }
        var text = ""
        for i in 0..<whisper_full_n_segments(context) {
            if let segment = whisper_full_get_segment_text(context, i) {
                text += String(cString: segment)
            }
        }
        let language = whisper_lang_str(whisper_full_lang_id(context)).map { String(cString: $0) } ?? "?"
        return Result(text: text, language: language,
                      milliseconds: Int(Date().timeIntervalSince(started) * 1000))
    }
}
