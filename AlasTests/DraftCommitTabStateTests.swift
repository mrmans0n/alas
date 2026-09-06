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
}
