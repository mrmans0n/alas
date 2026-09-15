import Testing
import CoreGraphics
@testable import Alas

/// The rail lives on the container and the elbow/dot live on each row, so
/// these constants are the only thing keeping them aligned.
struct SidebarTreeGuideTests {
    @Test func elbowStartsExactlyOnTheRail() {
        // A row's leading edge is `indent` right of the rail, so an elbow
        // offset of -indent puts its left end on the rail itself.
        #expect(SidebarTreeGuide.elbowOffsetX == -SidebarTreeGuide.indent)
    }

    @Test func elbowReachesFromRailTowardTheRow() {
        // The elbow must span part but not all of the gap: touching the rail
        // at one end, stopping short of the row at the other.
        #expect(SidebarTreeGuide.elbowWidth > 0)
        #expect(SidebarTreeGuide.elbowWidth < SidebarTreeGuide.indent)
    }

    @Test func selectionDotIsCentredOnTheRail() {
        let dotLeft = SidebarTreeGuide.selectionDotOffsetX + SidebarTreeGuide.indent
        let dotCentre = dotLeft + SidebarTreeGuide.selectionDotDiameter / 2
        let railCentre = SidebarTreeGuide.railWidth / 2
        #expect(abs(dotCentre - railCentre) < 0.001)
    }

    @Test func selectionDotIsWiderThanTheRail() {
        // Otherwise it reads as a thickening of the line, not a marker.
        #expect(SidebarTreeGuide.selectionDotDiameter > SidebarTreeGuide.railWidth)
    }

    @Test func matchesE1Metrics() {
        #expect(SidebarTreeGuide.indent == 13)
        #expect(SidebarTreeGuide.railWidth == 1)
        #expect(SidebarTreeGuide.elbowWidth == 8)
        #expect(SidebarTreeGuide.elbowOffsetY == 16)
        #expect(SidebarTreeGuide.selectionDotDiameter == 5)
        #expect(SidebarTreeGuide.selectionDotOffsetY == 13)
    }
}
