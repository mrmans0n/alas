import Foundation
import Testing
@testable import Alas

@Suite("ACPSetupNudgeBanner copy by mode")
struct ACPSetupNudgeBannerModeTests {
    @Test("install mode idle copy")
    func installIdleCopy() {
        let copy = ACPSetupNudgeBannerCopy.idleMessage(
            mode: .install,
            agentDisplayName: "Claude Code")
        #expect(copy == "Claude Code requires the ACP adapter to be installed.")
    }

    @Test("update mode idle copy shows both versions")
    func updateIdleCopy() {
        let copy = ACPSetupNudgeBannerCopy.idleMessage(
            mode: .update(current: "1.0.0", latest: "1.1.0"),
            agentDisplayName: "Claude Code")
        #expect(copy == "Claude Code adapter update available (1.0.0 → 1.1.0).")
    }

    @Test("install mode installed copy")
    func installInstalledCopy() {
        let copy = ACPSetupNudgeBannerCopy.installedMessage(
            mode: .install,
            agentDisplayName: "Claude Code")
        #expect(copy == "Claude Code adapter installed — connecting…")
    }

    @Test("update mode installed copy says updated")
    func updateInstalledCopy() {
        let copy = ACPSetupNudgeBannerCopy.installedMessage(
            mode: .update(current: "1.0.0", latest: "1.1.0"),
            agentDisplayName: "Claude Code")
        #expect(copy == "Claude Code adapter updated — reconnecting…")
    }

    @Test("button label is Install in install mode, Update in update mode")
    func buttonLabel() {
        #expect(ACPSetupNudgeBannerCopy.installButtonTitle(mode: .install, errored: false) == "Install")
        #expect(ACPSetupNudgeBannerCopy.installButtonTitle(mode: .update(current: "1", latest: "2"), errored: false) == "Update")
    }

    @Test("button label reads Retry on error in both modes")
    func retryLabel() {
        #expect(ACPSetupNudgeBannerCopy.installButtonTitle(mode: .install, errored: true) == "Retry")
        #expect(ACPSetupNudgeBannerCopy.installButtonTitle(mode: .update(current: "1", latest: "2"), errored: true) == "Retry")
    }

    @Test("installing copy by mode")
    func installingCopy() {
        #expect(ACPSetupNudgeBannerCopy.installingMessage(mode: .install, agentDisplayName: "Claude Code")
                == "Installing Claude Code adapter…")
        #expect(ACPSetupNudgeBannerCopy.installingMessage(
                    mode: .update(current: "1.0", latest: "1.1"),
                    agentDisplayName: "Claude Code")
                == "Updating Claude Code adapter…")
    }

    @Test("error copy by mode")
    func errorCopy() {
        #expect(ACPSetupNudgeBannerCopy.errorMessage(mode: .install, detail: "boom")
                == "Install failed: boom")
        #expect(ACPSetupNudgeBannerCopy.errorMessage(
                    mode: .update(current: "1.0", latest: "1.1"),
                    detail: "boom")
                == "Update failed: boom")
    }
}
