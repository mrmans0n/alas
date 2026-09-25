import AppKit
import SwiftUI

/// Hover popover for an image chip in the composer's text view.
///
/// One controller per `ACPNSTextView`. Debounced `show` / immediate `hide`
/// driven by the text view's tracking area; the popover is transient, so
/// clicking anywhere also dismisses it. Content is the image aspect-fit into
/// the composer's width and half the screen's height, whichever binds first.
@MainActor
class ACPImageChipHoverController {
    /// The chip a pending timer will show for; a struct (not a tuple) so
    /// equality comparison is synthesized.
    private struct ChipTarget: Equatable {
        let range: NSRange
        let fileURL: URL
    }

    private var popover: NSPopover?
    private var showWork: DispatchWorkItem?
    /// Range + URL the pending timer will show for; lets `hide` cancel a
    /// chip-to-chip move instead of flashing a stale popover.
    private var pendingTarget: ChipTarget?
    /// The chip whose image is currently loading off-main. Set by `show`,
    /// cleared when presentation completes or the controller hides, so an
    /// in-flight load is abandoned exactly when a real user-visible state
    /// (pending timer or shown popover) would be.
    private var inFlightTarget: ChipTarget?
    /// The chip whose popover is currently displayed, so moving from one
    /// chip directly onto another closes the stale preview immediately
    /// instead of leaving it up during the next chip's debounce.
    private var shownTarget: ChipTarget?

    static let hoverDelay: TimeInterval = 0.25

    /// Aspect-fit `size` into the `maxWidth` × `maxHeight` cap, preserving
    /// aspect ratio. Never scales up — a small image previews at its native
    /// size. A degenerate (zero) size falls back to a square at `maxWidth`.
    nonisolated static func fittedSize(
        for size: NSSize,
        maxWidth: CGFloat,
        maxHeight: CGFloat
    ) -> NSSize {
        guard size.width > 0, size.height > 0, maxWidth > 0, maxHeight > 0 else {
            return NSSize(width: maxWidth, height: maxWidth)
        }
        let scale = min(1, min(maxWidth / size.width, maxHeight / size.height))
        return NSSize(width: size.width * scale, height: size.height * scale)
    }

    func scheduleShow(range: NSRange, fileURL: URL, in textView: ACPNSTextView) {
        cancelPendingShow()
        let target = ChipTarget(range: range, fileURL: fileURL)
        // Moving onto a different chip while another popover is up closes it
        // right away — the debounced show below will open the new one.
        if shownTarget != target {
            popover?.performClose(nil)
            popover = nil
            self.shownTarget = nil
        }
        pendingTarget = target
        let work = DispatchWorkItem { [weak self, weak textView] in
            guard let self, let textView else { return }
            guard self.pendingTarget == target else { return }
            self.pendingTarget = nil
            self.show(range: target.range, fileURL: target.fileURL, in: textView)
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: work)
    }

    func hide() {
        cancelPendingShow()
        inFlightTarget = nil
        popover?.performClose(nil)
        popover = nil
        shownTarget = nil
    }

    #if DEBUG
    /// Test seam: true while a debounced show work item is still scheduled.
    var hasPendingShowForTesting: Bool { showWork != nil && showWork?.isCancelled == false }
    #endif

    private func cancelPendingShow() {
        showWork?.cancel()
        showWork = nil
        pendingTarget = nil
    }

    private func show(range: NSRange, fileURL: URL, in textView: ACPNSTextView) {
        guard let anchor = textView.imageChipAnchorRect(for: range) else { return }
        let target = ChipTarget(range: range, fileURL: fileURL)
        inFlightTarget = target

        // Cap: the visible composer width, and half the main screen's height
        // — whichever binds first for the image's aspect ratio.
        let cap = ACPNSTextView.imageChipPreviewCap(in: textView) ?? Self.fallbackCap

        // Decoding a staged image (up to 20 MiB) happens off the main actor
        // through the shared thumbnail cache; presentation stays on main.
        let cacheKey = ACPImageThumbnail.cacheKey(for: fileURL)
        let load: @Sendable () -> NSImage? = { [fileURL] in
            ACPImageThumbnail.loadImage(from: fileURL)
        }
        Task { @MainActor [weak self, weak textView] in
            guard let self, let textView else { return }
            guard let image = await ACPThumbnailImageCache.shared.image(for: cacheKey, load: load)
            else {
                self.inFlightTarget = nil
                return
            }
            // The load is obsolete if the user left the chip (hide cleared
            // every target) or moved onto another chip (a new in-flight
            // target replaced this one).
            guard self.inFlightTarget == target else { return }
            self.inFlightTarget = nil
            let size = Self.fittedSize(
                for: image.size,
                maxWidth: cap.width,
                maxHeight: cap.height
            )
            let popover = self.popover ?? NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.contentSize = size
            popover.contentViewController = NSHostingController(
                rootView: ACPImageChipHoverPreview(image: image, size: size)
            )
            popover.show(relativeTo: anchor, of: textView, preferredEdge: .maxY)
            self.popover = popover
            self.shownTarget = target
        }
    }

    static let fallbackPreviewCapWidth: CGFloat = 720

    static var fallbackCap: NSSize {
        NSSize(width: fallbackPreviewCapWidth, height: fallbackPreviewCapWidth)
    }
}

/// The popover's content: the image at its fitted size with a hairline
/// border, no extra chrome. The view is sized to the fitted size up front so
/// the popover hugs the image instead of showing NSHostingView padding.
private struct ACPImageChipHoverPreview: View {
    let image: NSImage
    let size: NSSize

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(
                Rectangle()
                    .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
            )
    }
}
