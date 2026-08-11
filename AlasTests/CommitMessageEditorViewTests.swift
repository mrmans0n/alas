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
            error: error,
            availableAgents: [],
            onGenerate: {},
            primaryAction: CommitPrimaryAction(
                label: "Save message",
                savedLabel: "Saved",
                isEnabled: dirty && !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                showSavedState: !dirty,
                handler: onSave
            )
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

    @Test func pairedSubjectAndBodyWrapSelectedText() async throws {
        let model = CommitComposerModel(subject: "subject", body: "body")
        let controller = NSHostingController(rootView: CommitComposerHarness(model: model, theme: currentTheme()))
        let window = attach(controller)
        await drain(controller.view)

        let subject = try #require(firstSubview(of: PairedTextFieldBackingView.self, in: controller.view))
        #expect(window.makeFirstResponder(subject))
        let subjectEditor = try #require(subject.currentEditor() as? PairedDelimiterTextView)
        subjectEditor.setSelectedRange(NSRange(location: 0, length: 7))
        subjectEditor.performKeyboardTextInsertion {
            subjectEditor.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        await drain(controller.view)
        #expect(model.subject == "`subject`")

        let body = try #require(firstSubview(of: PairedDelimiterTextView.self, in: controller.view))
        body.setSelectedRange(NSRange(location: 0, length: 4))
        body.performKeyboardTextInsertion {
            body.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        #expect(model.body == "`body`")

        window.orderOut(nil)
    }

    private func attach<Content: View>(_ controller: NSHostingController<Content>) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func drain(_ view: NSView) async {
        view.layoutSubtreeIfNeeded()
        await Task.yield()
        view.layoutSubtreeIfNeeded()
    }

    private func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview) { return match }
        }
        return nil
    }
}

@MainActor
private final class CommitComposerModel: ObservableObject {
    @Published var subject: String
    @Published var body: String

    init(subject: String, body: String) {
        self.subject = subject
        self.body = body
    }
}

@MainActor
private struct CommitComposerHarness: View {
    @ObservedObject var model: CommitComposerModel
    let theme: Theme

    var body: some View {
        CommitMessageEditorView(
            subject: $model.subject,
            bodyText: $model.body,
            aiToolId: .constant(""),
            title: "Edit abc1234",
            busy: false,
            error: nil,
            availableAgents: [],
            onGenerate: {},
            primaryAction: CommitPrimaryAction(label: "Save", isEnabled: true, handler: {})
        )
        .environment(\.theme, theme)
    }
}
