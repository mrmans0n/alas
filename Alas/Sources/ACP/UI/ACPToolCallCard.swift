import SwiftUI
import AppKit

/// Read / Search / Run / Edit tool invocation. Collapsed by default to
/// one row showing verb + target + status; expanded shows the tool's
/// full text output. While the tool is `in_progress` the right side
/// renders an animated spinner instead of a static glyph.
struct ACPToolCallCard: View {
    let toolCall: ACPMessage.ToolCall
    let messageCreatedAt: Date?
    var trustedImageRoot: URL? = nil
    /// Closure that returns the full persisted `content` for the tool call
    /// whose in-memory `content` was truncated when its row left the render
    /// window. Invoked the first time the card expands; the result is cached
    /// in `expandedContent` and rendered in place of the truncated copy.
    /// Optional — when nil (or when the lookup returns nil) the card falls
    /// back to the in-memory `toolCall.content`.
    var loadFullContent: ((String) async -> String?)? = nil
    @State private var expanded = false
    @State private var expandedContent: String? = nil
    @State private var expandedSyntax = ACPToolCallSyntaxCache()
    @State private var loadingContentToolCallId: String? = nil
    @State private var isHovering = false
    @Environment(\.theme) private var theme
    @Environment(\.acpTerminalHost) private var terminalHost

    init(
        toolCall: ACPMessage.ToolCall,
        messageCreatedAt: Date? = nil,
        trustedImageRoot: URL? = nil,
        loadFullContent: ((String) async -> String?)? = nil,
        initiallyExpanded: Bool = false
    ) {
        self.toolCall = toolCall
        self.messageCreatedAt = messageCreatedAt
        self.trustedImageRoot = trustedImageRoot
        self.loadFullContent = loadFullContent
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
                if expanded, toolCall.isContentTruncated, expandedContent == nil {
                    // First expand of an off-window truncated card: page the
                    // full content back in from SQLite via the host-provided
                    // loader. Subsequent toggles reuse the cached string.
                    let toolCallId = toolCall.toolCallId
                    loadingContentToolCallId = toolCallId
                    Task { @MainActor in
                        let loaded = await loadFullContent?(toolCallId)
                        guard loadingContentToolCallId == toolCallId else { return }
                        expandedContent = loaded
                        loadingContentToolCallId = nil
                    }
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
                    if isHovering, let messageCreatedAt {
                        Text(ACPMessageTimestampFormatter.string(for: messageCreatedAt))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.color("fg-faint"))
                            .lineLimit(1)
                    }
                    if let duration = toolCall.executionDuration {
                        Text(ACPToolCallDurationFormatter.string(for: duration))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.color("fg-faint"))
                            .lineLimit(1)
                            .accessibilityLabel("Tool duration")
                            .accessibilityValue(ACPToolCallDurationFormatter.string(for: duration))
                    }
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
            expandedSyntax.clear()
            loadingContentToolCallId = nil
        }
        .onChange(of: toolCall.contentRevision) { _, _ in
            expandedSyntax.clear()
        }
        .onHover { isHovering = $0 }
    }

    /// What to draw inside the expanded card. Prefers the just-fetched
    /// full SQLite content (set on first expand for truncated rows) and
    /// falls back to the in-memory `toolCall.content` otherwise. Live
    /// rows (`in_progress`, `pending`) are never truncated, so they
    /// always render straight from `toolCall.content`.
    private var displayContent: String {
        expandedContent ?? toolCall.content
    }

    private var displayContentSource: ACPToolCallSyntaxCache.ContentSource {
        expandedContent == nil ? .message : .expanded
    }

    private var displayContentLanguage: String? {
        if let explicit = toolCall.contentLanguage {
            return explicit
        }
        return expandedSyntax.language(
            for: .init(
                toolCallId: toolCall.toolCallId,
                contentRevision: toolCall.contentRevision,
                contentSource: displayContentSource,
                locations: toolCall.locations
            ),
            content: displayContent,
            locations: toolCall.locations
        )
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
                    ACPSyntaxHighlightedText(
                        text: displayContent,
                        explicitLanguage: displayContentLanguage,
                        fontSize: 11.5
                    )
                        .padding(.horizontal, 12).padding(.vertical, 10)
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

private final class ACPToolCallSyntaxCache {
    private var key: Key?
    private var cachedLanguage: String?

    func language(for key: Key, content: String, locations: [String]) -> String? {
        if self.key == key {
            return cachedLanguage
        }
        let language = ACPToolOutputSyntax.highlighterExtension(
            content: content,
            locations: locations
        )
        self.key = key
        cachedLanguage = language
        return language
    }

    func clear() {
        key = nil
        cachedLanguage = nil
    }

    enum ContentSource: Hashable {
        case message
        case expanded
    }

    struct Key: Hashable {
        let toolCallId: String
        let contentRevision: Int
        let contentSource: ContentSource
        let locations: [String]
    }
}

private struct ACPToolCallAssetView: View {
    let asset: ACPMessage.ToolCallAsset
    let trustedImageRoot: URL?
    @Environment(\.theme) private var theme

    var body: some View {
        switch asset.kind {
        case .image:
            if asset.canLoadImage(trustedRoot: trustedImageRoot) {
                cachedImageThumbnail
            } else if let remoteImage = remoteImageLocation {
                RemoteToolCallAssetImage(
                    host: remoteImage.host,
                    worktreeRoot: remoteImage.worktreeRoot,
                    path: remoteImage.path,
                    asset: asset
                )
            } else {
                compactRow(iconSystemName: "photo", title: asset.displayTitle, detail: asset.displayDetail)
            }
        case .resource:
            if asset.looksLikeImage, asset.canLoadImage(trustedRoot: trustedImageRoot) {
                cachedImageThumbnail
            } else if asset.looksLikeImage, let remoteImage = remoteImageLocation {
                RemoteToolCallAssetImage(
                    host: remoteImage.host,
                    worktreeRoot: remoteImage.worktreeRoot,
                    path: remoteImage.path,
                    asset: asset
                )
            } else {
                compactRow(iconSystemName: "doc.text", title: asset.displayTitle, detail: asset.displayDetail)
            }
        }
    }

    private var cachedImageThumbnail: some View {
        ACPCachedThumbnail(
            cacheKey: asset.thumbnailCacheKey(trustedRoot: trustedImageRoot),
            loadImage: { asset.loadedImage(trustedRoot: trustedImageRoot) }
        ) { image in
            imageThumbnail(image)
                .help(asset.displayText)
        } placeholder: {
            imagePlaceholder
                .help(asset.displayText)
        } failure: {
            compactRow(iconSystemName: "photo", title: asset.displayTitle, detail: asset.displayDetail)
        }
    }

    private var remoteImageLocation: (host: String, worktreeRoot: String, path: String)? {
        guard let trustedImageRoot, trustedImageRoot.isRemoteAlasPath,
              let host = RemoteHostRegistry.shared.host(forPath: trustedImageRoot.path),
              let uri = asset.uri,
              let path = ACPToolCallCard.trustedRemotePath(
                from: uri,
                trustedRoot: trustedImageRoot
              )
        else { return nil }
        return (host, trustedImageRoot.standardizedFileURL.path, path)
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

    private var imagePlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.color("bg-1").opacity(0.7))
            Image(systemName: "photo")
                .font(.system(size: 20))
                .foregroundStyle(theme.color("fg-faint"))
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

private struct RemoteToolCallAssetImage: View {
    let host: String
    let worktreeRoot: String
    let path: String
    let asset: ACPMessage.ToolCallAsset
    @State private var image: NSImage?
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if let image {
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
            } else {
                placeholder
            }
        }
        .help(asset.displayText)
        .task(id: "\(host)\u{0}\(path)") {
            image = nil
            guard (try? await ACPRemoteFileServer(host: host, worktreeRoot: worktreeRoot)
                .verifyRemoteContainment(path: path)) != nil
            else { return }
            guard let data = await RemoteImageCache.shared.imageData(host: host, path: path),
                  !Task.isCancelled
            else { return }
            image = NSImage(data: data)
        }
    }

    private var placeholder: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .font(.system(size: 12))
                .foregroundStyle(theme.color("accent"))
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(asset.displayTitle)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = asset.displayDetail {
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
    }
}

