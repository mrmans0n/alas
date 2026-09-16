import Testing
@testable import Alas

struct TabBarToolbarPresentationTests {
    @Test("menu controls stay lit while hovered or pressed")
    func menuControlsStayLitWhileHoveredOrPressed() {
        #expect(!ToolbarMenuControlPresentation.isLit(hovering: false, isPressed: false))
        #expect(ToolbarMenuControlPresentation.isLit(hovering: true, isPressed: false))
        #expect(ToolbarMenuControlPresentation.isLit(hovering: false, isPressed: true))
        #expect(ToolbarMenuControlPresentation.isLit(hovering: true, isPressed: true))
    }
}
