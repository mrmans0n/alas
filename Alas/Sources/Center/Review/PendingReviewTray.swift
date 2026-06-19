import SwiftUI

struct PendingReviewRail: View {
    @Bindable var pendingReview: PendingReview
    @Binding var collapsed: Bool
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
        VStack(spacing: 8) {
            collapseButton
                .padding(.top, 8)
            Text("\(pendingReview.staged.count)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.color("warn"))
                .frame(width: 26, height: 22)
                .background(theme.color("warn").opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("\(pendingReview.staged.count) pending review comments")
            Button {
                onFinish()
            } label: {
                Image(systemName: "arrow.up.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.color("fg-muted"))
                    .frame(width: 26, height: 24)
                    .background(theme.color("bg-3"))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Finish review")
            Spacer(minLength: 0)
        }
    }

    private var railHeader: some View {
        HStack {
            Text("Review (\(pendingReview.staged.count) comment\(pendingReview.staged.count == 1 ? "" : "s"))")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            Spacer(minLength: 0)
            collapseButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var collapseButton: some View {
        Button {
            collapsed.toggle()
        } label: {
            Image(systemName: collapsed ? "sidebar.right" : "sidebar.trailing")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.color("fg-muted"))
                .frame(width: 26, height: 24)
                .background(theme.color("bg-3"))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Expand review rail" : "Collapse review rail")
    }

    private var commentList: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pendingReview.staged) { comment in
                    commentRow(comment)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func commentRow(_ comment: StagedComment) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(commentLabel(comment))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.color("fg-dim"))
                    .lineLimit(1)
                Text(comment.body)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Button {
                pendingReview.remove(id: comment.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.color("fg-muted"))
            }
            .buttonStyle(.plain)
        }
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
                    .font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.accentColor)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
