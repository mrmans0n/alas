import Foundation

/// Pure character-or-word level diff between two strings. Used by the
/// 3-way merge editor to highlight which characters inside a conflict
/// hunk differ between the LOCAL and REMOTE versions. No SwiftUI / no
/// AppKit dependencies; safe to call from any thread.
enum MergeWordDiff {
    enum Mode: String, CaseIterable {
        case off
        case characters
        case words
    }

    struct Result: Equatable {
        let localChanged: [NSRange]
        let remoteChanged: [NSRange]
    }

    static func diff(local: String, remote: String, mode: Mode) -> Result {
        guard mode != .off, local != remote else {
            return Result(localChanged: [], remoteChanged: [])
        }
        // Bound the DP table to ~4MB (1024 * 1024 cells × 8 bytes/Int).
        // For long-line conflicts (lockfiles, minified JSON, base64
        // blobs) the quadratic cost spikes pathologically. Above the
        // cap, fall back to the hunk-level tint only — no character
        // overlay. The line-level diff is a nice-to-have, not a
        // correctness requirement.
        let maxLineLength = 1024
        guard local.utf16.count <= maxLineLength,
              remote.utf16.count <= maxLineLength else {
            return Result(localChanged: [], remoteChanged: [])
        }
        let localUnits = Array(local.utf16)
        let remoteUnits = Array(remote.utf16)
        let (localRanges, remoteRanges) = charDiff(localUnits, remoteUnits)
        switch mode {
        case .characters:
            return Result(
                localChanged: mergeAdjacent(localRanges),
                remoteChanged: mergeAdjacent(remoteRanges)
            )
        case .words:
            return Result(
                localChanged: mergeOverlapping(snapToWordBoundaries(in: local, ranges: mergeAdjacent(localRanges))),
                remoteChanged: mergeOverlapping(snapToWordBoundaries(in: remote, ranges: mergeAdjacent(remoteRanges)))
            )
        default:
            return Result(localChanged: [], remoteChanged: [])
        }
    }

    struct HunkResult: Equatable {
        /// Changed ranges per LOCAL hunk line, indexed like the hunk's lines.
        let local: [[NSRange]]
        let remote: [[NSRange]]
        /// False when the cell budget ran out before every pair was diffed.
        var isComplete = true
    }

    /// Two differing lines must share at least this fraction of their
    /// characters before intra-line changes are highlighted.
    static let minimumPairSimilarity = 0.5

    /// Upper bound on DP cells spent on one hunk, across line pairing and
    /// character diffs. The marks are computed on the main actor while the
    /// view renders, so a hunk of hundreds of long similar lines must
    /// degrade to partial marks rather than stall the UI.
    static let hunkCellBudget = 2_000_000

    /// Upper bound on DP cells spent computing marks for a whole file in
    /// one render. Hunks past it stay unmarked until a later render.
    static let fileCellBudget = 6_000_000

    /// Intra-line changes for a whole conflict hunk. Identical lines are
    /// matched first (line-level LCS); within each gap between matches, every
    /// LOCAL line pairs with its most similar REMOTE line, keeping order.
    /// Pairs below `minimumPairSimilarity` are unrelated rewrites and get no
    /// marks, since highlighting them would just be noise.
    static func hunk(local: [String], remote: [String], mode: Mode) -> HunkResult {
        var budget = hunkCellBudget
        return hunk(local: local, remote: remote, mode: mode, budget: &budget)
    }

