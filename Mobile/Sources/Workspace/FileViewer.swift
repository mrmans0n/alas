import AlasRemoteKit
import SwiftUI

/// One file's text with line numbers, pushed from the Files tab.
struct FileViewer: View {
    let workspace: SessionWorkspace

    var body: some View {
        Group {
            switch workspace.file?.1 {
            case .loaded(let reply):
                FileContent(reply: reply)
            case .failed(let message):
                ContentUnavailableView(message, systemImage: "exclamationmark.triangle")
            default:
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(workspace.file?.path.split(separator: "/").last.map(String.init) ?? "File")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemBackground))
        // Backstop for a pop that skips the destination binding (a stack reset to the root).
        .onDisappear { workspace.closeFile() }
    }
}

private struct FileContent: View {
    let reply: FileReply
    private let chunks: [AttributedString]
    private let linesTruncated: Bool

    /// Same as the web client's cap on rendered rows.
    private static let maxLines = 5000

    init(reply: FileReply) {
        self.reply = reply
        let all = reply.text.split(separator: "\n", omittingEmptySubsequences: false)
        linesTruncated = all.count > Self.maxLines
        let lines = all.prefix(Self.maxLines)
        let width = String(lines.count).count
        chunks = stride(from: 0, to: lines.count, by: MarkdownBlock.codeChunkLines).map { start in
            var text = AttributedString()
            for i in start ..< min(start + MarkdownBlock.codeChunkLines, lines.count) {
                let number = String(i + 1)
                var gutter = AttributedString((i == start ? "" : "\n") + String(repeating: " ", count: width - number.count) + number + "  ")
                gutter.foregroundColor = .secondary
                text += gutter + AttributedString(String(lines[lines.startIndex + i]))
            }
            return text
        }
    }

    var body: some View {
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
    }
}
