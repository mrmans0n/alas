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

    @Test func reusedHoverContentRefreshesDiagnosticLinkRoutes() throws {
        let hostWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        hostWindow.contentView = editor
        let theme = try Theme.loadBundled(id: "cool-slate")
        let controller = HoverWindowController()
        defer { controller.hide() }
        var routes: [String] = []

        showLink("[Quick Fixes](alas-diagnostic://actions)", in: controller, editor: editor, theme: theme) { url in
            routes.append("A \(url.host ?? "")")
            return true
        }
        clickFirstLink(in: hostWindow)

        showLink("[Related](alas-diagnostic://related/0)", in: controller, editor: editor, theme: theme) { url in
            routes.append("B \(url.host ?? "")")
            return true
        }
        clickFirstLink(in: hostWindow)

        showLink("[Documentation](https://example.test/docs)", in: controller, editor: editor, theme: theme) { url in
            routes.append("hover \(url.host ?? "")")
            return true
        }
        clickFirstLink(in: hostWindow)

        showLink("[Quick Fixes](alas-diagnostic://actions) [Related](alas-diagnostic://related/0)", in: controller, editor: editor, theme: theme) { url in
            routes.append("B \(url.host ?? "")")
            return true
        }
        clickLink(in: hostWindow, at: 0)
        clickLink(in: hostWindow, at: 1)

        #expect(routes == ["A actions", "B related", "hover example.test", "B actions", "B related"])
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

    private func showLink(
        _ markdown: String,
        in controller: HoverWindowController,
        editor: NSTextView,
        theme: Theme,
        onOpenLink: @escaping (URL) -> Bool
    ) {
        let result = MarkdownRenderer().render(
            document: Document(parsing: markdown),
            theme: theme,
            monospacedFontFamily: "SF Mono",
            monospacedFontSize: 13,
            baseDirectory: URL(fileURLWithPath: "/")
        )
        controller.show(
            result: result,
            size: HoverFeatureTesting.computePreferredSize(for: result),
            theme: theme,
            anchor: NSRect(x: 10, y: 10, width: 1, height: 14),
            in: editor,
            onWillPresentMermaidViewer: {},
            onOpenLink: onOpenLink
        )
        editor.window?.childWindows?.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
    }

    private func clickFirstLink(in hostWindow: NSWindow) {
        clickLink(in: hostWindow, at: 0)
    }

    private func clickLink(in hostWindow: NSWindow, at index: Int) {
        let panel = try! #require(hostWindow.childWindows?.first)
        let textView = try! #require(firstTextView(in: panel.contentView))
        var links: [(Any, NSRange)] = []
        textView.textStorage?.enumerateAttribute(.link, in: NSRange(location: 0, length: textView.string.utf16.count)) { value, range, _ in
            if let value { links.append((value, range)) }
        }
        let link = try! #require(links.indices.contains(index) ? links[index] : nil)
        _ = textView.delegate?.textView?(textView, clickedOnLink: link.0, at: link.1.location)
    }

    private func firstTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView { return textView }
        for child in view.subviews {
            if let textView = firstTextView(in: child) { return textView }
        }
        return nil
    }
}
