import AppKit
import Testing
@testable import Alas

struct EditorDisplayMapTests {
    private var pair: [EditorDisplayHint] {
        [EditorDisplayHint(id: "first", sourceOffset: 1, label: "x:", size: CGSize(width: 12, height: 16)),
         EditorDisplayHint(id: "second", sourceOffset: 1, label: "type:", size: CGSize(width: 40, height: 16))]
    }

    @Test func mapsEmojiAndSameBoundaryHintsWithExplicitAffinity() throws {
        let map = try EditorDisplayMap(source: "a🙂b", revision: 7, hints: pair)
        #expect(map.revision == 7)
        #expect(try map.displayOffset(forSource: 1, affinity: .beforeHints) == 1)
        #expect(try map.displayOffset(forSource: 1, affinity: .afterHints) == 3)
        #expect(try map.sourceRange(forDisplay: NSRange(location: 1, length: 2)) == NSRange(location: 1, length: 0))
        #expect(try map.displaySegments(forSource: NSRange(location: 1, length: 2)) == [NSRange(location: 3, length: 2)])
        #expect(try map.sourceRange(forDisplay: NSRange(location: 0, length: 6)) == NSRange(location: 0, length: 4))
        #expect(try map.sourceOffset(forDisplay: 2) == 1)
        #expect(try map.sourceOffset(forDisplay: 5) == 3)
    }

    @Test func sourceSegmentsExcludeAllHintsAndClipToRequestedRange() throws {
        let hints = pair + [EditorDisplayHint(id: "end", sourceOffset: 4, label: "!", size: CGSize(width: 3, height: 16))]
        let map = try EditorDisplayMap(source: "abcdef", revision: 0, hints: hints)
        #expect(try map.displaySegments(forSource: NSRange(location: 0, length: 6)) == [NSRange(location: 0, length: 1), NSRange(location: 3, length: 3), NSRange(location: 7, length: 2)])
        #expect(try map.displaySegments(forSource: NSRange(location: 2, length: 3)) == [NSRange(location: 4, length: 2), NSRange(location: 7, length: 1)])
        #expect(try map.displaySegments(forSource: NSRange(location: 1, length: 0)).isEmpty)
    }

    @Test func emptyAndEndOfDocumentHintsMapToSourceBoundary() throws {
        let hint = EditorDisplayHint(id: "end", sourceOffset: 0, label: "!", size: CGSize(width: 3, height: 16))
        let empty = try EditorDisplayMap(source: "", revision: 0, hints: [hint])
        #expect(try empty.displayOffset(forSource: 0, affinity: .beforeHints) == 0)
        #expect(try empty.displayOffset(forSource: 0, affinity: .afterHints) == 1)
        #expect(try empty.sourceRange(forDisplay: NSRange(location: 0, length: 1)) == NSRange(location: 0, length: 0))
        #expect(try empty.displaySegments(forSource: NSRange(location: 0, length: 0)).isEmpty)
        let end = try EditorDisplayMap(source: "a", revision: 0, hints: pair)
        #expect(try end.displayOffset(forSource: 1, affinity: .afterHints) == 3)
        #expect(try end.sourceOffset(forDisplay: 3) == 1)
    }

    @Test func rejectsInvalidAndScalarSplittingBoundaries() throws {
        let map = try EditorDisplayMap(source: "a🙂b", revision: 0, hints: pair)
        for offset in [-1, 2, 5, Int.max] {
            #expect(throws: Error.self) { try map.displayOffset(forSource: offset, affinity: .afterHints) }
        }
        for offset in [-1, 4, 7, Int.max] {
            #expect(throws: Error.self) { try map.sourceOffset(forDisplay: offset) }
        }
        let invalid = [NSRange(location: -1, length: 0), NSRange(location: 0, length: -1), NSRange(location: Int.max, length: 1), NSRange(location: 1, length: Int.max), NSRange(location: 0, length: 99)]
        for range in invalid {
            #expect(throws: Error.self) { try map.sourceRange(forDisplay: range) }
            #expect(throws: Error.self) { try map.displaySegments(forSource: range) }
        }
        #expect(throws: Error.self) { try map.displaySegments(forSource: NSRange(location: 1, length: 1)) }
        #expect(throws: Error.self) { try map.sourceRange(forDisplay: NSRange(location: 3, length: 1)) }
    }

    @Test func rejectsInvalidHintsAndDuplicateIDs() {
        for offset in [-1, 2, 5, Int.max] {
            #expect(throws: Error.self) { try EditorDisplayMap(source: "a🙂b", revision: 0, hints: [EditorDisplayHint(id: "bad", sourceOffset: offset, label: "", size: CGSize(width: 1, height: 1))]) }
        }
        for size in [CGSize(width: -1, height: 1), CGSize(width: 1, height: 0), CGSize(width: 0, height: 1), CGSize(width: CGFloat.infinity, height: 1), CGSize(width: 1, height: CGFloat.nan)] {
            #expect(throws: Error.self) { try EditorDisplayMap(source: "a", revision: 0, hints: [EditorDisplayHint(id: "bad", sourceOffset: 0, label: "", size: size)]) }
        }
        #expect(throws: Error.self) { try EditorDisplayMap(source: "ab", revision: 0, hints: [pair[0], pair[0]]) }
    }

    @Test func scalarBoundariesAllowCombiningMarksAndSourceObjectReplacementCharacter() throws {
        let map = try EditorDisplayMap(source: "e\u{301}\u{FFFC}", revision: 0, hints: pair)
        #expect(try map.displayOffset(forSource: 1, affinity: .afterHints) == 3)
        #expect(try map.sourceRange(forDisplay: NSRange(location: 4, length: 1)) == NSRange(location: 2, length: 1))
    }
}
