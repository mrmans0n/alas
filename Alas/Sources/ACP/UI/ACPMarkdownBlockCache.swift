import Foundation

/// Incrementally parses streaming markdown. Promotes already-completed
/// prefix into `stableBlocks` at every blank line that lies outside a
/// fenced code block (fence depth zero). Only the un-promoted tail is
/// re-parsed on each streaming chunk.
///
/// Behavior-preserving: `stableBlocks + ACPMarkdownText.parse(tailUnparsed)`
/// must equal `ACPMarkdownText.parse(fullText)` for any prefix-extending
/// stream. If a chunk arrives that does NOT extend the previous text
/// (e.g. the message was edited or replaced), the cache resets.
@MainActor
final class ACPMarkdownBlockCache {
    private(set) var stableBlocks: [ACPMarkdownText.Block] = []
    private(set) var tailUnparsed: String = ""
    private var stablePrefixLength: Int = 0
    private var lastFullText: String = ""

    #if DEBUG
    /// Approximate UTF-8 byte size of the retained text + a small per-stable-block
    /// constant covering the parsed AST overhead. Used by `MemoryDiagnostics`.
    var byteEstimate: UInt64 {
        UInt64(lastFullText.utf8.count) + UInt64(stableBlocks.count) * 128
    }
    #endif

    func update(with full: String) {
        // Detect non-extending updates and reset.
        if !full.hasPrefix(lastFullText) {
            stableBlocks = []
            stablePrefixLength = 0
        }
        lastFullText = full
        tailUnparsed = String(full.dropFirst(stablePrefixLength))
        promoteIfPossible()
    }

    /// Walk tailUnparsed; find the latest blank line at fence depth zero
    /// (counting ```-fenced blocks). Everything up to and including that
    /// blank line gets parsed once and frozen.
    private func promoteIfPossible() {
        guard let safeEnd = ACPMarkdownBlockCache.lastSafePromotionIndex(in: tailUnparsed) else {
            return
        }
        let promoted = String(tailUnparsed.prefix(safeEnd))
        let newBlocks = ACPMarkdownText.parse(promoted)
        stableBlocks.append(contentsOf: newBlocks)
        stablePrefixLength += promoted.count
        tailUnparsed = String(tailUnparsed.dropFirst(safeEnd))
    }

    /// Returns the offset (Int count of Characters) just past the last
    /// blank line at fence depth zero, or nil if no such boundary
    /// exists yet. Operates over `text` only — does not see prior
    /// stable prefix; for streaming, "fence at start of tail" implies
    /// the prior stable parse closed any earlier fences.
    static func lastSafePromotionIndex(in text: String) -> Int? {
        var fenceDepth = 0
        var lastSafeEnd: Int? = nil
        var line = ""
        var idx = 0
        for ch in text {
            if ch == "\n" {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") {
                    fenceDepth = (fenceDepth == 0) ? 1 : 0
                }
                if trimmed.isEmpty && fenceDepth == 0 {
                    lastSafeEnd = idx + 1 // include the newline
                }
                line = ""
            } else {
                line.append(ch)
            }
            idx += 1
        }
        return lastSafeEnd
    }
}
