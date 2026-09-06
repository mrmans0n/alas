import Testing
import Foundation
@testable import Alas

struct DraftCommitTabStateTests {
    @Test func idIsDerivedFromWorktreeId() {
        let s = DraftCommitTabState(worktreeId: "wt-1")
        #expect(s.id == "draft-commit:wt-1")
    }

    @Test func initialFieldsAreEmpty() {
        let s = DraftCommitTabState(worktreeId: "wt-1")
        #expect(s.subject == "")
        #expect(s.bodyText == "")
        #expect(s.amend == false)
        #expect(s.selectedPath == nil)
    }

    @Test func draftDefaultsToLocalCommitAndRegularReviewRequest() {
        let state = DraftCommitTabState(worktreeId: "wt-1")

        #expect(state.preferredAction == .commit)
        #expect(state.createReviewRequestAsDraft == false)
        #expect(state.publishCheckpoint == nil)
    }

    @Test func legacyDraftJSONDecodesNewFieldsWithDefaults() throws {
        let data = Data(#"{"id":"draft-commit:wt-1","worktreeId":"wt-1","subject":"Subject","bodyText":"Body","amend":false}"#.utf8)
        let state = try JSONDecoder().decode(DraftCommitTabState.self, from: data)

        #expect(state.preferredAction == .commit)
        #expect(state.createReviewRequestAsDraft == false)
        #expect(state.publishCheckpoint == nil)
    }

    @Test func roundTripsThroughCodable() throws {
        var s = DraftCommitTabState(worktreeId: "wt-1")
        s.subject = "feat: foo"
        s.bodyText = "Body\nmultiline"
        s.amend = true
        s.selectedPath = "src/foo.swift"
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(DraftCommitTabState.self, from: data)
        #expect(decoded == s)
    }

    @Test func localCommitPreferencePreservesDraftReviewRequestAndEmptyBody() throws {
        var state = DraftCommitTabState(worktreeId: "wt-1")
        state.subject = "Subject"
        state.createReviewRequestAsDraft = true
        let decoded = try JSONDecoder().decode(DraftCommitTabState.self, from: JSONEncoder().encode(state))
        #expect(decoded.preferredAction == .commit)
        #expect(decoded.createReviewRequestAsDraft)
        #expect(decoded.bodyText.isEmpty)
        let presentation = CommitPublishPresentation(subject: decoded.subject, hasStaged: true, availability: .gg())
        #expect(presentation.commit.isEnabled)
        #expect(presentation.publish?.isEnabled == true)
    }

    @Test func roundTripsPersistedPublishIntentAndPresentationRevision() throws {
        var state = DraftCommitTabState(worktreeId: "wt-1")
        state.preferredAction = .publish
        state.createReviewRequestAsDraft = true
        state.publishCheckpoint = CommitPublishCheckpoint(
            commitSHA: "abc123",
            baseRef: "main",
            commitTitle: "abc123 Subject",
            subject: "Subject",
            body: "Body",
            destination: .gg,
            nextPhase: .sync
        )
        state.prepareForNewCommit()
        state.prepareForNewCommit()
        let presentationID = state.presentationID

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(DraftCommitTabState.self, from: data)

        #expect(decoded == state)
        #expect(decoded.preferredAction == .publish)
        #expect(decoded.createReviewRequestAsDraft)
        #expect(decoded.publishCheckpoint == state.publishCheckpoint)
        #expect(decoded.presentationID == presentationID)
    }
}
