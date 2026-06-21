import SwiftUI
import AppKit

struct ACPMarkdownInlineTextView: NSViewRepresentable {
    private static let defaultFittingWidth: CGFloat = 240
    private static let minimumFittingWidth: CGFloat = 80

    let source: String
    let typography: ACPChatTypography
    let role: ACPMarkdownInlineRole
    let theme: Theme

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = ACPMarkdownInlineNSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.backgroundColor = .clear
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        let rendered = ACPMarkdownInlineRenderer.makeAttributedString(
            source: source,
            theme: theme,
            typography: typography,
            role: role
        )
        textView.textStorage?.setAttributedString(rendered)
        context.coordinator.loadRemoteImages(in: textView, attributedString: rendered)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let fallbackWidth = nsView.bounds.width > 1 ? nsView.bounds.width : Self.defaultFittingWidth
        let width = max(Self.minimumFittingWidth, proposal.width ?? fallbackWidth)
        return (nsView as? ACPMarkdownInlineNSTextView)?.fittingSize(for: width)
            ?? CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }

    @MainActor
    final class Coordinator {
        private let imageLoader = MarkdownImageLoader()
        private var generation = 0

        func loadRemoteImages(in textView: NSTextView, attributedString: NSAttributedString) {
            generation += 1
            _ = imageLoader
            _ = textView
            _ = attributedString
        }
    }
}

private final class ACPMarkdownInlineNSTextView: NSTextView {
    private let minimumFittingWidth: CGFloat = 80

    func fittingSize(for width: CGFloat) -> CGSize {
        let fittingWidth = max(minimumFittingWidth, width)
        guard let textContainer, let layoutManager else {
            return CGSize(width: fittingWidth, height: 0)
        }

        textContainer.containerSize = CGSize(width: fittingWidth, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return CGSize(width: fittingWidth, height: ceil(used.height))
    }

    override var intrinsicContentSize: NSSize {
        fittingSize(for: bounds.width)
    }
}
