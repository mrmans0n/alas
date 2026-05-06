import Testing
import Foundation
@testable import Alas

struct FuzzyMatchTests {
    @Test func emptyQueryReturnsZeroScoreNoIndices() {
        let m = FuzzyMatch.score(query: "", target: "anything")
        #expect(m != nil)
        #expect(m?.score == 0)
        #expect(m?.indices.isEmpty == true)
    }

    @Test func nonSubsequenceReturnsNil() {
        #expect(FuzzyMatch.score(query: "xyz", target: "tab_bar.rs") == nil)
    }

    @Test func emptyTargetWithNonEmptyQueryReturnsNil() {
        #expect(FuzzyMatch.score(query: "x", target: "") == nil)
    }

    @Test func startOfSegmentBonusFiresAfterDelimiters() {
        // "tb" matches t at index 0 (start) and b at index 4 (after _).
        // Both should earn the +4 segment bonus.
        let m = FuzzyMatch.score(query: "tb", target: "tab_bar.rs")
        #expect(m != nil)
        #expect(m?.indices == [0, 4])
        // Two segment bonuses (+8) + small adjustments for span/start.
        #expect((m?.score ?? 0) >= 7.5)
    }

    @Test func contiguousRunBeatsScattered() {
        // "tab" as a contiguous run vs. "tbr" scattered across tab_bar.rs.
        let contiguous = FuzzyMatch.score(query: "tab", target: "tab_bar.rs")
        let scattered  = FuzzyMatch.score(query: "tbr", target: "tab_bar.rs")
        #expect(contiguous != nil)
        #expect(scattered != nil)
        #expect((contiguous?.score ?? 0) > (scattered?.score ?? 0))
    }

    @Test func capitalMatchBonus() {
        let m = FuzzyMatch.score(query: "DS", target: "DragState")
        #expect(m != nil)
        #expect(m?.indices == [0, 4])
    }

    @Test func earlierMatchWinsOverLater() {
        let early = FuzzyMatch.score(query: "ab", target: "ab_xxx_xxx")!
        let late  = FuzzyMatch.score(query: "ab", target: "xxx_xxx_ab")!
        #expect(early.score > late.score)
    }

    @Test func tighterMatchWinsOverSpread() {
        let tight  = FuzzyMatch.score(query: "tb", target: "tab")!
        let spread = FuzzyMatch.score(query: "tb", target: "txxxxxb")!
        #expect(tight.score > spread.score)
    }

    @Test func indicesAreInOrderAndUnique() {
        let m = FuzzyMatch.score(query: "ape", target: "alphabet_pen")!
        #expect(m.indices.count == 3)
        // Strictly increasing.
        for i in 1..<m.indices.count {
            #expect(m.indices[i] > m.indices[i - 1])
        }
    }

    @Test func caseInsensitiveMatching() {
        let m = FuzzyMatch.score(query: "abc", target: "ABC.txt")
        #expect(m?.indices == [0, 1, 2])
    }

    @Test func preferredPositionDoesNotStrandRemainder() {
        // Regression: query "abz" against "axbz_b" passes isSubsequence
        // (a@0, b@2, z@3). The greedy preferred-position pick used to
        // jump to b@5 (segment start after `_`), leaving no room for
        // 'z' afterward and trapping on a force-unwrap. The fix gates
        // preferred selection on canMatchRemainder.
        let m = FuzzyMatch.score(query: "abz", target: "axbz_b")
        #expect(m != nil)
        #expect(m?.indices == [0, 2, 3])
    }

    @Test func multiBlockMatchScoresAllContiguousPairs() {
        // Regression: "abcd" against "ab_cd" has two contiguous blocks
        // (ab and cd). Earlier versions reset the run counter on the gap
        // between them and only credited the final block, scoring a
        // multi-block match identically to a single-block one. The
        // accumulator now sums pair counts across all blocks.
        let multiBlock  = FuzzyMatch.score(query: "abcd", target: "ab_cd")!
        let singleBlock = FuzzyMatch.score(query: "ad", target: "a___d")!
        // multiBlock has 2 pairs (ab + cd) → +8 run bonus.
        // singleBlock has 0 pairs → 0 run bonus. Plus segment-start bonuses
        // and penalties — but the contiguity premium should make multiBlock
        // strictly higher than what it would score with the old single-block
        // accumulator (which was equivalent to 1 pair, i.e. +4).
        #expect(multiBlock.score > singleBlock.score)
        // Sanity: 2-pair credit, not 1-pair. With the bug, the score would
        // be `bonus + 4 - 2*0.1 - 0`. With the fix, it's `bonus + 8 - ...`.
        // bonus = +4 (segStart at 0) + 4 (segStart at 3 after `_`) = 8.
        // span = 4 - 0 = 4 → -0.4. start = 0 → 0. score = 8 + 8 - 0.4 = 15.6.
        #expect(abs(multiBlock.score - 15.6) < 0.001)
    }
}
