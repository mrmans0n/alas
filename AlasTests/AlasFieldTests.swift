import Testing
import SwiftUI
import AppKit
@testable import Alas

@Suite(.serialized)
@MainActor
struct AlasFieldTests {
    private func currentTheme() -> Theme {
        try! ThemeStore().current
    }

    @Test func fieldWithLeadingIconRendersWithoutCrashing() {
        let view = AlasField(
            text: .constant("test"),
            placeholder: "Placeholder",
            leadingIcon: "magnifyingglass"
        )
        .environment(\.theme, currentTheme())

        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(!controller.view.subviews.isEmpty)
    }

    @Test func fieldWithoutLeadingIconRendersWithoutCrashing() {
        let view = AlasField(text: .constant("test"))
            .environment(\.theme, currentTheme())

        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(!controller.view.subviews.isEmpty)
    }
}
