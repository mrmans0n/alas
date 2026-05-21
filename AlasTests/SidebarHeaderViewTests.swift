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

    @Test func headerRendersWithoutCrashing() {
        let view = SidebarHeaderView(
            onSettings: {},
            onAddProject: {},
            onSearch: {}
        )
        .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }
}
