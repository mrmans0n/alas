import AppKit
import SwiftUI
import Testing
@testable import Alas

/// Guards the menu style behind `ToolbarMenuButton`.
///
/// `.menuStyle(.borderlessButton)` swaps the SwiftUI label for an AppKit
/// `SwiftUIPopupButton` that renders the glyph alone, so the hover fill never
/// draws and the label is never hit-tested — the reason three earlier attempts
/// at hover and press feedback had no visible effect. Both checks below fail
/// on that style and pass on `.menuStyle(.button)`.
@MainActor
struct ToolbarMenuButtonSurfaceTests {
    private func hostedMenuButton() -> NSHostingView<some View> {
        let view = ToolbarMenuButton(iconName: "sparkle", help: "Launch agent") {
            Button("Item") {}
        }
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func appKitDescendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + appKitDescendants(of: $0) }
    }

    @Test("menu-backed toolbar controls keep their label in SwiftUI")
    func menuButtonDoesNotDelegateItsLabelToAnAppKitPopUpButton() {
        let host = hostedMenuButton()
        let popUps = appKitDescendants(of: host).filter {
            $0 is NSPopUpButton || String(describing: type(of: $0)).localizedCaseInsensitiveContains("popupbutton")
        }
        #expect(popUps.isEmpty, "Label handed to an AppKit pop-up button: \(popUps.map { String(describing: type(of: $0)) })")
    }

    @Test("menu-backed toolbar controls keep the full toolbar surface size")
    func menuButtonMatchesStandardToolbarControlMetrics() {
        let size = hostedMenuButton().fittingSize
        #expect(size.width == ToolbarControlMetrics.standard.width)
        #expect(size.height == ToolbarControlMetrics.standard.height)
    }
}

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
