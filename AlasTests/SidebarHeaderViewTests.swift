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
        controller.view.frame = NSRect(x: 0, y: 0, width: 300, height: 42)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    @Test func headerRendersWithoutCrashing() {
        let controller = hostHeader()
        #expect(controller.view != nil)
    }

    @Test func sortMenuKeepsHeaderHeightAndAccessibilityLabel() throws {
        let controller = hostHeader()
        let fitted = controller.sizeThatFits(in: NSSize(width: 300, height: 100))
        let sortControls = accessibilityElements(in: controller.view, matching: "Sort worktrees")

        #expect(abs(fitted.height - 42) < 0.5)
        #expect(sortControls.count == 1)
        #expect(sortControls.first?.accessibilityRole() == .button)
        #expect(sortControls.first?.accessibilityActionNames().contains(.press) == true)
    }

    private func accessibilityElements(in view: NSView, matching expected: String) -> [NSView] {
        let matches = view.accessibilityLabel() == expected ? [view] : []
        return matches + view.subviews.flatMap {
            accessibilityElements(in: $0, matching: expected)
        }
    }
}
