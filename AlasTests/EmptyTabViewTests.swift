import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite("Empty tab view")
@MainActor
struct EmptyTabViewTests {
    private func currentTheme() -> Theme {
        try! ThemeStore().current
    }

    @Test("no-tabs empty state uses pleading face icon")
    func usesPleadingFaceIcon() {
        #expect(EmptyTabView.emptyIcon == "🥺")
    }

    @Test("no-tabs empty state renders")
    func emptyStateRenders() {
        let view = EmptyTabView(
            onNewTerminal: {},
            onNewAgentInChat: {},
            onNewAgentInTerminal: {},
            newTerminalShortcut: "⌘ T",
            newAgentInChatShortcut: nil,
            newAgentInTerminalShortcut: nil
        )
        .environment(\.theme, currentTheme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        controller.view.layoutSubtreeIfNeeded()

        #expect(controller.view.fittingSize.width > 0)
        #expect(controller.view.fittingSize.height > 0)
    }
}
