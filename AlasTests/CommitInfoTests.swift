import Testing
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
        for type in ["feat", "fix", "chore", "refactor", "perf", "docs", "test", "ci", "build"] {
            let (tag, _) = CommitInfo.parseConventional(subject: "\(type): something")
            #expect(tag == type, "expected \(type) to be recognised")
        }
    }
}
