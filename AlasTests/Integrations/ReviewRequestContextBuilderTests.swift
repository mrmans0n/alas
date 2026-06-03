import Testing
@testable import Alas

struct ReviewRequestContextBuilderTests {
    @Test func buildsProviderBranchCommitAndDiffContext() {
        let payload = ReviewRequestContextBuilder.build(
            provider: "GitHub",
            repository: "mrmans0n/alas",
            branch: "feature/pr-drafts",
            base: "origin/main",
            hasUncommittedChanges: true,
            commitSubjects: ["feat: add draft tab", "test: cover draft parser"],
            diff: "diff --git a/A.swift b/A.swift\n+let value = 1\n"
        )

        #expect(payload == """
        # Provider: GitHub
        # Repository: mrmans0n/alas
        # Branch: feature/pr-drafts
        # Base: origin/main
        # Uncommitted changes: present but excluded
        # Commit subjects:
        #   feat: add draft tab
        #   test: cover draft parser
        ---
        diff --git a/A.swift b/A.swift
        +let value = 1

        """)
    }

    @Test func omitsCommitSubjectsHeaderWhenEmpty() {
        let payload = ReviewRequestContextBuilder.build(
            provider: "GitHub",
            repository: "mrmans0n/alas",
            branch: "feature/pr-drafts",
            base: "origin/main",
            hasUncommittedChanges: false,
            commitSubjects: [],
            diff: "diff --git a/A.swift b/A.swift\n+let value = 1\n"
        )

        #expect(payload == """
        # Provider: GitHub
        # Repository: mrmans0n/alas
        # Branch: feature/pr-drafts
        # Base: origin/main
        # Uncommitted changes: none
        ---
        diff --git a/A.swift b/A.swift
        +let value = 1

        """)
    }
}
