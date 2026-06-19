import Testing
@testable import Alas

struct ReviewTabViewTests {
    @Test func loadingPresentationKeepsLoadedSessionVisibleDuringRefresh() {
        #expect(ReviewTabLoadingPresentation.showsBlockingLoader(isLoading: true, hasSession: false))
        #expect(!ReviewTabLoadingPresentation.showsBlockingLoader(isLoading: true, hasSession: true))
        #expect(!ReviewTabLoadingPresentation.showsBlockingLoader(isLoading: false, hasSession: true))
    }

    @Test func loadErrorPresentationReplacesStaleLoadedSessionAfterRefreshFailure() {
        #expect(ReviewTabLoadingPresentation.showsLoadError(
            loadError: "failed",
            isLoading: false,
            hasSession: true
        ))
        #expect(!ReviewTabLoadingPresentation.showsLoadError(
            loadError: "failed",
            isLoading: true,
            hasSession: false
        ))
        #expect(!ReviewTabLoadingPresentation.showsLoadError(
            loadError: nil,
            isLoading: false,
            hasSession: true
        ))
    }

    @Test func pendingReviewRailOnlyShowsForStagedComments() {
        #expect(!ReviewTabPendingReviewPresentation.showsRail(stagedCount: 0))
        #expect(ReviewTabPendingReviewPresentation.showsRail(stagedCount: 1))
    }

    @Test func finishReviewToolbarButtonRequiresSubmitCapabilityAndPendingReviewScope() {
        #expect(ReviewTabPendingReviewPresentation.showsToolbarFinishButton(
            canSubmitReview: true,
            hasPendingReviewScope: true
        ))
        #expect(!ReviewTabPendingReviewPresentation.showsToolbarFinishButton(
            canSubmitReview: false,
            hasPendingReviewScope: true
        ))
        #expect(!ReviewTabPendingReviewPresentation.showsToolbarFinishButton(
            canSubmitReview: true,
            hasPendingReviewScope: false
        ))
    }
}
