import AppKit
import SwiftUI
import Testing
@testable import Alas

/// Guards the construction of the split button's chevron half.
///
/// `.menuStyle(.borderlessButton)` renders the label inside an `NSPopUpButton`,
/// which ignores the label's frame (it sizes itself to the glyph, ~14pt) and
/// paints the glyph in its own label color. In a 26pt capsule that produced a
/// chevron tinted differently from the title, a segment background shorter than
/// the primary half, and dead click zones at the top and bottom of the segment.
/// No AppKit popup in the tree means the label stayed in SwiftUI, where the
/// frame and the inherited foreground style both apply.
@MainActor
@Suite("ACPComposerActionButton chevron half")
struct ACPComposerActionButtonChevronTests {
    @Test("send capsule renders its menu without an AppKit popup control")
    func sendCapsuleHasNoPopUpButton() {
        #expect(popUpButtons(in: .send).isEmpty)
    }

    @Test("queue capsule renders its menu without an AppKit popup control")
    func queueCapsuleHasNoPopUpButton() {
        #expect(popUpButtons(in: .queue(menu: [.steer, .stop])).isEmpty)
    }

    @Test("chevron padding keeps the segment narrower than the primary half")
    func chevronPaddingIsCompact() {
        #expect(ACPComposerActionButtonMetrics.chevronHorizontalPadding > 0)
        #expect(ACPComposerActionButtonMetrics.chevronHorizontalPadding * 2
                < ACPComposerActionButtonMetrics.capsuleHeight)
    }

    // MARK: - Helpers

    private func popUpButtons(in action: ComposerAction) -> [NSView] {
        let host = NSHostingView(
            rootView: ACPComposerActionButton(
                action: action,
                onPrimary: {},
                onMenu: { _ in },
                onSchedule: { _ in },
                queueBadgeCount: 0
            )
        )
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 60)
        host.layoutSubtreeIfNeeded()
        return descendants(of: host).filter { $0 is NSPopUpButton }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
