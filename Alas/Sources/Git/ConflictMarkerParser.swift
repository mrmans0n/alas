import Foundation

/// A region inside a file that may contain conflict markers.
enum ConflictRegion: Equatable {
    case text(String)
    case conflict(ConflictBlock)
}

/// One `<<<<<<< … >>>>>>>` block, optionally with a `|||||||` base section.
struct ConflictBlock: Equatable {
    let local: String                       // content of the "ours" half (with trailing \n)
    let base: String?                       // content of the |||||||  half, or nil for merge style
    let remote: String                      // content of the "theirs" half (with trailing \n)
    let localLabel: String                  // text after `<<<<<<< `
    let remoteLabel: String                 // text after `>>>>>>> `
    let lineRangeInMerged: ClosedRange<Int> // 0-indexed line range covering markers in the source
}

/// Splits a file's text into `[ConflictRegion]`. Pure / synchronous /
/// no I/O. Trusts the input — only run this on files that git reports
/// as unmerged.
enum ConflictMarkerParser {
    private static let beginMarker = "<<<<<<< "
    private static let baseMarker  = "||||||| "
    private static let midMarker   = "======="
    private static let endMarker   = ">>>>>>> "

    static func parse(_ source: String) -> [ConflictRegion] {
        // Preserve trailing-newline semantics: split keeping empty trailing element.
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" })
        var result: [ConflictRegion] = []
        var pendingText: [Substring] = []
        var i = 0

        func flushText(atEndOfFile: Bool = false) {
            guard !pendingText.isEmpty else { return }
            // pendingText is from split(omittingEmptySubsequences: false).
            // When we encounter a conflict marker, all pending text lines had
            // newlines after them in the original (because they weren't conflict markers).
            // At end of file, respect the original trailing state.
            let joined = pendingText.map(String.init).joined(separator: "\n")
            if atEndOfFile {
                // Preserve the original trailing-newline state.
                // If pendingText ends with "", source had trailing \n.
                result.append(.text(joined))
            } else {
                // Text before a conflict always needs a trailing \n.
                result.append(.text(joined + "\n"))
            }
            pendingText.removeAll(keepingCapacity: true)
        }

        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix(beginMarker) {
                // Find the matching `=======` and `>>>>>>>`. Track an
                // intermediate `|||||||` base section if present.
                let beginIndex = i
                var midIndex: Int? = nil
                var baseIndex: Int? = nil
                var endIndex: Int? = nil
                var j = i + 1
                while j < lines.count {
                    let l = lines[j]
                    if midIndex == nil && l.hasPrefix(baseMarker) {
                        baseIndex = j
                    } else if midIndex == nil && l == midMarker {
                        midIndex = j
                    } else if l.hasPrefix(endMarker) {
                        endIndex = j
                        break
                    }
                    j += 1
                }
                guard let mid = midIndex, let end = endIndex else {
                    // Malformed: no matching closing markers. Emit the rest
                    // as plain text and stop conflict scanning.
                    for k in i ..< lines.count { pendingText.append(lines[k]) }
                    i = lines.count
                    break
                }
                flushText()
                let localLabel = String(line.dropFirst(beginMarker.count))
                let remoteLabel = String(lines[end].dropFirst(endMarker.count))

                // Helper to extract a half: empty range → "", non-empty → text + "\n"
                func extractHalf(_ range: Range<Int>) -> String {
                    let slice = lines[range].map(String.init)
                    return slice.isEmpty ? "" : slice.joined(separator: "\n") + "\n"
                }

                // Local half: lines (beginIndex+1) ..< (baseIndex ?? mid)
                let localUpper = baseIndex ?? mid
                let localText = extractHalf((beginIndex + 1) ..< localUpper)
                let baseText: String? = baseIndex.map { extractHalf(($0 + 1) ..< mid) }
                let remoteText = extractHalf((mid + 1) ..< end)
                let block = ConflictBlock(
                    local: localText,
                    base: baseText,
                    remote: remoteText,
                    localLabel: localLabel,
                    remoteLabel: remoteLabel,
                    lineRangeInMerged: beginIndex ... end
                )
                result.append(.conflict(block))
                i = end + 1
            } else {
                pendingText.append(line)
                i += 1
            }
        }
        flushText(atEndOfFile: true)
        return result
    }
}
