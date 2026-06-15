import Foundation
import Testing
@testable import Alas

@Suite("Review feedback bundle")
struct ReviewFeedbackBundleTests {
    @Test func promptGroupsActiveCommentsByFileAndLine() throws {
        let session = ReviewDraftSessionID.commit(
            worktreeID: "wt",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "abc123"
        )
        let target = ReviewFeedbackTarget(
            title: "Review commit abc123",
            repositoryPath: "/repo",
            providerDescription: nil,
            sourceDescription: "commit abc123"
        )
        let bundle = ReviewFeedbackBundle(target: target, comments: [
            comment(
                id: "b",
                session: session,
                path: "Sources/B.swift",
                line: 9,
                body: "Rename this."
            ),
            comment(
                id: "a-resolved",
                session: session,
                path: "Sources/A.swift",
                line: 1,
                body: "Resolved body.",
                state: .resolved
            ),
            comment(
                id: "a",
                session: session,
                path: "Sources/A.swift",
                line: 2,
                body: "Extract helper."
            ),
        ])

        let prompt = bundle.promptMarkdown()

        #expect(prompt.contains("Please address each review comment below."))
        #expect(prompt.contains("Review target: Review commit abc123"))
        #expect(prompt.contains("Repository: /repo"))
        #expect(prompt.contains("Source: commit abc123"))
        #expect(prompt.contains("## Sources/A.swift"))
        #expect(prompt.contains("## Sources/B.swift"))
        let aHeader = try #require(prompt.range(of: "## Sources/A.swift")?.lowerBound)
        let bHeader = try #require(prompt.range(of: "## Sources/B.swift")?.lowerBound)
        #expect(aHeader < bHeader)
        #expect(prompt.contains("- `Sources/A.swift:2 (new)` — Extract helper."))
        #expect(prompt.contains("- `Sources/B.swift:9 (new)` — Rename this."))
        #expect(!prompt.contains("Resolved body."))
    }

    @Test func promptIncludesLineRangesAndSelectedText() {
        let session = ReviewDraftSessionID.localChanges(
            worktreeID: "wt",
            worktreePath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let target = ReviewFeedbackTarget(
            title: "Local changes",
            repositoryPath: nil,
            providerDescription: nil,
            sourceDescription: "local changes"
        )
        let bundle = ReviewFeedbackBundle(target: target, comments: [
            comment(
                id: "a",
                session: session,
                path: "A.swift",
                side: .old,
                line: 4,
                endLine: 6,
                selectedText: "old code",
                body: "This behavior regressed."
            ),
        ])

        let prompt = bundle.promptMarkdown()

        #expect(prompt.contains("`A.swift:4-6 (old)`"))
        #expect(prompt.contains("> old code"))
        #expect(prompt.contains("This behavior regressed."))
    }

    @Test func promptDistinguishesSamePathCommentsFromDifferentNamespaces() {
        let session = ReviewDraftSessionID.localChanges(
            worktreeID: "wt",
            worktreePath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let target = ReviewFeedbackTarget(
            title: "Local changes",
            repositoryPath: "/repo",
            providerDescription: nil,
            sourceDescription: "Review Changes"
        )
        let bundle = ReviewFeedbackBundle(target: target, comments: [
            comment(
                id: "unstaged",
                session: session,
                namespace: "unstaged",
                path: "Sources/App.swift",
                line: 4,
                body: "Fix the working tree edit."
            ),
            comment(
                id: "staged",
                session: session,
                namespace: "staged",
                path: "Sources/App.swift",
                line: 4,
                body: "Fix the staged edit."
            ),
        ])

        let prompt = bundle.promptMarkdown()

        #expect(prompt.contains("## Sources/App.swift [staged]"))
        #expect(prompt.contains("## Sources/App.swift [unstaged]"))
        #expect(prompt.contains("- `Sources/App.swift:4 (new, staged)` — Fix the staged edit."))
        #expect(prompt.contains("- `Sources/App.swift:4 (new, unstaged)` — Fix the working tree edit."))
    }

    @Test func promptPreservesMultilineMarkdownBodies() {
        let session = ReviewDraftSessionID.localChanges(
            worktreeID: "wt",
            worktreePath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let target = ReviewFeedbackTarget(
            title: "Local changes",
            repositoryPath: nil,
            providerDescription: nil,
            sourceDescription: "local changes"
        )
        let body = """
        This needs a guard.

        ```swift
        if value == nil {
            return
        }
        ```
        """
        let bundle = ReviewFeedbackBundle(target: target, comments: [
            comment(id: "a", session: session, path: "A.swift", line: 4, body: body),
        ])

        let prompt = bundle.promptMarkdown()

        #expect(prompt.contains("- `A.swift:4 (new)`"))
        #expect(prompt.contains("""
        This needs a guard.

        ```swift
        if value == nil {
            return
        }
        ```
        """))
        #expect(!prompt.contains("This needs a guard. ```swift if value == nil"))
    }

    @Test func promptPreservesSelectedTextIndentation() {
        let session = ReviewDraftSessionID.localChanges(
            worktreeID: "wt",
            worktreePath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let target = ReviewFeedbackTarget(
            title: "Local changes",
            repositoryPath: nil,
            providerDescription: nil,
            sourceDescription: "local changes"
        )
        let selectedText = """
            if condition {
                run()
            }
        """
        let bundle = ReviewFeedbackBundle(target: target, comments: [
            comment(
                id: "a",
                session: session,
                path: "A.swift",
                line: 4,
                selectedText: selectedText,
                body: "Keep indentation."
            ),
        ])

        let prompt = bundle.promptMarkdown()

        #expect(prompt.contains(">     if condition {"))
        #expect(prompt.contains(">         run()"))
    }

    private func comment(
        id: String,
        session: ReviewDraftSessionID,
        namespace: String = "review",
        path: String,
        side: DiffReviewInlineFeedbackSide = .new,
        line: Int,
        endLine: Int? = nil,
        selectedText: String? = nil,
        body: String,
        state: ReviewDraftCommentState = .active
    ) -> ReviewDraftComment {
        ReviewDraftComment(
            id: id,
            sessionID: session,
            fileID: DiffReviewFileID(namespace: namespace, path: path),
            path: path,
            originalPath: nil,
            side: side,
            startLine: line,
            endLine: endLine,
            selectedText: selectedText,
            bodyMarkdown: body,
            state: state,
            createdAt: Date(timeIntervalSince1970: Double(line)),
            updatedAt: Date(timeIntervalSince1970: Double(line))
        )
    }
}
