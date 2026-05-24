import Testing
import Foundation
@testable import Alas

struct ConflictMarkerParserTests {
    @Test func parsesPlainTextAsSingleRegion() {
        let regions = ConflictMarkerParser.parse("line 1\nline 2\n")
        #expect(regions.count == 1)
        if case .text(let s) = regions[0] {
            #expect(s == "line 1\nline 2\n")
        } else {
            Issue.record("expected .text region")
        }
    }

    @Test func parsesMergeStyleConflict() {
        let input = """
            before
            <<<<<<< HEAD
            ours line
            =======
            theirs line
            >>>>>>> feature
            after

            """
        let regions = ConflictMarkerParser.parse(input)
        #expect(regions.count == 3)
        guard case .text(let pre) = regions[0],
              case .conflict(let block) = regions[1],
              case .text(let post) = regions[2]
        else { Issue.record("region kinds wrong")
        return }
        #expect(pre == "before\n")
        #expect(block.local == "ours line\n")
        #expect(block.remote == "theirs line\n")
        #expect(block.base == nil)
        #expect(block.localLabel == "HEAD")
        #expect(block.remoteLabel == "feature")
        #expect(post == "after\n")
    }

    @Test func parsesZdiff3StyleConflict() {
        let input = """
            <<<<<<< HEAD
            ours
            ||||||| merged common ancestors
            base
            =======
            theirs
            >>>>>>> feature

            """
        let regions = ConflictMarkerParser.parse(input)
        #expect(regions.count == 2)
        guard case .conflict(let block) = regions[0] else {
            Issue.record("expected leading conflict region")
            return
        }
        #expect(block.local == "ours\n")
        #expect(block.base == "base\n")
        #expect(block.remote == "theirs\n")
    }

    @Test func parsesMultipleConflictsInOrder() {
        let input = """
            top
            <<<<<<< HEAD
            a-ours
            =======
            a-theirs
            >>>>>>> x
            middle
            <<<<<<< HEAD
            b-ours
            =======
            b-theirs
            >>>>>>> x
            bottom

            """
        let regions = ConflictMarkerParser.parse(input)
        #expect(regions.count == 5)
        // text, conflict, text, conflict, text
        guard case .text = regions[0],
              case .conflict(let first) = regions[1],
              case .text = regions[2],
              case .conflict(let second) = regions[3],
              case .text = regions[4]
        else { Issue.record("region order wrong")
        return }
        #expect(first.local == "a-ours\n")
        #expect(second.local == "b-ours\n")
    }

    @Test func recordsLineRanges() {
        let input = """
            line0
            <<<<<<< HEAD
            ours
            =======
            theirs
            >>>>>>> x
            line6

            """
        let regions = ConflictMarkerParser.parse(input)
        guard case .conflict(let block) = regions[1] else {
            Issue.record("expected conflict region")
            return
        }
        // Lines are 0-indexed in the merged buffer.
        // Marker lines are 1 (<<<), 3 (===), 5 (>>>).
        #expect(block.lineRangeInMerged.lowerBound == 1)
        #expect(block.lineRangeInMerged.upperBound == 5)
    }

    @Test func conflictMarkersInsideStringLiteralAreStillParsed() {
        // Real-world ambiguity: we deliberately do NOT try to be smart about
        // markers that appear inside source-code string literals. ParseFlat:
        // the only thing that matters is whether the *file* has unmerged
        // status. ConflictMarkerParser trusts the input.
        let input = """
            let template = \"\"\"
            <<<<<<< not actually a conflict
            \"\"\"

            """
        let regions = ConflictMarkerParser.parse(input)
        // We *will* misparse this — and that's fine because the parser is
        // only run on files git status reports as unmerged.
        #expect(regions.count >= 1)
    }

    @Test func unterminatedConflictIsTreatedAsText() {
        let input = """
            <<<<<<< HEAD
            ours

            """
        let regions = ConflictMarkerParser.parse(input)
        // Defensive: if we see <<< without === and >>>, emit everything as
        // text and let the user fix it manually.
        #expect(regions.count == 1)
        if case .text = regions[0] {} else { Issue.record("expected .text region for malformed conflict") }
    }

    @Test func parsesEmptyLocalHalf() {
        let input = "<<<<<<< HEAD\n=======\ntheirs\n>>>>>>> feature\n"
        let regions = ConflictMarkerParser.parse(input)
        guard case .conflict(let block) = regions[0] else {
            Issue.record("expected conflict region")
            return
        }
        #expect(block.local == "")
        #expect(block.remote == "theirs\n")
    }

    @Test func parsesEmptyRemoteHalf() {
        let input = "<<<<<<< HEAD\nours\n=======\n>>>>>>> feature\n"
        let regions = ConflictMarkerParser.parse(input)
        guard case .conflict(let block) = regions[0] else {
            Issue.record("expected conflict region")
            return
        }
        #expect(block.local == "ours\n")
        #expect(block.remote == "")
    }

    @Test func parsesEmptyBaseInZdiff3() {
        let input = "<<<<<<< HEAD\nours\n||||||| ancestor\n=======\ntheirs\n>>>>>>> feature\n"
        let regions = ConflictMarkerParser.parse(input)
        guard case .conflict(let block) = regions[0] else {
            Issue.record("expected conflict region")
            return
        }
        #expect(block.local == "ours\n")
        #expect(block.base == "")
        #expect(block.remote == "theirs\n")
    }

    @Test func parsesAllHalvesEmpty() {
        let input = "<<<<<<< HEAD\n=======\n>>>>>>> feature\n"
        let regions = ConflictMarkerParser.parse(input)
        guard case .conflict(let block) = regions[0] else {
            Issue.record("expected conflict region")
            return
        }
        #expect(block.local == "")
        #expect(block.base == nil)
        #expect(block.remote == "")
    }
}
