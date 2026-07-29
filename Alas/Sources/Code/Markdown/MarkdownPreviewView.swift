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
        context.coordinator.reapplyTheme(theme)
        context.coordinator.apply(result: result)
        return context.coordinator.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onLinkClick = onLinkClick
        // Theme/accent/system-appearance changes can produce a new `theme`
        // value without recreating the coordinator, so we must push the new
        // chrome colors into the existing NSScrollView/NSTextView here.
        context.coordinator.reapplyTheme(theme)
        // SwiftUI may call this repeatedly with the same value. The result's
        // revision lets the controller preserve attachment tasks and source
        // disclosure across those duplicate updates.
        context.coordinator.apply(result: result)
    }
}
