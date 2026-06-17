import SwiftUI

struct PendingReviewTray: View {
    @Bindable var pendingReview: PendingReview
    var onFinish: () -> Void = {}

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            trayHeader
            Divider()
            commentList
            Divider()
            finishButton
        }
        .frame(width: 280)
        .background(theme.color("bg-2"))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.color("line"), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
        .padding(12)
    }

    private var trayHeader: some View {
        HStack {
            Text("Review (\(pendingReview.staged.count) comment\(pendingReview.staged.count == 1 ? "" : "s"))")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
        .frame(maxHeight: 200)
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
