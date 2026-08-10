import SwiftUI

struct DiffInlineCommentCardEditorState: Equatable {
    var isComposerOpen = false
    var replyDraft = ""
    var editingCommentID: String?
    var editDraft = ""
}

struct DiffInlineCommentCard: View {
    private enum FocusedEditor: Hashable {
        case reply
        case edit(String)
    }

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
    var onActiveChange: (Bool) -> Void = { _ in }
    var editorState: Binding<DiffInlineCommentCardEditorState>?

    @State private var isExpanded: Bool
    @State private var localEditorState = DiffInlineCommentCardEditorState()
    @State private var isHovered = false
    @FocusState private var isCardFocused: Bool
    @FocusState private var focusedEditor: FocusedEditor?

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
        canAddToReview: Bool = false,
        editorState: Binding<DiffInlineCommentCardEditorState>? = nil,
        onActiveChange: @escaping (Bool) -> Void = { _ in }
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
        self.editorState = editorState
        self.onActiveChange = onActiveChange
        // Smart default: expanded when unresolved and not outdated
        _isExpanded = State(initialValue: !thread.isResolved && !thread.isOutdated)
    }

    var body: some View {
        Group {
            if isExpanded {
                expandedView
            } else {
                collapsedPill
            }
        }
        .focusable(true)
        .focused($isCardFocused)
        .onHover { hovering in
            isHovered = hovering
            onActiveChange(Self.isActive(isHovered: hovering, isFocused: isCardFocused))
        }
        .onChange(of: isCardFocused) { _, isFocused in
            onActiveChange(Self.isActive(isHovered: isHovered, isFocused: isFocused))
        }
    }

    static func isActive(isHovered: Bool, isFocused: Bool) -> Bool {
        isHovered || isFocused
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
                    Text(DiffReviewInlineFeedbackMarkdown.plainText(first.body))
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
            if editorStateBinding.wrappedValue.isComposerOpen {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Reply")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer(minLength: 0)
                        Button("Suggest") {
                            editorStateBinding.wrappedValue.replyDraft = "```suggestion\n\n```"
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                    }
                    PairedTextEditor(
                        text: editorStateBinding.replyDraft,
                        font: .systemFont(ofSize: 11),
                        isFocused: Binding(
                            get: { focusedEditor == .reply },
                            set: { value in
                                if value {
                                    focusedEditor = .reply
                                } else if focusedEditor == .reply {
                                    focusedEditor = nil
                                }
                            }
                        )
                    )
                        .frame(minHeight: 60)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                        .onAppear {
                            focusedEditor = .reply
                        }
                    HStack(spacing: 8) {
                        Button("Comment") {
                            onReply(editorStateBinding.wrappedValue.replyDraft)
                            clearReplyComposer()
                            focusedEditor = nil
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.accentColor)

                        if canAddToReview {
                            Button("Add to review") {
                                onStageReply(editorStateBinding.wrappedValue.replyDraft)
                                clearReplyComposer()
                                focusedEditor = nil
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.accentColor)
                        }

                        Button("Cancel") {
                            clearReplyComposer()
                            focusedEditor = nil
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
                    Button("Reply") {
                        editorStateBinding.wrappedValue.isComposerOpen.toggle()
                        focusedEditor = editorStateBinding.wrappedValue.isComposerOpen ? .reply : nil
                    }
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
        if editorStateBinding.wrappedValue.editingCommentID == comment.id {
            // Edit mode for this comment
            VStack(alignment: .leading, spacing: 3) {
                Text(comment.author)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                PairedTextEditor(
                    text: editorStateBinding.editDraft,
                        font: .systemFont(ofSize: 11),
                        isFocused: Binding(
                            get: { focusedEditor == .edit(comment.id) },
                            set: { value in
                                if value {
                                    focusedEditor = .edit(comment.id)
                                } else if focusedEditor == .edit(comment.id) {
                                    focusedEditor = nil
                                }
                            }
                        )
                    )
                    .frame(minHeight: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .onAppear {
                        focusedEditor = .edit(comment.id)
                    }
                HStack(spacing: 8) {
                    Button("Save") {
                        onEdit(comment, editorStateBinding.wrappedValue.editDraft)
                        clearEditComposer()
                        focusedEditor = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)

                    Button("Cancel") {
                        clearEditComposer()
                        focusedEditor = nil
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
                            editorStateBinding.wrappedValue.editingCommentID = comment.id
                            editorStateBinding.wrappedValue.editDraft = comment.body
                            focusedEditor = .edit(comment.id)
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

    private var editorStateBinding: Binding<DiffInlineCommentCardEditorState> {
        editorState ?? $localEditorState
    }

    private func clearReplyComposer() {
        editorStateBinding.wrappedValue.replyDraft = ""
        editorStateBinding.wrappedValue.isComposerOpen = false
    }

    private func clearEditComposer() {
        editorStateBinding.wrappedValue.editingCommentID = nil
        editorStateBinding.wrappedValue.editDraft = ""
    }

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
