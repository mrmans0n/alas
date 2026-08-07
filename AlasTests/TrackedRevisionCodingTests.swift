import Foundation
import Testing
@testable import Alas

struct TrackedRevisionCodingTests {
    private func revision(target: TrackedRevisionTarget) throws -> TrackedRevision {
        try #require(TrackedRevision(
            target: target,
            baselineBranch: "nacho/my-feature",
            baselineHEAD: "head000",
            resolvedSHA: "sha111"
        ))
    }

    @Test func legacyRecordWithoutTargetDecodesAsExpression() throws {
        let json = #"""
        {"expression":"HEAD~2","baselineBranch":"feature","baselineHEAD":"h1","resolvedSHA":"s1"}
        """#

        let decoded = try JSONDecoder().decode(TrackedRevision.self, from: Data(json.utf8))

        #expect(decoded.target == .expression("HEAD~2"))
        #expect(decoded.resolvedSHA == "s1")
        #expect(decoded.unresolvedReason == nil)
    }

    @Test func expressionRoundTripsAndKeepsLegacyMirror() throws {
        let original = try revision(target: .expression("HEAD~2"))

        let data = try JSONEncoder().encode(original)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["expression"] as? String == "HEAD~2")
        #expect(try JSONDecoder().decode(TrackedRevision.self, from: data) == original)
    }

    @Test func stackEntryMirrorsResolvedSHAForDowngradedBuilds() throws {
        let original = try revision(target: .stackEntry(ggID: "c-abc1234"))

        let data = try JSONEncoder().encode(original)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        // A build that predates targets reads `expression` and degrades to a
        // pinned commit rather than failing to decode.
        #expect(json["expression"] as? String == "sha111")
        #expect(try JSONDecoder().decode(TrackedRevision.self, from: data) == original)
    }

    @Test func stackEntryNeverDependsOnWorktreeHEAD() throws {
        let expression = try revision(target: .expression("HEAD~2"))
        // A GG-ID that happens to spell "HEAD" is still not HEAD-relative,
        // so the checkout-pause path must never fire for it.
        let entry = try revision(target: .stackEntry(ggID: "HEAD"))

        #expect(expression.dependsOnWorktreeHEAD)
        #expect(!entry.dependsOnWorktreeHEAD)
    }

    @Test func stallSetsMessageAndResolvingClearsIt() throws {
        let stalled = try revision(target: .stackEntry(ggID: "c-abc1234"))
            .stalled(reason: .stackEntryMissing)

        #expect(stalled.unresolvedReason == .stackEntryMissing)
        #expect(stalled.unresolvedMessage == "Stack entry c-abc1234 is not in the current stack.")

        let resolved = stalled.resolving(
            TrackedRevisionCandidate(branch: "nacho/my-feature", sha: "sha222", headSHA: "head222")
        )

        #expect(resolved.unresolvedReason == nil)
        #expect(resolved.unresolvedMessage == nil)
        #expect(resolved.resolvedSHA == "sha222")
    }

    @Test func stallSurvivesCodableRoundTrip() throws {
        let stalled = try revision(target: .stackEntry(ggID: "c-abc1234"))
            .stalled(reason: .stackEntryMissing)

        let decoded = try JSONDecoder().decode(
            TrackedRevision.self,
            from: JSONEncoder().encode(stalled)
        )

        #expect(decoded == stalled)
    }

    @Test func emptyTargetIsRejected() {
        #expect(TrackedRevision(
            target: .stackEntry(ggID: "  "),
            baselineBranch: "b",
            resolvedSHA: "s"
        ) == nil)
    }
}
