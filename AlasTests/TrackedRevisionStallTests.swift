import Foundation
import Testing
@testable import Alas

struct TrackedRevisionStallTests {
    private func followed(_ target: TrackedRevisionTarget) throws -> TrackedRevision {
        try #require(TrackedRevision(
            target: target,
            baselineBranch: "nacho/my-feature",
            baselineHEAD: "head000",
            resolvedSHA: "sha111"
        ))
    }

    @Test func missingStackEntryBecomesAStall() throws {
        let current = try followed(.stackEntry(ggID: "c-abc1234"))

        let transition = TrackedRevisionPolicy.evaluate(
            current: current,
            error: TrackedRevisionResolverError.stackEntryNotFound("c-abc1234")
        )

        guard case .stall(let stalled) = transition else {
            Issue.record("expected .stall, got \(String(describing: transition))")
            return
        }
        #expect(stalled.unresolvedReason == .stackEntryMissing)
        // The tab keeps rendering the commit it already had.
        #expect(stalled.resolvedSHA == "sha111")
    }

    @Test func otherErrorsAreNotStalls() throws {
        let current = try followed(.expression("HEAD~2"))

        #expect(TrackedRevisionPolicy.evaluate(
            current: current,
            error: TrackedRevisionResolverError.unsupportedReflogExpression("push")
        ) == nil)

        struct Boom: Error {}
        #expect(TrackedRevisionPolicy.evaluate(current: current, error: Boom()) == nil)
    }

    @Test func aSuccessfulResolveAfterAStallClearsIt() throws {
        let stalled = try followed(.stackEntry(ggID: "c-abc1234"))
            .stalled(reason: .stackEntryMissing)

        let transition = TrackedRevisionPolicy.evaluate(
            current: stalled,
            candidate: TrackedRevisionCandidate(
                branch: "nacho/my-feature",
                sha: "sha222",
                headSHA: "head222"
            )
        )

        guard case .follow(let revision) = transition else {
            Issue.record("expected .follow, got \(transition)")
            return
        }
        #expect(revision.unresolvedReason == nil)
        #expect(revision.resolvedSHA == "sha222")
    }
}
