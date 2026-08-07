import Foundation
import Testing
@testable import Alas

struct RevisionFollowCapabilityTests {
    @Test func defaultsKeepStackEntryOff() {
        let capability = RevisionFollowCapability(isSupported: true, isFollowing: false)
        #expect(!capability.supportsStackEntry)
    }

    @Test func stackEntrySupportRequiresRevisionSupport() {
        // A tab kind that cannot follow at all never offers stack entries,
        // however gg is configured.
        let capability = RevisionFollowCapability(
            isSupported: false,
            isFollowing: false,
            supportsStackEntry: true
        )
        #expect(!capability.supportsStackEntry)
    }

    @Test func supportedTabInAGGWorktreeOffersStackEntries() {
        let capability = RevisionFollowCapability(
            isSupported: true,
            isFollowing: true,
            supportsStackEntry: true
        )
        #expect(capability.supportsStackEntry)
    }
}
