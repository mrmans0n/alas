import SwiftUI

struct DiffInlineCommentCard: View {
    let thread: DiffInlineCommentThread
    var onReply: () -> Void = {}
    var onResolve: () -> Void = {}
    var onUnresolve: () -> Void = {}

    @State private var isExpanded: Bool

    init(
        thread: DiffInlineCommentThread,
        onReply: @escaping () -> Void = {},
        onResolve: @escaping () -> Void = {},
        onUnresolve: @escaping () -> Void = {}
    ) {
        self.thread = thread
        self.onReply = onReply
        self.onResolve = onResolve
        self.onUnresolve = onUnresolve
        // Smart default: expanded when unresolved and not outdated
        _isExpanded = State(initialValue: !thread.isResolved && !thread.isOutdated)
    }

    var body: some View {
        if isExpanded {
            expandedView
        } else {
            collapsedPill
        }
    }

    // MARK: - Collapsed pill

    private var collapsedPill: some View {
        Button {
            isExpanded = true
        } label: {
            HStack(spacing: 6) {
                Text(pillIcon)
                    .font(.system(size: 11))
                if let first = thread.comments.first {
                    Text("\(first.author):")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(first.body)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .overlay(
                Rectangle()
                    .fill(accentColor)
                    .frame(width: 3),
                alignment: .leading
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded view

    private var expandedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header tap area to collapse
            Button {
                isExpanded = false
            } label: {
                HStack(spacing: 4) {
                    Text(pillIcon)
                        .font(.system(size: 11))
                    Text(threadStatusLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)

            Divider()

            // Comments
            VStack(alignment: .leading, spacing: 10) {
                ForEach(thread.comments) { comment in
                    commentRow(comment)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            // Action buttons
            HStack(spacing: 8) {
                Button("Reply") { onReply() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)

                if !thread.isResolved {
                    Button("Resolve") { onResolve() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    Button("Unresolve") { onUnresolve() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            Rectangle()
                .fill(accentColor)
                .frame(width: 3),
            alignment: .leading
        )
    }

    // MARK: - Comment row

    private func commentRow(_ comment: DiffInlineComment) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(comment.author)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.primary)
            Text(comment.body)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private var accentColor: Color {
        if thread.isResolved {
            return Color.green.opacity(0.6)
        } else if thread.isOutdated {
            return Color.orange.opacity(0.6)
        } else {
            return Color.blue.opacity(0.6)
        }
    }

    private var pillIcon: String {
        if thread.isResolved {
            return "✓"
        } else if thread.isOutdated {
            return "⌛"
        } else {
            return "💬"
        }
    }

    private var threadStatusLabel: String {
        if thread.isResolved {
            return "Resolved"
        } else if thread.isOutdated {
            return "Outdated"
        } else {
            return "\(thread.comments.count) comment\(thread.comments.count == 1 ? "" : "s")"
        }
    }
}
