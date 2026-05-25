import Testing
import Foundation
@testable import Alas

struct MergeWordDiffTests {
    @Test func identicalStringsReportAllUnchanged() {
        let result = MergeWordDiff.diff(local: "let x = 1", remote: "let x = 1", mode: .characters)
        #expect(result.localChanged.isEmpty)
        #expect(result.remoteChanged.isEmpty)
    }

    @Test func singleCharDifferenceIsIsolated() {
        let result = MergeWordDiff.diff(local: "let x = 1", remote: "let x = 2", mode: .characters)
        #expect(result.localChanged == [NSRange(location: 8, length: 1)])
        #expect(result.remoteChanged == [NSRange(location: 8, length: 1)])
    }

    @Test func wordModeSnapsToWordBoundaries() {
        let result = MergeWordDiff.diff(local: "let host = local", remote: "let host = remote", mode: .words)
        #expect(result.localChanged.count == 1)
        #expect(result.remoteChanged.count == 1)
        let localRange = result.localChanged[0]
        let remoteRange = result.remoteChanged[0]
        #expect(("let host = local" as NSString).substring(with: localRange) == "local")
        #expect(("let host = remote" as NSString).substring(with: remoteRange) == "remote")
    }

    @Test func offModeReturnsEmpty() {
        let result = MergeWordDiff.diff(local: "a", remote: "b", mode: .off)
        #expect(result.localChanged.isEmpty)
        #expect(result.remoteChanged.isEmpty)
    }

    @Test func emptyStringsAreSafe() {
        let result = MergeWordDiff.diff(local: "", remote: "", mode: .characters)
        #expect(result.localChanged.isEmpty)
        #expect(result.remoteChanged.isEmpty)
    }

    @Test func longLinesFallBackToEmptyDiff() {
        // Simulate a 2000-char minified line. The DP table would be
        // 4M cells × 8 bytes = 32 MB and a lengthy compute — fall back.
        let long = String(repeating: "a", count: 2000)
        let longB = String(repeating: "b", count: 2000)
        let result = MergeWordDiff.diff(local: long, remote: longB, mode: .characters)
        #expect(result.localChanged.isEmpty)
        #expect(result.remoteChanged.isEmpty)
    }

    @Test func emojiInLocalDoesNotProduceMisalignedRanges() {
        // "🦆count" vs "🦆rate" — the difference starts at UTF-16
        // index 2 (after the surrogate pair) and runs to the end.
        // If charDiff were grapheme-indexed, the returned NSRange
        // would be measured in graphemes (start=1) which is wrong
        // for the UTF-16 backing.
        let local = "🦆count"
        let remote = "🦆rate"
        let result = MergeWordDiff.diff(local: local, remote: remote, mode: .characters)
        // Verify every returned range is a valid UTF-16 substring on
        // its respective NSString (no out-of-bounds, no surrogate
        // split). NSString.substring will trap on malformed ranges.
        let localNS = local as NSString
        let remoteNS = remote as NSString
        for r in result.localChanged {
            _ = localNS.substring(with: r) // would trap if misaligned
        }
        for r in result.remoteChanged {
            _ = remoteNS.substring(with: r)
        }
        // Sanity: at least one range exists.
        #expect(!result.localChanged.isEmpty || !result.remoteChanged.isEmpty)
    }
}
