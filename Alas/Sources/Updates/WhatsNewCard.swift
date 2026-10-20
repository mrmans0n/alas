import AppKit
import SwiftUI

/// Non-modal corner card announcing a release's headline feature. It never
/// takes keyboard focus and stays until one of its controls is used.
struct WhatsNewCard: View {
    let entry: WhatsNewEntry
    let mediaURL: URL?
    let onAction: (WhatsNewAction) -> Void
    let onReleaseNotes: () -> Void
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let mediaURL {
                WhatsNewMedia(url: mediaURL)
                    .id(mediaURL)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.headline.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                Text(entry.headline.body)
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !entry.also.isEmpty {
                Divider().opacity(0.5)
                Text("Also: " + entry.also.map(\.title).joined(separator: " · "))
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.color("fg-muted"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            actionRow
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(theme.color("bg-1"))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.color("accent"))
            Text(entry.headerTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.color("fg-muted"))
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.color("fg-muted"))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
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
    /// Loaded once per view identity; callers key the view by URL so a new file reloads.
    @State private var image: NSImage?

    init(url: URL) {
        // Bundled and small, so a synchronous load is fine and avoids an empty first frame.
        _image = State(initialValue: NSImage(contentsOf: url))
    }

    var body: some View {
        if let image, image.size.width > 0, image.size.height > 0 {
            AnimatedImageView(image: image)
                .aspectRatio(image.size, contentMode: .fit)
                .frame(maxHeight: 200)
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
