import Testing
@testable import Alas

@Suite struct ReviewThreadWriteTests {
    // Helper to build a minimal ReviewThread
    private func makeThread(id: String, comments: [ReviewComment] = [], isResolved: Bool = false) -> ReviewThread {
        ReviewThread(
            id: id,
            path: "Foo.swift",
            line: 1,
            startLine: nil,
            originalLine: nil,
            diffHunk: nil,
            isResolved: isResolved,
            isOutdated: false,
            isFileLevel: false,
            comments: comments,
            viewerCanResolve: true,
            viewerCanReply: true,
            url: nil
        )
    }

    private func makeComment(id: String, body: String) -> ReviewComment {
        ReviewComment(
            id: id,
            author: "alice",
            body: body,
            url: nil,
            createdAt: nil,
            viewerCanUpdate: true,
            viewerCanDelete: true,
            isPending: false
        )
    }

    @Test func applyReplyAppendsComment() {
        let thread = makeThread(id: "t1")
        let comment = makeComment(id: "c1", body: "hello")
        let result = ReviewThreadMutations.applyReply(to: [thread], threadID: "t1", comment: comment)
        #expect(result.first?.comments.count == 1)
        #expect(result.first?.comments.first?.body == "hello")
    }

    @Test func applyResolveMarksThreadResolved() {
        let thread = makeThread(id: "t1", isResolved: false)
        let result = ReviewThreadMutations.applyResolve(to: [thread], threadID: "t1")
        #expect(result.first?.isResolved == true)
    }

    @Test func applyUnresolveMarksThreadUnresolved() {
        let thread = makeThread(id: "t1", isResolved: true)
        let result = ReviewThreadMutations.applyUnresolve(to: [thread], threadID: "t1")
        #expect(result.first?.isResolved == false)
    }

    @Test func applyEditUpdatesCommentBody() {
        let comment = makeComment(id: "c1", body: "original")
        let thread = makeThread(id: "t1", comments: [comment])
        let result = ReviewThreadMutations.applyEdit(to: [thread], threadID: "t1", commentID: "c1", newBody: "updated")
        #expect(result.first?.comments.first?.body == "updated")
    }

    @Test func applyDeleteRemovesComment() {
        let comment = makeComment(id: "c1", body: "to delete")
        let thread = makeThread(id: "t1", comments: [comment])
        let result = ReviewThreadMutations.applyDelete(to: [thread], threadID: "t1", commentID: "c1")
        #expect(result.first?.comments.isEmpty == true)
    }

    @Test func applyToNonexistentThreadIsNoOp() {
        let thread = makeThread(id: "t1", isResolved: false)
        let threads = [thread]
        let resolved = ReviewThreadMutations.applyResolve(to: threads, threadID: "doesNotExist")
        #expect(resolved == threads)
        let replied = ReviewThreadMutations.applyReply(to: threads, threadID: "doesNotExist", comment: makeComment(id: "c1", body: "x"))
        #expect(replied == threads)
    }
}
