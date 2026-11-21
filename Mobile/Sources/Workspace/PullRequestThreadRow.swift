import AlasRemoteKit
import SwiftUI

/// One pull or merge request thread as its provider shows it: where it sits, its state and its comments.
struct PullRequestThreadRow: View {
    let thread: RemoteProviderThread

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(location).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if thread.isOutdated { badge("Outdated") }
                if thread.isResolved { badge("Resolved") }
            }
            .foregroundStyle(.secondary)
            ForEach(Array(thread.comments.enumerated()), id: \.offset) { index, comment in
                CommentBody(comment: comment, dimmed: !isOpen)
                    .padding(.leading, index == 0 ? 0 : 12)
                    .overlay(alignment: .leading) {
                        if index > 0 { Rectangle().fill(.quaternary).frame(width: 2) }
                    }
            }
        }
        .padding(.vertical, 4)
    }

    /// Open threads first, then by file and line.
    static func order(_ a: RemoteProviderThread, _ b: RemoteProviderThread) -> Bool {
        func key(_ t: RemoteProviderThread) -> (Int, String, Int) { (t.isResolved || t.isOutdated ? 1 : 0, t.path ?? "", t.line ?? 0) }
        return key(a) < key(b)
    }

    private var isOpen: Bool { !thread.isResolved && !thread.isOutdated }

    private var location: String {
        guard let path = thread.path else { return "Conversation" }
        return thread.line.map { "\(path):\($0)" } ?? path
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

private struct CommentBody: View {
    let comment: RemoteProviderThread.Comment
    let dimmed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(comment.author ?? "Unknown").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(markdown).font(.subheadline).foregroundStyle(dimmed ? .secondary : .primary)
        }
    }

    private var markdown: AttributedString {
        (try? AttributedString(markdown: comment.body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(comment.body)
    }
}
