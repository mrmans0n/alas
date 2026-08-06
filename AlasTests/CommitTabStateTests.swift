import Testing
import Foundation
@testable import Alas

struct CommitTabStateTests {
    @Test func legacyCommitJSONDecodesAsFixedRevision() throws {
        let json = #"{"id":"commit:wt:abc","worktreeId":"wt","sha":"abc","title":"Old"}"#

        let state = try JSONDecoder().decode(CommitTabState.self, from: Data(json.utf8))

        #expect(state.revision == .fixed(sha: "abc"))
        #expect(state.id == "commit:wt:abc")
        #expect(state.viewID == "commit:wt:abc")
    }

    @Test func idIsStablePerWorktreeAndSha() {
        let a = CommitTabState(worktreeId: "wt-1", sha: "a3f2c1d", title: "x")
        let b = CommitTabState(worktreeId: "wt-1", sha: "a3f2c1d", title: "different title")
        #expect(a.id == b.id)
        let c = CommitTabState(worktreeId: "wt-2", sha: "a3f2c1d", title: "x")
        #expect(a.id != c.id)
    }

    @Test func codableRoundTripPreservesAllFields() throws {
        let s = CommitTabState(worktreeId: "wt-1", sha: "deadbeefcafebabe", title: "fix: foo")
        let data = try JSONEncoder().encode(Tab.commit(s))
        let decoded = try JSONDecoder().decode(Tab.self, from: data)
        guard case .commit(let r) = decoded else {
            Issue.record("decoded tab was not .commit")
            return
        }
        #expect(r.id == s.id)
        #expect(r.worktreeId == "wt-1")
        #expect(r.viewID == s.viewID)
        #expect(r.sha == "deadbeefcafebabe")
        #expect(r.title == "fix: foo")
    }

