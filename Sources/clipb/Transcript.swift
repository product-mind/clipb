import Foundation

/// Cleans a raw Whisper transcript before it touches the pasteboard (SPEC §2.13).
/// Pure, tested.
enum Transcript {
    /// Whole-transcript phrases Whisper invents from silence or noise. Only
    /// phrases nobody dictates on their own: "okay" was here and ate real takes.
    static let hallucinations: Set<String> = [
        "thank you", "thank you very much", "thanks for watching",
        "thank you for watching", "you", "bye", "bye bye",
        "děkuji", "děkuji za pozornost", "titulky vytvořil johnyx",
    ]

    /// The text to put on the clipboard, or nil when nothing real was said.
    static func clean(_ raw: String) -> String? {
        var text = raw
        // Whisper's non-speech tags: [BLANK_AUDIO], [Music], (silence), *coughs*.
        for pattern in [#"\[[^\]]*\]"#, #"\([^)]*\)"#, #"\*[^*]*\*"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let bare = text.lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        // Punctuation only: a decode collapse, not speech.
        if bare.isEmpty || hallucinations.contains(bare) { return nil }
        return text
    }

    /// The configured language whisper finds likeliest; the first listed when
    /// it gave no probabilities.
    static func bestLanguage(_ allowed: [String], probabilities: [String: Float]) -> String? {
        allowed.max { (probabilities[$0] ?? -1) < (probabilities[$1] ?? -1) }
    }

    /// Whisper wants at least one second; shorter takes are padded with silence.
    static func padded(_ samples: [Float], sampleRate: Int = 16000) -> [Float] {
        let minimum = sampleRate + sampleRate / 10
        guard samples.count < minimum else { return samples }
        return samples + [Float](repeating: 0, count: minimum - samples.count)
    }
}
