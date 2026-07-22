import Testing
@testable import Alas

@MainActor
@Suite("ACP composer focus policy")
struct ACPComposerFocusPolicyTests {
    @Test("finishing first-run connecting requests composer focus")
    func finishingFirstRunConnectingRequestsComposerFocus() {
        let next = ACPComposerFocusPolicy.focusRequest(
            current: 3,
            oldFirstRunConnecting: true,
            newFirstRunConnecting: false,
            composerReady: true
        )

        #expect(next == 4)
    }

    @Test("non-ready first-run transitions keep the current focus request")
    func nonReadyFirstRunTransitionsKeepCurrentFocusRequest() {
        #expect(ACPComposerFocusPolicy.focusRequest(
            current: 3,
            oldFirstRunConnecting: true,
            newFirstRunConnecting: true,
            composerReady: true
        ) == 3)

        #expect(ACPComposerFocusPolicy.focusRequest(
            current: 3,
            oldFirstRunConnecting: false,
            newFirstRunConnecting: false,
            composerReady: true
        ) == 3)

        #expect(ACPComposerFocusPolicy.focusRequest(
            current: 3,
            oldFirstRunConnecting: true,
            newFirstRunConnecting: false,
            composerReady: false
        ) == 3)
    }
}
