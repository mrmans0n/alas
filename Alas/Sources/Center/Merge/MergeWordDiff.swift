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
        let localChars = Array(local)
        let remoteChars = Array(remote)
        let (localRanges, remoteRanges) = charDiff(localChars, remoteChars)
        switch mode {
        case .off:
            return Result(localChanged: [], remoteChanged: [])
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
        }
    }

    /// Classic Myers LCS via dynamic programming, emitting per-side
    /// ranges of characters NOT in the longest common subsequence.
    /// O(N*M) time and memory; the caller caps the inputs to ~200
    /// lines worth of text so this stays under a millisecond.
    private static func charDiff(
        _ a: [Character],
        _ b: [Character]
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