    @Test func followedRevisionRoundTrips() throws {
        let tracked = try #require(TrackedRevision(
            expression: "HEAD~2", baselineBranch: "feature", resolvedSHA: "deadbeef"
        ))
        let state = CommitTabState(worktreeId: "wt", trackedRevision: tracked, title: "Follow HEAD")

        let decoded = try JSONDecoder().decode(
            CommitTabState.self,
            from: JSONEncoder().encode(state)
        )

        #expect(decoded == state)
        #expect(decoded.revision == .following(tracked))
        #expect(decoded.sha == "deadbeef")
        #expect(decoded.fixedSHA == nil)
    }

    @Test func fixedSHAOnlyMatchesImmutableCommitRevisions() throws {
        let fixed = CommitTabState(worktreeId: "wt", sha: "deadbeef", title: "Fixed")
        let tracked = try #require(TrackedRevision(
            expression: "HEAD~2", baselineBranch: "feature", resolvedSHA: "deadbeef"
        ))
        let followed = CommitTabState(worktreeId: "wt", trackedRevision: tracked, title: "Follow")

        #expect(fixed.fixedSHA == "deadbeef")
        #expect(followed.sha == "deadbeef")
        #expect(followed.fixedSHA == nil)
    }

    @Test func commitViewIDSurvivesFollowAndFixRekeys() throws {
        var state = CommitTabState(worktreeId: "wt", sha: "old", title: "Old")
        let viewID = state.viewID
        let tracked = try #require(TrackedRevision(
            expression: "HEAD~2", baselineBranch: "feature", resolvedSHA: "new"
        ))

        state.follow(tracked)
        #expect(state.id != viewID)
        #expect(state.viewID == viewID)

        state.fix(sha: "new")
        #expect(state.id == "commit:wt:new")
        #expect(state.viewID == viewID)
    }

    @Test func trackedRevisionTrimsExpressionAndClassifiesHEADDependence() throws {
        let headRelative = try #require(TrackedRevision(
            expression: "  HEAD~3  ", baselineBranch: "feature", resolvedSHA: "old"
        ))
        let headAlias = try #require(TrackedRevision(
            expression: " \n@{upstream}", baselineBranch: "feature", resolvedSHA: "old"
        ))
        let namedRef = try #require(TrackedRevision(
            expression: " topic~2 ", baselineBranch: "feature", resolvedSHA: "old"
        ))
        let headPrefixRef = try #require(TrackedRevision(
            expression: "HEAD-feature", baselineBranch: "feature", resolvedSHA: "old"
        ))
        let atPrefixRef = try #require(TrackedRevision(
            expression: "@feature", baselineBranch: "feature", resolvedSHA: "old"
        ))

        #expect(headRelative.expression == "HEAD~3")
        #expect(headRelative.dependsOnWorktreeHEAD)
        #expect(headAlias.dependsOnWorktreeHEAD)
        #expect(!namedRef.dependsOnWorktreeHEAD)
        #expect(!headPrefixRef.dependsOnWorktreeHEAD)
        #expect(!atPrefixRef.dependsOnWorktreeHEAD)
        #expect(TrackedRevision(expression: " \n ", baselineBranch: "feature", resolvedSHA: "old") == nil)
    }

    @Test func resolverRejectsTimeRelativeReflogExpressions() async throws {
        let resolver = TrackedRevisionResolver(
            resolve: { _, _ in
                Issue.record("time-relative selector should be rejected before resolving")
                return "unused"
            },
            branch: { _ in
                Issue.record("time-relative selector should be rejected before reading branch")
                return "unused"
            }
        )

        do {
            _ = try await resolver.resolve(at: URL(fileURLWithPath: "/repo"), expression: "HEAD@{5 minutes ago}")
            Issue.record("Expected time-relative reflog selector to throw")
        } catch let error as TrackedRevisionResolverError {
            #expect(error == .unsupportedReflogExpression("5 minutes ago"))
        }
    }

    @Test func resolverRejectsPushReflogSelector() async throws {
        let resolver = TrackedRevisionResolver(
            resolve: { _, _ in
                Issue.record("@{push} should be rejected before resolving")
                return "unused"
            },
            branch: { _ in
                Issue.record("@{push} should be rejected before reading branch")
                return "unused"
            }
        )

        do {
            _ = try await resolver.resolve(at: URL(fileURLWithPath: "/repo"), expression: "@{push}")
            Issue.record("Expected @{push} selector to throw")
        } catch let error as TrackedRevisionResolverError {
            #expect(error == .unsupportedReflogExpression("push"))
        }
    }

    @Test func resolverAllowsHeadIndependentRevisionOnUnbornBranch() async throws {
        let resolver = TrackedRevisionResolver(
            resolve: { _, ref in
                if ref == "HEAD" { throw ResolverTestError.missingHEAD }
                if ref == "v1.0" { return "tag-sha" }
                throw ResolverTestError.unexpectedRef(ref)
            },
            branch: { _ in "orphan" }
        )

        let candidate = try await resolver.resolve(at: URL(fileURLWithPath: "/repo"), expression: "v1.0")

        #expect(candidate == TrackedRevisionCandidate(branch: "orphan", sha: "tag-sha", headSHA: ""))
    }

    @Test func headRelativeRevisionFollowsMovementOnSameBranch() throws {
        let current = try #require(TrackedRevision(
            expression: "HEAD~3", baselineBranch: "feature", resolvedSHA: "old"
        ))
        let candidate = TrackedRevisionCandidate(branch: "feature", sha: "new")

        #expect(TrackedRevisionPolicy.evaluate(current: current, candidate: candidate)
            == .follow(current.resolving(candidate)))
    }

    @Test func headRelativeRevisionPausesWhenBranchChanges() throws {
        let current = try #require(TrackedRevision(
            expression: " HEAD~3 ", baselineBranch: "feature", resolvedSHA: "old"
        ))
        let candidate = TrackedRevisionCandidate(branch: "main", sha: "new")

        #expect(TrackedRevisionPolicy.evaluate(current: current, candidate: candidate)
            == .pause(current.withPendingCheckout(candidate)))
    }

    @Test func headRelativeRevisionPausesWhenDetachedHeadChanges() throws {
        let current = try #require(TrackedRevision(
            expression: "HEAD~3", baselineBranch: "", baselineHEAD: "detached-old", resolvedSHA: "old"
        ))
        let candidate = TrackedRevisionCandidate(branch: "", sha: "new", headSHA: "detached-new")

        #expect(TrackedRevisionPolicy.evaluate(current: current, candidate: candidate)
            == .pause(current.withPendingCheckout(candidate)))
    }

    @Test func namedRefFollowsAcrossUnrelatedCheckout() throws {
        let current = try #require(TrackedRevision(
            expression: "topic~2", baselineBranch: "feature", resolvedSHA: "old"
        ))
        let candidate = TrackedRevisionCandidate(branch: "main", sha: "new")

        #expect(TrackedRevisionPolicy.evaluate(current: current, candidate: candidate)
            == .follow(current.resolving(candidate)))
    }

    @Test func unchangedSHAMetadataRefreshesWithoutReloading() throws {
        let revision = try #require(TrackedRevision(
            expression: "HEAD~3", baselineBranch: "feature", resolvedSHA: "same"
        ))
        let current = revision.withPendingCheckout(TrackedRevisionCandidate(branch: "main", sha: "other"))
        let candidate = TrackedRevisionCandidate(branch: "main", sha: "same")

        #expect(TrackedRevisionPolicy.evaluate(current: current, candidate: candidate)
            == .unchanged(current.resolving(candidate)))
    }

    @Test func acceptingPendingCheckoutAdoptsPendingRevision() throws {
        let current = try #require(TrackedRevision(
            expression: "HEAD~3", baselineBranch: "feature", resolvedSHA: "old"
        ))
        let candidate = TrackedRevisionCandidate(branch: "main", sha: "new")

        #expect(current.withPendingCheckout(candidate).acceptingPendingCheckout()
            == current.resolving(candidate))
        #expect(current.acceptingPendingCheckout() == nil)
    }

    @Test func preparingPendingCheckoutAcceptancePreservesDisplayedSHA() throws {
        let current = try #require(TrackedRevision(
            expression: "HEAD~3",
            baselineBranch: "feature",
            baselineHEAD: "feature-head",
            resolvedSHA: "old"
        ))
        let candidate = TrackedRevisionCandidate(branch: "main", sha: "new", headSHA: "main-head")

        let prepared = try #require(current.withPendingCheckout(candidate).preparingPendingCheckoutAcceptance())

        #expect(prepared.baselineBranch == "main")
        #expect(prepared.baselineHEAD == "main-head")
        #expect(prepared.resolvedSHA == "old")
        #expect(prepared.pendingCheckout == nil)
    }

    @Test func trackedRevisionRetargeterFollowsAndStopsReviewRecords() throws {
        let fixedTarget = ReviewSessionTarget.commit(
            worktreeID: "wt",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "aaa",
            title: "Review aaa"
        )
        let record = ReviewSessionRecord(
            id: fixedTarget.id,
            target: fixedTarget,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let revision = try #require(TrackedRevision(
            expression: "HEAD~2", baselineBranch: "feature", resolvedSHA: "bbb"
        ))

        let followed = try #require(TrackedRevisionRetargeter.follow(
            record: record,
            revision: revision,
            title: "Review HEAD~2",
            now: Date(timeIntervalSince1970: 2)
        ))
        let stopped = try #require(TrackedRevisionRetargeter.stop(
            record: followed.record,
            title: "Review bbb",
            now: Date(timeIntervalSince1970: 3)
        ))

        #expect(followed.oldDraftSessionID == fixedTarget.draftSessionID)
        #expect(followed.newDraftSessionID == followed.record.target.draftSessionID)
        #expect(followed.record.target.draftSessionID.sourceKind == .trackedCommit)
        #expect(stopped.oldDraftSessionID == followed.record.target.draftSessionID)
        #expect(stopped.newDraftSessionID.sourceKind == .commit)
        #expect(stopped.record.target.payload == .commit(sha: "bbb"))
    }

    @Test func trackedRevisionRetargeterPreservesVerdictWhenExpressionChangesOnly() throws {
        let original = try #require(TrackedRevision(
            expression: "HEAD~2", baselineBranch: "feature", resolvedSHA: "bbb"
        ))
        let edited = try #require(TrackedRevision(
            expression: "topic", baselineBranch: "feature", resolvedSHA: "bbb"
        ))
        let target = ReviewSessionTarget.trackedCommit(
            worktreeID: "wt",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            revision: original,
            title: "Review HEAD~2"
        )
        let record = ReviewSessionRecord(
            id: target.id,
            target: target,
            status: .reviewed,
            verdict: ReviewSessionVerdict(
                verdict: .approve,
                summary: "Same bytes",
                reviewedAt: Date(timeIntervalSince1970: 1)
            ),
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )

        let retargeted = try #require(TrackedRevisionRetargeter.follow(
            record: record,
            revision: edited,
            title: "Review topic",
            now: Date(timeIntervalSince1970: 2)
        ))

        #expect(retargeted.record.status == .reviewed)
        #expect(retargeted.record.verdict == record.verdict)
    }

    @Test func trackedRevisionRetargeterRekeysRecordsWhenTargetChanges() throws {
        let target = ReviewSessionTarget.commit(
            worktreeID: "wt",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "source",
            title: "Source"
        )
        let record = ReviewSessionRecord(
            id: target.id,
            target: target,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let revision = try #require(TrackedRevision(
            expression: "HEAD~2",
            baselineBranch: "feature",
            resolvedSHA: "tracked"
        ))

        let retargeted = try #require(TrackedRevisionRetargeter.follow(
            record: record,
            revision: revision,
            title: "Review HEAD~2",
            now: Date(timeIntervalSince1970: 2)
        ))

        #expect(retargeted.oldRecordID == record.id)
        #expect(retargeted.record.id != record.id)
        #expect(retargeted.record.id.rawValue.contains(retargeted.record.target.id.rawValue))
    }

    @Test func trackedRevisionDecodingNormalizesExpressionAndPreservesPendingCheckout() throws {
        let json = """
        {
          "expression": "  HEAD~2  ",
          "baselineBranch": "feature",
          "resolvedSHA": "old",
          "pendingCheckout": { "branch": "main", "sha": "new" }
        }
        """

        let revision = try JSONDecoder().decode(TrackedRevision.self, from: Data(json.utf8))

        #expect(revision.expression == "HEAD~2")
        #expect(revision.pendingCheckout == TrackedRevisionCandidate(branch: "main", sha: "new"))
        #expect(try JSONDecoder().decode(TrackedRevision.self, from: JSONEncoder().encode(revision)) == revision)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(TrackedRevision.self, from: Data("""
            { "expression": "  ", "baselineBranch": "feature", "resolvedSHA": "old" }
            """.utf8))
        }
    }

    @Test func trackedRevisionResolverRetriesWhenCheckoutInterleavesResolution() async throws {
        let sequence = RevisionSnapshotSequence(
            branches: ["feature", "main", "main", "main"],
            heads: ["feature-head", "main-head", "main-head", "main-head"],
            shas: ["feature-sha", "main-sha"]
        )
        let resolver = TrackedRevisionResolver(
            resolve: { _, ref in await sequence.nextSHA(for: ref) },
            branch: { _ in await sequence.nextBranch() }
        )

        let candidate = try await resolver.resolve(at: URL(fileURLWithPath: "/repo"), expression: "HEAD~2")

        #expect(candidate == TrackedRevisionCandidate(branch: "main", sha: "main-sha", headSHA: "main-head"))
    }

    @Test func trackedRevisionResolverPinsHEADRelativeExpressionAcrossTrueABA() async throws {
        let sequence = MixedCheckoutRevisionSequence()
        let resolver = TrackedRevisionResolver(
            resolve: { _, ref in await sequence.resolve(ref) },
            branch: { _ in "feature" }
        )

        let candidate = try await resolver.resolve(at: URL(fileURLWithPath: "/repo"), expression: "HEAD~2")

        #expect(candidate == TrackedRevisionCandidate(
            branch: "feature",
            sha: "feature-expression-sha",
            headSHA: "feature-head"
        ))
        #expect(await sequence.requestedRefs == ["HEAD", "feature-head~2", "HEAD"])
    }

    @Test func trackedRevisionResolverTrimsBeforePinningHEADRelativeExpression() async throws {
        let sequence = PinnedExpressionSequence(
            rawExpression: "  HEAD^  ",
            pinnedExpression: "feature-head^"
        )
        let resolver = TrackedRevisionResolver(
            resolve: { _, ref in await sequence.resolve(ref) },
            branch: { _ in "feature" }
        )

        let candidate = try await resolver.resolve(at: URL(fileURLWithPath: "/repo"), expression: "  HEAD^  ")

        #expect(candidate == TrackedRevisionCandidate(
            branch: "feature",
            sha: "feature-expression-sha",
            headSHA: "feature-head"
        ))
        #expect(await sequence.requestedRefs == ["HEAD", "feature-head^", "HEAD"])
    }

    @Test func trackedRevisionResolverPinsHEADAliasRelativeExpressionAcrossTrueABA() async throws {
        let sequence = PinnedExpressionSequence(
            rawExpression: "@~2",
            pinnedExpression: "feature-head~2"
        )
        let resolver = TrackedRevisionResolver(
            resolve: { _, ref in await sequence.resolve(ref) },
            branch: { _ in "feature" }
        )

        let candidate = try await resolver.resolve(at: URL(fileURLWithPath: "/repo"), expression: "@~2")

        #expect(candidate == TrackedRevisionCandidate(
            branch: "feature",
            sha: "feature-expression-sha",
            headSHA: "feature-head"
        ))
        #expect(await sequence.requestedRefs == ["HEAD", "feature-head~2", "HEAD"])
    }
}

private actor MixedCheckoutRevisionSequence {
    private(set) var requestedRefs: [String] = []

    func resolve(_ ref: String) -> String {
        requestedRefs.append(ref)
        switch ref {
        case "HEAD":
            return "feature-head"
        case "HEAD~2":
            // Simulates resolving the raw expression after HEAD moved to main,
            // then returning to feature before validation.
            return "main-expression-sha"
        case "feature-head~2":
            return "feature-expression-sha"
        default:
            Issue.record("Unexpected revision expression: \(ref)")
            return "unexpected"
        }
    }
}

private actor PinnedExpressionSequence {
    private let rawExpression: String
    private let pinnedExpression: String
    private(set) var requestedRefs: [String] = []

    init(rawExpression: String, pinnedExpression: String) {
        self.rawExpression = rawExpression
        self.pinnedExpression = pinnedExpression
    }

    func resolve(_ ref: String) -> String {
        requestedRefs.append(ref)
        switch ref {
        case "HEAD":
            return "feature-head"
        case pinnedExpression:
            return "feature-expression-sha"
        case rawExpression:
            // Simulates resolving the raw expression after HEAD moved to main,
            // then returning to feature before validation.
            return "main-expression-sha"
        default:
            Issue.record("Unexpected revision expression: \(ref)")
            return "unexpected"
        }
    }
}

private actor RevisionSnapshotSequence {
    private var branches: [String]
    private var heads: [String]
    private var shas: [String]

    init(
        branches: [String],
        heads: [String] = [],
        shas: [String]
    ) {
        self.branches = branches
        self.heads = heads
        self.shas = shas
    }

    func nextBranch() -> String {
        branches.removeFirst()
    }

    func nextSHA(for ref: String) -> String {
        ref == "HEAD" ? heads.removeFirst() : shas.removeFirst()
    }
}

private enum ResolverTestError: Error, Equatable {
    case missingHEAD
    case unexpectedRef(String)
}
