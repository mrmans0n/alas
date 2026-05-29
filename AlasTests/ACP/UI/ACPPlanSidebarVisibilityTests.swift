import Foundation
import Testing
@testable import Alas

@Suite("ACPPlanSidebarVisibility")
struct ACPPlanSidebarVisibilityTests {

    @Test("no plan → hidden regardless of width")
    func hiddenWithoutPlan() {
        #expect(ACPPlanSidebarVisibility.next(paneWidth: 2000, hasPlan: false, current: false) == false)
        #expect(ACPPlanSidebarVisibility.next(paneWidth: 2000, hasPlan: false, current: true)  == false)
        #expect(ACPPlanSidebarVisibility.next(paneWidth: 500,  hasPlan: false, current: false) == false)
    }

    @Test("width ≥ 900 with plan → shown")
    func showsAtOrAboveShowThreshold() {
        #expect(ACPPlanSidebarVisibility.next(paneWidth: 900,  hasPlan: true, current: false) == true)
        #expect(ACPPlanSidebarVisibility.next(paneWidth: 1200, hasPlan: true, current: false) == true)
        #expect(ACPPlanSidebarVisibility.next(paneWidth: 900,  hasPlan: true, current: true)  == true)
    }

    @Test("width < 820 with plan → hidden")
    func hidesBelowHideThreshold() {
        #expect(ACPPlanSidebarVisibility.next(paneWidth: 819, hasPlan: true, current: true)  == false)
        #expect(ACPPlanSidebarVisibility.next(paneWidth: 500, hasPlan: true, current: true)  == false)
        #expect(ACPPlanSidebarVisibility.next(paneWidth: 819, hasPlan: true, current: false) == false)
    }

    @Test("dead band 820–900 with plan → keep current")
    func deadBandLatches() {
        // Currently shown → stays shown
        #expect(ACPPlanSidebarVisibility.next(paneWidth: 850, hasPlan: true, current: true)  == true)
        #expect(ACPPlanSidebarVisibility.next(paneWidth: 820, hasPlan: true, current: true)  == true)
        #expect(ACPPlanSidebarVisibility.next(paneWidth: 899, hasPlan: true, current: true)  == true)
        // Currently hidden → stays hidden
        #expect(ACPPlanSidebarVisibility.next(paneWidth: 850, hasPlan: true, current: false) == false)
        #expect(ACPPlanSidebarVisibility.next(paneWidth: 820, hasPlan: true, current: false) == false)
        #expect(ACPPlanSidebarVisibility.next(paneWidth: 899, hasPlan: true, current: false) == false)
    }

    @Test("crossing up from below to ≥ 900 shows")
    func crossingUpShows() {
        var v = false
        v = ACPPlanSidebarVisibility.next(paneWidth: 700, hasPlan: true, current: v) // hidden
        #expect(v == false)
        v = ACPPlanSidebarVisibility.next(paneWidth: 850, hasPlan: true, current: v) // dead band, stays hidden
        #expect(v == false)
        v = ACPPlanSidebarVisibility.next(paneWidth: 920, hasPlan: true, current: v) // crosses up
        #expect(v == true)
    }

    @Test("crossing down from above to < 820 hides")
    func crossingDownHides() {
        var v = true
        v = ACPPlanSidebarVisibility.next(paneWidth: 1000, hasPlan: true, current: v) // shown
        #expect(v == true)
        v = ACPPlanSidebarVisibility.next(paneWidth: 850, hasPlan: true, current: v) // dead band, stays shown
        #expect(v == true)
        v = ACPPlanSidebarVisibility.next(paneWidth: 700, hasPlan: true, current: v) // crosses down
        #expect(v == false)
    }

    @Test("plan disappears mid-shown → hides immediately")
    func planRemovalForcesHide() {
        #expect(ACPPlanSidebarVisibility.next(paneWidth: 1500, hasPlan: false, current: true) == false)
    }

    @Test("thresholds are 900 show / 820 hide")
    func thresholdConstants() {
        #expect(ACPPlanSidebarVisibility.showThreshold == 900)
        #expect(ACPPlanSidebarVisibility.hideThreshold == 820)
    }
}
