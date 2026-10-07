import Foundation
import Testing
@testable import Alas

@Suite("ACPAdapterUpdateBannerDecider")
struct ACPAdapterUpdateBannerDeciderTests {
    @Test("missing setup state always prefers the install banner")
    func installTakesPrecedence() {
        let decision = ACPAdapterUpdateBannerDecider.decide(
            setupState: .needsSetup(reason: "missing"),
            updateState: .available(current: "1", latest: "2"),
            dismissedLatest: nil)
        #expect(decision == .showInstall)
    }

    @Test("setup errors take precedence over cached updates")
    func setupErrorTakesPrecedence() {
        let decision = ACPAdapterUpdateBannerDecider.decide(
            setupState: .setupError(reason: "broken"),
            updateState: .available(current: "1", latest: "2"),
            dismissedLatest: nil)
        #expect(decision == .none)
    }

    @Test("ready + available + no dismissal renders update")
    func readyShowsUpdate() {
        let decision = ACPAdapterUpdateBannerDecider.decide(
            setupState: .ready,
            updateState: .available(current: "1.0.0", latest: "1.1.0"),
            dismissedLatest: nil)
        #expect(decision == .showUpdate(current: "1.0.0", latest: "1.1.0"))
    }

    @Test("ready + available + matching dismissal renders nothing")
    func dismissalSuppresses() {
        let decision = ACPAdapterUpdateBannerDecider.decide(
            setupState: .ready,
            updateState: .available(current: "1.0.0", latest: "1.1.0"),
            dismissedLatest: "1.1.0")
        #expect(decision == .none)
    }

    @Test("dismissal does not suppress a newer latest")
    func newerLatestIgnoresOldDismissal() {
        let decision = ACPAdapterUpdateBannerDecider.decide(
            setupState: .ready,
            updateState: .available(current: "1.0.0", latest: "1.2.0"),
            dismissedLatest: "1.1.0")
        #expect(decision == .showUpdate(current: "1.0.0", latest: "1.2.0"))
    }

    @Test("ready + upToDate renders nothing")
    func upToDateRendersNothing() {
        let decision = ACPAdapterUpdateBannerDecider.decide(
            setupState: .ready,
            updateState: .upToDate,
            dismissedLatest: nil)
        #expect(decision == .none)
    }

    @Test("ready + unknown renders nothing (silent failure)")
    func unknownRendersNothing() {
        let decision = ACPAdapterUpdateBannerDecider.decide(
            setupState: .ready,
            updateState: .unknown,
            dismissedLatest: nil)
        #expect(decision == .none)
    }

    @Test("ready + nil update state (not yet checked) renders nothing")
    func notYetCheckedRendersNothing() {
        let decision = ACPAdapterUpdateBannerDecider.decide(
            setupState: .ready,
            updateState: nil,
            dismissedLatest: nil)
        #expect(decision == .none)
    }

    @Test("checking state with no update info renders nothing")
    func checkingRendersNothing() {
        let decision = ACPAdapterUpdateBannerDecider.decide(
            setupState: .checking,
            updateState: nil,
            dismissedLatest: nil)
        #expect(decision == .none)
    }

    @Test("adapter update outranks the agent CLI update until dismissed", arguments: [
        (AdapterUpdateState?.some(.available(current: "1", latest: "2")), String?.none,
         ACPAdapterUpdateBannerDecider.Decision.showUpdate(current: "1", latest: "2")),
        (.some(.available(current: "1", latest: "2")), "2", .showAgentUpdate(current: "3", latest: "4")),
        (.some(.upToDate), nil, .showAgentUpdate(current: "3", latest: "4")),
        (nil, nil, .showAgentUpdate(current: "3", latest: "4")),
    ])
    func agentUpdatePrecedence(
        adapterState: AdapterUpdateState?,
        adapterDismissed: String?,
        expected: ACPAdapterUpdateBannerDecider.Decision
    ) {
        let decision = ACPAdapterUpdateBannerDecider.decide(
            setupState: .ready,
            updateState: adapterState,
            dismissedLatest: adapterDismissed,
            agentUpdateState: .available(current: "3", latest: "4"),
            agentDismissedLatest: nil)
        #expect(decision == expected)
    }

    @Test("agent CLI update dismissal suppresses only that version")
    func agentUpdateDismissal() {
        let decide = { (dismissed: String) in
            ACPAdapterUpdateBannerDecider.decide(
                setupState: .ready,
                updateState: nil,
                dismissedLatest: nil,
                agentUpdateState: .available(current: "3", latest: "4"),
                agentDismissedLatest: dismissed)
        }
        #expect(decide("4") == .none)
        #expect(decide("3.5") == .showAgentUpdate(current: "3", latest: "4"))
    }

    @Test("generic failure visibility follows specialized setup banners", arguments: [
        (ACPSession.SetupState.checking, false, true),
        (.ready, false, true),
        (.needsSetup(reason: "missing"), false, false),
        (.needsSetup(reason: "missing"), true, true),
        (.setupError(reason: "broken"), false, false),
        (.needsAuth(methods: [], reason: nil), false, false),
    ])
    func genericFailureVisibility(
        setupState: ACPSession.SetupState,
        setupNudgeDismissed: Bool,
        expected: Bool
    ) {
        #expect(ACPAdapterUpdateBannerDecider.showsGenericFailure(
            setupState: setupState,
            setupNudgeDismissed: setupNudgeDismissed
        ) == expected)
    }
}
