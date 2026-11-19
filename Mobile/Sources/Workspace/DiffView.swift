import AlasHighlight
import AlasRemoteKit
import SwiftUI

/// One file's diff, pushed from the Changes list.
struct DiffView: View {
    let workspace: SessionWorkspace

    var body: some View {
        Group {
            switch workspace.diff?.1 {
            case .loaded(let reply):
                DiffContent(reply: reply, path: workspace.diff?.key.path ?? "")
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
        // Backstop for a pop that skips the destination binding (a stack reset to the root).
        .onDisappear { workspace.closeDiff() }
    }
}

private struct DiffContent: View {
    let reply: DiffReply
    let path: String
    /// Each line's syntax spans, counted across hunks; empty until tokenized, or without a grammar.
    @State private var spans: [[HighlightSpan]] = []
    @Environment(\.colorScheme) private var colorScheme

    private enum Block: Identifiable {
        case header(id: Int, String)
        case lines(id: Int, AttributedString)

        var id: Int {
            switch self {
            case .header(let id, _), .lines(let id, _): id
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
                        case .header(_, let text):
                            Text(text).foregroundStyle(.secondary).padding(.vertical, 6).padding(.horizontal, 8)
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

    private static func blocks(_ hunks: [RemoteDiffHunk], spans: [[HighlightSpan]], tokens: ThemeTokens) -> [Block] {
        var out: [Block] = []
        var index = 0
        for hunk in hunks {
            out.append(.header(id: out.count, hunk.header))
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
