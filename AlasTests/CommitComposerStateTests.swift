import Testing
import Foundation
@testable import Alas

@MainActor
struct CommitComposerStateTests {
    @Test func cannotCommitWithoutStagedFiles() {
        let s = CommitComposerState()
        s.subject = "hello"
        #expect(s.canCommit(stagedCount: 0) == false)
    }

    @Test func cannotCommitWithEmptySubject() {
        let s = CommitComposerState()
        s.subject = "   \n  "
        #expect(s.canCommit(stagedCount: 1) == false)
    }

    @Test func canCommitWithStagedAndSubject() {
        let s = CommitComposerState()
        s.subject = "feat: x"
        #expect(s.canCommit(stagedCount: 1) == true)
    }

    @Test func cannotCommitWhileBusy() {
        let s = CommitComposerState()
        s.subject = "x"
        s.busy = true
        #expect(s.canCommit(stagedCount: 1) == false)
    }

    @Test func amendPrefillFillsEmptyComposer() {
        let s = CommitComposerState()
        let prior = GitService.HeadMessage(subject: "prev", body: "explanation")
        s.applyAmendPrefill(prior)
        #expect(s.subject == "prev")
        #expect(s.body == "explanation")
        #expect(s.amendPrefilled == true)
    }

    @Test func amendPrefillPreservesUserDraft() {
        let s = CommitComposerState()
        s.subject = "draft"
        let prior = GitService.HeadMessage(subject: "prev", body: "explanation")
        s.applyAmendPrefill(prior)
        #expect(s.subject == "draft")
        #expect(s.body == "")
        #expect(s.amendPrefilled == false)
    }

    @Test func toggleOffClearsExactlyPrefilledText() {
        let s = CommitComposerState()
        let prior = GitService.HeadMessage(subject: "prev", body: "explanation")
        s.applyAmendPrefill(prior)
        s.clearAmendPrefillIfUnchanged()
        #expect(s.subject == "")
        #expect(s.body == "")
        #expect(s.amendPrefilled == false)
    }

    @Test func toggleOffLeavesEditedTextAlone() {
        let s = CommitComposerState()
        let prior = GitService.HeadMessage(subject: "prev", body: "explanation")
        s.applyAmendPrefill(prior)
        s.subject = "prev edited"
        s.clearAmendPrefillIfUnchanged()
        #expect(s.subject == "prev edited")
        #expect(s.body == "explanation") // unchanged body still clears? no — atomic check
    }

    @Test func toggleOffOnlyClearsWhenBothMatch() {
        let s = CommitComposerState()
        let prior = GitService.HeadMessage(subject: "prev", body: "explanation")
        s.applyAmendPrefill(prior)
        s.body = "edited body"
        s.clearAmendPrefillIfUnchanged()
        // Subject still matches prior.subject but body diverged → leave both alone.
        #expect(s.subject == "prev")
        #expect(s.body == "edited body")
    }
}
