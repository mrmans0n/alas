import Testing
import Foundation
@testable import Alas

struct CommitInfoTests {
    @Test func extractsFeatPrefix() {
        let (tag, stripped) = CommitInfo.parseConventional(subject: "feat: wire tab_drag")
        #expect(tag == "feat")
        #expect(stripped == "wire tab_drag")
    }

    @Test func extractsScopedPrefix() {
        let (tag, stripped) = CommitInfo.parseConventional(subject: "feat(scope): wire X")
        #expect(tag == "feat")
        #expect(stripped == "wire X")
    }

    @Test func extractsBreakingPrefix() {
        let (tag, stripped) = CommitInfo.parseConventional(subject: "feat!: wire X")
        #expect(tag == "feat")
        #expect(stripped == "wire X")
    }

    @Test func extractsScopedBreakingPrefix() {
        let (tag, stripped) = CommitInfo.parseConventional(subject: "chore(scope)!: bump")
        #expect(tag == "chore")
        #expect(stripped == "bump")
    }

    @Test func noPrefixReturnsNilTag() {
        let (tag, stripped) = CommitInfo.parseConventional(subject: "Wire X")
        #expect(tag == nil)
        #expect(stripped == "Wire X")
    }

    @Test func unknownPrefixReturnsNilTag() {
        // "WIP:" is a prefix but not in our recognised set — leave the
        // subject intact rather than rendering a bogus chip.
        let (tag, stripped) = CommitInfo.parseConventional(subject: "WIP: experiment")
        #expect(tag == nil)
        #expect(stripped == "WIP: experiment")
    }

    @Test func recognisesAllExpectedTypes() {
        for type in [
            "feat", "fix", "chore", "refactor", "perf", "docs", "test", "ci", "build",
            "style", "revert", "tune", "harden", "polish",
        ] {
            let (tag, _) = CommitInfo.parseConventional(subject: "\(type): something")
            #expect(tag == type, "expected \(type) to be recognised")
        }
    }

    @Test func extractsHardenPrefix() {
        let (tag, stripped) = CommitInfo.parseConventional(subject: "harden: tighten auth checks")
        #expect(tag == "harden")
        #expect(stripped == "tighten auth checks")
    }

    @Test func extractsTunePrefix() {
        let (tag, stripped) = CommitInfo.parseConventional(subject: "tune: adjust animation timing")
        #expect(tag == "tune")
        #expect(stripped == "adjust animation timing")
    }

    @Test func extractsStylePrefix() {
        let (tag, stripped) = CommitInfo.parseConventional(subject: "style: fix indentation")
        #expect(tag == "style")
        #expect(stripped == "fix indentation")
    }

    @Test func extractsRevertPrefix() {
        let (tag, stripped) = CommitInfo.parseConventional(subject: "revert: undo feature flag")
        #expect(tag == "revert")
        #expect(stripped == "undo feature flag")
    }

    @Test func extractsScopedTunePrefix() {
        let (tag, stripped) = CommitInfo.parseConventional(subject: "tune(sidebar): tweak row spacing")
        #expect(tag == "tune")
        #expect(stripped == "tweak row spacing")
    }

    @Test func extractsPolishPrefix() {
        let (tag, stripped) = CommitInfo.parseConventional(subject: "polish: refine commit chips")
        #expect(tag == "polish")
        #expect(stripped == "refine commit chips")
    }

    @Test func fullMessageIncludesRawSubjectAndTrimmedBody() {
        let commit = CommitInfo(
            sha: "abcdef1234567890",
            shortSha: "abcdef1",
            author: "Test User",
            authorInitials: "TU",
            date: Date(timeIntervalSince1970: 0),
            subject: "refine commit chips",
            rawSubject: "polish: refine commit chips",
            body: "\nMore context.\n\n",
            conventionalTag: "polish",
            filesChanged: 0,
            insertions: 0,
            deletions: 0
        )

        #expect(commit.fullMessage == "polish: refine commit chips\n\nMore context.")
    }

    @Test func fullMessageFallsBackToRawSubjectWhenBodyIsEmpty() {
        let commit = CommitInfo(
            sha: "abcdef1234567890",
            shortSha: "abcdef1",
            author: "Test User",
            authorInitials: "TU",
            date: Date(timeIntervalSince1970: 0),
            subject: "refine commit chips",
            rawSubject: "polish: refine commit chips",
            body: " \n ",
            conventionalTag: "polish",
            filesChanged: 0,
            insertions: 0,
            deletions: 0
        )

        #expect(commit.fullMessage == "polish: refine commit chips")
    }

    @Test func initialsEmpty() {
        #expect(CommitInfo.initials(for: "") == "?")
    }

    @Test func initialsWhitespaceOnly() {
        // split(whereSeparator:) drops empty subsequences, so the parts
        // array is empty and we fall back to "?".
        #expect(CommitInfo.initials(for: "   ") == "?")
    }

    @Test func initialsSingleName() {
        #expect(CommitInfo.initials(for: "Nacho") == "N")
    }

    @Test func initialsTwoNames() {
        #expect(CommitInfo.initials(for: "Nacho Lopez") == "NL")
    }

    @Test func initialsTruncatesToTwo() {
        // 3+ name parts only contribute their first initials, capped at 2.
        #expect(CommitInfo.initials(for: "Jean Luc Picard") == "JL")
    }
}
