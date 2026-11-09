import SwiftUI

struct PendingReviewRail: View {
    @Environment(\.designScale) private var scale
    @Bindable var pendingReview: PendingReview
    @Binding var collapsed: Bool
    var onSelectComment: (StagedComment) -> Void = { _ in }
    var onFinish: () -> Void = {}

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if collapsed {
                collapsedBody
            } else {
                expandedBody
            }
        }
        .frame(width: collapsed ? 44 : 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.color("bg-2"))
        .overlay(Rectangle().fill(theme.color("line")).frame(width: 0.5), alignment: .leading)
        .accessibilityIdentifier("pending-review-rail")
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            railHeader
            Divider().overlay(theme.color("line"))
            commentList
            Spacer(minLength: 0)
            Divider().overlay(theme.color("line"))
            finishButton
        }
    }

    private var collapsedBody: some View {
        VStack(spacing: scale.space[2]) {
            collapseButton
                .padding(.top, scale.space[2])
            Text("\(pendingReview.staged.count)")
                .font(scale.meta.font(weight: .semibold, design: .monospaced))
                .foregroundColor(theme.color("warn"))
                .frame(width: 26, height: 22)
                .background(theme.color("warn").opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
                .accessibilityLabel("\(pendingReview.staged.count) pending review comments")
            Button {
                onFinish()
            } label: {
                Image(systemName: "arrow.up.doc")
                    .font(scale.meta.font(weight: .medium))
                    .foregroundColor(theme.color("fg-muted"))
                    .frame(width: 26, height: 24)
                    .background(theme.color("bg-3"))
                    .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
            }
            .buttonStyle(.plain)
            .help("Finish review")
            Spacer(minLength: 0)
        }
    }

    private var railHeader: some View {
        HStack {
            Text("Review (\(pendingReview.staged.count) comment\(pendingReview.staged.count == 1 ? "" : "s"))")
                .font(scale.meta.font(weight: .semibold))
                .foregroundColor(theme.color("fg"))
            Spacer(minLength: 0)
            collapseButton
        }
        .padding(.horizontal, scale.space[3])
        .padding(.vertical, scale.space[2])
    }

    private var collapseButton: some View {
        Button {
            collapsed.toggle()
        } label: {
            Image(systemName: collapsed ? "sidebar.right" : "sidebar.trailing")
                .font(scale.meta.font(weight: .medium))
                .foregroundColor(theme.color("fg-muted"))
                .frame(width: 26, height: 24)
                .background(theme.color("bg-3"))
                .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Expand review rail" : "Collapse review rail")
    }

    private var commentList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: scale.space[2]) {
                    ForEach(pendingReview.staged) { comment in
                        commentRow(comment)
                            .id(comment.id)
                    }
                }
                .padding(.horizontal, scale.space[3])
                .padding(.vertical, scale.space[2])
            }
        }
    }

    private func commentRow(_ comment: StagedComment) -> some View {
        HStack(alignment: .top, spacing: scale.space[2]) {
            Button {
                onSelectComment(comment)
            } label: {
                VStack(alignment: .leading, spacing: scale.space[0]) {
                    Text(commentLabel(comment))
                        .font(scale.caption.font(weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.color("fg-dim"))
                        .lineLimit(1)
                    Text(comment.body)
                        .font(scale.metaFont)
                        .foregroundColor(theme.color("fg"))
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pending-review-comment-select-\(comment.id)")
            .help("Show in diff")
            Button {
                pendingReview.remove(id: comment.id)
            } label: {
                Image(systemName: "xmark")
                    .font(scale.caption.font(weight: .semibold))
                    .foregroundColor(theme.color("fg-muted"))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pending-review-comment-delete-\(comment.id)")
            .help("Remove staged comment")
        }
        .padding(.horizontal, scale.space[2])
        .padding(.vertical, scale.space[1])
        .background(theme.color("bg-1"))
        .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
        .contentShape(Rectangle())
    }

    private func commentLabel(_ comment: StagedComment) -> String {
        let path = (comment.filePath as NSString).lastPathComponent
        if let line = comment.line {
            return "\(path):\(line)"
        }
        return path
    }

    private var finishButton: some View {
        Button {
            onFinish()
        } label: {
            HStack {
                Text("Finish review")
                Image(systemName: "arrow.up")
                    .font(scale.caption.font(weight: .semibold))
            }
            .font(scale.meta.font(weight: .semibold))
            .foregroundColor(.accentColor)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, scale.space[3])
        .padding(.vertical, scale.space[2])
    }
}
