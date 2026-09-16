import Testing
import SwiftUI
import AppKit
@testable import Alas

/// Smoke tests for SidebarHeaderView to guard against crashes when rendering.
@Suite(.serialized)
@MainActor
struct SidebarHeaderViewTests {
    private func currentTheme() -> Theme {
        try! ThemeStore().current
    }

    private func hostHeader() -> NSHostingController<AnyView> {
        let view = SidebarHeaderView(
            worktreeSortMode: .lastUpdateDesc,
            onSetWorktreeSortMode: { _ in },
            onSettings: {},
            onAddProject: {},
            onSearch: {},
            onHideSidebar: {}
        )
        .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: AnyView(view))
        controller.view.frame = NSRect(x: 0, y: 0, width: 300, height: 38)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    @Test func headerRendersWithoutCrashing() {
        let controller = hostHeader()
        #expect(controller.view.fittingSize.height > 0)
    }

    @Test func sortMenuKeepsHeaderHeightAndAccessibilityLabel() throws {
        let controller = hostHeader()
        let fitted = controller.sizeThatFits(in: NSSize(width: 300, height: 100))
        let sortControls = accessibilityElements(in: controller.view, matching: "Sort worktrees")

        // E1 pins the header to a fixed 38px band rather than padding around
        // the control height.
        #expect(abs(fitted.height - 38) < 0.5)
        #expect(sortControls.count == 1)
        #expect(sortControls.first?.accessibilityRole() == .button)
        // `accessibilityActionNames()` is the deprecated informal-protocol query.
        // The NSAccessibility protocols express "exposes the press action" as
        // conformance to NSAccessibilityButton, which NSButton declares.
        let sortControl = try #require(sortControls.first)
        #expect(sortControl is NSAccessibilityButton)
    }

    @Test func sortAccessibilityButtonHasNoVisibleChromeOrFocus() {
        let controller = hostHeader()
        let sortButton = accessibilityElements(in: controller.view, matching: "Sort worktrees").first as? NSButton

        #expect(sortButton?.title == "")
        #expect(sortButton?.isBordered == false)
        #expect(sortButton?.acceptsFirstResponder == false)
    }

    @Test func sidebarHeaderButtonsAreSquare() {
        // E1's header buttons are 23x23; the app-wide default stays 26x22 so
        // the tab bar, right pane and ACP toolbars are unaffected.
        #expect(ToolbarControlMetrics.sidebarHeader.width == 23)
        #expect(ToolbarControlMetrics.sidebarHeader.height == 23)
        #expect(ToolbarControlMetrics.sidebarHeader.cornerRadius == 6)
        #expect(ToolbarControlMetrics.standard.width == 26)
        #expect(ToolbarControlMetrics.standard.height == 22)
        #expect(ToolbarControlMetrics.standard.cornerRadius == 5)
    }

    private func accessibilityElements(in view: NSView, matching expected: String) -> [NSView] {
        let matches = view.accessibilityLabel() == expected ? [view] : []
        return matches + view.subviews.flatMap {
            accessibilityElements(in: $0, matching: expected)
        }
    }
}
