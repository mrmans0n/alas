import AppKit
import SwiftUI

@MainActor
final class CompletionWindowController {
    private let maxHeight: CGFloat = 260
    private let listWidth: CGFloat = 320

    private let overlay = EditorOverlayPanel()
    private let mermaidCancellation = MermaidRenderCancellation()
    private var hostingController: NSHostingController<CompletionPopup>?

    var isVisible: Bool { overlay.isVisible }

    var screenFrame: NSRect? { overlay.screenFrame }

    func show(
        rows: [CompletionPopupRow],
        selection: Int,
        documentation: MarkdownRenderResult?,
        theme: Theme,
        anchor: NSRect,
        in textView: CodeTextView,
        onChoose: @escaping (Int) -> Void
    ) {
        let hasDocumentation = (documentation?.attributedString.length ?? 0) > 0
        let size = NSSize(width: hasDocumentation ? listWidth * 2 : listWidth, height: maxHeight)
        let root = CompletionPopup(
            rows: rows,
            selection: selection,
            documentation: documentation,
            theme: theme,
            mermaidCancellation: mermaidCancellation,
            onChoose: onChoose,
            onWillPresentMermaidViewer: { [weak self] in
                self?.hide()
            }
        )
        if let hostingController {
            hostingController.rootView = root
        } else {
            hostingController = NSHostingController(rootView: root)
        }
        guard let hostingController else { return }
        overlay.show(
            contentViewController: hostingController,
            size: size,
            anchor: anchor,
            in: textView
        )
    }

    func hide() {
        mermaidCancellation.cancel()
        overlay.hide()
    }
}
