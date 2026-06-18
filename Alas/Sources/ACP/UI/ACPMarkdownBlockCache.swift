import Foundation

/// Incrementally parses streaming markdown. Promotes already-completed
/// prefix into `stableBlocks` at every blank line that lies outside a
/// fenced code block. Only the un-promoted tail is
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
    private var promotionScanner = PromotionScanner()

    #if DEBUG
    private(set) var promotionScanCharacterCountForTests = 0
    #endif

    #if DEBUG
    /// Approximate UTF-8 byte size of the retained text + a small per-stable-block
    /// constant covering the parsed AST overhead. Used by `MemoryDiagnostics`.
    var byteEstimate: UInt64 {
        UInt64(lastFullText.utf8.count) + UInt64(stableBlocks.count) * 128
    }
    #endif

    func update(with full: String) {
        // Detect non-extending updates and reset.
        let extendsPreviousFullText = full.hasPrefix(lastFullText)
        if !extendsPreviousFullText {
            stableBlocks = []
            stablePrefixLength = 0
            promotionScanner.reset()
        }
        let previousTailLength = tailUnparsed.count
        lastFullText = full
        tailUnparsed = String(full.dropFirst(stablePrefixLength))
        if extendsPreviousFullText {
            let appended = tailUnparsed.dropFirst(previousTailLength)
            scanPromotionTail(String(appended), startingAt: previousTailLength)
        } else {
            promotionScanner.reset()
            scanPromotionTail(tailUnparsed, startingAt: 0)
        }
        promoteIfPossible()
    }

    /// Walk tailUnparsed; find the latest blank line outside fenced code
    /// blocks. Everything up to and including that
    /// blank line gets parsed once and frozen.
    private func promoteIfPossible() {
        guard let safeEnd = promotionScanner.lastSafeEnd else {
            return
        }
        let promoted = String(tailUnparsed.prefix(safeEnd))
        let newBlocks = ACPMarkdownText.parse(promoted)
        stableBlocks.append(contentsOf: newBlocks)
        stablePrefixLength += promoted.count
        tailUnparsed = String(tailUnparsed.dropFirst(safeEnd))
        promotionScanner.reset()
        scanPromotionTail(tailUnparsed, startingAt: 0)
    }

    private func scanPromotionTail(_ text: String, startingAt offset: Int) {
        #if DEBUG
        promotionScanCharacterCountForTests += text.count
        #endif
        promotionScanner.scan(text, startingAt: offset)
    }

    /// Returns the offset (Int count of Characters) just past the last
    /// blank line at fence depth zero, or nil if no such boundary
    /// exists yet. Operates over `text` only — does not see prior
    /// stable prefix; for streaming, "fence at start of tail" implies
    /// the prior stable parse closed any earlier fences.
    nonisolated static func lastSafePromotionIndex(in text: String) -> Int? {
        var openingFence: FenceDelimiter?
        var lastSafeEnd: Int? = nil
        var line = ""
        var idx = 0
        for ch in text {
            if ch == "\n" {
                if let currentFence = openingFence {
                    if closesFence(line, currentFence) {
                        openingFence = nil
                    }
                } else if let fence = matchFence(line) {
                    openingFence = fence
                }
                if line.trimmingCharacters(in: .whitespaces).isEmpty && openingFence == nil {
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

    private struct FenceDelimiter {
        let marker: Character
        let length: Int
    }

    private struct PromotionScanner {
        private(set) var lastSafeEnd: Int?
        private var openingFence: FenceDelimiter?
        private var line = ""

        mutating func reset() {
            lastSafeEnd = nil
            openingFence = nil
            line = ""
        }

        mutating func scan(_ text: String, startingAt offset: Int) {
            var idx = offset
            for ch in text {
                if ch == "\n" {
                    if let currentFence = openingFence {
                        if closesFence(line, currentFence) {
                            openingFence = nil
                        }
                    } else if let fence = matchFence(line) {
                        openingFence = fence
                    }
                    if line.trimmingCharacters(in: .whitespaces).isEmpty && openingFence == nil {
                        lastSafeEnd = idx + 1 // include the newline
                    }
                    line = ""
                } else {
                    line.append(ch)
                }
                idx += 1
            }
        }
    }

    nonisolated private static func matchFence(_ line: String) -> FenceDelimiter? {
        var index = line.startIndex
        var leadingSpaces = 0
        while index < line.endIndex, line[index] == " " {
            leadingSpaces += 1
            guard leadingSpaces <= 3 else { return nil }
            index = line.index(after: index)
        }
        guard index < line.endIndex else { return nil }
        let fenceText = line[index...]
        guard let marker = fenceText.first, marker == "`" || marker == "~" else { return nil }
        let length = fenceText.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }
        return FenceDelimiter(marker: marker, length: length)
    }

    nonisolated private static func closesFence(_ line: String, _ openingFence: FenceDelimiter) -> Bool {
        var index = line.startIndex
        var leadingSpaces = 0
        while index < line.endIndex, line[index] == " " {
            leadingSpaces += 1
            guard leadingSpaces <= 3 else { return false }
            index = line.index(after: index)
        }
        guard index < line.endIndex, line[index] == openingFence.marker else { return false }
        let markerCount = line[index...].prefix(while: { $0 == openingFence.marker }).count
        guard markerCount >= openingFence.length else { return false }
        let afterMarker = line.index(index, offsetBy: markerCount)
        return line[afterMarker...].allSatisfy(\.isWhitespace)
    }
}
