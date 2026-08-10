import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct PairedPrimaryComposerSurfaceTests {
    @Test func reviewRequestTitleAndBodyUsePairedBindings() async throws {
        let model = ReviewRequestComposerModel(title: "Review title", body: "Review body")
        let controller = NSHostingController(rootView: ReviewRequestComposerHarness(model: model, theme: try! ThemeStore().current))
        let window = attach(controller)
        await drain(controller.view)

        let title = try #require(firstSubview(of: PairedTextFieldBackingView.self, in: controller.view))
        #expect(window.makeFirstResponder(title))
        let titleEditor = try #require(window.fieldEditor(false, for: title) as? NSTextView)
        let coordinator = try #require(title.delegate as? PairedTextField.Coordinator)
        titleEditor.setSelectedRange(NSRange(location: 0, length: model.title.utf16.count))
        #expect(!coordinator.control(
            title,
            textView: titleEditor,
            shouldChangeCharactersIn: NSRange(location: 0, length: model.title.utf16.count),
            replacementString: "`")
        )
        #expect(model.title == "`Review title`")

        let body = try #require(firstSubview(of: PairedDelimiterTextView.self, in: controller.view))
        body.setSelectedRange(NSRange(location: 0, length: model.body.utf16.count))
        body.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(model.body == "`Review body`")

        window.orderOut(nil)
    }

    @Test func ggSplitMessageInvokesDraftChangeAfterPairedEdit() async throws {
        let model = GGSplitMessageModel(message: "split")
        var draftChanges: [String] = []
        let controller = NSHostingController(rootView: GGSplitMessageHarness(model: model) {
            draftChanges.append(model.message)
        })
        let window = attach(controller)
        await drain(controller.view)

        let field = try #require(firstSubview(of: PairedTextFieldBackingView.self, in: controller.view))
        let editor = try #require(field.currentEditor() as? NSTextView)
        let coordinator = try #require(field.delegate as? PairedTextField.Coordinator)
        editor.setSelectedRange(NSRange(location: 0, length: 5))
        #expect(!coordinator.control(
            field,
            textView: editor,
            shouldChangeCharactersIn: NSRange(location: 0, length: 5),
            replacementString: "`")
        )
        await drain(controller.view)

        #expect(model.message == "`split`")
        #expect(draftChanges == ["`split`"])
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
private final class ReviewRequestComposerModel: ObservableObject {
    @Published var title: String
    @Published var body: String

    init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

@MainActor
private struct ReviewRequestComposerHarness: View {
    @ObservedObject var model: ReviewRequestComposerModel
    let theme: Theme

    var body: some View {
        CommitMessageEditorView(
            subject: $model.title,
            bodyText: $model.body,
            aiToolId: .constant(""),
            title: "GitHub Pull Request",
            busy: false,
            error: nil,
            availableAgents: [],
            onGenerate: {},
            primaryAction: CommitPrimaryAction(label: "Create Pull Request", isEnabled: true, handler: {}),
            iconName: "branch"
        )
        .environment(\.theme, theme)
    }
}

@MainActor
private final class GGSplitMessageModel: ObservableObject {
    @Published var message: String

    init(message: String) {
        self.message = message
    }
}

@MainActor
private struct GGSplitMessageHarness: View {
    @ObservedObject var model: GGSplitMessageModel
    let draftDidChange: () -> Void

    var body: some View {
        PairedTextField(
            text: $model.message,
            placeholder: "Commit message",
            isFocused: .constant(true)
        )
        .frame(height: 22)
        .onChange(of: model.message) { draftDidChange() }
    }
}
