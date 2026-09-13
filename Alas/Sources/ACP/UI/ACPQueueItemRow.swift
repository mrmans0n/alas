import AppKit
import SwiftUI

/// A single row in the "Up next" queue section, rendered below the
/// transcript. Full-width and left-aligned (unlike a chat bubble) so the
/// dispatch order reads top-to-bottom, with a leading position number, a
/// hover toolbar, and a right-click menu carrying the same actions plus
/// move up/down. Items in `.sending` never reach this view — see
/// `ACPTranscriptQueuePolicy.shouldRenderQueueBubble`.
struct ACPQueueItemRow: View {
    let item: QueuedPrompt
    /// 1-based dispatch position among rendered rows. See
    /// `ACPTranscriptQueuePolicy.queuePosition(at:statuses:)`.
    let position: Int
    let contentMaxWidth: CGFloat
    let typography: ACPChatTypography
    let canMoveUp: Bool
    let canMoveDown: Bool
    /// Reorder to the front of the queue without interrupting a running
    /// turn. Clears a previous send error.
    let onPromote: () -> Void
    /// Interrupt a running turn with this item, or promote-and-drain it if
    /// the agent is idle. Every other pending item is left untouched.
    let onSendNow: () -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void
    /// Clear a previous send error without reordering the item.
    let onRetry: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    @StateObject private var hover = ACPDelayedHoverVisibility()
    @Environment(\.theme) private var theme

    var body: some View {
        let preview = Self.textPreview(of: item.blocks)

        HStack(alignment: .top, spacing: ACPQueueItemRowMetrics.markerToContentSpacing) {
            positionMarker
            VStack(alignment: .leading, spacing: 4) {
                statusRow
                contentColumn(preview: preview)
            }
            Spacer(minLength: ACPQueueItemRowMetrics.contentToToolbarSpacing)
            toolbar
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .opacity(item.status == .sending ? 0.85 : 1)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.color("bg-2").opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor, style: borderStyle)
        )
        .frame(maxWidth: contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { inside in
            if inside { hover.enter() } else { hover.leave() }
        }
        .contextMenu { contextMenuItems }
        .modifier(PendingDraggableModifier(
            enabled: item.status == .pending && item.scheduledAt == nil,
            payload: item.id.uuidString
        ))
    }

    // MARK: - Leading position marker

    @ViewBuilder
    private var positionMarker: some View {
        Group {
            if item.scheduledAt != nil {
                Image(systemName: "clock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.color("fg-faint"))
            } else {
                Text("\(position)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(position == 1 ? theme.color("accent") : theme.color("fg-faint"))
            }
        }
        .frame(width: ACPQueueItemRowMetrics.markerWidth, height: ACPQueueItemRowMetrics.markerWidth, alignment: .center)
    }

    // MARK: - Status pill + content

    private var statusRow: some View {
        HStack(spacing: 6) {
            if item.status == .sending {
                ProgressView().scaleEffect(0.45).frame(width: 12, height: 12)
            }
            statusText
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(statusColor)
            if let err = item.lastError {
                Text("· \(err)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.color("del"))
                    .lineLimit(1)
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var statusText: some View {
        if item.status == .sending {
            Text("Sending")
        } else if let scheduledAt = item.scheduledAt {
            Text("Scheduled for \(scheduledAt, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())")
        } else if position == 1 {
            Text("Next")
        } else {
            Text("Queued")
        }
    }

    private var statusColor: Color {
        (item.status == .pending && item.scheduledAt == nil && position == 1)
            ? theme.color("accent")
            : theme.color("fg-faint")
    }

    @ViewBuilder
    private func contentColumn(preview: String) -> some View {
        if !imageURLs.isEmpty {
            imageRow
        }
        if !preview.isEmpty {
            ACPMarkdownText(raw: preview, typography: typography)
        } else if imageURLs.isEmpty {
            Text("(empty prompt)")
                .font(.system(size: 13))
                .foregroundStyle(theme.color("fg-faint"))
        }
    }

    private var imageRow: some View {
        HStack(spacing: 4) {
            ForEach(Array(imageURLs.enumerated()), id: \.offset) { _, url in
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private var borderColor: Color {
        if item.lastError != nil { return theme.color("del").opacity(0.6) }
        if position == 1, item.scheduledAt == nil { return theme.color("accent").opacity(0.4) }
        return theme.color("line")
    }

    private var borderStyle: StrokeStyle {
        item.status == .sending
            ? StrokeStyle(lineWidth: 0.75)
            : StrokeStyle(lineWidth: 0.75, dash: [3, 3])
    }

    // MARK: - Hover toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 4) {
            if item.status == .pending {
                actionButton(
                    systemName: "arrow.up.to.line",
                    foreground: theme.color("fg-muted"),
                    help: "Move to front (won't interrupt a running turn)",
                    action: onPromote
                )
                actionButton(
                    systemName: "paperplane.fill",
                    foreground: theme.color("accent"),
                    help: "Send now (interrupts a running turn)",
                    action: onSendNow
                )
                if item.lastError != nil {
                    actionButton(
                        systemName: "arrow.clockwise",
                        foreground: theme.color("warn"),
                        help: "Retry",
                        action: onRetry
                    )
                }
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
        }
        .opacity(toolbarVisible ? 1 : 0)
        .allowsHitTesting(toolbarVisible)
        .accessibilityHidden(!toolbarVisible)
    }

    private var toolbarVisible: Bool {
        hover.isVisible && item.status == .pending
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
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Right-click menu

    @ViewBuilder
    private var contextMenuItems: some View {
        if item.status == .pending {
            Button("Move to front", action: onPromote)
            Button("Send now", action: onSendNow)
            Divider()
            Button("Move up", action: onMoveUp).disabled(!canMoveUp)
            Button("Move down", action: onMoveDown).disabled(!canMoveDown)
            Divider()
            if item.lastError != nil {
                Button("Retry", action: onRetry)
            }
            Button("Edit", action: onEdit)
            Button("Remove from queue", role: .destructive, action: onRemove)
        }
    }
}

enum ACPQueueItemRowMetrics {
    static let markerWidth: CGFloat = 18
    static let markerToContentSpacing: CGFloat = 10
    static let contentToToolbarSpacing: CGFloat = 8
}

private extension ACPQueueItemRow {
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
