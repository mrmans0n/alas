import AlasHighlight
import AlasRemoteKit
import SwiftUI

/// One file's diff, pushed from the Changes list.
struct DiffView: View {
    let workspace: SessionWorkspace
    @State private var discarding: (index: Int, hunk: RemoteDiffHunk)?
    @State private var error: String?

    var body: some View {
        Group {
            switch workspace.diff?.1 {
            case .loaded(let reply):
                DiffContent(reply: reply, path: workspace.diff?.key.path ?? "",
                            actions: workspace.canChangeHunks ? hunkActions(workspace.diff?.key.stage) : [],
                            busy: workspace.gitRunning != nil) { action, index, hunk in
                    if action == .discard { discarding = (index, hunk) } else { change(action, index, hunk) }
                }
            case .failed(let message):
                ContentUnavailableView(message, systemImage: "exclamationmark.triangle")
            default:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(workspace.diff?.key.path.split(separator: "/").last.map(String.init) ?? "Diff")
        .navigationSubtitle(workspace.diff.map { $0.key.sha.map { String($0.prefix(7)) } ?? $0.key.stage?.capitalized ?? "" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemBackground))
        .confirmationDialog("Discard this hunk?", isPresented: Binding { discarding != nil } set: { if !$0 { discarding = nil } },
                            titleVisibility: .visible, presenting: discarding) { held in
            Button("Discard", role: .destructive) { change(.discard, held.index, held.hunk) }
        } message: { _ in
            Text("Its changes are lost.")
        }
        .alert("Couldn't do that", isPresented: Binding { error != nil } set: { if !$0 { error = nil } }) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
        // Backstop for a pop that skips the destination binding (a stack reset to the root).
        .onDisappear { workspace.closeDiff() }
    }

    /// As the Mac: stage or discard from the unstaged diff, unstage from the staged one.
    private func hunkActions(_ stage: String?) -> [RemoteHunkAction] {
        switch stage {
        case "unstaged": [.stage, .discard]
        case "staged": [.unstage]
        default: []
        }
    }

    private func change(_ action: RemoteHunkAction, _ index: Int, _ hunk: RemoteDiffHunk) {
        Task { error = await workspace.changeHunk(action, index: index, hunk) }
    }
}

private struct DiffContent: View {
    let reply: DiffReply
    let path: String
    /// What each hunk's menu offers; empty for none.
    let actions: [RemoteHunkAction]
    let busy: Bool
    let act: (RemoteHunkAction, Int, RemoteDiffHunk) -> Void
    /// Each line's syntax spans, counted across hunks; empty until tokenized, or without a grammar.
    @State private var spans: [[HighlightSpan]] = []
    @Environment(\.colorScheme) private var colorScheme

    private enum Block: Identifiable {
        case header(id: Int, index: Int, RemoteDiffHunk)
        case lines(id: Int, AttributedString)

        var id: Int {
            switch self {
            case .header(let id, _, _), .lines(let id, _): id
            }
        }
    }

    /// Lines per `Text`, as `MarkdownBlock.code`: a 2,000-line diff stays a few dozen cheap views.
    private static let chunkLines = MarkdownBlock.codeChunkLines

    var body: some View {
        if reply.hunks.isEmpty {
            ContentUnavailableView(reply.metadataNote ?? "No changes in this file.", systemImage: "doc.text")
        } else {
            let blocks = Self.blocks(reply.hunks, spans: spans, tokens: ThemeTokens.forScheme(colorScheme))
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(blocks) { block in
                        switch block {
                        case .header(_, let index, let hunk):
                            HStack(spacing: 8) {
                                if !actions.isEmpty { menu(index, hunk) }
                                Text(hunk.header).foregroundStyle(.secondary).fixedSize(horizontal: true, vertical: false)
                            }
                            .padding(.vertical, 6).padding(.horizontal, 8)
                        case .lines(_, let text):
                            Text(text).fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    if reply.truncated {
                        Text("Diff truncated — open this file on the desktop to see the rest.")
                            .font(.footnote).foregroundStyle(.secondary).padding()
                    }
                }
                .font(.system(.footnote, design: .monospaced))
                .padding(.vertical, 8)
            }
            // Content smaller than the viewport sits top-left, not centred.
            .defaultScrollAnchor(.topLeading, for: .alignment)
            // Tokenized off the main actor; the diff shows plain until then. Keyed by the hunks, so
            // a reply refreshed after a reconnect never wears the previous text's spans.
            .task(id: reply.hunks) {
                spans = []
                let lines = reply.hunks.flatMap(\.lines).prefix(DiffHunksView.expandedLineLimit).map(\.text)
                let path = path
                let found = await Task.detached(priority: .userInitiated) {
                    DiffHunksView.spans(forLines: lines, path: path)
                }.value
                if !Task.isCancelled { spans = found }
            }
        }
    }

    private func menu(_ index: Int, _ hunk: RemoteDiffHunk) -> some View {
        Menu {
            ForEach(actions, id: \.self) { action in
                switch action {
                case .stage: Button("Stage Hunk", systemImage: "plus.circle") { act(.stage, index, hunk) }
                case .unstage: Button("Unstage Hunk", systemImage: "minus.circle") { act(.unstage, index, hunk) }
                case .discard: Button("Discard Hunk…", systemImage: "trash", role: .destructive) { act(.discard, index, hunk) }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                // A finger-sized target around the small glyph.
                .frame(width: 44, height: 32)
                .contentShape(Rectangle())
        }
        .disabled(busy)
        .accessibilityLabel("Hunk actions")
    }

    private static func blocks(_ hunks: [RemoteDiffHunk], spans: [[HighlightSpan]], tokens: ThemeTokens) -> [Block] {
        var out: [Block] = []
        var index = 0
        for (hunkIndex, hunk) in hunks.enumerated() {
            out.append(.header(id: out.count, index: hunkIndex, hunk))
            for start in stride(from: 0, to: hunk.lines.count, by: chunkLines) {
                var text = AttributedString()
                for (i, line) in hunk.lines[start ..< min(start + chunkLines, hunk.lines.count)].enumerated() {
                    text += row(line, first: i == 0, spans: index < spans.count ? spans[index] : [], tokens: tokens)
                    index += 1
                }
                out.append(.lines(id: out.count, text))
            }
        }
        return out
    }

    private static func row(_ line: RemoteDiffLine, first: Bool, spans: [HighlightSpan], tokens: ThemeTokens) -> AttributedString {
        func number(_ n: Int?) -> String {
            let s = n.map(String.init) ?? ""
            return String(repeating: " ", count: max(0, 4 - s.count)) + s
        }
        let tint: Color? = line.kind == "add" ? .green : line.kind == "delete" ? .red : nil
        var gutter = AttributedString((first ? "" : "\n") + number(line.oldNumber) + " " + number(line.newNumber) + " ")
        gutter.foregroundColor = .secondary
        var sign = AttributedString((line.kind == "add" ? "+" : line.kind == "delete" ? "\u{2212}" : " ") + " ")
        sign.foregroundColor = tint ?? .secondary
        var body = sign + tokens.attributed(line.text, spans: spans, changedLine: tint != nil)
        if let tint { body.backgroundColor = tint.opacity(0.12) }
        var out = gutter + body
        if line.noTrailingNewline {
            var note = AttributedString("\n\\ No newline at end of file")
            note.foregroundColor = .secondary
            out += note
        }
        return out
    }
}
