import AppKit

/// Coordinator for `MarkdownPreviewView`. Owns the read-only `NSTextView`,
/// intercepts link clicks, and asynchronously loads remote images by
/// patching the text storage in place. Held by SwiftUI's `Coordinator` slot.
@MainActor
final class MarkdownPreviewController: NSObject {
    /// Routes a link click. Set by `MarkdownTabView` when the preview is
    /// installed (Task 16); called with the URL the user clicked.
    var onLinkClick: ((URL) -> Void)?
    /// Reports the anchor map so the controller can scroll to a heading
    /// when the user clicks a `#slug` link. Filled in via `apply(result:)`.
    var anchorRanges: [String: NSRange] = [:]

    let textView: NSTextView
    let scrollView: NSScrollView

    private let imageLoader = MarkdownImageLoader()
    private let mermaidCoordinator: MermaidAttachmentCoordinator
    private nonisolated(unsafe) var anchorObserver: NSObjectProtocol?
    private(set) var lastAppliedRevision: UUID?

    init(
        theme: Theme,
        mermaidService: MermaidRenderService = .shared
    ) {
        mermaidCoordinator = MermaidAttachmentCoordinator(
            service: mermaidService,
            theme: theme
        )
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = false
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(theme.color("bg-1"))

        let containerSize = NSSize(width: scroll.contentSize.width,
                                   height: CGFloat.greatestFiniteMagnitude)
        let textContainer = NSTextContainer(size: containerSize)
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                                  textContainer: textContainer)
        textView.defaultParagraphStyle = CenterTypography.paragraphStyle()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(theme.color("bg-1"))
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor(theme.color("accent")),
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        scroll.documentView = textView

        self.textView = textView
        self.scrollView = scroll
        super.init()
        textView.delegate = self

        anchorObserver = NotificationCenter.default.addObserver(
            forName: .markdownScrollToAnchor,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let slug = note.userInfo?["slug"] as? String else { return }
            Task { @MainActor in self.scrollTo(slug: slug) }
        }
    }

    /// Replace the rendered content. Must be called on the main thread.
    func apply(result: MarkdownRenderResult) {
        guard result.revision != lastAppliedRevision else { return }
        let sourceDisclosureSnapshot = mermaidCoordinator
            .explicitSourceDisclosureSnapshot(in: textView)
        mermaidCoordinator.cancelAll()
        lastAppliedRevision = result.revision
        anchorRanges = result.anchorRanges
        textView.textStorage?.setAttributedString(result.attributedString)
        for ref in result.remoteImages {
            // Cache hit returns synchronously and skips the completion handler.
            // Apply it here so the fresh placeholder attachment created by the
            // new attributed string actually shows the cached image.
            if let cached = imageLoader.loadRemote(url: ref.url, completion: { [weak self] image in
                guard let self, let image else { return }
                self.applyRemoteImage(image, to: ref.attachment)
            }) {
                applyRemoteImage(cached, to: ref.attachment)
            }
        }
        mermaidCoordinator.apply(
            result.mermaidAttachments,
            revision: result.revision,
            to: textView,
            onTextStorageDelta: { [weak self] location, delta in
                self?.shiftAnchors(startingAt: location, by: delta)
            }
        )
        mermaidCoordinator.restoreExplicitSourceDisclosures(
            sourceDisclosureSnapshot,
            in: textView
        )
    }

    /// Scroll the preview so the anchor at `slug` is at the top.
    func scrollTo(slug: String) {
        guard let range = anchorRanges[slug] else { return }
        textView.scrollRangeToVisible(range)
    }

    /// Refresh the chrome colors that depend on the current theme. Safe to
    /// call repeatedly; idempotent if the theme hasn't actually changed.
    func reapplyTheme(_ theme: Theme) {
        mermaidCoordinator.updateViewerTheme(theme)
        let bg = NSColor(theme.color("bg-1"))
        scrollView.backgroundColor = bg
        textView.backgroundColor = bg
        textView.linkTextAttributes = [
            .foregroundColor: NSColor(theme.color("accent")),
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
    }

    func dismantle() {
        mermaidCoordinator.cancelAll()
    }

    func showMermaidSourceForTesting(id: String) {
        mermaidCoordinator.showSource(id: id, in: textView)
    }

    func shiftAnchors(startingAt location: Int, by delta: Int) {
        guard delta != 0 else { return }
        for (slug, range) in anchorRanges {
            if range.location >= location {
                anchorRanges[slug] = NSRange(
                    location: max(0, range.location + delta),
                    length: range.length
                )
            } else if NSMaxRange(range) > location {
                anchorRanges[slug] = NSRange(
                    location: range.location,
                    length: max(0, range.length + delta)
                )
            }
        }
    }

    /// Install a loaded `NSImage` into the placeholder attachment, resize it
    /// to fit within the preview, and invalidate layout so the glyph
    /// re-measures.
    private func applyRemoteImage(_ image: NSImage, to attachment: NSTextAttachment) {
        attachment.image = image
        let maxWidth: CGFloat = 600
        if image.size.width > maxWidth {
            let scale = maxWidth / image.size.width
            attachment.bounds = NSRect(x: 0, y: 0, width: maxWidth, height: image.size.height * scale)
        } else {
            attachment.bounds = NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        }
        guard let storage = textView.textStorage,
              let range = attachmentRange(for: attachment, in: storage)
        else { return }
        storage.edited([.editedAttributes], range: range, changeInLength: 0)
        for layoutManager in storage.layoutManagers {
            layoutManager.invalidateLayout(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            layoutManager.invalidateDisplay(forCharacterRange: range)
        }
    }

    private func attachmentRange(
        for attachment: NSTextAttachment,
        in storage: NSTextStorage
    ) -> NSRange? {
        var found: NSRange?
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            guard let candidate = value as? NSTextAttachment,
                  candidate === attachment else { return }
            found = range
            stop.pointee = true
        }
        return found
    }

    deinit {
        if let anchorObserver {
            NotificationCenter.default.removeObserver(anchorObserver)
        }
    }
}

extension MarkdownPreviewController: NSTextViewDelegate {
    nonisolated func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        // Bounce to MainActor for the link routing closure.
        if let url = link as? URL {
            Task { @MainActor in self.onLinkClick?(url) }
        } else if let s = link as? String, let url = URL(string: s) {
            Task { @MainActor in self.onLinkClick?(url) }
        }
        return true
    }
}
