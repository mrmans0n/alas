import SwiftUI
import AppKit

/// A clickable thumbnail for a sent image attachment. Tapping opens the
/// staged file in a floating preview panel over Alas.
struct ACPImageThumbnail: View {
    let fileURL: URL

    var body: some View {
        Button {
            ACPImagePreview.shared.show(fileURL)
        } label: {
            thumbnail
        }
        .buttonStyle(.plain)
        // Make the entire 96×96 frame hit-testable, not just opaque pixels.
        .contentShape(Rectangle())
        .help(fileURL.lastPathComponent)
    }

    @ViewBuilder private var thumbnail: some View {
        ACPCachedThumbnail(
            cacheKey: ACPThumbnailImageCache.fileCacheKey(for: fileURL),
            loadImage: { NSImage(contentsOf: fileURL) }
        ) { image in
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        } placeholder: {
            RoundedRectangle(cornerRadius: 8)
                .fill(.gray.opacity(0.3))
                .frame(width: 96, height: 96)
                .overlay(Image(systemName: "photo"))
        }
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

    func show(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
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
        panel.title = url.lastPathComponent
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
