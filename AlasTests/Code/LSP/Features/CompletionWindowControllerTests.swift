import AppKit
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct CompletionWindowControllerTests {
    @Test func isVisibleStartsFalse() {
        let controller = CompletionWindowController()
        #expect(controller.isVisible == false)
    }

    @Test func documentationKeepsExistingPopupBounds() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let storage = NSTextStorage(string: "completion")
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(width: 800, height: 600)
        )
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        let textView = CodeTextView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            textContainer: textContainer
        )
        window.contentView = textView
        let theme = try Theme.loadBundled(id: "cool-slate")
        let documentation = CompletionDocumentationRenderer.render(
            "```mermaid\ngraph TD; A-->B\n```",
            theme: theme,
            monospacedFontFamily: "SF Mono",
            monospacedFontSize: 13
        )
        let cell = try #require(
            documentation.mermaidAttachments.first?.attachment.mermaidCell
        )
        let controller = CompletionWindowController()
        defer {
            MermaidDiagramViewerController.shared.dismiss()
            controller.hide()
        }

        controller.show(
            rows: [
                CompletionPopupRow(
                    id: UUID(),
                    label: "completion",
                    detail: nil,
                    kind: nil,
                    source: .lsp
                )
            ],
            selection: 0,
            documentation: documentation,
            theme: theme,
            anchor: NSRect(x: 10, y: 10, width: 1, height: 14),
            in: textView,
            onChoose: { _ in }
        )

        #expect(controller.screenFrame?.size == NSSize(width: 640, height: 260))
        #expect(cell.delegate != nil)

        cell.delegate?.mermaidTextAttachmentCellDidRequestExpansion(cell)

        #expect(!controller.isVisible)
        #expect(window.attachedSheet?.title == "Mermaid Diagram")
    }
}
