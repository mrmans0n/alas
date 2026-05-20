import Testing
import SwiftUI
import AppKit
@testable import Alas

@Suite(.serialized)
@MainActor
struct CodeLanguageDetailViewTests {
    private func currentTheme() -> Theme {
        try! ThemeStore().current
    }

    @Test func newLanguageViewRendersWithoutCrashing() {
        let config = LanguageServerConfig(
            language: "",
            extensions: [],
            command: "",
            args: [],
            env: [:],
            rootMarkers: [],
            enabled: true
        )
        let view = CodeLanguageDetailView(
            initial: config,
            isNew: true,
            onSave: { _, _ in },
            onCancel: {}
        )
        .environment(\.theme, currentTheme())

        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(!controller.view.subviews.isEmpty)
    }

    @Test func existingLanguageViewRendersWithoutCrashing() {
        let config = LanguageServerConfig(
            language: "swift",
            extensions: ["swift"],
            command: "sourcekit-lsp",
            args: [],
            env: [:],
            rootMarkers: [],
            enabled: true
        )
        let view = CodeLanguageDetailView(
            initial: config,
            isNew: false,
            onSave: { _, _ in },
            onCancel: {}
        )
        .environment(\.theme, currentTheme())

        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(!controller.view.subviews.isEmpty)
    }
}