    /// Same as `hunk(local:remote:mode:)`, drawing DP cells from `budget`
    /// so callers can bound the work across many hunks. A negative budget
    /// on return means it ran out.
    static func hunk(local: [String], remote: [String], mode: Mode, budget: inout Int) -> HunkResult {
        var localRanges = Array(repeating: [NSRange](), count: local.count)
        var remoteRanges = Array(repeating: [NSRange](), count: remote.count)
        let maxHunkLines = 400
        guard mode != .off, !local.isEmpty, !remote.isEmpty,
              local.count <= maxHunkLines, remote.count <= maxHunkLines
        else { return HunkResult(local: localRanges, remote: remoteRanges) }

        guard local.count * remote.count <= budget else {
            budget = -1
            return HunkResult(local: localRanges, remote: remoteRanges, isComplete: false)
        }
        budget -= local.count * remote.count
        for (i, j) in pairedLines(local, remote, budget: &budget) {
            let cost = local[i].utf16.count * remote[j].utf16.count
            guard cost <= budget else {
                budget = -1
                break
            }
            budget -= cost
            let result = diff(local: local[i], remote: remote[j], mode: mode)
            localRanges[i] = result.localChanged
            remoteRanges[j] = result.remoteChanged
        }
        return HunkResult(local: localRanges, remote: remoteRanges, isComplete: budget >= 0)
    }

    /// Fraction of both lines' tokens (identifiers, numbers, punctuation
    /// runs) they share in order. Token-level so two unrelated sentences
    /// don't look similar just because they share common letters.
    /// Returns nil once `budget` can't cover the comparison.
    private static func similarity(_ a: String, _ b: String, budget: inout Int) -> Double? {
        // Same length cap as `diff`: longer lines (minified or generated
        // code) never get marks, so don't spend a tokenizing pass on them.
        // `utf8.count` is O(1) for native strings.
        guard a.utf8.count <= 4 * 1024, b.utf8.count <= 4 * 1024 else { return 0 }
        let ta = tokens(a), tb = tokens(b)
        let total = ta.count + tb.count
        guard total > 0 else { return 1 }
        guard ta.count <= 256, tb.count <= 256 else { return 0 }
        guard ta.count * tb.count <= budget else {
            budget = -1
            return nil
        }
        budget -= ta.count * tb.count
        var previous = Array(repeating: 0, count: tb.count + 1)
        for x in ta {
            var row = Array(repeating: 0, count: tb.count + 1)
            for (j, y) in tb.enumerated() {
                row[j + 1] = x == y ? previous[j] + 1 : max(previous[j + 1], row[j])
            }
            previous = row
        }
        return Double(2 * previous[tb.count]) / Double(total)
    }

    private static func tokens(_ s: String) -> [Substring] {
        var result: [Substring] = []
        var start: String.Index?
        var startIsWord = false
        for index in s.indices {
            let ch = s[index]
            if ch.isWhitespace {
                if let st = start { result.append(s[st ..< index]); start = nil }
                continue
            }
            let isWord = ch.isLetter || ch.isNumber || ch == "_"
            if let st = start, isWord != startIsWord {
                result.append(s[st ..< index])
                start = nil
            }
            if start == nil {
                start = index
                startIsWord = isWord
            }
        }
        if let st = start { result.append(s[st...]) }
        return result
    }

