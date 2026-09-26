import Testing
import Foundation
@testable import Alas

struct CommitInfoTests {
    struct ConventionalCase: Sendable, CustomTestStringConvertible {
        let subject: String
        let tag: String?
        let stripped: String

        var testDescription: String { subject }
    }

    static let conventionalCases: [ConventionalCase] = [
        ConventionalCase(subject: "feat: wire tab_drag", tag: "feat", stripped: "wire tab_drag"),
        ConventionalCase(subject: "feat(scope): wire X", tag: "feat", stripped: "wire X"),
        ConventionalCase(subject: "feat!: wire X", tag: "feat", stripped: "wire X"),
        ConventionalCase(subject: "chore(scope)!: bump", tag: "chore", stripped: "bump"),
        ConventionalCase(subject: "tune(sidebar): tweak row spacing", tag: "tune", stripped: "tweak row spacing"),
        ConventionalCase(subject: "harden: tighten auth checks", tag: "harden", stripped: "tighten auth checks"),
        ConventionalCase(subject: "tune: adjust animation timing", tag: "tune", stripped: "adjust animation timing"),
        ConventionalCase(subject: "style: fix indentation", tag: "style", stripped: "fix indentation"),
        ConventionalCase(subject: "revert: undo feature flag", tag: "revert", stripped: "undo feature flag"),
        ConventionalCase(subject: "polish: refine commit chips", tag: "polish", stripped: "refine commit chips"),
        // No prefix: the subject stays intact.
        ConventionalCase(subject: "Wire X", tag: nil, stripped: "Wire X"),
        // "WIP:" is a prefix but not in our recognised set — leave the
        // subject intact rather than rendering a bogus chip.
        ConventionalCase(subject: "WIP: experiment", tag: nil, stripped: "WIP: experiment"),
    ]

    @Test("Parses conventional commit prefix", arguments: CommitInfoTests.conventionalCases)
    func parsesConventionalPrefix(_ c: ConventionalCase) {
        let (tag, stripped) = CommitInfo.parseConventional(subject: c.subject)
        #expect(tag == c.tag)
        #expect(stripped == c.stripped)
    }

    @Test("Recognises conventional commit type", arguments: [
        "feat", "fix", "chore", "refactor", "perf", "docs", "test", "ci", "build",
        "style", "revert", "tune", "harden", "polish",
    ])
    func recognisesConventionalType(_ type: String) {
        let (tag, _) = CommitInfo.parseConventional(subject: "\(type): something")
        #expect(tag == type)
    }

    @Test("Full message joins raw subject and trimmed body", arguments: [
        ("\nMore context.\n\n", "polish: refine commit chips\n\nMore context."),
        // Whitespace-only body falls back to the raw subject alone.
        (" \n ", "polish: refine commit chips"),
    ])
    func fullMessage(body: String, expected: String) {
        let commit = CommitInfo(
            sha: "abcdef1234567890",
            shortSha: "abcdef1",
            author: "Test User",
            authorInitials: "TU",
            date: Date(timeIntervalSince1970: 0),
            subject: "refine commit chips",
            rawSubject: "polish: refine commit chips",
            body: body,
            conventionalTag: "polish",
            filesChanged: 0,
            insertions: 0,
            deletions: 0
        )

        #expect(commit.fullMessage == expected)
    }

    @Test("Author initials", arguments: [
        ("", "?"),
        // split(whereSeparator:) drops empty subsequences, so the parts
        // array is empty and we fall back to "?".
        ("   ", "?"),
        ("Nacho", "N"),
        ("Nacho Lopez", "NL"),
        // 3+ name parts only contribute their first initials, capped at 2.
        ("Jean Luc Picard", "JL"),
    ])
    func initials(name: String, expected: String) {
        #expect(CommitInfo.initials(for: name) == expected)
    }
}
