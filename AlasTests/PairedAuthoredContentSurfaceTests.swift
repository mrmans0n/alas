import AppKit
import Combine
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct PairedAuthoredContentSurfaceTests {
    @Test func promptEditorDraftBindingWrapsSelectedCommand() async throws {
        let model = PromptDraftCapture(text: "prompt command")
        let controller = NSHostingController(rootView: PromptEditorHarness(model: model))
        let window = attach(controller)
        await drain(controller.view)

        wrapSelection(in: try #require(textView(containing: "prompt command", in: controller.view)))

        #expect(model.text == "`prompt command`")
        window.orderOut(nil)
    }

    @Test func terminalStartupScriptBindingWrapsSelectedCommand() async throws {
        let state = AppState(store: MemoryStore())
        state.config.terminal.startupScript = "terminal command"
        let controller = NSHostingController(rootView: TerminalPane(state: state)
            .environment(\.theme, try! ThemeStore().current))
        let window = attach(controller, height: 620)
        await drain(controller.view)

        wrapSelection(in: try #require(textView(containing: "terminal command", in: controller.view)))

        #expect(state.config.terminal.startupScript == "`terminal command`")
        window.orderOut(nil)
    }

    @Test func projectStartupScriptBindingWrapsSelectedCommandBeforeSave() async throws {
        let model = ProjectStartupScriptCapture(text: "project command")
        let controller = NSHostingController(rootView: ProjectStartupScriptHarness(model: model))
        let window = attach(controller)
        await drain(controller.view)

        wrapSelection(in: try #require(textView(containing: "project command", in: controller.view)))

        #expect(model.text == "`project command`")
        window.orderOut(nil)
    }

    private func attach<Content: View>(
        _ controller: NSHostingController<Content>,
        height: CGFloat = 320
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func drain(_ view: NSView) async {
        for _ in 0..<6 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
            await Task.yield()
        }
    }

    private func textView(containing text: String, in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView, textView.string == text {
            return textView
        }
        return view.subviews.lazy.compactMap { textView(containing: text, in: $0) }.first
    }

    private func wrapSelection(in textView: NSTextView) {
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))
        if let pairedTextView = textView as? PairedDelimiterTextView {
            pairedTextView.performKeyboardTextInsertion {
                pairedTextView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        } else {
            textView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }
}

@MainActor
private final class PromptDraftCapture: ObservableObject {
    @Published var text: String

    init(text: String) {
        self.text = text
    }
}

@MainActor
private struct PromptEditorHarness: View {
    @ObservedObject var model: PromptDraftCapture

    var body: some View {
        PromptEditorBody(
            windowTitle: "Prompt",
            title: "Prompt title",
            description: "Prompt description",
            draftPrompt: $model.text,
            onReset: {},
            onCancel: {},
            onSave: {},
            theme: try! ThemeStore().current
        )
    }
}

@MainActor
private final class ProjectStartupScriptCapture: ObservableObject {
    @Published var text: String

    init(text: String) {
        self.text = text
    }
}

@MainActor
private struct ProjectStartupScriptHarness: View {
    @ObservedObject var model: ProjectStartupScriptCapture

    var body: some View {
        ProjectStartupScriptEditor(text: $model.text, minHeight: 60)
            .environment(\.theme, try! ThemeStore().current)
    }
}

private struct MemoryStore: PersistenceStoreProtocol {
    var projectsFile: ProjectsFile? = nil

    func write<T: Encodable>(_: T, to _: URL) throws {}

    func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? {
        if T.self == ProjectsFile.self {
            return projectsFile as? T
        }
        return nil
    }
}
