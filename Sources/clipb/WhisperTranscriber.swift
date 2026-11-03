import Foundation
import whisper

/// On-device speech to text with whisper.cpp (SPEC §2.13). The model is
/// loaded once at launch and kept warm. Every whisper call runs on `queue`
/// (a whisper context is not thread-safe); results hop to main.
final class WhisperTranscriber {
    static let modelFile = "ggml-large-v3-turbo.bin"

    /// Where the model is looked for, first hit wins: inside the app (a
    /// `make dist DIST_MODEL=…` build), ClipB's own folder (a separate
    /// download), then voxtype's copy, reused in place.
    static var modelCandidates: [String] {
        var paths: [String] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(modelFile).path { paths.append(bundled) }
        paths.append(NSString(string: "~/Library/Application Support/ClipB/models/\(modelFile)").expandingTildeInPath)
        paths.append(NSString(string: "~/Library/Application Support/voxtype/models/\(modelFile)").expandingTildeInPath)
        return paths
    }

    /// The first existing candidate; none: ClipB's own folder, named in the
    /// "No speech model" notice as where to put it.
    static func modelPath(in candidates: [String], exists: (String) -> Bool) -> String {
        candidates.first(where: exists) ?? candidates.first { $0.contains("/ClipB/models/") } ?? candidates.last ?? modelFile
    }

    static var defaultModelPath: String {
        modelPath(in: modelCandidates) { FileManager.default.fileExists(atPath: $0) }
    }

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

    /// `samples`: 16 kHz mono. `languages`: `[voice] languages`, empty for
    /// whisper's own guess. `done` runs on main with nil on failure.
    func transcribe(_ samples: [Float], languages: [String] = [], done: @escaping (Result?) -> Void) {
        queue.async { [weak self] in
            let result = self?.decode(Transcript.padded(samples), languages: languages)
            DispatchQueue.main.async { done(result) }
        }
    }

    private func decode(_ samples: [Float], languages: [String]) -> Result? {
        guard let context else { return nil }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.no_timestamps = true
        params.n_threads = Int32(min(8, ProcessInfo.processInfo.activeProcessorCount))
        let started = Date()
        let chosen = language(for: samples, among: languages, threads: params.n_threads)
        let status: Int32 = chosen.withCString { language in
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

    /// None configured: "auto", whisper picks from all it knows. One: that,
    /// no detection. Several: whisper scores every language on this audio
    /// (one extra encoder pass) and the best of the configured ones wins, so
    /// a short Czech take can't come out as Slovak or Polish.
    private func language(for samples: [Float], among languages: [String], threads: Int32) -> String {
        guard let context, languages.count > 1 else { return languages.first ?? "auto" }
        let started = Date()
        let converted = samples.withUnsafeBufferPointer {
            whisper_pcm_to_mel(context, $0.baseAddress, Int32($0.count), threads)
        }
        var probs = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
        guard converted == 0, whisper_lang_auto_detect(context, 0, threads, &probs) >= 0 else {
            return languages[0]
        }
        var scores: [String: Float] = [:]
        for code in languages {
            let id = Int(whisper_lang_id(code))
            if probs.indices.contains(id) { scores[code] = probs[id] }
        }
        let best = Transcript.bestLanguage(languages, probabilities: scores) ?? languages[0]
        devLog("whisper: language \(best) of \(languages.joined(separator: ",")) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return best
    }
}
