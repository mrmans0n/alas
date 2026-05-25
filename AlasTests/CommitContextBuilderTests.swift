import Testing
import Foundation
@testable import Alas

struct CommitContextBuilderTests {
    @Test func minimalContextWithNoAmendNoRecent() {
        let s = CommitContextBuilder.build(
            branch: "main",
            base: "main",
            recentSubjects: [],
            priorMessage: nil,
            diff: "DIFF\n"
        )
        #expect(s.contains("# Branch: main"))
        #expect(s.contains("# Base: main"))
        #expect(!s.contains("Recent subjects"))
        #expect(!s.contains("Amending previous commit"))
        #expect(s.contains("\n---\nDIFF"))
    }

    @Test func includesRecentSubjects() {
        let s = CommitContextBuilder.build(
            branch: "feat",
            base: "main",
            recentSubjects: ["feat: a", "fix: b"],
            priorMessage: nil,
            diff: "DIFF\n"
        )
        #expect(s.contains("# Recent subjects on this branch:"))
        #expect(s.contains("#   feat: a"))
        #expect(s.contains("#   fix: b"))
    }

    @Test func includesAmendBlockWhenPriorMessageProvided() {
        let prior = GitService.HeadMessage(subject: "prev subject", body: "prev body line 1\nprev body line 2")
        let s = CommitContextBuilder.build(
            branch: "feat",
            base: "main",
            recentSubjects: [],
            priorMessage: prior,
            diff: "DIFF\n"
        )
        #expect(s.contains("# Amending previous commit:"))
        #expect(s.contains("#   prev subject"))
        #expect(s.contains("#   prev body line 1"))
        #expect(s.contains("#   prev body line 2"))
    }

    @Test func handlesDetachedHeadWithoutBranch() {
        let s = CommitContextBuilder.build(
            branch: nil,
            base: nil,
            recentSubjects: [],
            priorMessage: nil,
            diff: "DIFF\n"
        )
        #expect(s.contains("# Branch: (detached)"))
        #expect(!s.contains("# Base:"))
    }

    @Test func editContextNamesExistingCommitAndIncludesSelectedDiff() {
        let payload = CommitContextBuilder.buildForCommitEdit(
            branch: "feature/live-editor",
            base: "origin/main",
            nearbySubjects: ["base", "old target", "descendant"],
            priorMessage: GitService.HeadMessage(subject: "old target", body: "old body"),
            diff: "diff --git a/a.txt b/a.txt\n+new\n"
        )

        #expect(payload.contains("# Editing existing commit message"))
        #expect(payload.contains("# Branch: feature/live-editor"))
        #expect(payload.contains("# Base: origin/main"))
        #expect(payload.contains("# Nearby subjects on this branch:"))
        #expect(payload.contains("#   old target"))
        #expect(payload.contains("# Current commit message:"))
        #expect(payload.contains("#   old target"))
        #expect(payload.contains("diff --git a/a.txt b/a.txt"))
    }
}
