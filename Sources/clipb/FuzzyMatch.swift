import Foundation

/// Case-insensitive subsequence fuzzy matching, à la Sublime Text/VS Code.
enum FuzzyMatch {
    /// Returns a match score if every character of `query` appears in
    /// `text`, in order, case-insensitively — nil otherwise. Higher score
    /// is a better match. An empty query always matches with score 0.
    static func score(query: String, in text: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let queryChars = Array(query.lowercased())
        let textChars = Array(text.lowercased())

        var qi = 0
        var score = 0
        var consecutiveBonus = 0
        for ti in 0..<textChars.count where qi < queryChars.count {
            if textChars[ti] == queryChars[qi] {
                consecutiveBonus += 1
                score += consecutiveBonus
                qi += 1
            } else {
                consecutiveBonus = 0
            }
        }
        guard qi == queryChars.count else { return nil }
        return score
    }
}
