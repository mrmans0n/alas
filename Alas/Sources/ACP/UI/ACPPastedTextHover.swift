import AppKit

/// Hover and click-to-pin popover for pasted-text chips in any
/// `NSTextView`: the composer and transcript paragraphs. Hovering shows the
/// preview after the shared delay and hides it when the pointer leaves the
/// chip. Clicking pins it: movement no longer hides it, and the transient
/// popover closes on the next outside click.
@MainActor
final class ACPPastedTextHoverController: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var showWork: DispatchWorkItem?
    private var target: NSRange?
    private(set) var isPinned = false

    func update(at point: NSPoint, in textView: NSTextView) {
        guard !isPinned else { return }
        guard let hit = ACPPastedTextChip.hit(at: point, in: textView) else {
            hide()
            return
        }
        guard target != hit.range else { return }
        hide()
        target = hit.range
        let work = DispatchWorkItem { [weak self, weak textView] in
            guard let self, let textView, self.target == hit.range else { return }
            self.present(hit.attachment, range: hit.range, in: textView)
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ACPImageChipHoverController.hoverDelay, execute: work)
    }

    func pin(_ attachment: ACPPastedTextChipAttachment, range: NSRange, in textView: NSTextView) {
        showWork?.cancel()
        showWork = nil
        if target != range || popover?.isShown != true {
            hide()
            target = range
            present(attachment, range: range, in: textView)
        }
        isPinned = popover?.isShown == true
    }

    func hideUnlessPinned() {
        if !isPinned { hide() }
    }

    func hide() {
        showWork?.cancel()
        showWork = nil
        target = nil
        isPinned = false
        popover?.performClose(nil)
        popover = nil
    }

    private func present(_ attachment: ACPPastedTextChipAttachment, range: NSRange, in textView: NSTextView) {
        guard let anchor = textView.upstreamReferenceAnchorRect(for: range) else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = ACPPastedTextPreviewController(label: attachment.label, content: attachment.content)
        popover.show(relativeTo: anchor, of: textView, preferredEdge: .maxY)
        self.popover = popover
    }

    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        popover = nil
        target = nil
        isPinned = false
    }
}

/// Popover content: the label and a Copy button over the pasted text in a
/// read-only, selectable, monospaced text view. Built only when shown.
final class ACPPastedTextPreviewController: NSViewController {
    static let size = NSSize(width: 520, height: 340)

    private let label: String
    private let content: String

    init(label: String, content: String) {
        self.label = label
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField(labelWithString: label)
        title.font = ACPMentionChipMetrics.labelFont
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyContent))
        copyButton.controlSize = .small
        let header = NSStackView(views: [title, copyButton])
        header.orientation = .horizontal

        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.textColor = .labelColor
            textView.textContainerInset = NSSize(width: 4, height: 4)
            textView.layoutManager?.allowsNonContiguousLayout = true
            textView.string = content
        }

        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        for view in [header, scrollView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        view = container
        preferredContentSize = Self.size
    }

    @objc private func copyContent() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }
}
