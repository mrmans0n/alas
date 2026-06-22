import SwiftUI

struct DiffInlineCommentCard: View {
    let thread: DiffInlineCommentThread
    var onReply: (String) -> Void = { _ in }
    var onResolve: () -> Void = {}
    var onUnresolve: () -> Void = {}
    var onEdit: (DiffInlineComment, String) -> Void = { _, _ in }
    var onDelete: (DiffInlineComment) -> Void = { _ in }
    var canReply: Bool = true
    var canResolve: Bool = true
    var onStageReply: (String) -> Void = { _ in }
    var canAddToReview: Bool = false

    @State private var isExpanded: Bool
    @State private var isComposerOpen = false
    @State private var replyDraft = ""
    @State private var editingCommentID: String? = nil
    @State private var editDraft = ""

    init(
        thread: DiffInlineCommentThread,
        onReply: @escaping (String) -> Void = { _ in },
        onStageReply: @escaping (String) -> Void = { _ in },
        onResolve: @escaping () -> Void = {},
        onUnresolve: @escaping () -> Void = {},
        onEdit: @escaping (DiffInlineComment, String) -> Void = { _, _ in },
        onDelete: @escaping (DiffInlineComment) -> Void = { _ in },
        canReply: Bool = true,
        canResolve: Bool = true,
        canAddToReview: Bool = false
    ) {
        self.thread = thread
        self.onReply = onReply
        self.onStageReply = onStageReply
        self.onResolve = onResolve
        self.onUnresolve = onUnresolve
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.canReply = canReply
        self.canResolve = canResolve
        self.canAddToReview = canAddToReview
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

            // Inline reply composer
            if isComposerOpen {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Reply")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer(minLength: 0)
                        Button("Suggest") {
                            replyDraft = "```suggestion\n\n```"
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                    }
                    TextEditor(text: $replyDraft)
                        .font(.system(size: 11))
                        .frame(minHeight: 60)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                    HStack(spacing: 8) {
                        Button("Comment") {
                            onReply(replyDraft)
                            replyDraft = ""
                            isComposerOpen = false
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.accentColor)

                        if canAddToReview {
                            Button("Add to review") {
                                onStageReply(replyDraft)
                                replyDraft = ""
                                isComposerOpen = false
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.accentColor)
                        }

                        Button("Cancel") {
                            replyDraft = ""
                            isComposerOpen = false
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }

            Divider()

            // Action buttons
            HStack(spacing: 8) {
                if canReply {
                    Button("Reply") { isComposerOpen.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                }

                if canResolve && !thread.isResolved {
                    Button("Resolve") { onResolve() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else if canResolve && thread.isResolved && thread.viewerCanUnresolve {
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

    @ViewBuilder
    private func commentRow(_ comment: DiffInlineComment) -> some View {
        if editingCommentID == comment.id {
            // Edit mode for this comment
            VStack(alignment: .leading, spacing: 3) {
                Text(comment.author)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                TextEditor(text: $editDraft)
                    .font(.system(size: 11))
                    .frame(minHeight: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                HStack(spacing: 8) {
                    Button("Save") {
                        onEdit(comment, editDraft)
                        editingCommentID = nil
                        editDraft = ""
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)

                    Button("Cancel") {
                        editingCommentID = nil
                        editDraft = ""
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Display mode for this comment
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: 4) {
                    Text(comment.author)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer(minLength: 0)
                    if comment.viewerCanUpdate {
                        Button {
                            editingCommentID = comment.id
                            editDraft = comment.body
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Edit comment")
                    }
                    if comment.viewerCanDelete {
                        Button {
                            onDelete(comment)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Delete comment")
                    }
                }
                DiffReviewInlineFeedbackMarkdown.view(comment.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        DiffReviewAccessibilityMarker(
                            identifier: "diff-inline-comment-markdown-\(comment.id)",
                            label: DiffReviewInlineFeedbackMarkdown.plainText(comment.body)
                        )
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
