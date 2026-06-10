import AppKit
import SwiftUI

/// A single queued-item bubble, rendered below the transcript. Right-
/// aligned (same as the user message bubble) but with a dashed border,
/// reduced opacity, and a "Queued" pill. Hover reveals send / edit / remove
/// affordances without changing their reserved layout. Items in `.sending`
/// lose those affordances and gain a spinner-edged border.
struct ACPQueuedBubble: View {
    let item: QueuedPrompt
    let contentMaxWidth: CGFloat
    let typography: ACPChatTypography
    let onForceSend: () -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void
    let onRetry: () -> Void

    @StateObject private var hover = ACPDelayedHoverVisibility()
    @Environment(\.theme) private var theme

    var body: some View {
        let preview = Self.textPreview(of: item.blocks)

        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: ACPQueuedBubbleActionMetrics.minimumLeadingSpacerWidth)
            VStack(alignment: .trailing, spacing: 4) {
                statusRow
                if !imageURLs.isEmpty, !preview.isEmpty {
                    imageRow
                }
                queuedContentRow(preview: preview)
            }
            .opacity(item.status == .sending ? 0.85 : 0.6)
            .frame(maxWidth: contentColumnMaxWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .onHover { inside in
            if inside { hover.enter() } else { hover.leave() }
        }
        .modifier(PendingDraggableModifier(enabled: item.status == .pending, payload: item.id.uuidString))
    }

    private var statusRow: some View {
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
    }

    private var imageRow: some View {
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

    @ViewBuilder
    private func queuedContentRow(preview: String) -> some View {
        if !preview.isEmpty {
            HStack(alignment: .center, spacing: ACPQueuedBubbleActionMetrics.actionGroupToContentSpacing) {
                if item.status == .pending { actionsRow }
                textBubble(preview)
            }
        } else if !imageURLs.isEmpty {
            HStack(alignment: .center, spacing: ACPQueuedBubbleActionMetrics.actionGroupToContentSpacing) {
                if item.status == .pending { actionsRow }
                imageRow
            }
        } else if item.status == .pending {
            HStack(alignment: .center, spacing: ACPQueuedBubbleActionMetrics.actionGroupToContentSpacing) {
                actionsRow
                Color.clear.frame(width: 0, height: ACPQueuedBubbleActionMetrics.buttonSize)
            }
        }
    }

    private func textBubble(_ preview: String) -> some View {
        ACPMarkdownText(raw: preview, typography: typography)
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
        hover.isVisible && item.status == .pending
    }

    private var contentColumnMaxWidth: CGFloat {
        let bubbleMaxWidth = contentMaxWidth * 0.75
        return item.status == .pending
            ? bubbleMaxWidth + ACPQueuedBubbleActionMetrics.reservedAccessoryWidth
            : bubbleMaxWidth
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
