// ABOUTME: Subsequence fuzzy scorer for the command palette.
// ABOUTME: Pure function: higher is better, zero means no match.

import Foundation

enum FuzzyMatcher {
    /// Scores how well `query` matches `candidate`. Every character of the
    /// query must appear in the candidate in order (case-insensitive) or the
    /// score is 0. Matches at the start of the candidate, at word boundaries,
    /// and in consecutive runs score higher.
    static func score(query: String, candidate: String) -> Int {
        if query.isEmpty {
            return 1
        }
        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        var qi = 0
        var total = 0
        var streak = 0
        for (i, ch) in c.enumerated() {
            guard qi < q.count else { break }
            if ch == q[qi] {
                streak += 1
                var points = 1 + streak * 2
                if i == 0 {
                    points += 8
                } else if !(c[i - 1].isLetter || c[i - 1].isNumber) {
                    points += 6
                }
                total += points
                qi += 1
            } else {
                streak = 0
            }
        }
        return qi == q.count ? total : 0
    }
}
