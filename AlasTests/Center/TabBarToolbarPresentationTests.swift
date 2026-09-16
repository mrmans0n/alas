import Testing
@testable import Alas

struct TabBarToolbarPresentationTests {
    @Test("menu controls distinguish idle, hover, and press presentation")
    func menuControlPresentationTracksInteraction() {
        #expect(ToolbarMenuControlPresentation.interactionState(hovering: false, isPressed: false) == .idle)
        #expect(ToolbarMenuControlPresentation.interactionState(hovering: true, isPressed: false) == .hovering)
        #expect(ToolbarMenuControlPresentation.interactionState(hovering: false, isPressed: true) == .pressed)
        #expect(ToolbarMenuControlPresentation.interactionState(hovering: true, isPressed: true) == .pressed)
    }

    @Test("menu controls stay lit while hovered or pressed")
    func menuControlsStayLitWhileHoveredOrPressed() {
        #expect(!ToolbarMenuControlPresentation.isLit(hovering: false, isPressed: false))
        #expect(ToolbarMenuControlPresentation.isLit(hovering: true, isPressed: false))
        #expect(ToolbarMenuControlPresentation.isLit(hovering: false, isPressed: true))
        #expect(ToolbarMenuControlPresentation.isLit(hovering: true, isPressed: true))
    }
}
