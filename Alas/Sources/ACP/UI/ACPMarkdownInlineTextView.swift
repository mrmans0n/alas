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
        private var inFlightImageURLs: Set<URL> = []
        private var currentRemoteImageTargets: [URL: RemoteImageRenderTargets] = [:]

        func loadRemoteImages(in textView: NSTextView, attributedString: NSAttributedString) {
            generation += 1
            let renderGeneration = generation
            let fullRange = NSRange(location: 0, length: attributedString.length)
            var collectedTargets: [URL: [RemoteImageTarget]] = [:]

            attributedString.enumerateAttribute(.acpMarkdownInlineRemoteImage, in: fullRange) { value, range, _ in
                guard let remoteImage = value as? ACPMarkdownInlineRemoteImage else { return }
                let fallbackAttributes = attributedString.attributes(at: range.location, effectiveRange: nil)
                let target = RemoteImageTarget(remoteImage: remoteImage, fallbackAttributes: fallbackAttributes)
                collectedTargets[remoteImage.url, default: []].append(target)
            }

            currentRemoteImageTargets = collectedTargets.mapValues {
                RemoteImageRenderTargets(generation: renderGeneration, targets: $0)
            }

            for url in collectedTargets.keys {
                guard !inFlightImageURLs.contains(url) else { continue }

                if let cached = imageLoader.loadRemote(url: url, completion: { [weak self, weak textView] image in
                    guard let self else { return }
                    self.inFlightImageURLs.remove(url)
                    guard let textView else { return }
                    self.applyLoadedImage(image, for: url, in: textView)
                }) {
                    applyLoadedImage(cached, for: url, in: textView)
                } else {
                    inFlightImageURLs.insert(url)
                }
            }
        }

        private func applyLoadedImage(
            _ loadedImage: NSImage?,
            for url: URL,
            in textView: NSTextView
        ) {
            guard let renderTargets = currentRemoteImageTargets[url],
                  generation == renderTargets.generation
            else { return }

            var didReplace = false
            for target in renderTargets.targets {
                didReplace = applyLoadedImage(
                    loadedImage,
                    to: target,
                    in: textView
                ) || didReplace
            }

            guard didReplace else { return }
            if let textContainer = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: textContainer)
            }
            textView.invalidateIntrinsicContentSize()
        }

        private func applyLoadedImage(
            _ loadedImage: NSImage?,
            to target: RemoteImageTarget,
            in textView: NSTextView
        ) -> Bool {
            let remoteImage = target.remoteImage
            guard let storage = textView.textStorage,
                  let range = range(of: remoteImage, in: storage)
            else { return false }

            let replacement: NSAttributedString
            if let loadedImage {
                let attachment = ACPMarkdownInlineRenderer.loadedImageAttachment(
                    for: loadedImage,
                    isSubscript: remoteImage.image.isSubscript
                )
                replacement = NSAttributedString(attachment: attachment)
            } else {
                replacement = ACPMarkdownInlineRenderer.mutedAltString(
                    for: remoteImage.image,
                    attributes: target.fallbackAttributes
                )
            }
            storage.replaceCharacters(in: range, with: replacement)
            return true
        }

        private struct RemoteImageRenderTargets {
            let generation: Int
            let targets: [RemoteImageTarget]
        }

        private struct RemoteImageTarget {
            let remoteImage: ACPMarkdownInlineRemoteImage
            let fallbackAttributes: [NSAttributedString.Key: Any]
        }

        private func range(
            of remoteImage: ACPMarkdownInlineRemoteImage,
            in storage: NSTextStorage
        ) -> NSRange? {
            let fullRange = NSRange(location: 0, length: storage.length)
            var foundRange: NSRange?
            storage.enumerateAttribute(.acpMarkdownInlineRemoteImage, in: fullRange) { value, range, stop in
                guard let candidate = value as? ACPMarkdownInlineRemoteImage,
                      candidate == remoteImage
                else { return }
                foundRange = range
                stop.pointee = true
            }
            return foundRange
        }
    }
}

extension NSAttributedString.Key {
    static let acpMarkdownInlineRemoteImage = NSAttributedString.Key("ACPMarkdownInlineRemoteImage")
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
