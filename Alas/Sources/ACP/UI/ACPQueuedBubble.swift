import AppKit
import SwiftUI

/// A single queued-item bubble, rendered below the transcript. Right-
/// aligned (same as the user message bubble) but with a dashed border,
/// reduced opacity, and a "Queued" pill. Hover reveals send / edit / remove
/// affordances without changing their reserved layout. Items in `.sending`
/// lose those affordances and gain a spinner-edged border.
struct ACPQueuedBubble: View {
    let item: QueuedPrompt
    let onForceSend: () -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void
    let onRetry: () -> Void

    @State private var isHovering = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
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
                    }
                    .lineLimit(1)
                    if item.status == .pending {
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
            actionButton(
                systemName: "paperplane.fill",
                foreground: theme.color("accent"),
                help: "Send now",
                action: onForceSend
            )
            actionButton(
                systemName: "arrow.clockwise",
                foreground: theme.color("warn"),
                help: "Retry",
                action: onRetry
            )
            .opacity(item.lastError == nil ? 0 : 1)
            .allowsHitTesting(item.lastError != nil)
            .accessibilityHidden(item.lastError == nil)
            actionButton(
                systemName: "pencil",
                foreground: theme.color("fg-muted"),
                help: "Edit",
                action: onEdit
            )
            actionButton(
                systemName: "xmark",
                foreground: theme.color("fg-muted"),
                help: "Remove from queue",
                action: onRemove
            )
        }
        .frame(width: ACPQueuedBubbleActionMetrics.reservedWidth, alignment: .trailing)
        .opacity(actionsVisible ? 1 : 0)
        .allowsHitTesting(actionsVisible)
        .accessibilityHidden(!actionsVisible)
    }

    private var actionsVisible: Bool {
        isHovering && item.status == .pending
    }

    private func actionButton(
        systemName: String,
        foreground: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(
                    width: ACPQueuedBubbleActionMetrics.buttonSize,
                    height: ACPQueuedBubbleActionMetrics.buttonSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

enum ACPQueuedBubbleActionMetrics {
    static let buttonSize: CGFloat = 16
    static let buttonSpacing: CGFloat = 4
    static let reservedButtonSlots = 4
    static let actionGroupToContentSpacing: CGFloat = 8
    static let minimumLeadingSpacerWidth: CGFloat = 16

    static var reservedWidth: CGFloat {
        CGFloat(reservedButtonSlots) * buttonSize
            + CGFloat(reservedButtonSlots - 1) * buttonSpacing
    }

    static var reservedAccessoryWidth: CGFloat {
        reservedWidth + actionGroupToContentSpacing
    }
}

private extension ACPQueuedBubble {
    /// Staged file URLs for the queued prompt's image blocks, so an image-only
    /// queued item still shows a thumbnail (its text preview is empty).
    var imageURLs: [URL] {
        item.blocks.compactMap { block in
            if case .image(_, let uri, _) = block, let uri { return URL(string: uri) }
            return nil
        }
    }

    static func textPreview(of blocks: [ACPContentBlock]) -> String {
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
