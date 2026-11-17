import AlasHighlight
import Foundation
import Testing

struct HighlightChunksTests {
    @Test func spanCrossingChunkBoundaryAppearsInBoth() {
        let source = (0 ..< 4).map { "l\($0)" }.joined(separator: "\n") // l0\nl1\nl2\nl3
        let span = HighlightSpan(range: NSRange(location: 3, length: 5), capture: .comment) // "l1\nl2"
        let chunks = HighlightChunks.split(source: source, spans: [span], linesPerChunk: 2)
        #expect(chunks.map(\.text) == ["l0\nl1", "l2\nl3"])
        #expect(chunks[0].spans == [HighlightSpan(range: NSRange(location: 3, length: 2), capture: .comment)])
        #expect(chunks[1].spans == [HighlightSpan(range: NSRange(location: 0, length: 2), capture: .comment)])
    }

    @Test func emptySourceGivesOneEmptyChunk() {
        let chunks = HighlightChunks.split(source: "", spans: [], linesPerChunk: 100)
        #expect(chunks.count == 1 && chunks[0].text.isEmpty)
    }

    @Test func utf16RangesSurviveNonASCII() {
        let source = "é😀\nx"
        let span = HighlightSpan(range: NSRange(location: 4, length: 1), capture: .keyword) // "x"
        let chunks = HighlightChunks.split(source: source, spans: [span], linesPerChunk: 1)
        #expect(chunks[1].spans == [HighlightSpan(range: NSRange(location: 0, length: 1), capture: .keyword)])
    }
}

struct CodeFenceTests {
    @Test(arguments: [
        (["```swift", "x", "```"], true),
        (["~~~", "x", "~~~~"], true),
        (["    indented"], true),
        (["```swift", "x"], false),
        (["```swift"], false),
        (["````", "x", "```"], false),
        (["```", "x", "~~~"], false),
    ])
    func closedOnlyByAMatchingFence(lines: [String], closed: Bool) {
        #expect(CodeFence.isClosed(lines.map { Substring($0) }) == closed)
    }
}
