import SwiftUI
import AppKit

/// Read / Search / Run / Edit tool invocation. Collapsed by default to
/// one row showing verb + target + status; expanded shows the tool's
/// full text output. While the tool is `in_progress` the right side
/// renders an animated spinner instead of a static glyph.
struct ACPToolCallCard: View {
    let toolCall: ACPMessage.ToolCall
    var trustedImageRoot: URL? = nil
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
                    Text(presentation.label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(theme.color("fg-faint"))
                    if !toolCall.title.isEmpty && toolCall.title.lowercased() != presentation.label.lowercased() {
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
            if !hasExpandedOutput {
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
                            explicitLanguage: toolCall.contentLanguage ?? ACPToolOutputSyntax.highlighterExtension(
                                content: displayContent,
                                locations: toolCall.locations
                            ),
                            fontSize: 11.5
                        )
                            .padding(.horizontal, 12).padding(.vertical, 10)
                    }
                    .background(theme.color("bg-0").opacity(0.55))
                }
                if !toolCall.assets.isEmpty {
                    assetBody
                }
                if let host = terminalHost {
                    ForEach(toolCall.terminalIds, id: \.self) { tid in
                        ACPTerminalTailView(terminalId: tid, host: host)
                    }
                }
            }
        }
    }

    private var hasExpandedOutput: Bool {
        !displayContent.isEmpty || !toolCall.assets.isEmpty || !toolCall.terminalIds.isEmpty
    }

    private var assetBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(toolCall.assets.enumerated()), id: \.offset) { entry in
                ACPToolCallAssetView(asset: entry.element, trustedImageRoot: trustedImageRoot)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(theme.color("bg-0").opacity(0.55))
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

    private var presentation: ACPToolCallPresentation {
        ACPToolCallPresentation.resolve(toolCall)
    }

    @ViewBuilder
    private var glyph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(theme.color("bg-0").opacity(0.8))
            Image(systemName: presentation.iconSystemName)
                .font(.system(size: 10))
                .foregroundStyle(theme.color("accent"))
        }
        .frame(width: 18, height: 18)
    }
}

private struct ACPToolCallAssetView: View {
    let asset: ACPMessage.ToolCallAsset
    let trustedImageRoot: URL?
    @Environment(\.theme) private var theme

    var body: some View {
        switch asset.kind {
        case .image:
            if let image = asset.loadedImage(trustedRoot: trustedImageRoot) {
                imageThumbnail(image)
                    .help(asset.displayText)
            } else {
                compactRow(iconSystemName: "photo", title: asset.displayTitle, detail: asset.displayDetail)
            }
        case .resource:
            compactRow(iconSystemName: "doc.text", title: asset.displayTitle, detail: asset.displayDetail)
        }
    }

    private func imageThumbnail(_ image: NSImage) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.color("bg-1").opacity(0.7))
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(6)
        }
            .frame(width: 160, height: 120)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
    }

    private func compactRow(iconSystemName: String, title: String, detail: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconSystemName)
                .font(.system(size: 12))
                .foregroundStyle(theme.color("accent"))
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.color("fg-faint"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(theme.color("bg-1").opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line-soft"), lineWidth: 0.5))
        .help(asset.displayText)
    }
}

private extension ACPMessage.ToolCallAsset {
    func loadedImage(trustedRoot: URL?) -> NSImage? {
        if let data, let decoded = Self.decodeBase64ImageData(data), let image = NSImage(data: decoded) {
            return image
        }
        guard let uri = nonEmpty(uri) else { return nil }
        if uri.lowercased().hasPrefix("data:"),
           let decoded = Self.decodeBase64ImageData(uri),
           let image = NSImage(data: decoded) {
            return image
        }
        guard let url = Self.trustedLocalURL(from: uri, trustedRoot: trustedRoot) else { return nil }
        return NSImage(contentsOf: url)
    }

    var displayTitle: String {
        if let name = nonEmpty(name) {
            return name
        }
        if let uri = nonEmpty(uri) {
            if let url = Self.displayURL(from: uri), !url.lastPathComponent.isEmpty {
                return url.lastPathComponent
            }
            return uri
        }
        return kind == .image ? "Image" : "Resource"
    }

    var displayDetail: String? {
        guard let uri = nonEmpty(uri), uri != displayTitle else { return nil }
        return uri
    }

    var displayText: String {
        if let detail = displayDetail {
            return "\(displayTitle) \(detail)"
        }
        return displayTitle
    }

    private static func decodeBase64ImageData(_ value: String) -> Data? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let base64: String
        if let marker = trimmed.range(of: "base64,", options: .caseInsensitive) {
            base64 = String(trimmed[marker.upperBound...])
        } else {
            base64 = trimmed
        }
        return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
    }

    private static func trustedLocalURL(from value: String, trustedRoot: URL?) -> URL? {
        guard let trustedRoot else { return nil }
        let candidate: URL
        if let url = URL(string: value), let scheme = url.scheme {
            guard scheme.lowercased() == "file" else { return nil }
            candidate = url
        } else if value.hasPrefix("/") {
            candidate = URL(fileURLWithPath: value)
        } else {
            candidate = URL(fileURLWithPath: value, relativeTo: trustedRoot)
        }
        let root = trustedRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard resolved.path == rootPath || resolved.path.hasPrefix(rootPrefix) else { return nil }
        return resolved
    }

    private static func displayURL(from value: String) -> URL? {
        if let url = URL(string: value), url.scheme != nil { return url }
        return URL(fileURLWithPath: value)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
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