    private static func pairedLines(_ a: [String], _ b: [String], budget: inout Int) -> [(Int, Int)] {
        let n = a.count, m = b.count
        // Intern lines once so the LCS compares integers: comparing long
        // lines pairwise would cost O(n * m * line length).
        var ids: [String: Int] = [:]
        let aIDs = a.map { line -> Int in
            if let id = ids[line] { return id }
            let id = ids.count
            ids[line] = id
            return id
        }
        let bIDs = b.map { ids[$0] ?? -1 }
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = aIDs[i] == bIDs[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var gapA: [Int] = []
        var gapB: [Int] = []
        func flushGap() {
            defer {
                gapA.removeAll()
                gapB.removeAll()
            }
            guard !gapA.isEmpty, !gapB.isEmpty, gapA.count * gapB.count <= 400 else { return }
            var next = 0
            for i in gapA where next < gapB.count {
                var best: (index: Int, score: Double)?
                for k in next ..< gapB.count {
                    guard let score = similarity(a[i], b[gapB[k]], budget: &budget) else { return }
                    if score >= minimumPairSimilarity, score > (best?.score ?? 0) {
                        best = (k, score)
                    }
                }
                if let best {
                    pairs.append((i, gapB[best.index]))
                    next = best.index + 1
                }
            }
        }
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, aIDs[i] == bIDs[j] {
                flushGap()
                i += 1
                j += 1
            } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
                gapB.append(j)
                j += 1
            } else {
                gapA.append(i)
                i += 1
            }
        }
        flushGap()
        return pairs
    }

    /// Classic Myers LCS via dynamic programming, emitting per-side
    /// UTF-16-unit ranges NOT in the longest common subsequence.
    /// O(N*M) time and memory.  `MergeResultPane.buildAttributedString`
    /// calls this per hunk-line pair (typically 5–20 lines, ≤60 UTF-16
    /// units each side), so N and M are at most ~1 200 units and the
    /// LCS table fits comfortably within ~11 MB.  Returned `NSRange`
    /// values are UTF-16 offsets, matching `NSString.substring(with:)`.
    private static func charDiff(
        _ a: [Unicode.UTF16.CodeUnit],
        _ b: [Unicode.UTF16.CodeUnit]
    ) -> (aChanged: [NSRange], bChanged: [NSRange]) {
        let n = a.count, m = b.count
        if n == 0 { return ([], [NSRange(location: 0, length: m)]) }
        if m == 0 { return ([NSRange(location: 0, length: n)], []) }
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0 ..< n {
            for j in 0 ..< m {
                if a[i] == b[j] {
                    lcs[i + 1][j + 1] = lcs[i][j] + 1
                } else {
                    lcs[i + 1][j + 1] = max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var aChanged: [NSRange] = []
        var bChanged: [NSRange] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, a[i - 1] == b[j - 1] {
                i -= 1
                j -= 1
            } else if j > 0, (i == 0 || lcs[i][j - 1] >= lcs[i - 1][j]) {
                bChanged.append(NSRange(location: j - 1, length: 1))
                j -= 1
            } else {
                aChanged.append(NSRange(location: i - 1, length: 1))
                i -= 1
            }
        }
        return (aChanged.reversed(), bChanged.reversed())
    }

    /// Coalesces adjacent single-char ranges into longer ones.
    /// `[(0,1), (1,1), (3,1)]` -> `[(0,2), (3,1)]`.
    private static func mergeAdjacent(_ ranges: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        var out: [NSRange] = [ranges[0]]
        for r in ranges.dropFirst() {
            let last = out[out.count - 1]
            if r.location == NSMaxRange(last) {
                out[out.count - 1] = NSRange(location: last.location, length: last.length + r.length)
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// Merges overlapping or adjacent ranges into the smallest set of
    /// non-overlapping ranges. Required after word-boundary snapping
    /// because multiple char-level changes can snap to the same word.
    private static func mergeOverlapping(_ ranges: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.location < $1.location }
        var out: [NSRange] = [sorted[0]]
        for r in sorted.dropFirst() {
            let last = out[out.count - 1]
            if r.location <= NSMaxRange(last) {
                let newEnd = max(NSMaxRange(last), NSMaxRange(r))
                out[out.count - 1] = NSRange(location: last.location, length: newEnd - last.location)
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// Expands each range to the surrounding word boundaries so changed
    /// runs span whole identifiers rather than partial characters.
    private static func snapToWordBoundaries(in string: String, ranges: [NSRange]) -> [NSRange] {
        let ns = string as NSString
        let length = ns.length
        let wordChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return ranges.map { range in
            var start = range.location
            var end = NSMaxRange(range)
            while start > 0 {
                let ch = ns.character(at: start - 1)
                if let scalar = UnicodeScalar(ch), wordChars.contains(scalar) {
                    start -= 1
                } else {
                    break
                }
            }
            while end < length {
                let ch = ns.character(at: end)
                if let scalar = UnicodeScalar(ch), wordChars.contains(scalar) {
                    end += 1
                } else {
                    break
                }
            }
            return NSRange(location: start, length: end - start)
        }
    }
}