extension ACPToolCallCard {
    /// Resolves a remote tool asset under its worktree using the same lexical
    /// containment rule as ACP remote file serving. Remote symlinks are not
    /// resolved here because doing so would require an SSH round trip.
    static func trustedRemotePath(from value: String, trustedRoot: URL) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if let url = URL(string: trimmed), let scheme = url.scheme {
            guard scheme.lowercased() == "file" else { return nil }
            candidate = url.path
        } else if trimmed.hasPrefix("/") {
            candidate = trimmed
        } else {
            candidate = trustedRoot.path + "/" + trimmed
        }

        let root = trustedRoot.standardizedFileURL.path
        return try? ACPRemoteFileServer(host: "", worktreeRoot: root)
            .lexicallyResolveInsideWorktree(path: candidate)
    }
}

extension ACPMessage.ToolCallAsset {
    var looksLikeImage: Bool {
        if mimeType?.lowercased().hasPrefix("image/") == true { return true }
        guard let candidate = nonEmpty(uri) ?? nonEmpty(name) else { return false }
        switch URL(fileURLWithPath: candidate).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "webp":
            return true
        default:
            return false
        }
    }

    func canLoadImage(trustedRoot: URL?) -> Bool {
        if data != nil {
            return true
        }
        guard let uri = nonEmpty(uri) else { return false }
        if Self.isDataURI(uri) {
            return true
        }
        return Self.trustedLocalURL(from: uri, trustedRoot: trustedRoot) != nil
    }

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

    func thumbnailCacheKey(trustedRoot: URL?) -> String {
        if let data = nonEmpty(data) {
            return "data:\(data.hashValue)"
        }
        if let uri = nonEmpty(uri), Self.isDataURI(uri) {
            return "data-uri:\(uri.hashValue)"
        }
        if let uri = nonEmpty(uri), let url = Self.trustedLocalURL(from: uri, trustedRoot: trustedRoot) {
            return ACPThumbnailImageCache.fileCacheKey(for: url)
        }
        return "asset:\(hashValue)"
    }

    var displayTitle: String {
        if let name = nonEmpty(name) {
            return name
        }
        if let uri = nonEmpty(uri) {
            if Self.isDataURI(uri) {
                return kind == .image ? "Image" : "Resource"
            }
            if let url = Self.displayURL(from: uri), !url.lastPathComponent.isEmpty {
                return url.lastPathComponent
            }
            return uri
        }
        return kind == .image ? "Image" : "Resource"
    }

    var displayDetail: String? {
        guard let uri = nonEmpty(uri), uri != displayTitle else { return nil }
        guard !Self.isDataURI(uri) else { return nil }
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

    private static func isDataURI(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("data:")
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
            candidate = trustedRoot.appendingPathComponent(value)
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
