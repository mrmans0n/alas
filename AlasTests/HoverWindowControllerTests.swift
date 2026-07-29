import AppKit
import Markdown
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct HoverWindowControllerTests {
    @Test func isVisibleStartsFalse() {
        let controller = HoverWindowController()
        #expect(controller.isVisible == false)
    }

    @Test func compactAttachmentUsesMenuInsteadOfVisibleHeaderActions() {
        let attachment = MermaidTextAttachment(
            id: "mermaid-0",
            source: "graph TD; A-->B",
            profile: .compact
        )
        let cell = attachment.mermaidCell
        let frame = NSRect(
            origin: .zero,
            size: NSSize(width: 500, height: cell.cellSize.height)
        )
        let layout = cell.layoutFrames(in: frame)

        #expect(layout.header == nil)
        #expect(layout.sourceButton == .zero)
        #expect(layout.copyButton == .zero)
        #expect(layout.expandButton == .zero)
        #expect(cell.menu?.items.map(\.title) == [
            "Show Mermaid source",
            "Copy Mermaid source"
        ])

        cell.setSourceVisible(true)

        #expect(cell.menu?.items.map(\.title) == [
            "Show Mermaid diagram",
            "Copy Mermaid source"
        ])
    }

    @Test func hoverReplacesCompactAttachmentWorkAndDismissesBeforeExpansion() throws {
        let hostWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let editor = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        hostWindow.contentView = editor
        let theme = try Theme.loadBundled(id: "cool-slate")
        let first = renderMermaid("graph TD; first-->result", theme: theme)
        let second = renderMermaid("graph TD; second-->result", theme: theme)
        let firstCell = try #require(first.mermaidAttachments.first?.attachment.mermaidCell)
        let secondCell = try #require(second.mermaidAttachments.first?.attachment.mermaidCell)
        let controller = HoverWindowController()
        defer {
            MermaidDiagramViewerController.shared.dismiss()
            controller.hide()
        }

        controller.show(
            result: first,
            size: HoverFeatureTesting.computePreferredSize(for: first),
            theme: theme,
            anchor: NSRect(x: 10, y: 10, width: 1, height: 14),
            in: editor,
            onWillPresentMermaidViewer: { [weak controller] in
                controller?.hide()
            }
        )

        #expect(firstCell.delegate != nil)

        controller.show(
            result: second,
            size: HoverFeatureTesting.computePreferredSize(for: second),
            theme: theme,
            anchor: NSRect(x: 10, y: 10, width: 1, height: 14),
            in: editor,
            onWillPresentMermaidViewer: { [weak controller] in
                controller?.hide()
            }
        )
        hostWindow.childWindows?.forEach {
            $0.contentViewController?.view.layoutSubtreeIfNeeded()
        }

        #expect(firstCell.delegate == nil)
        #expect(secondCell.delegate != nil)
        #expect(controller.isVisible)

        secondCell.delegate?.mermaidTextAttachmentCellDidRequestExpansion(
            secondCell
        )

        #expect(!controller.isVisible)
        #expect(hostWindow.attachedSheet?.title == "Mermaid Diagram")
    }

    private func renderMermaid(
        _ source: String,
        theme: Theme
    ) -> MarkdownRenderResult {
        MarkdownRenderer().render(
            document: Document(
                parsing: "```mermaid\n\(source)\n```"
            ),
            theme: theme,
            monospacedFontFamily: "SF Mono",
            monospacedFontSize: 13,
            baseDirectory: URL(fileURLWithPath: "/"),
            mermaidProfile: .compact
        )
    }
}
