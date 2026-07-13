import Testing
@testable import Alas

struct BaseResolutionMappingTests {
    typealias Mode = AppConfig.Changes.ChangesComparisonMode

    @Test func autoMapsToOriginFirst() {
        #expect(GitService.BaseResolution.forCommits(mode: .auto, userOverrodeBaseBranch: false) == .baseOriginFirst)
    }
    @Test func branchUpstreamMapsToUpstreamThenBase() {
        #expect(GitService.BaseResolution.forCommits(mode: .branchUpstream, userOverrodeBaseBranch: false) == .upstreamThenBase)
    }
    @Test func manualMapsToLocalFirst() {
        #expect(GitService.BaseResolution.forCommits(mode: .manual, userOverrodeBaseBranch: false) == .baseLocalFirst)
    }
    @Test func perWorktreeOverrideForcesLocalFirstRegardlessOfMode() {
        #expect(GitService.BaseResolution.forCommits(mode: .auto, userOverrodeBaseBranch: true) == .baseLocalFirst)
        #expect(GitService.BaseResolution.forCommits(mode: .branchUpstream, userOverrodeBaseBranch: true) == .baseLocalFirst)
    }
    @Test func reviewLoopBaseIsOriginFirstExceptManualAndOverride() {
        #expect(GitService.BaseResolution.forReviewLoopBase(mode: .auto, userOverrodeBaseBranch: false) == .baseOriginFirst)
        #expect(GitService.BaseResolution.forReviewLoopBase(mode: .branchUpstream, userOverrodeBaseBranch: false) == .baseOriginFirst)
        #expect(GitService.BaseResolution.forReviewLoopBase(mode: .manual, userOverrodeBaseBranch: false) == .baseLocalFirst)
        #expect(GitService.BaseResolution.forReviewLoopBase(mode: .auto, userOverrodeBaseBranch: true) == .baseLocalFirst)
    }
}
