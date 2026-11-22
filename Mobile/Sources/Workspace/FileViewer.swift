import AlasHighlight
import AlasRemoteKit
import SwiftUI

/// One file pushed from the Files tab: an image as itself, markdown rendered or as source, any
/// other text with line numbers and syntax colour.
struct FileViewer: View {
    let workspace: SessionWorkspace
    let session: TranscriptSession
    let openPreview: (URL) -> OpenURLAction.Result?
    @State private var showSource = false
    @State private var showHistory = false
    /// Why a link the user followed didn't open.
    @State private var linkError: String?
    /// False once the viewer leaves the stack; a full-screen image over it leaves it true.
    @Environment(\.isPresented) private var isPresented

    private var path: String { workspace.file?.path ?? "" }

    var body: some View {
        Group {
            if FileKind(path: path) == .image {
                // Read as an image of the worktree, as the transcript reads one, not as text.
                let source = workspace.imageSource(forRepositoryPath: path)
                ScrollView {
                    TranscriptImage(id: "file:\(source)", source: source, label: name, session: session).padding()
                }
                // Read again on each opening, so an image changed since shows as it is now.
                .task(id: source) { session.forgetHostImage(source) }
            } else {
                switch workspace.file?.1 {
                case .loaded(let reply):
                    if FileKind(path: path) == .markdown, !showSource {
                        ScrollView {
                            AgentMarkdown(id: "file:\(path)", text: reply.text, session: session,
                                          resolve: { workspace.imageSource(forRepositoryPath: RemoteTranscriptLink.imageSource($0, besideFile: path)) })
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                // A file link opens in this viewer, a relative one taken from this file's folder.
                                .environment(\.openURL, OpenURLAction { url in
                                    if let result = openPreview(url) { return result }
                                    let relative = url.scheme == nil && url.host == nil && !url.path.hasPrefix("/")
                                    // A link to a heading of this document (`#install`) keeps it open.
                                    if relative, url.path.isEmpty { return .handled }
                                    if let checkout = workspace.checkout {
                                        // `path` is relative to the focused member; the agent's links resolve from the checkout root.
                                        guard let owner = workspace.pushedBy else { return .handled }
                                        let memberRoot = workspace.focusedMember?.worktree.path ?? checkout.rootPath
                                        let target = relative ? URL(fileURLWithPath: RemoteTranscriptLink.worktreePath(url.path, besideFile: path),
                                                                    relativeTo: URL(fileURLWithPath: memberRoot + "/"))
                                            : url
                                        switch RemoteTranscriptLink.route(target.absoluteURL, worktreeRoot: checkout.rootPath) {
                                        case .file(let file):
                                            if !workspace.openCheckoutLink(rootRelative: file, by: owner) { linkError = SessionWorkspace.linkOutsideMembers }
                                            return .handled
                                        case .system: return .systemAction
                                        case .discard: return .discarded
                                        }
                                    }
                                    let target = relative ? URL(fileURLWithPath: RemoteTranscriptLink.worktreePath(url.path, besideFile: path),
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
            if workspace.canReadFileHistory {
                ToolbarItem(placement: .secondaryAction) {
                    Button("History", systemImage: "clock.arrow.circlepath") { showHistory = true }
                }
            }
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
        .navigationDestination(isPresented: $showHistory) { FileHistoryView(workspace: workspace, path: path) }
        .alert("Couldn't open that", isPresented: Binding { linkError != nil } set: { if !$0 { linkError = nil } }) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(linkError ?? "")
        }
        // Backstop for a pop that skips the destination binding (a stack reset to the root).
        .onDisappear {
            guard !isPresented else { return }
            MarkdownBlockCache.shared.remove(ids: ["file:\(path)"])
            workspace.closeFile()
        }
    }

    private var name: String { path.split(separator: "/").last.map(String.init) ?? "File" }
}

/// The commits that touched a file; one opens its diff of the file as it was named then.
private struct FileHistoryView: View {
    let workspace: SessionWorkspace
    let path: String
    @State private var history: Load<(entries: [HostFileHistoryEntry], truncated: Bool)> = .loading

    var body: some View {
        Group {
            switch history {
            case .loaded(let found) where found.entries.isEmpty:
                ContentUnavailableView("No Commits", systemImage: "clock", description: Text("No commit has touched this file yet."))
            case .loaded(let found):
                List {
                    ForEach(found.entries, id: \.commit.sha) { entry in
                        Button { open(entry) } label: { row(entry) }
                    }
                    if found.truncated {
                        Text("Older commits aren't shown.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            case .failed(let message):
                ContentUnavailableView(message, systemImage: "exclamationmark.triangle")
            default:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            switch await workspace.fileHistory(path) {
            case .success(let found): history = .loaded(found)
            case .failure(let failure): history = .failed(failure.message)
            }
        }
        .commitReviewDestination(workspace)
    }

    private func row(_ entry: HostFileHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.commit.subject).font(.body).foregroundStyle(.primary).lineLimit(2)
            HStack(spacing: 6) {
                Text(entry.commit.shortSha).monospaced()
                Text(entry.commit.author)
                Text(entry.commit.date, style: .relative)
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if entry.pathAtCommit != path {
                Label(entry.pathAtCommit, systemImage: "arrow.turn.down.right").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func open(_ entry: HostFileHistoryEntry) {
        guard let owner = workspace.pushedBy else { return }
        workspace.openReview(.commit(sha: entry.commit.sha), focus: ReviewEntryID(namespace: "commit", path: entry.pathAtCommit), by: owner)
    }
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
