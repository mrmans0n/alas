import Testing
import SwiftUI
import AppKit
@testable import Alas

/// Smoke tests for SidebarHeaderView to guard against crashes when rendering
/// with the right-sidebar reveal button visible and hidden.
@Suite(.serialized)
@MainActor
struct SidebarHeaderViewTests {
    private func currentTheme() -> Theme {
        try! ThemeStore().current
    }

    @Test func headerWithHiddenRightSidebarRendersWithoutCrashing() {
        let view = SidebarHeaderView(
            onSettings: {},
            onAddProject: {},
            onSearch: {},
            onRevealRightSidebar: {},
            rightSidebarHidden: true
        )
        .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    @Test func headerWithVisibleRightSidebarRendersWithoutCrashing() {
        let view = SidebarHeaderView(
            onSettings: {},
            onAddProject: {},
            onSearch: {},
            onRevealRightSidebar: {},
            rightSidebarHidden: false
        )
        .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }
}
