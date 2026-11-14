import AlasRemoteKit
import SwiftUI

/// One file's diff, pushed from the Changes list.
struct DiffView: View {
    let workspace: SessionWorkspace

    var body: some View {
        Group {
            switch workspace.diff?.1 {
            case .loaded(let reply):
                DiffContent(reply: reply)
            case .failed(let message):
                ContentUnavailableView(message, systemImage: "exclamationmark.triangle")
            default:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(workspace.diff?.key.path.split(separator: "/").last.map(String.init) ?? "Diff")
        .navigationSubtitle(workspace.diff?.key.stage?.capitalized ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemBackground))
    }
}

private struct DiffContent: View {
    let reply: DiffReply
    private let blocks: [Block]

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

    init(reply: DiffReply) {
        self.reply = reply
        blocks = Self.blocks(reply.hunks)
    }

    var body: some View {
        if reply.hunks.isEmpty {
            ContentUnavailableView(reply.metadataNote ?? "No changes in this file.", systemImage: "doc.text")
        } else {
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
        }
    }

    private static func blocks(_ hunks: [RemoteDiffHunk]) -> [Block] {
        var out: [Block] = []
        for hunk in hunks {
            out.append(.header(id: out.count, hunk.header))
            for start in stride(from: 0, to: hunk.lines.count, by: chunkLines) {
                var text = AttributedString()
                for (i, line) in hunk.lines[start ..< min(start + chunkLines, hunk.lines.count)].enumerated() {
                    text += row(line, first: i == 0)
                }
                out.append(.lines(id: out.count, text))
            }
        }
        return out
    }

    private static func row(_ line: RemoteDiffLine, first: Bool) -> AttributedString {
        func number(_ n: Int?) -> String {
            let s = n.map(String.init) ?? ""
            return String(repeating: " ", count: max(0, 4 - s.count)) + s
        }
        let sign = line.kind == "add" ? "+" : line.kind == "delete" ? "\u{2212}" : " "
        var gutter = AttributedString((first ? "" : "\n") + number(line.oldNumber) + " " + number(line.newNumber) + " ")
        gutter.foregroundColor = .secondary
        var body = AttributedString(sign + " " + line.text)
        switch line.kind {
        case "add":
            body.foregroundColor = .green
            body.backgroundColor = .green.opacity(0.12)
        case "delete":
            body.foregroundColor = .red
            body.backgroundColor = .red.opacity(0.12)
        default: break
        }
        var out = gutter + body
        if line.noTrailingNewline {
            var note = AttributedString("\n\\ No newline at end of file")
            note.foregroundColor = .secondary
            out += note
        }
        return out
    }
}
