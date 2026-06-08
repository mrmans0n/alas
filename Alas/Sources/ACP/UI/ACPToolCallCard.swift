import SwiftUI

/// Read / Search / Run / Edit tool invocation. Collapsed by default to
/// one row showing verb + target + status; expanded shows the tool's
/// full text output. While the tool is `in_progress` the right side
/// renders an animated spinner instead of a static glyph.
struct ACPToolCallCard: View {
    let toolCall: ACPMessage.ToolCall
    /// Closure that returns the full persisted `content` for the tool call
    /// whose in-memory `content` was truncated when its row left the render
    /// window. Invoked the first time the card expands; the result is cached
    /// in `expandedContent` and rendered in place of the truncated copy.
    /// Optional — when nil (or when the lookup returns nil) the card falls
    /// back to the in-memory `toolCall.content`.
    var loadFullContent: (() -> String?)? = nil
    @State private var expanded = false
    @State private var expandedContent: String? = nil
    @Environment(\.theme) private var theme
    @Environment(\.acpTerminalHost) private var terminalHost

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
                if expanded, toolCall.isContentTruncated, expandedContent == nil {
                    // First expand of an off-window truncated card: page the
                    // full content back in from SQLite via the host-provided
                    // loader. Subsequent toggles reuse the cached string.
                    expandedContent = loadFullContent?()
                }
            } label: {
                HStack(spacing: 8) {
                    glyph
                    Text(verb)
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(theme.color("fg-faint"))
                    if !toolCall.title.isEmpty && toolCall.title.lowercased() != verb.lowercased() {
                        FileChip(path: toolCall.title, lines: nil, iconSystemName: nil)
                    }
                    if let first = toolCall.locations.first {
                        FileChip(path: first, lines: nil, iconSystemName: nil)
                    }
                    if !expanded, let preview = toolCall.preview, !preview.isEmpty {
                        Text(preview)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.color("fg-faint"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    statusIndicator
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.color("fg-faint"))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider().background(theme.color("line-soft"))
                expandedBody
            }
        }
        .background(theme.color("bg-1").opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(borderColor, lineWidth: 0.5))
        // `expandedContent` is keyed to SwiftUI view identity, not to the
        // tool call's id. If SwiftUI recycles this card for a different
        // tool call at the same position (e.g. during prepend / reorder),
        // we must drop the cached full content so we don't render a stale
        // body from the previous tool call.
        .onChange(of: toolCall.toolCallId) { _, _ in
            expandedContent = nil
        }
    }

    /// What to draw inside the expanded card. Prefers the just-fetched
    /// full SQLite content (set on first expand for truncated rows) and
    /// falls back to the in-memory `toolCall.content` otherwise. Live
    /// rows (`in_progress`, `pending`) are never truncated, so they
    /// always render straight from `toolCall.content`.
    private var displayContent: String {
        expandedContent ?? toolCall.content
    }

    @ViewBuilder
    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if displayContent.isEmpty && toolCall.terminalIds.isEmpty {
                HStack(spacing: 6) {
                    if toolCall.status == "in_progress" || toolCall.status == "pending" {
                        Spinner(lineWidth: 1.5, duration: 0.7).frame(width: 10, height: 10)
                        Text("Working…")
                    } else if toolCall.status == "canceled" || toolCall.status == "cancelled" {
                        Text("Canceled.")
                    } else {
                        Text("No output.")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(theme.color("fg-faint"))
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(theme.color("bg-0").opacity(0.55))
            } else {
                if !displayContent.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        ACPSyntaxHighlightedText(
                            text: displayContent,
                            explicitLanguage: ACPToolOutputSyntax.highlighterExtension(
                                content: displayContent,
                                locations: toolCall.locations
                            ),
                            fontSize: 11.5
                        )
                            .padding(.horizontal, 12).padding(.vertical, 10)
                    }
                    .background(theme.color("bg-0").opacity(0.55))
                }
                if let host = terminalHost {
                    ForEach(toolCall.terminalIds, id: \.self) { tid in
                        ACPTerminalTailView(terminalId: tid, host: host)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch toolCall.status {
        case "in_progress":
            Spinner(lineWidth: 1.5, duration: 0.7).frame(width: 11, height: 11)
        case "pending":
            // Static dot while waiting for permission / queue.
            Circle().fill(theme.color("fg-faint")).frame(width: 5, height: 5)
        case "completed":
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.color("add"))
        case "failed":
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.color("del"))
        case "canceled", "cancelled":
            Image(systemName: "stop.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.color("fg-faint"))
        default:
            Text(toolCall.status)
                .font(.system(size: 10))
                .foregroundStyle(theme.color("fg-faint"))
        }
    }

    private var borderColor: Color {
        expanded ? theme.color("bg-4") : theme.color("line")
    }

    private var verb: String {
        switch toolCall.kind {
        case "read":          return "Read"
        case "search":        return "Searched"
        case "execute","run": return "Ran"
        case "edit":          return "Edit"
        default:              return toolCall.kind?.capitalized ?? "Tool"
        }
    }

    private var iconSystemName: String {
        switch toolCall.kind {
        case "read":          return "doc.text"
        case "search":        return "magnifyingglass"
        case "execute","run": return "terminal"
        case "edit":          return "pencil"
        default:              return "gearshape"
        }
    }

    @ViewBuilder
    private var glyph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(theme.color("bg-0").opacity(0.8))
            Image(systemName: iconSystemName)
                .font(.system(size: 10))
                .foregroundStyle(theme.color("accent"))
        }
        .frame(width: 18, height: 18)
    }
}

private struct ACPTerminalHostKey: EnvironmentKey {
    static let defaultValue: ACPTerminalHost? = nil
}

extension EnvironmentValues {
    var acpTerminalHost: ACPTerminalHost? {
        get { self[ACPTerminalHostKey.self] }
        set { self[ACPTerminalHostKey.self] = newValue }
    }
}
