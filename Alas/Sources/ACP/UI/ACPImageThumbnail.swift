import SwiftUI
import AppKit

/// A clickable thumbnail for a sent image attachment. Tapping opens the
/// staged file in a floating preview panel over Alas.
struct ACPImageThumbnail: View {
    let fileURL: URL
    /// 1-based position among the message's images, shown as a small corner
    /// badge so it matches the `` `🖼 N` `` marker `ACPUserMessageImageMarkers`
    /// splices into the bubble's text. `nil` when the message has only one
    /// image — nothing to disambiguate, so no badge.
    var index: Int? = nil

    /// `fileURL.lastPathComponent` for a `data:` URI is meaningless (no
    /// path component), so those fall back to a generic label instead.
    private var displayName: String {
        fileURL.scheme?.lowercased() == "data" ? "Image" : fileURL.lastPathComponent
    }

    var body: some View {
        Button {
            if let image = Self.loadImage(from: fileURL) {
                ACPImagePreview.shared.show(image, title: displayName)
            }
        } label: {
            thumbnail
        }
        .buttonStyle(.plain)
        // Make the entire 96×96 frame hit-testable, not just opaque pixels.
        .contentShape(Rectangle())
        .help(displayName)
    }

    @ViewBuilder private var thumbnail: some View {
        ACPCachedThumbnail(
            cacheKey: Self.cacheKey(for: fileURL),
            loadImage: { Self.loadImage(from: fileURL) }
        ) { image in
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
                .overlay(alignment: .topLeading) { indexBadge }
        } placeholder: {
            RoundedRectangle(cornerRadius: 8)
                .fill(.gray.opacity(0.3))
                .frame(width: 96, height: 96)
                .overlay(Image(systemName: "photo"))
                .overlay(alignment: .topLeading) { indexBadge }
        }
    }

    @ViewBuilder private var indexBadge: some View {
        if let index {
            Text("\(index)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(minWidth: 14, minHeight: 14)
                .background(Circle().fill(.black.opacity(0.55)))
                .padding(4)
        }
    }

    /// Loads an image from either a regular file URL or an inline `data:`
    /// URI — a child prompt's data-only image (no staged file, no `uri` on
    /// the wire) is persisted as a `data:` attachment, which
    /// `NSImage(contentsOf:)` alone cannot read.
    nonisolated static func loadImage(from url: URL) -> NSImage? {
        guard url.scheme?.lowercased() == "data" else { return NSImage(contentsOf: url) }
        guard let decoded = decodeDataURI(url.absoluteString) else { return nil }
        return NSImage(data: decoded)
    }

    nonisolated static func cacheKey(for url: URL) -> String {
        guard url.scheme?.lowercased() == "data" else {
            return ACPThumbnailImageCache.fileCacheKey(for: url)
        }
        return "data-uri:\(url.absoluteString.hashValue)"
    }

    nonisolated private static func decodeDataURI(_ value: String) -> Data? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let marker = trimmed.range(of: "base64,", options: .caseInsensitive) else { return nil }
        return Data(base64Encoded: String(trimmed[marker.upperBound...]), options: .ignoreUnknownCharacters)
    }
}

/// Floating image preview owned entirely by Alas. We deliberately avoid
/// `QLPreviewPanel.shared()`: the shared Quick Look panel takes control via
/// the responder chain, and since nothing in a SwiftUI app implements the
/// `QLPreviewPanelController` protocol it resets our data source and shows
/// "nothing selected". A self-owned `NSPanel` hosting an `NSImageView` is
/// reliable and stays above the app.
@MainActor
final class ACPImagePreview {
    static let shared = ACPImagePreview()
    private var panel: NSPanel?

    func show(_ image: NSImage, title: String) {
        panel?.close()

        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let cap = NSSize(width: screen.width * 0.8, height: screen.height * 0.8)
        let size = Self.fit(image.size, into: cap)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.titlebarAppearsTransparent = true
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        panel.contentView = imageView

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    /// Scale `size` down to fit within `cap`, preserving aspect ratio. Never
    /// scales up — a small image previews at its native size.
    private static func fit(_ size: NSSize, into cap: NSSize) -> NSSize {
        guard size.width > 0, size.height > 0 else { return cap }
        let scale = min(1, min(cap.width / size.width, cap.height / size.height))
        return NSSize(width: size.width * scale, height: size.height * scale)
    }
}
