import Testing
@testable import Alas

@Suite("Standalone AppKit diff scroller")
struct DiffPaneAppKitScrollerTests {
    @Test("only internally scrolling panes switch to AppKit")
    func switchContract() {
        #expect(DiffPaneView.usesAppKitScroller(flagEnabled: true, verticalScrollMode: .internalScroll))
        #expect(!DiffPaneView.usesAppKitScroller(flagEnabled: false, verticalScrollMode: .internalScroll))
        #expect(!DiffPaneView.usesAppKitScroller(flagEnabled: true, verticalScrollMode: .staticHeight))
    }
}
