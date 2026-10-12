import Foundation

/// Case-insensitive subsequence fuzzy matching, à la Sublime Text/VS Code,
/// ranked so longer contiguous matches come first.
enum FuzzyMatch {
    private static let substringBonus = 10_000
    private static let matchScore = 16
    private static let boundaryBonus = 8
    private static let consecutiveBonus = 20
    private static let gapStart = -3
    private static let gapExtend = -1
    private static let leadingPenaltyCap = 10
    // Alignment is O(text × query); huge clipboard values only score this much.
    private static let alignmentWindow = 2_000
    private static let impossible = Int.min / 4

    /// Returns a match score if every character of `query` appears in
    /// `text`, in order, case-insensitively — nil otherwise. Higher score
    /// is a better match. An empty query always matches with score 0.
    static func score(query: String, in text: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let queryChars = Array(query.lowercased())
        let lowered = text.lowercased()
        guard isSubsequence(queryChars, of: lowered) else { return nil }

        var total = 0
        if lowered.contains(query.lowercased()) { total += substringBonus }
        let window = Array(lowered.prefix(alignmentWindow))
        // Nil only when the match lies beyond the window; it still matched.
        return total + (alignmentScore(queryChars, window) ?? 1)
    }

    /// Whether `score` would return non-nil, without the cost of aligning.
    static func matches(query: String, in text: String) -> Bool {
        query.isEmpty || isSubsequence(Array(query.lowercased()), of: text.lowercased())
    }

    /// Items that match, best first. Equal scores keep their original order,
    /// so a recency-ordered input stays recency-ordered among ties.
    static func rank<T>(_ items: [T], query: String, text: (T) -> String) -> [T] {
        guard !query.isEmpty else { return items }
        let scored = items.enumerated().compactMap { index, item in
            score(query: query, in: text(item)).map { (index: index, score: $0, item: item) }
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map(\.item)
    }

    private static func isSubsequence(_ query: [Character], of text: String) -> Bool {
        var next = 0
        for char in text where char == query[next] {
            next += 1
            if next == query.count { return true }
        }
        return false
    }

    /// Best alignment of `query` inside `text`: rewards runs of adjacent
    /// matches and word starts, penalizes gaps and late starts.
    private static func alignmentScore(_ query: [Character], _ text: [Character]) -> Int? {
        let n = text.count, m = query.count
        guard m <= n else { return nil }

        var bonus = [Int](repeating: 0, count: n)
        for j in 0..<n where j == 0 || !(text[j - 1].isLetter || text[j - 1].isNumber) {
            bonus[j] = boundaryBonus
        }

        var previous = [Int](repeating: impossible, count: n)
        for j in 0..<n where text[j] == query[0] {
            previous[j] = matchScore + bonus[j] - min(j, leadingPenaltyCap)
        }

        for i in 1..<max(m, 1) {
            var current = [Int](repeating: impossible, count: n)
            var gapBest = impossible
            for j in 0..<n {
                var best = gapBest
                if j >= 1, previous[j - 1] > impossible / 2 {
                    best = max(best, previous[j - 1] + consecutiveBonus)
                }
                if text[j] == query[i], best > impossible / 2 {
                    current[j] = matchScore + bonus[j] + best
                }
                let decayed = gapBest > impossible / 2 ? gapBest + gapExtend : impossible
                let opened = j >= 1 && previous[j - 1] > impossible / 2 ? previous[j - 1] + gapStart : impossible
                gapBest = max(decayed, opened)
            }
            previous = current
        }

        let best = previous.max() ?? impossible
        return best > impossible / 2 ? best : nil
    }
}
