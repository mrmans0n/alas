import Testing
import SwiftUI
import AppKit
@testable import Alas

@Suite(.serialized)
@MainActor
struct CommitMessageEditorViewTests {
    private func currentTheme() -> Theme {
        try! ThemeStore().current
    }

    private func makeView(
        subject: String = "feat: hello",
        bodyText: String = "",
        busy: Bool = false,
        dirty: Bool = true,
        error: String? = nil,
        onSave: @escaping () -> Void = {}
    ) -> some View {
        CommitMessageEditorView(
            subject: .constant(subject),
            bodyText: .constant(bodyText),
            aiToolId: .constant(""),
            title: "Edit abc1234",
            busy: busy,
            dirty: dirty,
            error: error,
            availableAgents: [],
            onGenerate: {},
            onSave: onSave
        )
        .environment(\.theme, currentTheme())
    }

    @Test func rendersWithoutCrashing() {
        let view = makeView()
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    @Test func rendersWhenBusy() {
        let view = makeView(busy: true)
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    @Test func rendersWhenNotDirty() {
        let view = makeView(dirty: false)
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    @Test func rendersWithError() {
        let view = makeView(error: "Something went wrong")
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    @Test func rendersWithEmptySubject() {
        let view = makeView(subject: "")
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }

    @Test func rendersWithWhitespaceOnlySubject() {
        let view = makeView(subject: "   ")
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view != nil)
    }
}
