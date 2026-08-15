import AppKit
import Testing
@testable import Alas

struct IssueCompletionGeometryTests {
    @Test func popupAnchorExpandsToTheFieldChrome() {
        let anchor = IssueCompletionGeometry.popupAnchor(
            for: NSRect(x: 0, y: 0, width: 180, height: 28)
        )

        #expect(anchor.origin.x == -10)
        #expect(anchor.width == 200)
        #expect(anchor.height == 28)
    }
}
