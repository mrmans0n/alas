import AppKit
import SwiftUI

/// A single queued-item bubble, rendered below the transcript. Right-
/// aligned (same as the user message bubble) but with a dashed border,
/// reduced opacity, and a "Queued" pill. Hover reveals edit / remove
/// affordances. Items in `.sending` lose those affordances and gain a
/// spinner-edged border.
struct ACPQueuedBubble: View {
    let item: QueuedPrompt
    let onEdit: () -> Void
    let onRemove: () -> Void
    let onRetry: () -> Void

    @State private var isHovering = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    if item.status == .sending {
                        ProgressView().scaleEffect(0.45).frame(width: 12, height: 12)
                    }
                    Text(item.status == .sending ? "Sending" : "Queued")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.4)
                        .textCase(.uppercase)
                        .foregroundStyle(theme.color("fg-faint"))
                    if let err = item.lastError {
                        Text("· \(err)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(theme.color("del"))
                            .lineLimit(1)
                    }
                    if isHovering, item.status == .pending {
                        actionsRow
                    }
                }
                if !imageURLs.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(imageURLs.enumerated()), id: \.offset) { _, url in
                            if let image = NSImage(contentsOf: url) {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
                let preview = Self.textPreview(of: item.blocks)
                if !preview.isEmpty {
                    ACPMarkdownText(raw: preview)
                        .padding(.vertical, 9).padding(.horizontal, 13)
                        .background(theme.color("accent").opacity(0.10))
                        .clipShape(
                            UnevenRoundedRectangle(
                                cornerRadii: .init(topLeading: 12, bottomLeading: 12, bottomTrailing: 4, topTrailing: 12)
                            )
                        )
                        .overlay(
                            UnevenRoundedRectangle(
                                cornerRadii: .init(topLeading: 12, bottomLeading: 12, bottomTrailing: 4, topTrailing: 12)
                            )
                            .strokeBorder(borderColor, style: borderStyle)
                        )
                }
            }
            .opacity(item.status == .sending ? 0.85 : 0.6)
            .frame(maxWidth: 540, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .onHover { isHovering = $0 }
        .modifier(PendingDraggableModifier(enabled: item.status == .pending, payload: item.id.uuidString))
    }

    private var borderColor: Color {
        if item.lastError != nil { return theme.color("del").opacity(0.7) }
        return theme.color("accent").opacity(0.5)
    }
    private var borderStyle: StrokeStyle {
        item.status == .sending
            ? StrokeStyle(lineWidth: 0.75)
            : StrokeStyle(lineWidth: 0.75, dash: [3, 3])
    }

    private var actionsRow: some View {
        HStack(spacing: 4) {
            if item.lastError != nil {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.color("warn"))
                }
                .buttonStyle(.plain)
                .help("Retry")
            }
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.color("fg-muted"))
            }
            .buttonStyle(.plain)
            .help("Edit")
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.color("fg-muted"))
            }
            .buttonStyle(.plain)
            .help("Remove from queue")
        }
    }

    /// Staged file URLs for the queued prompt's image blocks, so an image-only
    /// queued item still shows a thumbnail (its text preview is empty).
    private var imageURLs: [URL] {
        item.blocks.compactMap { block in
            if case .image(_, let uri, _) = block, let uri { return URL(string: uri) }
            return nil
        }
    }

    private static func textPreview(of blocks: [ACPContentBlock]) -> String {
        blocks.compactMap { b -> String? in
            if case .text(let s) = b { return s }
            return nil
        }.joined()
    }
}

/// Conditional `.draggable` modifier. SwiftUI doesn't expose a clean
/// "drag if X" view modifier, so we wrap it in a ViewModifier that
/// short-circuits when disabled.
private struct PendingDraggableModifier: ViewModifier {
    let enabled: Bool
    let payload: String
    func body(content: Content) -> some View {
        if enabled {
            content.draggable(payload)
        } else {
            content
        }
    }
}
