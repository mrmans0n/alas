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
}
