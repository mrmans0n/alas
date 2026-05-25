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
