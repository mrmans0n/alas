import SwiftUI
import AppKit

struct MarkdownPreviewView: NSViewRepresentable {
    let result: MarkdownRenderResult
    let onLinkClick: (URL) -> Void
    @Environment(\.theme) var theme

    func makeCoordinator() -> MarkdownPreviewController {
        MarkdownPreviewController(theme: theme)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.onLinkClick = onLinkClick
        context.coordinator.apply(result: result)
        return context.coordinator.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onLinkClick = onLinkClick
        context.coordinator.apply(result: result)
    }
}
