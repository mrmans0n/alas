import AlasHighlight
import AlasRemoteKit
import SwiftUI

/// One file pushed from the Files tab: an image as itself, markdown rendered or as source, any
/// other text with line numbers and syntax colour.
struct FileViewer: View {
    let workspace: SessionWorkspace
    let session: TranscriptSession
    @State private var showSource = false
    /// False once the viewer leaves the stack; a full-screen image over it leaves it true.
    @Environment(\.isPresented) private var isPresented

    private var path: String { workspace.file?.path ?? "" }

    var body: some View {
        Group {
            if FileKind(path: path) == .image {
                // Read as an image of the worktree, as the transcript reads one, not as text.
                ScrollView {
                    TranscriptImage(id: "file:\(path)", source: path, label: name, session: session).padding()
                }
            } else {
                switch workspace.file?.1 {
                case .loaded(let reply):
                    if FileKind(path: path) == .markdown, !showSource {
                        ScrollView {
                            AgentMarkdown(id: "file:\(path)", text: reply.text, session: session,
                                          resolve: { FileKind.worktreePath($0, besideFile: path) })
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                // A file link opens in this viewer, a relative one taken from this file's folder.
                                .environment(\.openURL, OpenURLAction { url in
                                    let relative = url.scheme == nil && url.host == nil && !url.path.hasPrefix("/")
                                    let target = relative ? URL(fileURLWithPath: FileKind.worktreePath(url.path, besideFile: path),
                                                                relativeTo: session.worktreeRoot.map { URL(fileURLWithPath: $0 + "/") })
                                        : url
                                    switch RemoteTranscriptLink.route(target.absoluteURL, worktreeRoot: session.worktreeRoot) {
                                    case .file(let file):
                                        if let owner = workspace.pushedBy { workspace.openFile(file, by: owner) }
                                        return .handled
                                    case .system: return .systemAction
                                    case .discard: return .discarded
                                    }
                                })
                        }
                    } else {
                        FileContent(reply: reply, path: path)
                    }
                case .failed(let message):
                    ContentUnavailableView(message, systemImage: "exclamationmark.triangle")
                default:
                    ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if FileKind(path: path) == .markdown {
                ToolbarItem(placement: .primaryAction) {
                    Picker("View", selection: $showSource) {
                        Text("Preview").tag(false)
                        Text("Source").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .background(Color(.systemBackground))
        // Backstop for a pop that skips the destination binding (a stack reset to the root).
        .onDisappear {
            guard !isPresented else { return }
            MarkdownBlockCache.shared.remove(ids: ["file:\(path)"])
            workspace.closeFile()
        }
    }

    private var name: String { path.split(separator: "/").last.map(String.init) ?? "File" }
}

/// How the viewer shows a file, by its extension.
enum FileKind: Equatable {
    case image, markdown, text

    init(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "ico": self = .image
        case "md", "markdown", "mdown", "mkd": self = .markdown
        default: self = .text
        }
    }

    /// `ref`, from a document at worktree path `file`, as a worktree path: a relative reference is
    /// taken from the document's folder, `..` included; an absolute one or a URL is left alone.
    static func worktreePath(_ ref: String, besideFile file: String) -> String {
        guard !ref.hasPrefix("/"), URL(string: ref)?.scheme == nil else { return ref }
        let folder = (file as NSString).deletingLastPathComponent
        let joined = URL(fileURLWithPath: "/" + (folder as NSString).appendingPathComponent(ref)).standardized.path
        return String(joined.dropFirst())
    }
}

private struct FileContent: View {
    let reply: FileReply
    let path: String
    private let lines: [String]
    private let linesTruncated: Bool
    /// Each line's syntax spans; empty until tokenized, or without a grammar.
    @State private var spans: [[HighlightSpan]] = []
    @Environment(\.colorScheme) private var colorScheme

    /// Same as the web client's cap on rendered rows.
    private static let maxLines = 5000

    init(reply: FileReply, path: String) {
        self.reply = reply
        self.path = path
        let all = reply.text.split(separator: "\n", omittingEmptySubsequences: false)
        linesTruncated = all.count > Self.maxLines
        lines = all.prefix(Self.maxLines).map(String.init)
    }

    var body: some View {
        let chunks = Self.chunks(lines, spans: spans, tokens: spans.isEmpty ? nil : ThemeTokens.forScheme(colorScheme))
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(chunks.indices, id: \.self) { Text(chunks[$0]).fixedSize(horizontal: true, vertical: false) }
                if reply.truncated {
                    Text("File truncated.").font(.footnote).foregroundStyle(.secondary).padding()
                }
                if linesTruncated {
                    Text("File truncated — too many lines to show.").font(.footnote).foregroundStyle(.secondary).padding()
                }
            }
            .font(.system(.footnote, design: .monospaced))
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
        }
        // Content smaller than the viewport sits top-left, not centred.
        .defaultScrollAnchor(.topLeading, for: .alignment)
        // Tokenized off the main actor; the file shows plain until then. Keyed by the text, so a
        // reread file never wears the previous text's spans.
        .task(id: reply.text) {
            spans = []
            let lines = Array(lines.prefix(DiffHunksView.expandedLineLimit))
            let path = path
            let found = await Task.detached(priority: .userInitiated) {
                DiffHunksView.spans(forLines: lines, path: path)
            }.value
            if !Task.isCancelled { spans = found }
        }
    }

    /// Line-numbered text in `MarkdownBlock.codeChunkLines` pieces, coloured where `spans` reaches.
    private static func chunks(_ lines: [String], spans: [[HighlightSpan]], tokens: ThemeTokens?) -> [AttributedString] {
        let width = String(lines.count).count
        return stride(from: 0, to: lines.count, by: MarkdownBlock.codeChunkLines).map { start in
            var text = AttributedString()
            for i in start ..< min(start + MarkdownBlock.codeChunkLines, lines.count) {
                let number = String(i + 1)
                var gutter = AttributedString((i == start ? "" : "\n") + String(repeating: " ", count: width - number.count) + number + "  ")
                gutter.foregroundColor = .secondary
                let body = if let tokens, i < spans.count { tokens.attributed(lines[i], spans: spans[i]) } else { AttributedString(lines[i]) }
                text += gutter + body
            }
            return text
        }
    }
}
