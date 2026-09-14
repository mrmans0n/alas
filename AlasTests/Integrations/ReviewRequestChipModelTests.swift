import Foundation
import Testing
@testable import Alas

struct ReviewRequestChipModelTests {
    private func remote(kind: CodeHostKind) -> CodeHostRemote {
        CodeHostRemote(
            kind: kind, host: "example.com", owner: "acme", repository: "app",
            remoteName: "origin", webURL: URL(string: "https://example.com/acme/app")!
        )
    }

    private func check(_ bucket: ReviewCheckBucket) -> ReviewCheck {
        ReviewCheck(
            id: bucket.rawValue, name: bucket.rawValue, workflow: nil,
            bucket: bucket, detailURL: nil, completedAt: nil
        )
    }

    private func request(
        kind: CodeHostKind = .github,
        number: Int = 512,
        state: ReviewRequestState = .open,
        isDraft: Bool = false,
        reviewDecision: ReviewDecision = .reviewRequired,
        checks: [ReviewCheck] = []
    ) -> ReviewRequest {
        ReviewRequest(
            remote: remote(kind: kind),
            number: number,
            title: "t",
            url: URL(string: "https://example.com/acme/app/pull/\(number)")!,
            state: state,
            isDraft: isDraft,
            headRefName: "feature",
            baseRefName: "main",
            reviewDecision: reviewDecision,
            mergeState: .unknown,
            checks: checks,
            threads: []
        )
    }

    @Test func githubUsesHashPrefixGitlabUsesBang() {
        #expect(GGStackChipModel.model(for: request(kind: .github)).label == "#512")
        #expect(GGStackChipModel.model(for: request(kind: .gitlab)).label == "!512")
    }

    @Test func approvedAddsCheckmark() {
        #expect(GGStackChipModel.model(for: request(reviewDecision: .approved)).label == "#512 ✓")
    }

    @Test func stateMapsToColorToken() {
        #expect(GGStackChipModel.model(for: request(state: .open)).colorToken == "add")
        #expect(GGStackChipModel.model(for: request(state: .open, isDraft: true)).colorToken == "fg-muted")
        #expect(GGStackChipModel.model(for: request(state: .merged)).colorToken == "accent")
        #expect(GGStackChipModel.model(for: request(state: .closed)).colorToken == "del")
    }

    @Test func draftOnlyMattersWhileOpen() {
        #expect(GGStackChipModel.model(for: request(state: .merged, isDraft: true)).colorToken == "accent")
    }

    @Test func helpLabelUsesHostTerminology() {
        #expect(GGStackChipModel.model(for: request(kind: .github)).helpLabel == "Open PR #512")
        #expect(GGStackChipModel.model(for: request(kind: .gitlab)).helpLabel == "Open MR !512")
        #expect(GGStackChipModel.model(for: request(reviewDecision: .approved)).helpLabel == "Open PR #512")
    }

    @Test func ciStatusIsNilWithoutChecks() {
        #expect(GGCIStatus.rollup(of: request(checks: [])) == nil)
    }

    @Test func ciStatusFollowsWorstBucket() {
        #expect(GGCIStatus.rollup(of: request(checks: [check(.pass), check(.pass)])) == .success)
        #expect(GGCIStatus.rollup(of: request(checks: [check(.pass), check(.pending)])) == .pending)
        #expect(GGCIStatus.rollup(of: request(checks: [check(.pending), check(.fail)])) == .failed)
        #expect(GGCIStatus.rollup(of: request(checks: [check(.cancel)])) == .canceled)
        #expect(GGCIStatus.rollup(of: request(checks: [check(.unknown)])) == .unknown)
        #expect(GGCIStatus.rollup(of: request(checks: [check(.skipping)])) == .success)
    }
}
