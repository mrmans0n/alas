import Foundation

/// Subsequence fuzzy match scorer ported from the source design's `fuzzy()`
/// in `file-search.jsx`. Pure, deterministic, no I/O.
///
/// Scoring rules:
///   - Each character in `query` must appear in `target` in order
///     (case-insensitive). If not, returns nil.
///   - +4 bonus when a matched character starts a new segment
///     (target index 0 or preceded by `/`, `_`, `.`, `-`).
///   - +1 bonus when the target character at the matched index is uppercase.
///   - +4 per contiguous pair of matches (two adjacent matched indices).
///   - Penalty: -0.1 per unit of span between first and last matched index.
///   - Penalty: -0.05 per unit of distance from start of target.
///
/// Matching strategy (greedy-contiguous, then segment-aware, then plain):
///   For each query character we check, in order of preference:
///   1. The immediately next position (contiguous with the previous match).
///   2. The first segment-start or uppercase position from the current offset.
///   3. The first plain match from the current offset.
///   This ensures a contiguous run like "tab" beats a scattered match like
///   "tbr" even when the scattered match would land on three segment starts.
///
/// An empty query returns `(score: 0, indices: [])` (matches anything).
enum FuzzyMatch {
    struct Result: Equatable {
        var indices: [Int]
        var score: Double
    }

    static func score(query: String, target: String) -> Result? {
        if query.isEmpty { return Result(indices: [], score: 0) }
        let q = Array(query.lowercased())
        let t = Array(target)
        let tLower = Array(target.lowercased())
        if t.isEmpty { return nil }

        // Verify the query is a subsequence at all.
        guard isSubsequence(q, of: tLower) else { return nil }

        // Find best positions using greedy-contiguous, then segment-aware.
        let indices = bestIndices(q: q, t: t, tLower: tLower)
        // bestIndices returns [] if an invariant break left a query char
        // unplaceable. In that case treat as "no match" rather than crashing.
        guard indices.count == q.count else { return nil }

        // Score the chosen placement. `pairs` accumulates contiguous-pair
        // count across ALL blocks of the match — earlier versions reset
        // on each gap and only credited the final block, so a query like
        // "abcd" against "ab_cd" (two contiguous pairs) was scored the
        // same as a single-pair scattered match.
        var pairs = 0
        var lastMatchedAt = -2
        var bonus = 0.0

        for ti in indices {
            if ti == lastMatchedAt + 1 { pairs += 1 }
            if ti == 0 || isSegmentDelimiter(tLower[ti - 1]) { bonus += 4 }
            let ch = t[ti]
            if ch.isLetter && ch.isUppercase { bonus += 1 }
            lastMatchedAt = ti
        }

        let span = Double(indices.last! - indices.first!)
        // Run bonus is 4 per contiguous pair, which lets a contiguous run of
        // 3 chars (+8) beat three separate segment-start matches (+12) only
        // when span/start penalties also apply. This balances "tab" vs "tbr"
        // in "tab_bar.rs" correctly.
        let score = bonus + Double(pairs) * 4 - span * 0.1 - Double(indices.first!) * 0.05
        return Result(indices: indices, score: score)
    }

    // MARK: - Private helpers

    private static func isSubsequence(_ q: [Character], of t: [Character]) -> Bool {
        var qi = 0
        for ch in t {
            if qi < q.count, ch == q[qi] { qi += 1 }
        }
        return qi == q.count
    }

    /// For each query character, chooses the best matching position:
    ///   1. Contiguous with the previous match (highest priority).
    ///   2. First segment-start or uppercase match from searchFrom that
    ///      doesn't strand the remainder of the query.
    ///   3. First plain match from searchFrom (fallback).
    ///
    /// The lookahead in (1) and (2) is important: greedily taking a
    /// later "preferred" position can skip past the only viable plain
    /// match, leaving the rest of the query unmatchable. We verify with
    /// `canMatchRemainder` before committing to a non-plain position.
    private static func bestIndices(q: [Character], t: [Character], tLower: [Character]) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(q.count)
        var searchFrom = 0
        var lastChosen = -2

        for qi in 0..<q.count {
            let qChar = q[qi]

            // 1. Contiguous check: if the immediate next position matches AND
            // the remainder is still placeable, take it.
            let contiguousPos = lastChosen + 1
            if contiguousPos < t.count,
               contiguousPos >= searchFrom,
               tLower[contiguousPos] == qChar,
               canMatchRemainder(q: q, qFrom: qi + 1, t: tLower, tFrom: contiguousPos + 1) {
                result.append(contiguousPos)
                lastChosen = contiguousPos
                searchFrom = contiguousPos + 1
                continue
            }

            // 2. Look for a segment-start or uppercase match from searchFrom
            // that doesn't strand the remainder.
            var preferred: Int? = nil
            var plain: Int? = nil

            for ti in searchFrom..<t.count {
                guard tLower[ti] == qChar else { continue }
                if plain == nil { plain = ti }
                let isSegStart = (ti == 0 || isSegmentDelimiter(tLower[ti - 1]))
                let isCap = t[ti].isLetter && t[ti].isUppercase
                if isSegStart || isCap,
                   canMatchRemainder(q: q, qFrom: qi + 1, t: tLower, tFrom: ti + 1) {
                    preferred = ti
                    break
                }
            }

            // `plain` is guaranteed non-nil whenever `isSubsequence` succeeded
            // and we have only ever advanced past positions whose remainder
            // was reachable — but defend against an invariant break instead
            // of force-unwrapping.
            guard let chosen = preferred ?? plain else { return [] }
            result.append(chosen)
            lastChosen = chosen
            searchFrom = chosen + 1
        }

        return result
    }

    /// True iff `q[qFrom...]` is a subsequence of `t[tFrom...]`.
    private static func canMatchRemainder(
        q: [Character], qFrom: Int,
        t: [Character], tFrom: Int
    ) -> Bool {
        var qi = qFrom
        var ti = tFrom
        while qi < q.count, ti < t.count {
            if t[ti] == q[qi] { qi += 1 }
            ti += 1
        }
        return qi == q.count
    }

    private static func isSegmentDelimiter(_ c: Character) -> Bool {
        c == "/" || c == "_" || c == "." || c == "-"
    }
}
