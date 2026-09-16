import Testing
import Foundation
@testable import Alas

/// The workspace tree renders as one flat row list, so each checkout draws its
/// own rail segment and has to know whether a sibling follows.
struct WorkspaceSidebarRailTests {
    private let a = UUID()
    private let b = UUID()
    private let w = UUID()

    @Test func lastRowNeverContinues() {
        #expect(!WorkspaceSidebarLayout.rowContinuesRail(rows: [.checkout(a)], after: 0))
    }

    @Test func indexPastTheEndDoesNotCrash() {
        #expect(!WorkspaceSidebarLayout.rowContinuesRail(rows: [.checkout(a)], after: 7))
    }

    @Test func anotherCheckoutContinuesTheRail() {
        let rows: [WorkspaceSidebarRow] = [.checkout(a), .checkout(b)]
        #expect(WorkspaceSidebarLayout.rowContinuesRail(rows: rows, after: 0))
    }

    @Test func expandedMembersContinueTheRail() {
        // Members render beneath their checkout; the rail runs past them.
        let rows: [WorkspaceSidebarRow] = [.checkout(a), .member(b), .checkout(b)]
        #expect(WorkspaceSidebarLayout.rowContinuesRail(rows: rows, after: 0))
        #expect(WorkspaceSidebarLayout.rowContinuesRail(rows: rows, after: 1))
    }

    @Test func aFollowingWorkspaceHeaderStopsTheRail() {
        // Otherwise the last checkout trails a stub into the next workspace.
        let rows: [WorkspaceSidebarRow] = [.checkout(a), .workspace(w)]
        #expect(!WorkspaceSidebarLayout.rowContinuesRail(rows: rows, after: 0))
    }

    @Test func aFollowingProjectRowStopsTheRail() {
        let rows: [WorkspaceSidebarRow] = [.checkout(a), .project("p1")]
        #expect(!WorkspaceSidebarLayout.rowContinuesRail(rows: rows, after: 0))
    }

    @Test func aFollowingFormerWorkspaceHeaderStopsTheRail() {
        let rows: [WorkspaceSidebarRow] = [.checkout(a), .formerWorkspace]
        #expect(!WorkspaceSidebarLayout.rowContinuesRail(rows: rows, after: 0))
    }
}
