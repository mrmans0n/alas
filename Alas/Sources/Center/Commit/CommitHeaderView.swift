import SwiftUI

struct CommitHeaderView: View {
    static let maxExpandedHeight: CGFloat = 180

    let details: CommitDetails
    @Binding var expanded: Bool
    var revisionExpression: String?
    var pendingCheckout: TrackedRevisionCandidate?
    var isRefreshingRevision = false
    var revisionError: String?
    var onFollowRevision: (() -> Void)?
    var onEditRevision: (() -> Void)?
    var onStopFollowingRevision: (() -> Void)?
    var onAcceptPendingCheckout: (() -> Void)?

    @Environment(\.theme) private var theme
    @StateObject private var copyFeedback = CopyFeedbackState()
    @State private var shaHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            compactRow
            if showsRevisionRow {
                revisionRow
                    .padding(.top, 8)
            }
            if expanded {
                ScrollView(.vertical) {
                    expandedBlock
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: Self.maxExpandedHeight)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
        .copyFeedbackOverlay(message: copyFeedback.message)
    }

    private var showsRevisionRow: Bool {
        revisionExpression != nil ||
            pendingCheckout != nil ||
            isRefreshingRevision ||
            revisionError != nil ||
            onFollowRevision != nil
    }

    private var compactRow: some View {
        HStack(spacing: 8) {
            if let tag = details.info.conventionalTag {
                Text(tag)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.color("accent"))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(theme.color("accent").opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Text(details.info.subject)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.color("fg"))
                .lineLimit(1)
            Text(details.info.shortSha)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(shaHovering ? theme.color("accent") : theme.color("fg-faint"))
                .onTapGesture {
                    copyToPasteboard(details.info.sha, feedback: "Copied SHA")
                }
                .onHover { hovering in
                    shaHovering = hovering
                }
                .pointingHandCursor()
                .help("Click to copy SHA")
            Text("·").foregroundColor(theme.color("fg-faint"))
            Text(details.info.author)
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-dim"))
            Text("·").foregroundColor(theme.color("fg-faint"))
            Text(relativeTime(details.info.date))
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-dim"))
            Spacer()
            Button { expanded.toggle() } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-dim"))
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Toggle commit details")
    }

    private var revisionRow: some View {
        HStack(spacing: 8) {
            if let revisionExpression {
                Text("\(revisionExpression) -> \(details.info.shortSha)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.color("fg-muted"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("commit-revision-following-label")
            } else if onFollowRevision != nil {
                Text("Fixed commit")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-muted"))
            }

            if isRefreshingRevision {
                Text("Refreshing")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-muted"))
                    .accessibilityIdentifier("commit-revision-updating")
            }

            if let pendingCheckout {
                Text("Paused on checkout to \(pendingCheckout.branch)")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("warn"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("commit-revision-pending-checkout")
                Button("Update") {
                    onAcceptPendingCheckout?()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityIdentifier("commit-revision-accept-checkout")
            }

            if let revisionError, !revisionError.isEmpty {
                Text(revisionError)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("del"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("commit-revision-error")
            }

            Spacer(minLength: 8)

            if revisionExpression == nil, let onFollowRevision {
                Button("Follow Revision…", action: onFollowRevision)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityIdentifier("commit-revision-follow")
            } else {
                if let onEditRevision {
                    Button("Edit…", action: onEditRevision)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .accessibilityIdentifier("commit-revision-edit")
                }
                if let onStopFollowingRevision {
                    Button("Stop", action: onStopFollowingRevision)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .accessibilityIdentifier("commit-revision-stop")
                }
            }
        }
    }

    private var expandedBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !details.body.isEmpty {
                Text(details.body)
                    .font(.system(size: 12))
                    .lineSpacing(CenterTypography.textLineSpacing(forFontSize: 12))
                    .foregroundColor(theme.color("fg-dim"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Text("\(details.info.author) <\(details.authorEmail)>")
                Text(absoluteDate(details.info.date))
                if !details.parents.isEmpty {
                    HStack(spacing: 4) {
                        Text("parent" + (details.parents.count > 1 ? "s" : "") + ":")
                        ForEach(Array(details.parents.enumerated()), id: \.offset) { index, parent in
                            Text(parent)
                                .onTapGesture {
                                    copyToPasteboard(parent, feedback: "Copied SHA")
                                }
                                .pointingHandCursor()
                                .help("Click to copy SHA")
                            if index < details.parents.count - 1 {
                                Text(" ")
                            }
                        }
                    }
                }
                Text("\(details.files.count) file\(details.files.count == 1 ? "" : "s")")
                Text("+\(details.info.insertions)").foregroundColor(theme.color("add"))
                Text("−\(details.info.deletions)").foregroundColor(theme.color("del"))
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundColor(theme.color("fg-faint"))
        }
        .padding(.top, 8)
        .textSelection(.enabled)
    }

    private func absoluteDate(_ date: Date) -> String {
        Self.absoluteDateFormatter.string(from: date)
    }

    private func copyToPasteboard(_ text: String, feedback: String) {
        Clipboard.copy(text)
        copyFeedback.show(feedback)
    }

    private static let absoluteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
