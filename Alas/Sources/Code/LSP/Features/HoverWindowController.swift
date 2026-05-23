import AppKit
import SwiftUI

@MainActor
final class HoverWindowController {
    private let overlay = EditorOverlayPanel()
    private var hostingController: NSHostingController<HoverPopupView>?

    var isVisible: Bool { overlay.isVisible }

    var screenFrame: NSRect? { overlay.screenFrame }

    func show(
        result: MarkdownRenderResult,
        size: NSSize,
        theme: Theme,
        anchor: NSRect,
        in textView: CodeTextView
    ) {
        let root = HoverPopupView(result: result, theme: theme)
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
        overlay.hide()
    }
}

struct HoverPopupView: View {
    let result: MarkdownRenderResult
    let theme: Theme

    var body: some View {
        HoverPopupContent(result: result, theme: theme)
            .background(Color(nsColor: NSColor(theme.color("bg-1"))))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct HoverPopupContent: NSViewRepresentable {
    let result: MarkdownRenderResult
    let theme: Theme

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()
        textView.isEditable = false
        textView.drawsBackground = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        scrollView.drawsBackground = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder

        context.coordinator.textView = textView
        textView.textStorage?.setAttributedString(result.attributedString)
        scrollView.backgroundColor = NSColor(theme.color("bg-1"))
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        textView.textStorage?.setAttributedString(result.attributedString)
        nsView.backgroundColor = NSColor(theme.color("bg-1"))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView? {
            didSet { textView?.delegate = self }
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL {
                NSWorkspace.shared.open(url)
            } else if let string = link as? String, let url = URL(string: string) {
                NSWorkspace.shared.open(url)
            }
            return true
        }
    }
}
