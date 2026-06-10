import AppKit
import SwiftUI
import Testing
@testable import Alas

@MainActor
struct ChatPaneTests {
    private func currentTheme() -> Theme {
        try! ThemeStore().current
    }

    @Test func chatPaneRendersWithoutCrashing() {
        let view = ChatPane(state: AppState())
            .environment(\.theme, currentTheme())
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(!controller.view.subviews.isEmpty)
    }

    @Test func chatPaneDefinesMovedChatControls() {
        #expect(ChatPane.groupTitles == [
            "Appearance",
            "Launcher (⌥⌘T)",
            "Composer",
            "Sessions",
        ])
        #expect(ChatPane.rowLabels == [
            "Font family",
            "Font size",
            "Default launch surface",
            "While busy, ⏎ queues; ⌥⏎ steers",
            "Confirm before closing chat tabs",
            "⚡ Auto-run",
        ])
    }
}
