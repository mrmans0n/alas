import AppKit
import SwiftUI

/// Non-modal corner card announcing a release's headline feature. It never
/// takes keyboard focus and stays until one of its controls is used.
struct WhatsNewCard: View {
    private static let width: CGFloat = 320 // design-literal: fixed card width

    let entry: WhatsNewEntry
    let mediaURL: URL?
    let onAction: (WhatsNewAction) -> Void
    let onReleaseNotes: () -> Void
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space[3]) {
            header
            if let mediaURL {
                WhatsNewMedia(url: mediaURL, width: Self.width - 2 * scale.space[4])
                    .id(mediaURL)
            }
            VStack(alignment: .leading, spacing: scale.space[1]) {
                Text(entry.headline.title)
                    .font(scale.titleFont)
                    .foregroundColor(theme.color("fg"))
                Text(entry.headline.body)
                    .font(scale.metaFont)
                    .foregroundColor(theme.color("fg-dim"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !entry.also.isEmpty {
                Divider().opacity(0.5)
                Text("Also: " + entry.also.map(\.title).joined(separator: " · "))
                    .font(scale.metaFont)
                    .foregroundColor(theme.color("fg-muted"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            actionRow
        }
        .padding(scale.space[4])
        .frame(width: Self.width, alignment: .leading)
        .background(theme.color("bg-1"))
        .overlay(
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private var header: some View {
        HStack(spacing: scale.space[2]) {
            Image(systemName: "sparkles")
                .font(scale.meta.font(weight: .semibold))
                .foregroundColor(theme.color("accent"))
            Text(entry.headerTitle)
                .font(scale.meta.font(weight: .semibold))
                .foregroundColor(theme.color("fg-muted"))
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(scale.glyphFont)
                    .foregroundColor(theme.color("fg-muted"))
                    .frame(width: 18, height: 18) // design-literal: dismiss hit target
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
    }

    private var actionRow: some View {
        HStack(spacing: scale.space[2]) {
            if let action = entry.headline.action {
                AlasButton(title: entry.headline.actionLabel ?? "Try it", style: .primary) {
                    onAction(action)
                }
            }
            AlasButton(title: "Release notes", style: .subtle, action: onReleaseNotes)
            Spacer()
        }
    }
}

/// Scales the image to the card's width, keeping its aspect ratio. GIFs animate.
private struct WhatsNewMedia: View {
    private static let maxHeight: CGFloat = 200 // design-literal: media height cap

    /// Loaded once per view identity; callers key the view by URL so a new file reloads.
    @Environment(\.designScale) private var scale
    @State private var image: NSImage?
    let width: CGFloat

    init(url: URL, width: CGFloat) {
        // Bundled and small, so a synchronous load is fine and avoids an empty first frame.
        _image = State(initialValue: NSImage(contentsOf: url))
        self.width = width
    }

    var body: some View {
        if let image, image.size.width > 0, image.size.height > 0 {
            // An explicit size: the NSImageView's intrinsic size would
            // otherwise stretch the frame and letterbox the image.
            let height = min(Self.maxHeight, width * image.size.height / image.size.width)
            AnimatedImageView(image: image)
                .frame(width: height * image.size.width / image.size.height, height: height)
                .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
                .frame(maxWidth: .infinity)
        }
    }
}

private struct AnimatedImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.isEditable = false
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        // Let SwiftUI own the size instead of the image's intrinsic size.
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            view.setContentCompressionResistancePriority(.defaultLow, for: orientation)
            view.setContentHuggingPriority(.defaultLow, for: orientation)
        }
        view.image = image
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image { view.image = image }
    }
}
